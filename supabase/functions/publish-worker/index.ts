import { createClient } from "npm:@supabase/supabase-js@2";

type Json = Record<string, unknown>;
type Job = { id:string; organization_id:string; content_item_id:string; platform_variant_id:string; social_connection_id:string; content_revision:number; state:string; provider_job_id:string|null; provider_payload:Json; attempt:number; max_attempts:number };
type Credential = { ciphertext:string; organizationId:string; brandId:string; connectionId:string; accountId:string };
// deno-lint-ignore no-explicit-any
type Db = any;

const env = (name:string) => { const value=Deno.env.get(name)?.trim(); if(!value) throw new Error(`${name} is missing`); return value; };
const json = (value:unknown,status=200) => new Response(JSON.stringify(value),{status,headers:{"content-type":"application/json"}});
const fromBase64Url = (value:string) => Uint8Array.from(atob(value.replaceAll("-","+").replaceAll("_","/").padEnd(Math.ceil(value.length/4)*4,"=")),c=>c.charCodeAt(0));
const fromBase64 = (value:string) => Uint8Array.from(atob(value),c=>c.charCodeAt(0));

class PublishError extends Error {
  constructor(public code:string,message:string,public retryable:boolean){super(message);}
}

async function decrypt(envelope:string,credential:Credential){
  const [version,iv,tag,ciphertext,extra]=envelope.split(".");
  if(version!=="v1"||!iv||!tag||!ciphertext||extra!==undefined) throw new PublishError("credential_invalid","Instagram credentials could not be read. Reconnect Instagram.",false);
  const keyBytes=fromBase64(env("SOCIAL_CREDENTIALS_ENCRYPTION_KEY"));
  if(keyBytes.length!==32) throw new Error("SOCIAL_CREDENTIALS_ENCRYPTION_KEY must decode to 32 bytes");
  const key=await crypto.subtle.importKey("raw",keyBytes,"AES-GCM",false,["decrypt"]);
  const encrypted=fromBase64Url(ciphertext); const authTag=fromBase64Url(tag);
  const combined=new Uint8Array(encrypted.length+authTag.length); combined.set(encrypted); combined.set(authTag,encrypted.length);
  const aad=new TextEncoder().encode(JSON.stringify(["rithena:social-credentials:v1",credential.organizationId,credential.brandId,credential.connectionId]));
  try { return new TextDecoder().decode(await crypto.subtle.decrypt({name:"AES-GCM",iv:fromBase64Url(iv),additionalData:aad,tagLength:128},key,combined)); }
  catch { throw new PublishError("credential_invalid","Instagram credentials could not be read. Reconnect Instagram.",false); }
}

function graphVersion(){ const version=env("INSTAGRAM_API_VERSION"); if(!/^v\d+\.0$/.test(version)) throw new Error("INSTAGRAM_API_VERSION must look like v24.0"); return version; }

async function graph(path:string,token:string,init:RequestInit={},ambiguous=false):Promise<Json>{
  let response:Response;
  try { response=await fetch(`https://graph.instagram.com/${graphVersion()}/${path}`,{...init,headers:{authorization:`Bearer ${token}`,...init.headers},signal:AbortSignal.timeout(25_000)}); }
  catch { throw new PublishError(ambiguous?"publish_outcome_unknown":"instagram_unavailable",ambiguous?"Instagram received the publish request, but its result could not be confirmed. Check the Instagram account before retrying to avoid a duplicate post.":"Instagram could not be reached. Rithena will retry automatically.",!ambiguous); }
  let body:Json={}; try { body=await response.json() as Json; } catch { /* classified below */ }
  if(!response.ok){
    const error=(body.error&&typeof body.error==="object"?body.error:body) as Json;
    const code=Number(error.code||0); const subcode=Number(error.error_subcode||0);
    if(code===190) throw new PublishError(subcode===463?"instagram_expired":"instagram_revoked",subcode===463?"Instagram access expired. Reconnect the account, then reschedule this post.":"Instagram access was removed. Reconnect the account, then reschedule this post.",false);
    if(code===10||code===200||response.status===403) throw new PublishError("instagram_permissions","Instagram no longer allows publishing for this connection. Reconnect it and grant content publishing access.",false);
    if(response.status===429||response.status>=500) throw new PublishError("instagram_unavailable","Instagram is temporarily unavailable. Rithena will retry automatically.",true);
    throw new PublishError(`instagram_${code||response.status}`,String(error.message||"Instagram rejected this post.").slice(0,400),false);
  }
  return body;
}

async function checkpoint(db:Db,job:Job,worker:string,state:string,options:{providerId?:string;payload?:Json;retryAfter?:number;code?:string;message?:string;remoteId?:string;remoteUrl?:string}={}){
  const result=await db.rpc("checkpoint_instagram_publish_job",{p_job_id:job.id,p_worker_id:worker,p_state:state,p_provider_job_id:options.providerId||null,p_provider_payload:options.payload||{},p_retry_after_seconds:options.retryAfter||null,p_error_code:options.code||null,p_error_message:options.message||null,p_remote_post_id:options.remoteId||null,p_remote_post_url:options.remoteUrl||null});
  if(result.error) throw new Error(`Publish checkpoint failed: ${result.error.message}`);
}

async function createContainer(accountId:string,token:string,parameters:Record<string,string>){
  const body=await graph(`${accountId}/media`,token,{method:"POST",headers:{"content-type":"application/x-www-form-urlencoded"},body:new URLSearchParams(parameters)});
  if(typeof body.id!=="string"||!body.id) throw new PublishError("instagram_invalid_response","Instagram did not return a media container. The post was not published.",true);
  return body.id;
}

async function resources(db:Db,job:Job){
  const variant=await db.from("platform_variants").select("format,selected_media_asset_id,post_copies(caption,hashtags,is_selected,version)").eq("id",job.platform_variant_id).eq("organization_id",job.organization_id).single();
  if(variant.error||!variant.data) throw new PublishError("content_unavailable","The approved Instagram version is no longer available.",false);
  const selected=[...(variant.data.post_copies||[])].sort((a:{is_selected:boolean;version:number},b:{is_selected:boolean;version:number})=>Number(b.is_selected)-Number(a.is_selected)||b.version-a.version)[0];
  if(!selected?.is_selected) throw new PublishError("copy_unavailable","The selected Instagram caption is no longer available.",false);
  const selectedAsset=await db.from("media_assets").select("id,metadata").eq("id",variant.data.selected_media_asset_id).eq("organization_id",job.organization_id).single();
  if(selectedAsset.error||!selectedAsset.data) throw new PublishError("media_unavailable","The approved Instagram media is no longer available.",false);
  let query=db.from("media_assets").select("id,asset_type,storage_bucket,storage_path,mime_type,metadata").eq("organization_id",job.organization_id).eq("content_item_id",job.content_item_id).eq("status","ready");
  if(variant.data.format!=="carousel") query=query.eq("id",variant.data.selected_media_asset_id);
  else {
    const generationJobId=selectedAsset.data.metadata?.generationJobId;
    query=query.eq("asset_type","carousel_slide");
    if(typeof generationJobId==="string"&&generationJobId) query=query.contains("metadata",{generationJobId});
  }
  const assets=await query; if(assets.error||!assets.data?.length) throw new PublishError("media_unavailable","The approved Instagram media is no longer available.",false);
  const ordered=[...assets.data].sort((a:{metadata:Json},b:{metadata:Json})=>Number(a.metadata?.slideIndex||0)-Number(b.metadata?.slideIndex||0));
  if(variant.data.format==="carousel"&&(ordered.length<2||ordered.length>10)) throw new PublishError("carousel_invalid","Instagram carousels require between 2 and 10 ready slides.",false);
  const caption=[selected.caption||"",...(selected.hashtags||[])].filter(Boolean).join("\n\n");
  return {format:variant.data.format as string,assets:ordered,caption};
}

async function signedUrl(db:Db,asset:{storage_bucket:string;storage_path:string}){
  const signed=await db.storage.from(asset.storage_bucket).createSignedUrl(asset.storage_path,21600);
  if(signed.error||!signed.data?.signedUrl) throw new PublishError("media_delivery_failed","The approved media could not be prepared for Instagram.",true);
  return signed.data.signedUrl as string;
}

async function run(db:Db,job:Job,worker:string,credential:Credential,token:string){
  const source=await resources(db,job); const payload=job.provider_payload||{};
  if(!job.provider_job_id){
    if(source.format==="carousel"){
      const children=Array.isArray(payload.childContainers)?payload.childContainers.filter((id):id is string=>typeof id==="string"):[];
      if(children.length<source.assets.length){
        const asset=source.assets[children.length]; const url=await signedUrl(db,asset);
        const id=await createContainer(credential.accountId,token,{[String(asset.mime_type||"").startsWith("video/")?"video_url":"image_url"]:url,is_carousel_item:"true"});
        const next=[...children,id]; await checkpoint(db,job,worker,"waiting_external",{payload:{stage:"creating_children",childContainers:next},retryAfter:2}); return;
      }
      const id=await createContainer(credential.accountId,token,{media_type:"CAROUSEL",children:children.join(","),caption:source.caption});
      await checkpoint(db,job,worker,"waiting_external",{providerId:id,payload:{stage:"processing",childContainers:children},retryAfter:8}); return;
    }
    const asset=source.assets[0]; const url=await signedUrl(db,asset); const video=String(asset.mime_type||"").startsWith("video/");
    const id=await createContainer(credential.accountId,token,{[video?"video_url":"image_url"]:url,...(video?{media_type:"REELS"}:{}),caption:source.caption});
    await checkpoint(db,job,worker,"waiting_external",{providerId:id,payload:{stage:"processing"},retryAfter:video?15:5}); return;
  }
  const status=await graph(`${job.provider_job_id}?fields=status_code,status`,token);
  const statusCode=String(status.status_code||"").toUpperCase();
  if(statusCode==="ERROR"||statusCode==="EXPIRED") throw new PublishError("instagram_processing_failed",String(status.status||"Instagram could not process the uploaded media.").slice(0,400),false);
  if(statusCode==="PUBLISHED") throw new PublishError("publish_outcome_unknown","Instagram reports that this media container was already published, but its post ID is unavailable. Check Instagram before retrying.",false);
  if(statusCode!=="FINISHED"&&statusCode!=="PUBLISHED"){
    const polls=Number(payload.processingPolls||0)+1;
    if(polls>40) throw new PublishError("instagram_processing_timeout","Instagram did not finish processing this media within the expected time. It was not published.",false);
    await checkpoint(db,job,worker,"waiting_external",{providerId:job.provider_job_id,payload:{stage:"processing",processingPolls:polls},retryAfter:15}); return;
  }
  if(payload.publishRequestedAt) throw new PublishError("publish_outcome_unknown","A previous Instagram publish request could not be confirmed. Check the Instagram account before retrying to avoid a duplicate post.",false);
  // Persist intent first. If this request times out, the worker will fail closed instead of posting twice.
  await checkpoint(db,job,worker,"waiting_external",{providerId:job.provider_job_id,payload:{stage:"publishing",publishRequestedAt:new Date().toISOString()},retryAfter:1});
  // Re-claiming is required after every checkpoint, so the actual publish happens on the next invocation.
}

async function publishPrepared(db:Db,job:Job,worker:string,credential:Credential,token:string){
  const result=await graph(`${credential.accountId}/media_publish`,token,{method:"POST",headers:{"content-type":"application/x-www-form-urlencoded"},body:new URLSearchParams({creation_id:job.provider_job_id!})},true);
  const remoteId=typeof result.id==="string"?result.id:"";
  if(!remoteId) throw new PublishError("publish_outcome_unknown","Instagram received the publish request, but its post ID could not be confirmed. Check Instagram before retrying.",false);
  let permalink:string|undefined;
  try { const post=await graph(`${remoteId}?fields=permalink,timestamp`,token); if(typeof post.permalink==="string") permalink=post.permalink; } catch { /* publication succeeded; permalink is optional */ }
  await checkpoint(db,job,worker,"succeeded",{providerId:job.provider_job_id!,payload:{stage:"published",remotePostId:remoteId},remoteId,remoteUrl:permalink});
}

Deno.serve(async(request)=>{
  const expected=Deno.env.get("CRON_SECRET"); if(!expected||request.headers.get("authorization")!==`Bearer ${expected}`) return json({error:"Unauthorized"},401);
  const worker=`edge:${crypto.randomUUID()}`; const db=createClient(env("SUPABASE_URL"),env("SUPABASE_SERVICE_ROLE_KEY"),{auth:{persistSession:false}});
  const claimed=await db.rpc("claim_next_instagram_publish_job",{p_worker_id:worker,p_lease_seconds:120});
  if(claimed.error){console.error("publish_claim_failed",{message:claimed.error.message});return json({error:"Job claim failed"},500);}
  const job=claimed.data as Job|null; if(!job?.id) return json({ok:true,claimed:false});
  try {
    const secret=await db.rpc("instagram_publish_credential",{p_job_id:job.id,p_worker_id:worker});
    if(secret.error) throw new PublishError("instagram_expired","Instagram must be reconnected before this post can publish.",false);
    const credential=secret.data as Credential; const token=await decrypt(credential.ciphertext,credential);
    if(job.provider_payload?.stage==="publishing"&&job.provider_payload?.publishRequestedAt) await publishPrepared(db,job,worker,credential,token);
    else await run(db,job,worker,credential,token);
    return json({ok:true,claimed:true,jobId:job.id});
  } catch(error){
    const known=error instanceof PublishError; const code=known?error.code:"publisher_failed"; const message=(known?error.message:"Instagram publishing failed unexpectedly.").slice(0,500);
    const retry=known&&error.retryable&&job.attempt<job.max_attempts;
    console.error("publish_failed",{jobId:job.id,attempt:job.attempt,code,message});
    try { await checkpoint(db,job,worker,retry?"retrying":"failed",{providerId:job.provider_job_id||undefined,payload:{stage:retry?"retry_scheduled":"failed"},retryAfter:retry?Math.min(900,15*2**Math.max(0,job.attempt-1)):undefined,code,message}); } catch(checkpointError){console.error("publish_failure_checkpoint_failed",{jobId:job.id,message:String(checkpointError)});}
    return json({error:message,jobId:job.id,retrying:retry},known?400:500);
  }
});
