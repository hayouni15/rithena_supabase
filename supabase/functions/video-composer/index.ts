import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.4";

declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void };

const json=(body:Record<string,unknown>,status=200)=>new Response(JSON.stringify(body),{status,headers:{"content-type":"application/json","cache-control":"no-store"}});
const env=(name:string)=>{const value=Deno.env.get(name);if(!value)throw new Error(`${name} is not configured`);return value;};

async function renderVideo(admin: ReturnType<typeof createClient>, item: {id:string;organization_id:string;content_revision:number}, raw: {id:string;storage_bucket:string;storage_path:string}, composition: Record<string,unknown>&{duration:number;overlays:Array<{id:string;text:string}>;audio:{url:string}}, requestId: string) {
  try {
    const finalPath=`${item.organization_id}/${item.id}/composition-${item.content_revision}-${Date.now()}.mp4`;
    const [source,upload]=await Promise.all([admin.storage.from(raw.storage_bucket).createSignedUrl(raw.storage_path,900),admin.storage.from("creative-media").createSignedUploadUrl(finalPath)]);
    if(source.error||upload.error||!source.data?.signedUrl||!upload.data?.signedUrl)throw new Error("Secure render URLs could not be created.");
    const response=await fetch(`${env("MEDIA_COMPOSER_URL").replace(/\/$/,"")}/compose`,{method:"POST",headers:{authorization:`Bearer ${env("MEDIA_COMPOSER_SECRET")}`,"content-type":"application/json"},body:JSON.stringify({sourceUrl:source.data.signedUrl,outputUploadUrl:upload.data.signedUrl,durationSeconds:composition.duration,overlays:composition.overlays,logo:composition.logo,musicUrl:composition.audio.url,audio:composition.audio}),signal:AbortSignal.timeout(150_000)});
    if(!response.ok)throw new Error("The media renderer could not complete this video.");
    const result=await response.json() as {bytes?:number};
    const {data:asset,error}=await admin.from("media_assets").insert({organization_id:item.organization_id,content_item_id:item.id,asset_type:"video",origin:"generated",status:"ready",storage_bucket:"creative-media",storage_path:finalPath,mime_type:"video/mp4",file_size_bytes:result.bytes||null,provider:"media-composer",metadata:{rawMaster:false,compositionState:"rendered",renderRequestId:requestId,sourceAssetId:raw.id,composition}}).select("id").single();
    if(error||!asset)throw new Error("The rendered video could not be recorded.");
    const headline=composition.overlays.find(entry=>entry.id==="headline")?.text||"";const subhead=composition.overlays.find(entry=>entry.id==="subhead")?.text||"";const cta=composition.overlays.find(entry=>entry.id==="cta")?.text||"";
    const {data:variants}=await admin.from("platform_variants").select("id,post_copies(locale,caption,hashtags,title,description,version,is_selected)").eq("content_item_id",item.id).eq("organization_id",item.organization_id);
    for(const variant of variants||[]){const selected=[...(variant.post_copies||[])].sort((a,b)=>Number(b.is_selected)-Number(a.is_selected)||b.version-a.version)[0];if(!selected)continue;await admin.from("post_copies").update({is_selected:false}).eq("platform_variant_id",variant.id).eq("locale",selected.locale).eq("is_selected",true);await admin.from("post_copies").insert({organization_id:item.organization_id,platform_variant_id:variant.id,locale:selected.locale,version:Math.max(...variant.post_copies.map(copy=>copy.version))+1,is_selected:true,headline,subhead,call_to_action:cta,caption:selected.caption,hashtags:selected.hashtags,title:selected.title,description:selected.description});}
    await admin.from("platform_variants").update({selected_media_asset_id:asset.id,platform_config:{compositionState:"rendered",composition}}).eq("content_item_id",item.id).eq("organization_id",item.organization_id);
  } catch(error) {
    console.error("video-composer background render failed", {requestId, contentItemId:item.id, error:error instanceof Error?error.message:String(error)});
  }
}

Deno.serve(async(request)=>{
  if(request.method!=="POST")return json({error:"Method not allowed"},405);
  const supplied=request.headers.get("x-rithena-internal-secret")||"";if(!supplied||supplied!==env("VIDEO_COMPOSER_INTERNAL_SECRET"))return json({error:"Unauthorized"},401);
  const admin=createClient(env("SUPABASE_URL"),env("SUPABASE_SERVICE_ROLE_KEY"),{auth:{persistSession:false}});
  const body=await request.json() as {contentItemId:string;assetId:string;requestId:string;composition:Record<string,unknown>&{duration:number;overlays:Array<{id:string;text:string}>;audio:{url:string}}};
  const {data:item}=await admin.from("content_items").select("id,organization_id,status,content_revision").eq("id",body.contentItemId).maybeSingle();if(!item||!["ready_for_review","approved"].includes(item.status))return json({error:"This video is not ready for composition."},409);
  const {data:raw}=await admin.from("media_assets").select("id,storage_bucket,storage_path,metadata").eq("id",body.assetId).eq("content_item_id",item.id).eq("organization_id",item.organization_id).maybeSingle();if(!raw||(raw.metadata as Record<string,unknown>)?.rawMaster!==true)return json({error:"The raw video master is unavailable."},404);
  if(!body.requestId)return json({error:"A render request id is required."},400);
  EdgeRuntime.waitUntil(renderVideo(admin,item,raw,body.composition,body.requestId));
  return json({requestId:body.requestId,state:"rendering"},202);
});
