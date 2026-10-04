/** Receipts grant no rights until an applicable commercial agreement and verified payment exist. */
export const COMMERCIAL_TERMS_VERSION='doin-commercial-1.0';
export const COMMERCIAL_TERMS=`doinWITH Commercial Use Terms 1.0 — Studio Yeehaw LLC
The purchasing legal entity may use, copy, modify and self-host doin.sh internally for its licensed users during the paid annual term. Each active internal user, including employees and contractors, occupies one purchased seat. Seats may be reassigned when a user leaves. Paid teams may choose their own infrastructure or the offered doin-operated team service. Personal subscriptions alone grant no business-use rights.
This grant permits internal organizational use and team features, not selling, renting, white-labeling, commercially redistributing copies or modifications, or providing a paid service to third parties. Third-party components retain their licenses; earlier MIT grants remain unchanged. Your task content remains yours.
The price is USD $99 per seat per year, annual only. Additions require explicit acceptance of the remaining-term prorated charge; no added seat is granted before payment. Removed users lose hosted access immediately; already-paid seats remain reusable until term end. Decreases apply to renewal without automatic midterm refunds. A requested renewal reduction reserves capacity: new members cannot join above that renewal seat limit unless the owner restores capacity. Restoring already-paid capacity within the current term adds no prorated charge; adding beyond it requires a separate confirmed charge. Cancellation stops renewal and retains licensed rights through the paid term. Taxes shown at payment are additional when applicable.
Self-hosted operators supply and manage infrastructure, backups, email and external provider credentials and costs. No certification, uptime commitment or enterprise support is implied. On expiry, organizational execution and team use require renewal. You retain ownership of all task data and may retain/export copies without using expired team features. An offline receipt is valid only for its signed term and seat limit and does not guarantee immediate remote revocation.
All rights not expressly granted are reserved. No trademark or commercial redistribution right is granted. The software is provided AS IS without warranty, subject to the disclaimer in its distributed LICENSE. These terms and the accepted price/quantity/term identify the commercial grant; a sandbox receipt is only test evidence and grants no production commercial rights.`;
export type LicenseEnv={LICENSE_SIGNING_KEY?:string;LICENSE_PUBLIC_KEY?:string;LICENSE_KEY_ID?:string;STRIPE_SECRET_KEY?:string;SELF_HOST_MODE?:string;SELF_HOST_OWNER_EMAIL?:string;COMMERCIAL_LICENSE_RECEIPT?:string};
export type LicenseClaims={version:1;issuer:'Studio Yeehaw LLC';key_id:string;team_id:string;legal_entity:string;seats:number;issued_at:number;expires_at:number;terms_version:string;environment:'test'|'live';scope:'internal-business-and-self-hosting'};
const enc=new TextEncoder();
const b64=(bytes:Uint8Array)=>btoa(String.fromCharCode(...bytes)).replaceAll('+','-').replaceAll('/','_').replaceAll('=','');
const decode=(text:string)=>Uint8Array.from(atob(text.replaceAll('-','+').replaceAll('_','/')),v=>v.charCodeAt(0));
const fail=(error:string):never=>{throw Response.json({error},{status:503});};
export async function issueLicense(env:LicenseEnv,claims:Omit<LicenseClaims,'version'|'issuer'|'key_id'|'issued_at'|'terms_version'|'environment'|'scope'>){
 if(!env.LICENSE_SIGNING_KEY||!env.LICENSE_PUBLIC_KEY||!env.LICENSE_KEY_ID)fail('license_signing_not_configured');
 const environment=/^(sk|rk)_test_/.test(env.STRIPE_SECRET_KEY||'')?'test':/^(sk|rk)_live_/.test(env.STRIPE_SECRET_KEY||'')?'live':fail('license_billing_unavailable');
 try{
  const privateJwk=JSON.parse(env.LICENSE_SIGNING_KEY),publicJwk=JSON.parse(env.LICENSE_PUBLIC_KEY);
  if(privateJwk.kty!=='OKP'||privateJwk.crv!=='Ed25519'||!privateJwk.d||publicJwk.d||publicJwk.x!==privateJwk.x)fail('license_signing_not_configured');
  const payload=b64(enc.encode(JSON.stringify({version:1,issuer:'Studio Yeehaw LLC',key_id:env.LICENSE_KEY_ID,issued_at:Math.floor(Date.now()/1000),terms_version:COMMERCIAL_TERMS_VERSION,environment,scope:'internal-business-and-self-hosting',...claims})));
  const key=await crypto.subtle.importKey('jwk',privateJwk,{name:'Ed25519'},false,['sign']);
  const signature=b64(new Uint8Array(await crypto.subtle.sign('Ed25519',key,enc.encode(`doin-license-v1.${payload}`))));
  return {receipt:`doin-license-v1.${payload}.${signature}`,environment,expires_at:claims.expires_at};
 }catch(error){if(error instanceof Response)throw error;fail('license_signing_unavailable');}
}
/** Trusted public key comes from deployment configuration, never from the untrusted receipt. */
export async function verifyLicense(receipt:string,publicJwk:JsonWebKey,keyId:string,expected:{entity?:string;team_id?:string;environment:'test'|'live'},time=Math.floor(Date.now()/1000)):Promise<LicenseClaims>{
 try{
  if(typeof receipt!=='string'||receipt.length>8192||publicJwk.d)throw new Error('invalid_license');
  const parts=receipt.split('.');if(parts.length!==3||parts[0]!=='doin-license-v1'||!parts.slice(1).every(v=>/^[A-Za-z0-9_-]+$/.test(v)))throw new Error('invalid_license');
  const key=await crypto.subtle.importKey('jwk',publicJwk,{name:'Ed25519'},false,['verify']);
  if(!await crypto.subtle.verify('Ed25519',key,decode(parts[2]),enc.encode(`${parts[0]}.${parts[1]}`)))throw new Error('invalid_license');
  const c=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(decode(parts[1])));
  if(c.version!==1||c.issuer!=='Studio Yeehaw LLC'||c.key_id!==keyId||c.terms_version!==COMMERCIAL_TERMS_VERSION||c.scope!=='internal-business-and-self-hosting'||c.environment!==expected.environment||!Number.isSafeInteger(c.seats)||c.seats<1||c.seats>10000||!Number.isSafeInteger(c.issued_at)||!Number.isSafeInteger(c.expires_at)||c.issued_at<0||c.issued_at>time+300||c.expires_at<=c.issued_at||c.expires_at<=time||typeof c.team_id!=='string'||typeof c.legal_entity!=='string'||(expected.entity!==undefined&&c.legal_entity!==expected.entity)||(expected.team_id!==undefined&&c.team_id!==expected.team_id))throw new Error('invalid_license');
  return c;
 }catch{throw new Error('invalid_or_expired_license');}
}

/** Self-hosted deployments receive only a receipt and a separately trusted public key. */
export async function selfHostLicense(env:LicenseEnv):Promise<LicenseClaims>{
 if(env.SELF_HOST_MODE!=='commercial'||!env.COMMERCIAL_LICENSE_RECEIPT||!env.LICENSE_PUBLIC_KEY||!env.LICENSE_KEY_ID)throw Response.json({error:'commercial_license_required'},{status:402});
 try{return await verifyLicense(env.COMMERCIAL_LICENSE_RECEIPT,JSON.parse(env.LICENSE_PUBLIC_KEY),env.LICENSE_KEY_ID,{environment:'live'});}
 catch{throw Response.json({error:'invalid_or_expired_commercial_license'},{status:402});}
}
