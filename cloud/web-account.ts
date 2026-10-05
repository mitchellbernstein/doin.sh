// Framework-free browser account surface. All credentials stay on this origin.
const html = `<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Account · doin.sh</title><link rel="stylesheet" href="/account.css"><script src="/account.js" defer></script></head>
<body><main>
<a href="https://doin.sh" class="brand">doin.sh</a><h1>Your account</h1><p id="message" role="status" aria-live="polite"></p>
<section id="login"><p>Sign in or create an account with your email.</p>
<form id="login-form"><label for="email">Email</label><input id="email" type="email" autocomplete="email" required maxlength="254"><button id="start" type="submit">Continue with email</button></form>
<div id="approval" hidden><p>Open the email link and enter this code to confirm this browser.</p><strong id="code"></strong><p>Keep this page open while you confirm.</p><button id="cancel-login" type="button">Cancel sign-in</button></div></section>
<section id="billing" hidden>
<p id="identity"></p><nav aria-label="Account sections" class="tabs"><button id="more-tab" type="button" aria-selected="true">doinMORE</button><button id="teams-tab" type="button" aria-selected="false">Teams</button></nav>
<section id="more-section" aria-labelledby="more-tab">
<h2>doinMORE</h2><p id="plan-status"></p><p id="period"></p><p id="pending-plan" hidden></p><p id="mode"></p>
<p class="note">AI providers you configure yourself work for free. doinMORE adds cloud sync and hosted account services.</p>
<div id="upgrade" hidden><label for="new-interval">Billing period</label><select id="new-interval"><option value="month">$4.99 USD / month</option><option value="year">$49.99 USD / year</option></select><button id="checkout" type="button">Upgrade on web</button></div>
<div id="change-plan" hidden><label for="change-interval">Change billing period</label><select id="change-interval"><option value="month">Monthly · $4.99 USD</option><option value="year">Yearly · $49.99 USD</option></select><button id="preview-change" type="button">Preview change</button><div id="change-preview" class="panel" hidden><p id="change-quote"></p><button id="confirm-change" type="button">Confirm plan change</button><button id="dismiss-change" type="button">Dismiss</button></div></div>
<div id="personal-payment" hidden><h3>Payment help</h3><p id="personal-recovery-note" hidden></p><button id="recover-personal" type="button" hidden>Get payment link</button><a id="personal-invoice-link" target="_blank" rel="noopener noreferrer" hidden>Open secure invoice</a><button id="personal-payment-method" type="button" hidden>Update payment method</button><a id="personal-portal-link" target="_blank" rel="noopener noreferrer" hidden>Open secure payment settings</a></div>
<button id="cancel-renewal" type="button" hidden>Cancel doinMORE renewal</button><button id="resume-renewal" type="button" hidden>Resume doinMORE renewal</button></section>
<section id="teams-section" aria-labelledby="teams-tab" hidden>
<h2>Teams</h2><p id="team-message" role="status" aria-live="polite"></p><p id="team-coexistence" class="note">Team billing is separate from your personal doinMORE subscription. Your personal sync data and billing stay with your account.</p>
<div id="team-list-panel" hidden><label for="team-select">Your teams</label><select id="team-select"></select><p id="team-role"></p><p id="team-billing-status"></p><p id="team-period"></p><p id="team-seat-counts"></p><p id="team-next-seats"></p><p id="team-pending"></p></div>
<div id="team-empty" hidden><p>No teams are connected to this account.</p></div><button id="refresh-teams" type="button">Refresh team status</button>
<div id="team-create"><h3>Create a commercial team</h3><p>A team is created without starting a subscription. Review the terms and enter the purchasing legal entity.</p>
<label for="team-name">Team name</label><input id="team-name" maxlength="120" autocomplete="organization-title"><label for="legal-entity">Purchasing legal entity</label><input id="legal-entity" maxlength="200" autocomplete="organization">
<details><summary id="terms-summary">Review commercial terms</summary><p id="terms-version"></p><pre id="terms-text"></pre></details>
<label class="check"><input id="accept-terms" type="checkbox"> I accept the terms for this legal entity.</label><button id="create-team" type="button" disabled>Create team</button></div>
<section id="team-owner-panel" hidden><div id="team-purchase" hidden><h3>Start a team subscription</h3><p id="team-purchase-copy"></p><label for="checkout-seats">Number of seats</label><input id="checkout-seats" type="number" min="1" max="10000" value="1" inputmode="numeric"><p id="team-total"></p><label class="check"><input id="confirm-team-terms" type="checkbox"> I reviewed these commercial terms and want to continue to secure checkout.</label><button id="team-checkout" type="button" disabled>Continue to checkout</button></div>
<div id="team-active-panel" hidden><h3>Team subscription</h3><div id="team-seat-change" class="panel"><label for="new-seats">Seats for renewal</label><input id="new-seats" type="number" min="1" max="10000" inputmode="numeric"><button id="preview-seats" type="button">Preview seat change</button><div id="seat-preview" hidden><p id="seat-quote"></p><button id="confirm-seats" type="button">Confirm seat change</button><button id="dismiss-seats" type="button">Dismiss</button></div></div>
<div class="actions"><button id="recover-team" type="button" hidden>Get payment link</button><a id="team-invoice-link" target="_blank" rel="noopener noreferrer" hidden>Open secure invoice</a><button id="team-payment-method" type="button">Update payment method</button><a id="team-portal-link" target="_blank" rel="noopener noreferrer" hidden>Open secure payment settings</a><button id="team-receipt" type="button">Download team receipt</button><button id="cancel-team" type="button" hidden>Cancel team renewal</button><button id="resume-team" type="button" hidden>Resume team renewal</button><button id="cancel-personal-for-team" type="button" hidden>Stop personal doinMORE renewal</button></div><p id="personal-stop-copy" class="note" hidden>This stops renewal on your personal subscription after its paid term. It does not move personal data or billing to this team.</p><div id="personal-stop-confirm" class="panel" hidden><label for="personal-stop-phrase">Type <code>cancel personal renewal</code> to confirm</label><input id="personal-stop-phrase" type="text" autocomplete="off" autocapitalize="off" spellcheck="false"><button id="confirm-personal-stop" type="button" disabled>Confirm personal renewal cancellation</button><button id="dismiss-personal-stop" type="button">Keep renewal active</button></div></div>
<div id="team-member-panel" hidden><p>Team billing is managed by an owner.</p></div></section></section><button id="refresh" type="button">Refresh account status</button><button id="logout" type="button">Sign out</button></section></main></body></html>`;
const css = `:root{color-scheme:light dark;font:16px system-ui;background:light-dark(#fafafa,#0c0c0c);color:light-dark(#202020,#ededed)}main{max-width:560px;margin:7vh auto;padding:24px}a{color:inherit}.brand{font-weight:700}h1{margin-top:36px}h2{margin-top:28px}h3{margin-bottom:8px}label{display:block;margin:16px 0 8px}input,select,button{font:inherit;box-sizing:border-box;border:1px solid light-dark(#ccc,#444);border-radius:12px;padding:12px;background:light-dark(#fff,#202020);color:inherit}input:not([type=checkbox]),select{width:100%}button{cursor:pointer;margin:14px 8px 0 0}button:disabled{opacity:.45;cursor:wait}input:focus-visible,select:focus-visible,button:focus-visible,a:focus-visible,summary:focus-visible{outline:2px solid #268bff;outline-offset:3px}.tabs{display:flex;gap:8px;border-bottom:1px solid light-dark(#ddd,#333)}.tabs button{border:0;border-radius:10px 10px 0 0;margin:8px 0 0}.tabs button[aria-selected=true]{background:#268bff;color:#fff}.note,#mode{color:light-dark(#666,#aaa);line-height:1.5}.panel{margin-top:16px;padding:16px;border:1px solid light-dark(#ddd,#333);border-radius:12px}.check{display:flex;align-items:flex-start;gap:10px}.check input{margin-top:5px}details{margin:18px 0}summary{cursor:pointer}pre{white-space:pre-wrap;font:inherit;font-size:.9em;max-height:300px;overflow:auto;padding:12px;background:light-dark(#f0f0f0,#171717);border-radius:8px}#code{font-size:32px;letter-spacing:.2em}#message,#team-message{min-height:24px}[hidden]{display:none!important}`;

const js = String.raw`'use strict';
const $=id=>document.getElementById(id), key='doin.browser.session.v1', selectedKey='doin.browser.team.v1';
let token=null, flow=0, timer=null, busy=false, initialRefresh=true, plan=null, account=null, billing=null, terms=null, teams=[], currentTeam=null, teamBilling=null, moreQuote=null, seatQuote=null;
try{token=sessionStorage.getItem(key);}catch{}
const paymentReturn=location.pathname==='/team/payment';
const paymentStatus=paymentReturn?new URL(location.href).searchParams.get('status'):null;
function message(text){$('message').textContent=text;}
function teamMessage(text){$('team-message').textContent=text;}
function forget(){token=null;try{sessionStorage.removeItem(key);sessionStorage.removeItem(selectedKey);}catch{} $('billing').hidden=true;$('login').hidden=false;}
function stop(){flow++;clearTimeout(timer);timer=null;$('approval').hidden=true;$('login-form').hidden=false;}
function apiError(response){if(response.status===401)return 'Please sign in again.';if(response.status===402)return 'This account or team needs an active subscription.';if(response.status===403)return 'This action is limited to team owners.';if(response.status===404)return 'That account or team could not be found.';if(response.status===409)return 'Billing is busy or needs attention. Refresh and try again.';if(response.status===503)return 'Service unavailable. Try again later.';return 'Unable to complete that request.';}
async function api(path,data,authenticated=false){
 const controller=new AbortController(),timeout=setTimeout(()=>controller.abort(),15000);
 try{
  const response=await fetch(path,{method:data===undefined?'GET':'POST',credentials:'omit',cache:'no-store',redirect:'error',signal:controller.signal,headers:{...(data===undefined?{}:{'content-type':'application/json'}),...(authenticated?{authorization:'Bearer '+token}:{})},...(data===undefined?{}:{body:JSON.stringify(data)})});
  let result={};try{result=await response.json();}catch{}
  if(!response.ok){if(response.status===401&&authenticated)forget();throw new Error(apiError(response));}
  return {status:response.status,data:result};
 }finally{clearTimeout(timeout);}
}
async function lock(action){if(busy)return;busy=true;document.querySelectorAll('button').forEach(b=>b.disabled=true);try{await action();}catch(error){message(error.message||'Unable to complete that request.');teamMessage(error.message||'Unable to complete that request.');}finally{busy=false;document.querySelectorAll('button').forEach(b=>{if(b.id==='create-team')b.disabled=!terms||!$('accept-terms').checked;else if(b.id==='team-checkout')b.disabled=!$('confirm-team-terms').checked;else if(b.id==='confirm-change')b.disabled=!moreQuote;else if(b.id==='confirm-seats')b.disabled=!seatQuote;else if(b.id==='confirm-personal-stop')b.disabled=$('personal-stop-phrase').value!=='cancel personal renewal';else b.disabled=false;});}}
function money(amount,currency='usd'){if(!Number.isSafeInteger(amount))return 'an unavailable amount';return new Intl.NumberFormat(undefined,{style:'currency',currency:currency.toUpperCase()}).format(amount/100);}
function date(value){return Number.isSafeInteger(value)&&value>0?new Date(value*1000).toLocaleDateString():'';}
function instant(value){return Number.isSafeInteger(value)&&value>0?new Date(value*1000).toLocaleString():'';}
function updateCheckoutTotal(){if(!terms){$('team-total').textContent='';return;}const seats=Number($('checkout-seats').value),total=seats*terms.amount;$('team-total').textContent=Number.isSafeInteger(seats)&&seats>=1&&seats<=10000&&Number.isSafeInteger(total)?'Estimated annual total before applicable taxes: '+money(total,terms.currency)+' / year':'Enter a valid seat count.';}
function validDestination(value,host){let u;try{u=new URL(value);}catch{throw new Error('Invalid billing destination.');}if(u.protocol!=='https:'||u.hostname!==host||u.username||u.password||u.port)throw new Error('Invalid billing destination.');return u.href;}
function openExternalLink(anchor,url,host,label){anchor.href=validDestination(url,host);anchor.textContent=label;anchor.hidden=false;}
function hideExternalLinks(){for(const id of ['personal-invoice-link','personal-portal-link','team-invoice-link','team-portal-link']){$(id).hidden=true;$(id).removeAttribute('href');}}
function setView(name){const isMore=name==='more';$('more-section').hidden=!isMore;$('teams-section').hidden=isMore;$('more-tab').setAttribute('aria-selected',String(isMore));$('teams-tab').setAttribute('aria-selected',String(!isMore));}
async function loadTerms(){terms=(await api('/v1/teams/terms',undefined,true)).data;if(typeof terms.version!=='string'||typeof terms.text!=='string'||typeof terms.name!=='string'||!Number.isSafeInteger(terms.amount)||terms.currency!=='usd'||terms.interval!=='year')throw new Error('Team terms are unavailable.');$('terms-version').textContent='Version '+terms.version;$('terms-text').textContent=terms.text;$('terms-summary').textContent='Review '+terms.name+' commercial terms';$('team-purchase-copy').textContent=terms.name+' is '+money(terms.amount)+' per seat per '+terms.interval+'. Checkout will show any applicable taxes. Team subscription and personal doinMORE billing are separate.';$('team-create').hidden=!terms.billing_ready;updateCheckoutTotal();}
function safeTeamId(value){if(typeof value!=='string'||!/^[a-zA-Z0-9-]{1,80}$/.test(value))throw new Error('Invalid team selection.');return value;}
function teamPath(action=''){return '/v1/teams/'+encodeURIComponent(safeTeamId(currentTeam.id))+(action?'/'+action:'');}
function renderMore(){
 const active=!!billing.active,canChange=active&&!billing.cancel_at_period_end&&!billing.pending_update&&['month','year'].includes(billing.interval);
 $('plan-status').textContent=active?'Active · '+(billing.interval==='year'?'yearly':'monthly'):'Not active';
 $('period').textContent=billing.current_period_end?((billing.cancel_at_period_end?'Access until ':'Renews ')+date(billing.current_period_end)):'';
 $('pending-plan').hidden=!billing.pending_update;$('pending-plan').textContent=billing.pending_update?'A plan payment is pending'+(billing.pending_interval?' for '+billing.pending_interval+' billing.':'.'):'';
 $('mode').textContent=plan.billing_mode==='test'?'Sandbox billing. No live payment.':plan.billing_ready?'':'Billing is temporarily unavailable.';
 $('upgrade').hidden=active||!plan.billing_ready||!!account.deletion_pending;$('change-plan').hidden=!canChange;
 if(billing.interval)$('change-interval').value=billing.interval==='month'?'year':'month';
 $('cancel-renewal').hidden=!active||billing.cancel_at_period_end||billing.status==='personal_self_hosted';$('resume-renewal').hidden=!active||!billing.cancel_at_period_end;
 const needsRecovery=['past_due','incomplete','unpaid'].includes(billing.status)||!!billing.pending_update;
 $('personal-payment').hidden=!active&&!needsRecovery;$('personal-recovery-note').hidden=!needsRecovery;$('personal-recovery-note').textContent=billing.pending_update?'A plan change is waiting for payment.':'There is an unpaid invoice for this subscription.';$('recover-personal').hidden=!needsRecovery;$('personal-payment-method').hidden=!active&&!needsRecovery;
 $('personal-invoice-link').hidden=true;$('personal-portal-link').hidden=true;
}
function renderPaymentReturn(){if(!paymentReturn)return;if(paymentStatus==='success')message('Checkout returned successfully. Checking your authenticated team status.');else if(paymentStatus==='canceled')message('Checkout was canceled. No team access was added.');else message('Returned from team checkout. Refresh to check authenticated billing status.');}
function showTeamOwner(isOwner){$('team-owner-panel').hidden=!isOwner;$('team-member-panel').hidden=isOwner;}
function renderTeam(){
 const has=currentTeam!==null;$('team-list-panel').hidden=!teams.length;$('team-empty').hidden=teams.length!==0;$('team-create').hidden=!terms||!terms.billing_ready;
 if(!has){showTeamOwner(false);$('team-billing-status').textContent='';$('team-period').textContent='';$('team-seat-counts').textContent='';return;}
 const isOwner=currentTeam.role==='owner';$('team-role').textContent='Your role: '+currentTeam.role;showTeamOwner(isOwner);
 if(!isOwner){$('team-billing-status').textContent='Billing details are available to the team owner.';$('team-period').textContent='';$('team-seat-counts').textContent='';$('team-next-seats').textContent='';return;}
 if(!teamBilling){$('team-billing-status').textContent='Loading team billing status…';$('team-active-panel').hidden=true;$('team-purchase').hidden=true;return;}
 const active=!!teamBilling.active;$('team-billing-status').textContent=active?'Active · '+(teamBilling.status||'team subscription'):'Not active';
 $('team-period').textContent=teamBilling.current_period_end?(teamBilling.cancel_at_period_end?'Access until ':'Renews ')+date(teamBilling.current_period_end):'';
 $('team-seat-counts').textContent=active?'Paid seats: '+teamBilling.paid_seats+' · Occupied: '+teamBilling.occupied_seats:'';
 $('team-next-seats').textContent=active?'Seats at renewal: '+teamBilling.next_renewal_seats:'';
 $('team-pending').textContent=teamBilling.pending_update?'A team seat payment is pending. Refresh status after payment.':'';
 $('team-purchase').hidden=active||!terms||!terms.billing_ready;$('team-active-panel').hidden=!active;
 if(!active&&terms&&terms.billing_ready){$('team-purchase-copy').textContent='Team: '+currentTeam.name+'. '+terms.name+' costs '+money(terms.amount)+' per seat per '+terms.interval+'. Your personal doinMORE billing stays separate.';updateCheckoutTotal();}
 if(active){$('new-seats').value=String(teamBilling.next_renewal_seats||teamBilling.paid_seats||1);$('cancel-team').hidden=!!teamBilling.cancel_at_period_end;$('resume-team').hidden=!teamBilling.cancel_at_period_end;$('recover-team').hidden=!['past_due','incomplete','unpaid'].includes(teamBilling.status)&&!teamBilling.pending_update;$('team-invoice-link').hidden=true;$('team-portal-link').hidden=true;
  const personalActive=!!billing.active&&!billing.cancel_at_period_end;$('cancel-personal-for-team').hidden=!personalActive||!isOwner;$('personal-stop-copy').hidden=!personalActive||!isOwner;
 }else{$('cancel-personal-for-team').hidden=true;$('personal-stop-copy').hidden=true;}
 if(paymentReturn&&paymentStatus==='success')message(active?'Checkout returned. Authenticated team billing confirms access.':'Checkout returned, but the authenticated team status is not active yet. Refresh after payment clears.');
}
async function selectTeam(id){const found=teams.find(t=>t.id===id);currentTeam=found||null;teamBilling=null;seatQuote=null;$('seat-preview').hidden=true;if(currentTeam){try{sessionStorage.setItem(selectedKey,currentTeam.id);}catch{}if(currentTeam.role==='owner'){try{teamBilling=(await api(teamPath('billing'),undefined,true)).data;}catch(error){renderTeam();teamMessage(error.message);return;}}}renderTeam();}
async function loadTeams(){
 hideExternalLinks();teamMessage('');
 try{const result=(await api('/v1/teams',undefined,true)).data;teams=Array.isArray(result.teams)?result.teams.filter(t=>t&&typeof t.id==='string'&&typeof t.name==='string'&&['owner','admin','member'].includes(t.role)):[];}
 catch(error){teams=[];currentTeam=null;$('team-list-panel').hidden=true;$('team-empty').hidden=true;showTeamOwner(false);teamMessage(error.message);return;}
 let selected=null;try{selected=sessionStorage.getItem(selectedKey);}catch{}const select=$('team-select');select.replaceChildren();
 for(const t of teams){const option=document.createElement('option');option.value=t.id;option.textContent=t.name+' · '+t.role;select.append(option);}
 if(!teams.some(t=>t.id===selected))selected=teams[0]?.id||null;
 if(selected){select.value=selected;await selectTeam(selected);}else{currentTeam=null;teamBilling=null;renderTeam();}
}
async function refresh(){
 moreQuote=null;$('change-preview').hidden=true;
 const [accountResponse,billingResponse,planResponse]=await Promise.all([api('/v1/account',undefined,true),api('/v1/billing',undefined,true),api('/v1/plan')]);
 account=accountResponse.data;billing=billingResponse.data;plan=planResponse.data;$('identity').textContent=account.email;renderMore();$('billing').hidden=false;$('login').hidden=true;renderPaymentReturn();
 try{await loadTerms();}catch(error){terms=null;$('team-create').hidden=true;teamMessage(error.message);}
 await loadTeams();
 if(paymentReturn&&paymentStatus!=='success'&&paymentStatus!=='canceled'&&teams.length===0)message('Returned from team checkout. Sign-in succeeded; authenticated team status is empty.');
 if(initialRefresh){if(paymentReturn)setView('teams');initialRefresh=false;}
 if(!paymentReturn)message('');
}
async function refreshTeam(){if(!currentTeam)return await loadTeams();await selectTeam(currentTeam.id);}
function setQuoteText(node,quote){if(quote.renewal_only)node.textContent='This changes seats at renewal only. No refund is due for this term. Paid capacity remains available until '+date(quote.current_period_end)+'. New members cannot exceed the new renewal seat limit.';else node.textContent='The immediate charge is '+money(quote.amount_due,quote.currency)+'. The change covers '+quote.seats+' seats.'+(quote.expires_at?' Quote expires '+instant(quote.expires_at)+'.':' Confirm this preview now.');}
async function downloadReceipt(){const result=(await api(teamPath('receipt'),undefined,true)).data;const body=JSON.stringify(result,null,2),blob=new Blob([body],{type:'application/json'}),url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download='doinWITH-receipt.json';a.rel='noopener';document.body.append(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),1000);teamMessage('Team receipt downloaded.');}
$('login-form').addEventListener('submit',event=>{event.preventDefault();lock(async()=>{
 stop();const id=flow;const verifier=Array.from(crypto.getRandomValues(new Uint8Array(32)),b=>b.toString(16).padStart(2,'0')).join('');const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(verifier));
 const challenge=btoa(String.fromCharCode(...new Uint8Array(digest))).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');const start=(await api('/v1/auth/start',{email:$('email').value.trim(),name:'doin web browser',code_challenge:challenge})).data;
 if(id!==flow)return;if(typeof start.request_id!=='string'||!/^[0-9]{6}$/.test(start.confirmation_code))throw new Error('Unable to start sign-in.');
 $('code').textContent=start.confirmation_code;$('approval').hidden=false;$('login-form').hidden=true;message('Check your email.');const deadline=Date.now()+Math.min(600,Number(start.expires_in)||600)*1000;
 const poll=async()=>{if(id!==flow)return;if(Date.now()>deadline){stop();message('Sign-in expired. Try again.');return;}try{const result=await api('/v1/auth/poll',{request_id:start.request_id,code_verifier:verifier});if(id!==flow)return;if(result.status===202){timer=setTimeout(poll,2000);return;}if(typeof result.data.token!=='string'||!result.data.token)throw new Error('Unable to finish sign-in.');token=result.data.token;try{sessionStorage.setItem(key,token);}catch{}stop();await refresh();}catch(error){if(id!==flow)return;stop();message(error.message);}};
 timer=setTimeout(poll,2000);
});});
$('cancel-login').addEventListener('click',()=>{stop();message('Sign-in canceled.');});
$('more-tab').addEventListener('click',()=>setView('more'));$('teams-tab').addEventListener('click',()=>setView('teams'));
$('refresh-teams').addEventListener('click',()=>lock(loadTeams));$('team-select').addEventListener('change',event=>lock(()=>selectTeam(event.target.value)));
$('accept-terms').addEventListener('change',()=>{$('create-team').disabled=!terms||!$('accept-terms').checked;});
$('create-team').addEventListener('click',()=>lock(async()=>{
 if(!terms||!$('accept-terms').checked)throw new Error('Review and accept the commercial terms first.');
 if(!$('team-name').value.trim()||!$('legal-entity').value.trim())throw new Error('Enter a team name and purchasing legal entity.');
 const body={name:$('team-name').value.trim(),legal_entity:$('legal-entity').value.trim(),deployment:'hosted',accepted_terms:terms.version};
 const created=(await api('/v1/teams',body,true)).data;$('accept-terms').checked=false;$('team-name').value='';$('legal-entity').value='';teamMessage('Team created. No subscription or payment has started.');
 await loadTeams();if(created&&typeof created.id==='string')await selectTeam(created.id);
}));
$('confirm-team-terms').addEventListener('change',()=>{$('team-checkout').disabled=!$('confirm-team-terms').checked;});
$('checkout-seats').addEventListener('input',updateCheckoutTotal);
$('team-select').addEventListener('change',()=>{$('confirm-team-terms').checked=false;$('team-checkout').disabled=true;});
$('team-checkout').addEventListener('click',()=>lock(async()=>{
 if(!$('confirm-team-terms').checked||!terms)throw new Error('Review the terms and confirm before continuing.');
 const seats=Number($('checkout-seats').value);if(!Number.isSafeInteger(seats)||seats<1||seats>10000)throw new Error('Enter a valid seat count.');
 const result=(await api(teamPath('checkout'),{seats,accepted_terms:terms.version},true)).data;location.assign(validDestination(result.url,'checkout.stripe.com'));
}));
$('preview-change').addEventListener('click',()=>lock(async()=>{
 const interval=$('change-interval').value;if(!['month','year'].includes(interval)||interval===billing.interval)throw new Error('Choose a different billing period.');
 const result=(await api('/v1/billing/change',{interval},true)).data;
 if(!result.confirmation_required||typeof result.quote_id!=='string'||!Number.isSafeInteger(result.amount_due)||result.currency!=='usd'||result.interval!==interval||!Number.isSafeInteger(result.expires_at)||!Number.isSafeInteger(result.proration_date))throw new Error('Unable to verify the billing preview. Refresh and try again.');
 if(result.expires_at<=Math.floor(Date.now()/1000))throw new Error('That billing preview expired. Request a fresh preview.');
 moreQuote={...result,interval};$('change-quote').textContent='Change to '+interval+' billing. The confirmed charge is '+money(result.amount_due,result.currency)+'. Proration is calculated at '+instant(result.proration_date)+'. Quote expires '+instant(result.expires_at)+'.';$('change-preview').hidden=false;
}));
$('change-interval').addEventListener('change',()=>{moreQuote=null;$('change-preview').hidden=true;});
$('confirm-change').addEventListener('click',()=>lock(async()=>{
 if(!moreQuote)throw new Error('Request a fresh billing preview first.');const quote=moreQuote;if(quote.expires_at<=Math.floor(Date.now()/1000)){moreQuote=null;$('change-preview').hidden=true;throw new Error('That billing preview expired. Request a fresh preview.');}let result;try{result=(await api('/v1/billing/change',{interval:quote.interval,quote_id:quote.quote_id,confirm_amount:quote.amount_due},true)).data;}catch(error){moreQuote=null;$('change-preview').hidden=true;try{await refresh();}catch{}throw error;}
 if(result.confirmation_required){if(result.quote_id!==quote.quote_id||result.interval!==quote.interval||result.currency!=='usd'||!Number.isSafeInteger(result.amount_due)||!Number.isSafeInteger(result.expires_at)||!Number.isSafeInteger(result.proration_date))throw new Error('Unable to verify the updated billing quote.');moreQuote=result;$('change-quote').textContent='The billing amount changed. Review the updated '+result.interval+' plan charge of '+money(result.amount_due,result.currency)+'. Proration is calculated at '+instant(result.proration_date)+'. Quote expires '+instant(result.expires_at)+'. Confirm again to accept this amount.';return;}
 moreQuote=null;$('change-preview').hidden=true;await refresh();message(result.payment_pending?'Plan change submitted. Payment is still pending.':result.changed?'Plan changed to '+(result.interval||quote.interval)+' billing.':'Your plan remains '+(result.interval||billing.interval)+' billing.');
}));
$('dismiss-change').addEventListener('click',()=>{moreQuote=null;$('change-preview').hidden=true;});
$('checkout').addEventListener('click',()=>lock(async()=>{const result=(await api('/v1/checkout',{interval:$('new-interval').value},true)).data;location.assign(validDestination(result.url,'checkout.stripe.com'));}));
$('cancel-renewal').addEventListener('click',()=>lock(async()=>{if(!confirm('Cancel doinMORE renewal? Paid access stays until the current period ends.'))return;await api('/v1/billing/cancel',{},true);await refresh();message('doinMORE renewal canceled. Paid access remains through the current term.');}));
$('resume-renewal').addEventListener('click',()=>lock(async()=>{if(!confirm('Resume renewal for your existing doinMORE subscription?'))return;await api('/v1/billing/resume',{},true);await refresh();message('doinMORE renewal resumed.');}));
$('recover-personal').addEventListener('click',()=>lock(async()=>{const result=(await api('/v1/billing/recover',{},true)).data;openExternalLink($('personal-invoice-link'),result.url,'invoice.stripe.com','Open secure invoice');}));
$('personal-payment-method').addEventListener('click',()=>lock(async()=>{const result=(await api('/v1/billing/portal',{},true)).data;openExternalLink($('personal-portal-link'),result.url,'billing.stripe.com','Open secure payment settings');}));
$('refresh').addEventListener('click',()=>lock(refresh));
$('preview-seats').addEventListener('click',()=>lock(async()=>{
 if(!currentTeam||currentTeam.role!=='owner')throw new Error('Only a team owner can change seats.');const seats=Number($('new-seats').value);if(!Number.isSafeInteger(seats)||seats<1||seats>10000)throw new Error('Enter a valid seat count.');
 const result=(await api(teamPath('seats'),{seats},true)).data;if(result.confirmation_required){seatQuote={...result,seats};setQuoteText($('seat-quote'),seatQuote);$('seat-preview').hidden=false;}else{seatQuote=null;await refreshTeam();teamMessage(result.changed?'Seat change completed.':'No seat change was needed.');}
}));
$('new-seats').addEventListener('input',()=>{seatQuote=null;$('seat-preview').hidden=true;});
$('confirm-seats').addEventListener('click',()=>lock(async()=>{
 if(!seatQuote)throw new Error('Request a fresh seat preview first.');const q=seatQuote,body={seats:q.seats};if(q.renewal_only)body.confirm_renewal_reduction=true;else{body.confirm_amount=q.amount_due;body.proration_date=q.proration_date;}
 let result;try{result=(await api(teamPath('seats'),body,true)).data;}catch(error){seatQuote=null;$('seat-preview').hidden=true;try{await refreshTeam();}catch{}throw error;}if(result.confirmation_required){seatQuote={...result,seats:q.seats};setQuoteText($('seat-quote'),seatQuote);teamMessage('The seat quote changed. Review the updated amount and confirm again.');return;}seatQuote=null;$('seat-preview').hidden=true;await refreshTeam();teamMessage(result.payment_pending?'Seat change submitted. Payment is pending.':'Team seats updated.');
}));
$('dismiss-seats').addEventListener('click',()=>{seatQuote=null;$('seat-preview').hidden=true;});
$('recover-team').addEventListener('click',()=>lock(async()=>{const result=(await api(teamPath('recover'),{},true)).data;openExternalLink($('team-invoice-link'),result.url,'invoice.stripe.com','Open secure invoice');}));
$('team-payment-method').addEventListener('click',()=>lock(async()=>{const result=(await api(teamPath('portal'),{},true)).data;openExternalLink($('team-portal-link'),result.url,'billing.stripe.com','Open secure payment settings');}));
$('team-receipt').addEventListener('click',()=>lock(downloadReceipt));
$('cancel-team').addEventListener('click',()=>lock(async()=>{if(!confirm('Cancel this team renewal? Paid team access and seats remain through the current term.'))return;await api(teamPath('cancel'),{},true);await refreshTeam();teamMessage('Team renewal canceled. Paid team access remains through the current term.');}));
$('resume-team').addEventListener('click',()=>lock(async()=>{if(!confirm('Resume renewal for this team?'))return;await api(teamPath('resume'),{},true);await refreshTeam();teamMessage('Team renewal resumed.');}));
$('cancel-personal-for-team').addEventListener('click',()=>{if(!currentTeam||currentTeam.role!=='owner')return;$('personal-stop-phrase').value='';$('confirm-personal-stop').disabled=true;$('personal-stop-confirm').hidden=false;$('personal-stop-phrase').focus();});
$('personal-stop-phrase').addEventListener('input',()=>{$('confirm-personal-stop').disabled=$('personal-stop-phrase').value!=='cancel personal renewal';});
$('dismiss-personal-stop').addEventListener('click',()=>{$('personal-stop-confirm').hidden=true;$('personal-stop-phrase').value='';});
$('confirm-personal-stop').addEventListener('click',()=>lock(async()=>{
 const confirmation=$('personal-stop-phrase').value;if(confirmation!=='cancel personal renewal')throw new Error('Type the exact confirmation phrase before continuing.');
 await api(teamPath('personal-renewal/cancel'),{confirmation},true);$('personal-stop-confirm').hidden=true;$('personal-stop-phrase').value='';await refresh();setView('teams');teamMessage('Personal doinMORE renewal canceled. Its paid term and data remain on your personal account.');
}));
$('logout').addEventListener('click',()=>lock(async()=>{await api('/v1/logout',{},true);forget();stop();message('Signed out.');}));
window.addEventListener('pagehide',stop);
if(token)lock(refresh);else renderPaymentReturn();
`;
export function webAccount(request: Request): Response | null {
 const path=new URL(request.url).pathname;
 if(request.method!=='GET'||!['/account','/account.js','/account.css','/team/payment'].includes(path))return null;
 const content=path==='/account'||path==='/team/payment'?html:path==='/account.js'?js:css;
 return new Response(content,{headers:{'content-type':path==='/account.js'?'text/javascript; charset=utf-8':path==='/account.css'?'text/css; charset=utf-8':'text/html; charset=utf-8','cache-control':'no-store','referrer-policy':'no-referrer','x-content-type-options':'nosniff','content-security-policy':"default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"}});
}
