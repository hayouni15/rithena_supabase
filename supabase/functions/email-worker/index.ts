import { createClient } from "npm:@supabase/supabase-js@2";

type Delivery={id:string;user_id:string;event_type:string;event_key:string;payload:Record<string,unknown>};
// deno-lint-ignore no-explicit-any
type Db=any;

const env=(name:string)=>{const value=Deno.env.get(name)?.trim();if(!value)throw new Error(`${name} is missing`);return value;};
const json=(value:unknown,status=200)=>new Response(JSON.stringify(value),{status,headers:{"content-type":"application/json"}});
const escape=(value:unknown)=>String(value||"").replace(/[&<>"']/g,(char)=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;"})[char]!);
const text=(payload:Record<string,unknown>,key:string,fallback:string)=>typeof payload[key]==="string"&&payload[key]?String(payload[key]):fallback;
const appUrl=(path:string)=>new URL(path.startsWith("/")?path:`/${path}`,env("APP_URL")).toString();

function template(delivery:Delivery,firstName:string){
  const p=delivery.payload||{};const action=text(p,"actionUrl","/home");const handle=text(p,"handle","Instagram").replace(/^@/,"");
  const messages:Record<string,{subject:string;preheader:string;eyebrow:string;heading:string;body:string;cta:string}>={
    welcome:{subject:"Welcome to Rithena",preheader:"Your autonomous social workspace is ready.",eyebrow:"YOUR SOCIAL MEDIA · ALREADY HANDLED",heading:`Welcome${firstName?`, ${firstName}`:""}.`,body:`Your workspace for ${text(p,"brandName","your brand")} is ready. Rithena can now plan, create, review, and publish from one continuous workflow.`,cta:"Open your workspace"},
    first_week_ready:{subject:text(p,"title","Your first content week is ready"),preheader:"Review the plan and begin creative production.",eyebrow:"PLANNING COMPLETE",heading:text(p,"message","Your first week has a clear direction."),body:"Review the plan, adjust any timing, and start creative production when it feels right.",cta:"Review your plan"},
    content_ready:{subject:`Ready for review: ${text(p,"contentTitle","New creative")}`,preheader:"The media and platform copy are ready for your review.",eyebrow:"CREATIVE READY",heading:text(p,"contentTitle","A new creative is ready."),body:text(p,"message","The media and platform copy are ready for your review."),cta:"Review content"},
    content_published:{subject:`Published: ${text(p,"title","Your content")}`,preheader:"Your content is now live on Instagram.",eyebrow:"LIVE ON INSTAGRAM",heading:"Your content is published.",body:`${text(p,"title","Your post")} is now live on ${text(p,"platform","Instagram")}.`,cta:"Open published post"},
    generation_failed:{subject:"Creative production needs attention",preheader:"A creative stopped and needs your attention.",eyebrow:"ACTION NEEDED",heading:"A creative could not be completed.",body:text(p,"message","Open the content to see what happened and retry safely."),cta:"Review the issue"},
    publishing_failed:{subject:"Instagram publishing needs attention",preheader:"A scheduled post did not publish.",eyebrow:"ACTION NEEDED",heading:"A post did not publish.",body:text(p,"message","Open the post to review the failure and reschedule it."),cta:"Open the post"},
    connection_connected:{subject:"Instagram is connected",preheader:`@${handle} is ready for publishing.`,eyebrow:"CONNECTION READY",heading:"Instagram is connected.",body:`@${handle} is ready. Approved content can now be scheduled and published through Rithena.`,cta:"View connections"},
    connection_disconnected:{subject:"Instagram was disconnected",preheader:`@${handle} is no longer connected to Rithena.`,eyebrow:"CONNECTION UPDATED",heading:"Instagram was disconnected.",body:`Rithena no longer has access to @${handle}. Scheduled publishing through this connection will remain unavailable until you reconnect it.`,cta:"Reconnect Instagram"},
    connection_expired:{subject:"Reconnect Instagram",preheader:"Instagram access expired or was revoked.",eyebrow:"CONNECTION NEEDED",heading:"Instagram needs to be reconnected.",body:text(p,"message","Reconnect before the next scheduled post so publishing can continue."),cta:"Reconnect Instagram"},
  };
  const c=messages[delivery.event_type]||messages.generation_failed;
  const destination=delivery.event_type==="content_published"&&typeof p.remotePostUrl==="string"&&p.remotePostUrl?p.remotePostUrl:appUrl(action);
  const logo=appUrl("/logos/rithena-logo-dark-bg.png");
  const html=`<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="dark"><title>${escape(c.subject)}</title><style>a.email-button,a.email-button:link,a.email-button:visited{color:#172000!important;-webkit-text-fill-color:#172000!important}</style></head><body style="margin:0;background:#0e0f13;color:#e4e1e6;font-family:Arial,Helvetica,sans-serif"><div style="display:none;max-height:0;overflow:hidden;opacity:0">${escape(c.preheader)}</div><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#0e0f13"><tr><td align="center" style="padding:40px 16px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:620px"><tr><td style="padding:0 4px 24px"><img src="${escape(logo)}" width="170" height="60" alt="Rithena" style="display:block;width:170px;height:60px;object-fit:contain;border:0"></td></tr><tr><td style="background:#1b1b20;border:1px solid #303037;border-radius:16px;padding:42px 40px"><p style="margin:0 0 18px;color:#b8c3ff;font-size:11px;font-weight:700;letter-spacing:2px">${escape(c.eyebrow)}</p><h1 style="margin:0 0 18px;color:#f2eff4;font-size:30px;line-height:1.2">${escape(c.heading)}</h1><p style="margin:0 0 30px;color:#c4c5d9;font-size:15px;line-height:1.7">${escape(c.body)}</p><table role="presentation" cellpadding="0" cellspacing="0"><tr><td bgcolor="#bcfe00" style="border-radius:8px;background-color:#bcfe00"><a class="email-button" href="${escape(destination)}" target="_blank" style="display:inline-block;color:#172000!important;-webkit-text-fill-color:#172000!important;text-decoration:none;font-size:14px;font-weight:700;padding:14px 20px">${escape(c.cta)}</a></td></tr></table></td></tr><tr><td style="padding:24px 4px 0;color:#858592;font-size:11px;line-height:1.6"><p style="margin:0">Operational update from Rithena · Your social media, already handled.</p><p style="margin:6px 0 0">This email was sent because the state of your workspace changed.</p></td></tr></table></td></tr></table></body></html>`;
  return{subject:c.subject,html,plain:`${c.heading}\n\n${c.body}\n\n${c.cta}: ${destination}`};
}

async function checkpoint(db:Db,row:Delivery,worker:string,providerId:string|null,error:string|null){
  const result=await db.rpc("checkpoint_email_delivery",{p_id:row.id,p_worker_id:worker,p_provider_message_id:providerId,p_error:error});
  if(result.error)throw new Error(`Email checkpoint failed: ${result.error.message}`);
}

async function deliver(db:Db,row:Delivery,worker:string){
  try{
    const user=await db.auth.admin.getUserById(row.user_id);const recipient=user.data?.user?.email;
    if(user.error||!recipient)throw new Error("Recipient email is unavailable.");
    const firstName=String(user.data.user.user_metadata?.full_name||"").trim().split(/\s+/)[0];const message=template(row,firstName);
    const response=await fetch("https://api.resend.com/emails",{method:"POST",headers:{authorization:`Bearer ${env("RESEND_API_KEY")}`,"content-type":"application/json","idempotency-key":row.event_key.slice(0,256)},body:JSON.stringify({from:env("RESEND_FROM_EMAIL"),to:[recipient],reply_to:Deno.env.get("RESEND_REPLY_TO")?.trim()||undefined,subject:message.subject,html:message.html,text:message.plain,tags:[{name:"event",value:row.event_type}]}),signal:AbortSignal.timeout(20_000)});
    const body=await response.json().catch(()=>({})) as Record<string,unknown>;const providerId=typeof body.id==="string"?body.id:"";
    if(!response.ok||!providerId)throw new Error(typeof body.message==="string"?body.message:"Resend rejected the email.");
    await checkpoint(db,row,worker,providerId,null);return true;
  }catch(error){await checkpoint(db,row,worker,null,error instanceof Error?error.message:"Email delivery failed.");return false;}
}

Deno.serve(async(request)=>{
  const secret=Deno.env.get("CRON_SECRET");if(!secret||request.headers.get("authorization")!==`Bearer ${secret}`)return json({error:"Unauthorized"},401);
  const db=createClient(env("SUPABASE_URL"),env("SUPABASE_SERVICE_ROLE_KEY"),{auth:{persistSession:false}});const worker=`email-edge:${crypto.randomUUID()}`;
  const claimed=await db.rpc("claim_email_deliveries",{p_worker_id:worker,p_limit:10});if(claimed.error)return json({error:"Email queue could not be claimed."},500);
  const rows=(claimed.data||[]) as Delivery[];const results=await Promise.all(rows.map((row)=>deliver(db,row,worker)));
  return json({claimed:rows.length,sent:results.filter(Boolean).length,failed:results.filter((value)=>!value).length});
});
