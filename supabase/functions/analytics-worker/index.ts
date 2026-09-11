import { createClient } from "npm:@supabase/supabase-js@2";
type Json=Record<string,unknown>; type Due={id:string;brand_id:string}; type Claim={ciphertext:string;organizationId:string;accountId:string;revision:string;leaseId:string};
// deno-lint-ignore no-explicit-any
type Db=any;
const env=(name:string)=>{const value=Deno.env.get(name)?.trim();if(!value)throw new Error(`${name} is missing`);return value;};
const response=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{"content-type":"application/json"}});
const decode=(value:string,url=false)=>Uint8Array.from(atob((url?value.replaceAll("-","+").replaceAll("_","/"):value).padEnd(Math.ceil(value.length/4)*4,"=")),c=>c.charCodeAt(0));
async function token(envelope:string,claim:Claim,brandId:string,connectionId:string){
  const [version,iv,tag,ciphertext]=envelope.split(".");if(version!=="v1"||!iv||!tag||!ciphertext)throw new Error("credential_invalid");
  const key=await crypto.subtle.importKey("raw",decode(env("SOCIAL_CREDENTIALS_ENCRYPTION_KEY")),"AES-GCM",false,["decrypt"]);
  const encrypted=decode(ciphertext,true),auth=decode(tag,true),combined=new Uint8Array(encrypted.length+auth.length);combined.set(encrypted);combined.set(auth,encrypted.length);
  const aad=new TextEncoder().encode(JSON.stringify(["rithena:social-credentials:v1",claim.organizationId,brandId,connectionId]));
  return new TextDecoder().decode(await crypto.subtle.decrypt({name:"AES-GCM",iv:decode(iv,true),additionalData:aad,tagLength:128},key,combined));
}
async function graph(path:string,accessToken:string){const result=await fetch(`https://graph.instagram.com/${env("INSTAGRAM_API_VERSION")}/${path}`,{headers:{authorization:`Bearer ${accessToken}`},signal:AbortSignal.timeout(25000)});const body=await result.json() as Json;if(!result.ok)throw new Error(`instagram_${result.status}`);return body;}
function insight(body:Json,name:string){const row=(Array.isArray(body.data)?body.data:[]).find((entry)=>entry&&typeof entry==="object"&&(entry as Json).name===name) as Json|undefined;const values=Array.isArray(row?.values)?row.values:[];const last=values.at(-1) as Json|undefined;return typeof last?.value==="number"?last.value:null;}
async function sync(db:Db,row:Due){
  const connection=await db.from("social_connections").select("scopes").eq("id",row.id).single();if(connection.error||!connection.data.scopes.includes("instagram_business_manage_insights"))return false;
  const claimed=await db.rpc("instagram_connection_command",{p_action:"claim",p_user:null,p_brand:row.brand_id,p_data:{connectionId:row.id}});if(claimed.error)throw claimed.error;
  const claim=claimed.data as Claim;
  try{
    const accessToken=await token(claim.ciphertext,claim,row.brand_id,row.id);const capturedAt=new Date(Math.floor(Date.now()/3600000)*3600000).toISOString();
    const mediaResponse=await graph(`${claim.accountId}/media?fields=id,media_type,media_product_type,permalink,like_count,comments_count&limit=100`,accessToken);
    const media=(Array.isArray(mediaResponse.data)?mediaResponse.data:[]) as Json[];const mediaById=new Map(media.map((item)=>[String(item.id),item]));
    const posts=await db.from("published_posts").select("id,remote_post_id").eq("social_connection_id",row.id).in("remote_post_id",[...mediaById.keys()]);if(posts.error)throw posts.error;
    const snapshots=[];
    for(const post of posts.data||[]){
      const item=mediaById.get(post.remote_post_id);if(!item)continue;let details:Json={data:[]};try{details=await graph(`${post.remote_post_id}/insights?metric=views,reach,saved,shares`,accessToken);}catch{/* metric unavailable */}
      const values={views:insight(details,"views"),reach:insight(details,"reach"),saves:insight(details,"saved"),shares:insight(details,"shares"),likes:typeof item.like_count==="number"?item.like_count:null,comments:typeof item.comments_count==="number"?item.comments_count:null};
      snapshots.push({organization_id:claim.organizationId,published_post_id:post.id,captured_at:capturedAt,...values,raw_metrics:{provider:"instagram",remote_media_id:post.remote_post_id,available_metrics:Object.entries(values).filter(([,value])=>value!==null).map(([key])=>key),captured_by:"supabase_analytics_worker",schema_version:1}});
    }
    if(snapshots.length){const saved=await db.from("metric_snapshots").upsert(snapshots,{onConflict:"published_post_id,captured_at"});if(saved.error)throw saved.error;}
    const until=Math.floor(Date.now()/1000);let account:Json={data:[]};try{account=await graph(`${claim.accountId}/insights?metric=reach,profile_views,follower_count&period=day&since=${until-90*86400}&until=${until}`,accessToken);}catch{/* account metric unavailable */}
    const days=new Map<string,Json>();for(const series of (Array.isArray(account.data)?account.data:[]) as Json[]){for(const point of (Array.isArray(series.values)?series.values:[]) as Json[]){if(typeof point.end_time!=="string"||typeof point.value!=="number")continue;const date=point.end_time.slice(0,10),entry=days.get(date)||{organization_id:claim.organizationId,social_connection_id:row.id,captured_for:date,reach:null,profile_visits:null,follower_count:null};if(series.name==="reach")entry.reach=point.value;if(series.name==="profile_views")entry.profile_visits=point.value;if(series.name==="follower_count")entry.follower_count=point.value;days.set(date,entry);}}
    if(days.size){const saved=await db.from("account_metric_snapshots").upsert([...days.values()].map((entry)=>({...entry,raw_metrics:{provider:"instagram",captured_at:capturedAt,captured_by:"supabase_analytics_worker",schema_version:1}})),{onConflict:"social_connection_id,captured_for"});if(saved.error)throw saved.error;}
    const finished=await db.rpc("instagram_connection_command",{p_action:"finish",p_user:null,p_brand:row.brand_id,p_data:{connectionId:row.id,revision:claim.revision,leaseId:claim.leaseId,status:"connected",scopes:connection.data.scopes,errorCode:null,errorMessage:null}});if(finished.error)throw finished.error;return true;
  }catch(error){await db.rpc("instagram_connection_command",{p_action:"finish",p_user:null,p_brand:row.brand_id,p_data:{connectionId:row.id,revision:claim.revision,leaseId:claim.leaseId,status:"error",errorCode:"analytics_sync_failed",errorMessage:"Instagram insights could not be refreshed."}});throw error;}
}
Deno.serve(async(request)=>{if(request.headers.get("authorization")!==`Bearer ${Deno.env.get("CRON_SECRET")}`)return response({error:"Unauthorized"},401);const db=createClient(env("SUPABASE_URL"),env("SUPABASE_SERVICE_ROLE_KEY"),{auth:{persistSession:false}});const due=await db.rpc("instagram_connection_command",{p_action:"due",p_user:null,p_brand:null,p_data:{}});if(due.error)return response({error:"Connections unavailable"},500);let synced=0,failed=0;for(const row of (due.data||[]) as Due[]){try{if(await sync(db,row))synced++;}catch(error){failed++;console.error("analytics_sync_failed",{connectionId:row.id,name:error instanceof Error?error.name:typeof error});}}return response({synced,failed},failed?207:200);});
