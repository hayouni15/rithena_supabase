import { createClient } from "npm:@supabase/supabase-js@2";

type Json = Record<string, unknown>;
type Job = { id:string; organization_id:string; content_item_id:string; platform_variant_id:string; social_connection_id:string; content_revision:number; state:string; provider_job_id:string|null; provider_payload:Json; attempt:number; max_attempts:number };
type Credential = { ciphertext:string; organizationId:string; brandId:string; connectionId:string; accountId:string; platform:"instagram"|"facebook"|"linkedin"|"youtube" };
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
  const platformName=credential.platform[0].toUpperCase()+credential.platform.slice(1);
  const [version,iv,tag,ciphertext,extra]=envelope.split(".");
  if(version!=="v1"||!iv||!tag||!ciphertext||extra!==undefined) throw new PublishError("credential_invalid",`${platformName} credentials could not be read. Reconnect the account.`,false);
  const keyBytes=fromBase64(env("SOCIAL_CREDENTIALS_ENCRYPTION_KEY"));
  if(keyBytes.length!==32) throw new Error("SOCIAL_CREDENTIALS_ENCRYPTION_KEY must decode to 32 bytes");
  const key=await crypto.subtle.importKey("raw",keyBytes,"AES-GCM",false,["decrypt"]);
  const encrypted=fromBase64Url(ciphertext); const authTag=fromBase64Url(tag);
  const combined=new Uint8Array(encrypted.length+authTag.length); combined.set(encrypted); combined.set(authTag,encrypted.length);
  const aad=new TextEncoder().encode(JSON.stringify(["rithena:social-credentials:v1",credential.organizationId,credential.brandId,credential.connectionId]));
  try { return new TextDecoder().decode(await crypto.subtle.decrypt({name:"AES-GCM",iv:fromBase64Url(iv),additionalData:aad,tagLength:128},key,combined)); }
  catch { throw new PublishError("credential_invalid",`${platformName} credentials could not be read. Reconnect the account.`,false); }
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
  const result=await db.rpc("checkpoint_social_publish_job",{p_job_id:job.id,p_worker_id:worker,p_state:state,p_provider_job_id:options.providerId||null,p_provider_payload:options.payload||{},p_retry_after_seconds:options.retryAfter||null,p_error_code:options.code||null,p_error_message:options.message||null,p_remote_post_id:options.remoteId||null,p_remote_post_url:options.remoteUrl||null});
  if(result.error) throw new Error(`Publish checkpoint failed: ${result.error.message}`);
}

async function createContainer(accountId:string,token:string,parameters:Record<string,string>){
  const body=await graph(`${accountId}/media`,token,{method:"POST",headers:{"content-type":"application/x-www-form-urlencoded"},body:new URLSearchParams(parameters)});
  if(typeof body.id!=="string"||!body.id) throw new PublishError("instagram_invalid_response","Instagram did not return a media container. The post was not published.",true);
  return body.id;
}

async function resources(db:Db,job:Job){
  const variant=await db.from("platform_variants").select("format,selected_media_asset_id,post_copies(title,headline,subhead,caption,hashtags,is_selected,version)").eq("id",job.platform_variant_id).eq("organization_id",job.organization_id).single();
  if(variant.error||!variant.data) throw new PublishError("content_unavailable","The approved social version is no longer available.",false);
  const selected=[...(variant.data.post_copies||[])].sort((a:{is_selected:boolean;version:number},b:{is_selected:boolean;version:number})=>Number(b.is_selected)-Number(a.is_selected)||b.version-a.version)[0];
  if(!selected?.is_selected) throw new PublishError("copy_unavailable","The selected social caption is no longer available.",false);
  const selectedAsset=await db.from("media_assets").select("id,metadata").eq("id",variant.data.selected_media_asset_id).eq("organization_id",job.organization_id).single();
  if(selectedAsset.error||!selectedAsset.data) throw new PublishError("media_unavailable","The approved social media is no longer available.",false);
  let query=db.from("media_assets").select("id,asset_type,storage_bucket,storage_path,mime_type,file_size_bytes,metadata").eq("organization_id",job.organization_id).eq("content_item_id",job.content_item_id).eq("status","ready");
  if(variant.data.format!=="carousel") query=query.eq("id",variant.data.selected_media_asset_id);
  else {
    const generationJobId=selectedAsset.data.metadata?.generationJobId;
    query=query.eq("asset_type","carousel_slide");
    if(typeof generationJobId==="string"&&generationJobId) query=query.contains("metadata",{generationJobId});
  }
  const assets=await query; if(assets.error||!assets.data?.length) throw new PublishError("media_unavailable","The approved social media is no longer available.",false);
  const ordered=[...assets.data].sort((a:{metadata:Json},b:{metadata:Json})=>Number(a.metadata?.slideIndex||0)-Number(b.metadata?.slideIndex||0));
  if(variant.data.format==="carousel"&&(ordered.length<2||ordered.length>10)) throw new PublishError("carousel_invalid","Instagram carousels require between 2 and 10 ready slides.",false);
  const caption=[selected.caption||"",...(selected.hashtags||[])].filter(Boolean).join("\n\n");
  return {format:variant.data.format as string,assets:ordered,caption,title:String(selected.title||selected.headline||selected.subhead||"").slice(0,200)};
}

async function signedUrl(db:Db,asset:{storage_bucket:string;storage_path:string}){
  const signed=await db.storage.from(asset.storage_bucket).createSignedUrl(asset.storage_path,21600);
  if(signed.error||!signed.data?.signedUrl) throw new PublishError("media_delivery_failed","The approved media could not be prepared for Instagram.",true);
  return signed.data.signedUrl as string;
}

function facebookVersion(){const version=env("FACEBOOK_API_VERSION");if(!/^v\d+\.0$/.test(version))throw new Error("FACEBOOK_API_VERSION must look like v24.0");return version;}
async function facebookGraph(path:string,token:string,init:RequestInit={},ambiguous=false):Promise<Json>{
  let response:Response;
  try{response=await fetch(`https://graph.facebook.com/${facebookVersion()}/${path}`,{...init,headers:{authorization:`Bearer ${token}`,...init.headers},signal:AbortSignal.timeout(30_000)});}
  catch{throw new PublishError(ambiguous?"publish_outcome_unknown":"facebook_unavailable",ambiguous?"Facebook received the publish request, but its result could not be confirmed. Check the Page before retrying to avoid a duplicate post.":"Facebook could not be reached. Rithena will retry automatically.",!ambiguous);}
  let body:Json={};try{body=await response.json() as Json;}catch{/* classified below */}
  if(!response.ok){const error=(body.error&&typeof body.error==="object"?body.error:body) as Json;const code=Number(error.code||0);const subcode=Number(error.error_subcode||0);if(code===190)throw new PublishError(subcode===463?"facebook_expired":"facebook_revoked",subcode===463?"Facebook access expired. Reconnect the Page, then reschedule.":"Facebook access was removed. Reconnect the Page, then reschedule.",false);if(code===10||code===200||response.status===403)throw new PublishError("facebook_permissions","Facebook no longer allows publishing for this Page. Reconnect and grant Page publishing access.",false);if(response.status===429||response.status>=500)throw new PublishError("facebook_unavailable","Facebook is temporarily unavailable. Rithena will retry automatically.",true);throw new PublishError(`facebook_${code||response.status}`,String(error.message||"Facebook rejected this post.").slice(0,400),false);}
  return body;
}

function facebookToken(decrypted:string,accountId:string){try{const stored=JSON.parse(decrypted) as {pageAccessTokens?:Record<string,string>};const token=stored.pageAccessTokens?.[accountId];if(!token)throw new Error();return token;}catch{throw new PublishError("credential_invalid","Facebook credentials could not be read. Reconnect Facebook.",false);}}

async function runFacebook(db:Db,job:Job,worker:string,credential:Credential,token:string){
  const source=await resources(db,job);const payload=job.provider_payload||{};
  if(source.format==="video"||String(source.assets[0]?.mime_type||"").startsWith("video/")){
    if(!payload.publishRequestedAt){await checkpoint(db,job,worker,"waiting_external",{payload:{stage:"publishing_video",publishRequestedAt:new Date().toISOString()},retryAfter:1});return;}
    if(job.attempt>1)throw new PublishError("publish_outcome_unknown","A previous Facebook video publish request could not be confirmed. Check the Page before retrying.",false);
    const url=await signedUrl(db,source.assets[0]);const result=await facebookGraph(`${credential.accountId}/videos`,token,{method:"POST",headers:{"content-type":"application/x-www-form-urlencoded"},body:new URLSearchParams({file_url:url,description:source.caption})},true);const id=typeof result.id==="string"?result.id:"";if(!id)throw new PublishError("publish_outcome_unknown","Facebook accepted the video but did not return its ID. Check the Page before retrying.",false);await checkpoint(db,job,worker,"succeeded",{payload:{stage:"published",remotePostId:id},remoteId:id});return;
  }
  const photoIds=Array.isArray(payload.photoIds)?payload.photoIds.filter((id):id is string=>typeof id==="string"):[];
  if(photoIds.length<source.assets.length){const url=await signedUrl(db,source.assets[photoIds.length]);const result=await facebookGraph(`${credential.accountId}/photos`,token,{method:"POST",headers:{"content-type":"application/x-www-form-urlencoded"},body:new URLSearchParams({url,published:"false"})});const id=typeof result.id==="string"?result.id:"";if(!id)throw new PublishError("facebook_invalid_response","Facebook did not return an uploaded photo ID.",true);await checkpoint(db,job,worker,"waiting_external",{payload:{stage:"uploading_photos",photoIds:[...photoIds,id]},retryAfter:1});return;}
  if(!payload.publishRequestedAt){await checkpoint(db,job,worker,"waiting_external",{payload:{stage:"publishing",photoIds,publishRequestedAt:new Date().toISOString()},retryAfter:1});return;}
  const body=new URLSearchParams({message:source.caption});photoIds.forEach((id,index)=>body.set(`attached_media[${index}]`,JSON.stringify({media_fbid:id})));
  const result=await facebookGraph(`${credential.accountId}/feed`,token,{method:"POST",headers:{"content-type":"application/x-www-form-urlencoded"},body},true);const id=typeof result.id==="string"?result.id:"";if(!id)throw new PublishError("publish_outcome_unknown","Facebook accepted the post but did not return its ID. Check the Page before retrying.",false);let permalink:string|undefined;try{const post=await facebookGraph(`${id}?fields=permalink_url`,token);if(typeof post.permalink_url==="string")permalink=post.permalink_url;}catch{/* publish succeeded */}await checkpoint(db,job,worker,"succeeded",{payload:{stage:"published",remotePostId:id,photoIds},remoteId:id,remoteUrl:permalink});
}

function linkedinVersion(){const version=env("LINKEDIN_VERSION");if(!/^20\d{4}$/.test(version))throw new Error("LINKEDIN_VERSION must look like 202603");return version;}
function linkedinToken(decrypted:string){try{const stored=JSON.parse(decrypted) as {accessToken?:string;expiresAt?:string};if(!stored.accessToken)throw new Error();if(stored.expiresAt&&Date.parse(stored.expiresAt)<=Date.now())throw new PublishError("linkedin_expired","LinkedIn access expired. Reconnect the Company Page, then reschedule.",false);return stored.accessToken;}catch(error){if(error instanceof PublishError)throw error;throw new PublishError("credential_invalid","LinkedIn credentials could not be read. Reconnect LinkedIn.",false);}}
async function linkedin(path:string,token:string,init:RequestInit={},ambiguous=false):Promise<{body:Json;response:Response}>{
  let response:Response;
  try{response=await fetch(`https://api.linkedin.com/rest/${path}`,{...init,headers:{authorization:`Bearer ${token}`,"Linkedin-Version":linkedinVersion(),"X-Restli-Protocol-Version":"2.0.0",...init.headers},signal:AbortSignal.timeout(45_000)});}
  catch{throw new PublishError(ambiguous?"publish_outcome_unknown":"linkedin_unavailable",ambiguous?"LinkedIn received the publish request, but its result could not be confirmed. Check the Company Page before retrying.":"LinkedIn could not be reached. Rithena will retry automatically.",!ambiguous);}
  let body:Json={};try{body=await response.json() as Json;}catch{/* upload and empty responses are valid */}
  if(!response.ok){const message=String(body.message||body.errorDetails||"LinkedIn rejected this post.").slice(0,400);if(response.status===401)throw new PublishError("linkedin_revoked","LinkedIn access was removed or expired. Reconnect the Company Page, then reschedule.",false);if(response.status===403)throw new PublishError("linkedin_permissions","LinkedIn no longer allows publishing for this Company Page. Reconnect it and grant publishing access.",false);if(response.status===429||response.status>=500)throw new PublishError("linkedin_unavailable","LinkedIn is temporarily unavailable. Rithena will retry automatically.",true);throw new PublishError(`linkedin_${response.status}`,message,false);}
  return {body,response};
}
async function assetBytes(db:Db,asset:{storage_bucket:string;storage_path:string}){const result=await db.storage.from(asset.storage_bucket).download(asset.storage_path);if(result.error||!result.data)throw new PublishError("media_delivery_failed","The approved media could not be prepared for LinkedIn.",true);return new Uint8Array(await result.data.arrayBuffer());}
async function uploadLinkedInImage(db:Db,asset:{storage_bucket:string;storage_path:string;mime_type:string},owner:string,token:string){
  const initialized=await linkedin("images?action=initializeUpload",token,{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({initializeUploadRequest:{owner}})});const value=initialized.body.value as Json|undefined;const uploadUrl=String(value?.uploadUrl||"");const image=String(value?.image||"");if(!uploadUrl||!image)throw new PublishError("linkedin_invalid_response","LinkedIn did not initialize the image upload.",true);
  const bytes=await assetBytes(db,asset);const response=await fetch(uploadUrl,{method:"PUT",headers:{authorization:`Bearer ${token}`,"content-type":asset.mime_type||"application/octet-stream"},body:bytes,signal:AbortSignal.timeout(90_000)});if(!response.ok)throw new PublishError(response.status>=500?"linkedin_unavailable":"linkedin_upload_failed","LinkedIn could not upload the image.",response.status>=500);return image;
}
async function uploadLinkedInVideo(db:Db,asset:{storage_bucket:string;storage_path:string;mime_type:string},owner:string,token:string){
  const bytes=await assetBytes(db,asset);const initialized=await linkedin("videos?action=initializeUpload",token,{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({initializeUploadRequest:{owner,fileSizeBytes:bytes.byteLength,uploadCaptions:false,uploadThumbnail:false}})});const value=initialized.body.value as Json|undefined;const video=String(value?.video||"");const instructions=Array.isArray(value?.uploadInstructions)?value.uploadInstructions as Json[]:[];if(!video||!instructions.length)throw new PublishError("linkedin_invalid_response","LinkedIn did not initialize the video upload.",true);
  const uploadedPartIds:string[]=[];for(const instruction of instructions){const first=Number(instruction.firstByte||0),last=Number(instruction.lastByte);const uploadUrl=String(instruction.uploadUrl||"");if(!uploadUrl||!Number.isFinite(last))throw new PublishError("linkedin_invalid_response","LinkedIn returned invalid video upload instructions.",true);const response=await fetch(uploadUrl,{method:"PUT",headers:{authorization:`Bearer ${token}`,"content-type":asset.mime_type||"application/octet-stream"},body:bytes.slice(first,last+1),signal:AbortSignal.timeout(120_000)});if(!response.ok)throw new PublishError(response.status>=500?"linkedin_unavailable":"linkedin_upload_failed","LinkedIn could not upload the video.",response.status>=500);const etag=response.headers.get("etag");if(!etag)throw new PublishError("linkedin_invalid_response","LinkedIn did not confirm an uploaded video part.",true);uploadedPartIds.push(etag.replace(/^\"|\"$/g,""));}
  await linkedin("videos?action=finalizeUpload",token,{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({finalizeUploadRequest:{video,uploadToken:"",uploadedPartIds}})});return video;
}
async function linkedinMediaReady(urn:string,token:string){const kind=urn.includes(":video:")?"videos":"images";const result=await linkedin(`${kind}/${encodeURIComponent(urn)}`,token);const status=String((result.body.value as Json|undefined)?.status||result.body.status||"").toUpperCase();if(["PROCESSING_FAILED","CLIENT_ERROR","SERVER_ERROR"].includes(status))throw new PublishError("linkedin_processing_failed","LinkedIn could not process the uploaded media.",false);return status==="AVAILABLE";}
async function runLinkedIn(db:Db,job:Job,worker:string,credential:Credential,token:string){
  const source=await resources(db,job);const payload=job.provider_payload||{};const owner=`urn:li:organization:${credential.accountId}`;const mediaUrns=Array.isArray(payload.mediaUrns)?payload.mediaUrns.filter((id):id is string=>typeof id==="string"):[];
  if(mediaUrns.length<source.assets.length){const asset=source.assets[mediaUrns.length];const isVideo=String(asset.mime_type||"").startsWith("video/");const urn=isVideo?await uploadLinkedInVideo(db,asset,owner,token):await uploadLinkedInImage(db,asset,owner,token);await checkpoint(db,job,worker,"waiting_external",{payload:{stage:"processing_media",mediaUrns:[...mediaUrns,urn],processingPolls:0},retryAfter:isVideo?15:3});return;}
  const ready=await Promise.all(mediaUrns.map((urn)=>linkedinMediaReady(urn,token)));if(ready.some((value)=>!value)){const polls=Number(payload.processingPolls||0)+1;if(polls>40)throw new PublishError("linkedin_processing_timeout","LinkedIn did not finish processing this media within the expected time.",false);await checkpoint(db,job,worker,"waiting_external",{payload:{stage:"processing_media",mediaUrns,processingPolls:polls},retryAfter:15});return;}
  if(!payload.publishRequestedAt){await checkpoint(db,job,worker,"waiting_external",{payload:{stage:"publishing",mediaUrns,publishRequestedAt:new Date().toISOString()},retryAfter:1});return;}
  const content=mediaUrns.length>1?{multiImage:{images:mediaUrns.map((id)=>({id,altText:source.title||"Post image"}))}}:{media:{id:mediaUrns[0],title:source.title||undefined}};
  const result=await linkedin("posts",token,{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({author:owner,commentary:source.caption.slice(0,3000),visibility:"PUBLIC",distribution:{feedDistribution:"MAIN_FEED",targetEntities:[],thirdPartyDistributionChannels:[]},content,lifecycleState:"PUBLISHED",isReshareDisabledByAuthor:false})},true);const remoteId=result.response.headers.get("x-restli-id")||String(result.body.id||"");if(!remoteId)throw new PublishError("publish_outcome_unknown","LinkedIn accepted the post but did not return its ID. Check the Company Page before retrying.",false);await checkpoint(db,job,worker,"succeeded",{payload:{stage:"published",mediaUrns,remotePostId:remoteId},remoteId,remoteUrl:`https://www.linkedin.com/feed/update/${remoteId}/`});
}

async function youtubeToken(decrypted:string){
  let stored:{accessToken?:string;refreshToken?:string;expiresAt?:string};try{stored=JSON.parse(decrypted);}catch{throw new PublishError("credential_invalid","YouTube credentials could not be read. Reconnect YouTube.",false);}
  if(stored.accessToken&&stored.expiresAt&&Date.parse(stored.expiresAt)>Date.now()+60_000)return stored.accessToken;
  if(!stored.refreshToken)throw new PublishError("youtube_revoked","YouTube access expired. Reconnect the channel, then reschedule.",false);
  let response:Response;try{response=await fetch("https://oauth2.googleapis.com/token",{method:"POST",headers:{"content-type":"application/x-www-form-urlencoded"},body:new URLSearchParams({refresh_token:stored.refreshToken,client_id:env("YOUTUBE_CLIENT_ID"),client_secret:env("YOUTUBE_CLIENT_SECRET"),grant_type:"refresh_token"}),signal:AbortSignal.timeout(25_000)});}catch{throw new PublishError("youtube_unavailable","YouTube authentication is temporarily unavailable. Rithena will retry automatically.",true);}
  let body:Json={};try{body=await response.json() as Json;}catch{/* classified below */}if(!response.ok){if(body.error==="invalid_grant"||response.status===401)throw new PublishError("youtube_revoked","YouTube access was removed. Reconnect the channel, then reschedule.",false);throw new PublishError("youtube_unavailable","YouTube authentication is temporarily unavailable. Rithena will retry automatically.",response.status>=500||response.status===429);}if(typeof body.access_token!=="string")throw new PublishError("youtube_invalid_response","YouTube did not return a usable access token.",true);return body.access_token;
}
async function youtubeJson(url:string,token:string,init:RequestInit={}):Promise<{body:Json;response:Response}>{
  let response:Response;try{response=await fetch(url,{...init,headers:{authorization:`Bearer ${token}`,...init.headers},signal:AbortSignal.timeout(90_000)});}catch{throw new PublishError("youtube_unavailable","YouTube could not be reached. Rithena will retry automatically.",true);}
  let body:Json={};try{body=await response.json() as Json;}catch{/* resumable responses may be empty */}if(!response.ok&&response.status!==308){const error=body.error&&typeof body.error==="object"?body.error as Json:body;const message=String(error.message||"YouTube rejected this upload.").slice(0,400);if(response.status===401)throw new PublishError("youtube_revoked","YouTube access was removed. Reconnect the channel, then reschedule.",false);if(response.status===403)throw new PublishError("youtube_permissions","YouTube does not allow uploads for this channel or its upload quota is unavailable.",false);if(response.status===429||response.status>=500)throw new PublishError("youtube_unavailable","YouTube is temporarily unavailable. Rithena will retry automatically.",true);throw new PublishError(`youtube_${response.status}`,message,false);}return {body,response};
}
async function runYouTube(db:Db,job:Job,worker:string,token:string){
  const source=await resources(db,job);const asset=source.assets[0];if(!asset||!String(asset.mime_type||"").startsWith("video/"))throw new PublishError("youtube_video_required","YouTube publishing requires a finished video creative.",false);const payload=job.provider_payload||{};
  if(job.provider_job_id){const result=await youtubeJson(`https://www.googleapis.com/youtube/v3/videos?part=processingDetails,status&id=${encodeURIComponent(job.provider_job_id)}`,token);const items=Array.isArray(result.body.items)?result.body.items as Json[]:[];const details=items[0]?.processingDetails as Json|undefined;const processing=String(details?.processingStatus||"").toLowerCase();if(processing==="failed"||processing==="terminated")throw new PublishError("youtube_processing_failed","YouTube could not process the uploaded video.",false);if(processing!=="succeeded"){const polls=Number(payload.processingPolls||0)+1;if(polls>80)throw new PublishError("youtube_processing_timeout","YouTube did not finish processing this video within the expected time.",false);await checkpoint(db,job,worker,"waiting_external",{providerId:job.provider_job_id,payload:{...payload,stage:"processing",processingPolls:polls},retryAfter:15});return;}const id=job.provider_job_id;await checkpoint(db,job,worker,"succeeded",{providerId:id,payload:{...payload,stage:"published",remotePostId:id},remoteId:id,remoteUrl:`https://www.youtube.com/watch?v=${id}`});return;}
  const bytes=await assetBytes(db,asset);let uploadUrl=typeof payload.uploadUrl==="string"?payload.uploadUrl:"";
  if(!uploadUrl){const tags=source.caption.match(/#[\p{L}\p{N}_]+/gu)?.map((tag)=>tag.slice(1)).slice(0,30)||[];const initialized=await youtubeJson("https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status",token,{method:"POST",headers:{"content-type":"application/json; charset=UTF-8","X-Upload-Content-Length":String(bytes.byteLength),"X-Upload-Content-Type":asset.mime_type||"video/mp4"},body:JSON.stringify({snippet:{title:(source.title||"Untitled video").slice(0,100),description:source.caption.slice(0,5000),tags,categoryId:"22"},status:{privacyStatus:"public",selfDeclaredMadeForKids:false}})});uploadUrl=initialized.response.headers.get("location")||"";if(!uploadUrl)throw new PublishError("youtube_invalid_response","YouTube did not initialize the resumable upload.",true);await checkpoint(db,job,worker,"waiting_external",{payload:{stage:"uploading",uploadUrl,totalBytes:bytes.byteLength},retryAfter:1});return;}
  const status=await youtubeJson(uploadUrl,token,{method:"PUT",headers:{"content-length":"0","content-range":`bytes */${bytes.byteLength}`}});if(status.response.ok&&typeof status.body.id==="string"){await checkpoint(db,job,worker,"waiting_external",{providerId:status.body.id,payload:{stage:"processing",processingPolls:0},retryAfter:10});return;}const range=status.response.headers.get("range");const offset=range?Number(range.split("-").pop())+1:0;if(!Number.isFinite(offset)||offset<0||offset>=bytes.byteLength)throw new PublishError("youtube_invalid_response","YouTube returned an invalid resumable upload position.",true);const uploaded=await youtubeJson(uploadUrl,token,{method:"PUT",headers:{"content-type":asset.mime_type||"video/mp4","content-length":String(bytes.byteLength-offset),"content-range":`bytes ${offset}-${bytes.byteLength-1}/${bytes.byteLength}`},body:bytes.slice(offset)});if(uploaded.response.status===308){await checkpoint(db,job,worker,"waiting_external",{payload:{stage:"uploading",uploadUrl,totalBytes:bytes.byteLength},retryAfter:3});return;}const id=typeof uploaded.body.id==="string"?uploaded.body.id:"";if(!id)throw new PublishError("publish_outcome_unknown","YouTube completed the upload but did not return its video ID. Check the channel before retrying.",false);await checkpoint(db,job,worker,"waiting_external",{providerId:id,payload:{stage:"processing",processingPolls:0},retryAfter:10});
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
    const secret=await db.rpc("social_publish_credential",{p_job_id:job.id,p_worker_id:worker});
    if(secret.error) throw new PublishError("credential_invalid","The social account must be reconnected before this post can publish.",false);
    const credential=secret.data as Credential; const decrypted=await decrypt(credential.ciphertext,credential);
    if(credential.platform==="facebook")await runFacebook(db,job,worker,credential,facebookToken(decrypted,credential.accountId));
    else if(credential.platform==="linkedin")await runLinkedIn(db,job,worker,credential,linkedinToken(decrypted));
    else if(credential.platform==="youtube")await runYouTube(db,job,worker,await youtubeToken(decrypted));
    else if(job.provider_payload?.stage==="publishing"&&job.provider_payload?.publishRequestedAt) await publishPrepared(db,job,worker,credential,decrypted);
    else await run(db,job,worker,credential,decrypted);
    return json({ok:true,claimed:true,jobId:job.id});
  } catch(error){
    const known=error instanceof PublishError; const code=known?error.code:"publisher_failed"; const message=(known?error.message:"Social publishing failed unexpectedly.").slice(0,500);
    const retry=known&&error.retryable&&job.attempt<job.max_attempts;
    console.error("publish_failed",{jobId:job.id,attempt:job.attempt,code,message});
    try { await checkpoint(db,job,worker,retry?"retrying":"failed",{providerId:job.provider_job_id||undefined,payload:{stage:retry?"retry_scheduled":"failed"},retryAfter:retry?Math.min(900,15*2**Math.max(0,job.attempt-1)):undefined,code,message}); } catch(checkpointError){console.error("publish_failure_checkpoint_failed",{jobId:job.id,message:String(checkpointError)});}
    return json({error:message,jobId:job.id,retrying:retry},known?400:500);
  }
});
