import {useCallback,useEffect,useState,type FormEvent} from 'react'
import {supabase} from './lib/supabase'
type Props={organizationId:string;role:string;notify:(message:string,isError?:boolean)=>void}
type Member={user_id:string;email:string;role:string;joined_at:string}
type Invitation={id:string;invited_email:string;role:string;expires_at:string;accepted_at:string|null;revoked_at:string|null}
type Plan={code:string;title:string;monthly_price_cad:number;features:{users:number;receipt_ocr_monthly:number;bank_connections:number;api_access:boolean}}
type Subscription={plan_code:string|null;status:string;current_period_end:string|null;cancel_at_period_end:boolean}
type Audit={id:number;action:string;entity_type:string;occurred_at:string;details:Record<string,unknown>}
const roles=['administrator','accountant','bookkeeper','viewer']
const apiUrl=(import.meta.env.VITE_BILLING_API_URL||'').replace(/\/$/,'')
export default function BusinessAdministration({organizationId,role,notify}:Props){
 const [members,setMembers]=useState<Member[]>([])
 const [invitations,setInvitations]=useState<Invitation[]>([])
 const [plans,setPlans]=useState<Plan[]>([])
 const [subscription,setSubscription]=useState<Subscription|null>(null)
 const [entitlements,setEntitlements]=useState<Record<string,unknown>|null>(null)
 const [audit,setAudit]=useState<Audit[]>([])
 const [email,setEmail]=useState('')
 const [newRole,setNewRole]=useState('bookkeeper')
 const [invitationLink,setInvitationLink]=useState('')
 const [busy,setBusy]=useState(false)
 const [acceptToken,setAcceptToken]=useState(()=>new URLSearchParams(window.location.hash.slice(1)).get('invite')||'')
 const canManage=role==='owner'||role==='administrator'
 const canSeeAudit=canManage||role==='accountant'
 const refresh=useCallback(async()=>{
   if(!supabase||!organizationId)return
   const [m,i,p,s,e,a]=await Promise.all([
    supabase.rpc('list_organization_members',{p_org:organizationId}),
    supabase.from('organization_invitations').select('id,invited_email,role,expires_at,accepted_at,revoked_at').eq('organization_id',organizationId).order('created_at',{ascending:false}).limit(50),
    supabase.from('subscription_plans').select('code,title,monthly_price_cad,features').order('monthly_price_cad'),
    supabase.from('organization_subscriptions').select('plan_code,status,current_period_end,cancel_at_period_end').eq('organization_id',organizationId).maybeSingle(),
    supabase.rpc('organization_entitlements',{p_org:organizationId}),
    supabase.from('audit_events').select('id,action,entity_type,occurred_at,details').eq('organization_id',organizationId).order('occurred_at',{ascending:false}).limit(100)
   ])
   if(m.error)throw m.error
   if(p.error)throw p.error
   if(s.error)throw s.error
   if(e.error)throw e.error
   if(canManage&&i.error)throw i.error
   if(canSeeAudit&&a.error)throw a.error
   setMembers((m.data||[]) as Member[])
   setInvitations(canManage?(i.data||[]) as Invitation[]:[])
   setPlans((p.data||[]) as Plan[])
   setSubscription(s.data as Subscription|null)
   setEntitlements(e.data as Record<string,unknown>|null)
   setAudit(canSeeAudit?(a.data||[]) as Audit[]:[])
 },[organizationId,canManage,canSeeAudit])
 useEffect(()=>{void refresh().catch(e=>notify(e.message,true))},[refresh])
 const run=async(work:()=>Promise<void>)=>{setBusy(true);try{await work()}catch(e){notify(e instanceof Error?e.message:String(e),true)}finally{setBusy(false)}}
 const invite=(e:FormEvent)=>{e.preventDefault();void run(async()=>{
   if(!supabase)return
   const {data,error}=await supabase.rpc('invite_organization_member',{p_org:organizationId,p_email:email.trim(),p_role:newRole})
   if(error)throw error
   // Keep the bearer token out of server access logs and HTTP referer headers.
   setInvitationLink(window.location.origin+window.location.pathname+'#invite='+data)
   await refresh();notify('Invitation created. Share the link privately with the intended user.')
 })}
 const revoke=(id:string)=>void run(async()=>{
  if(!supabase)return
  const {error}=await supabase.rpc('revoke_organization_invitation',{p_org:organizationId,p_invitation:id})
  if(error)throw error
  await refresh();notify('Invitation revoked.')
 })
 const changeRole=(userId:string,next:string)=>void run(async()=>{
  if(!supabase)return
  const {error}=await supabase.rpc('set_organization_member_role',{p_org:organizationId,p_user:userId,p_role:next})
  if(error)throw error
  await refresh();notify('Member role updated.')
 })
 const remove=(userId:string)=>void run(async()=>{
  if(!supabase)return
  const {error}=await supabase.rpc('remove_organization_member',{p_org:organizationId,p_user:userId})
  if(error)throw error
  await refresh();notify('Member removed.')
 })
 const accept=(e:FormEvent)=>{e.preventDefault();void run(async()=>{
  if(!supabase)return
  const {error}=await supabase.rpc('accept_organization_invitation',{p_token:acceptToken.trim()})
  if(error)throw error
  setAcceptToken('')
  if(window.location.hash.includes('invite='))history.replaceState(null,'',window.location.pathname+window.location.search)
  await refresh();notify('Invitation accepted. Switch to the invited business to access its books.')
 })}
 const billing=(operation:'checkout'|'portal',code?:string)=>void run(async()=>{
  if(!supabase)throw new Error('Authentication unavailable')
  if(!apiUrl)throw new Error('VITE_BILLING_API_URL must be configured')
  const {data,error}=await supabase.auth.getSession()
  if(error||!data.session)throw new Error('Sign in first')
  const response=await fetch(apiUrl+'/billing/'+operation,{
   method:'POST',headers:{Authorization:'Bearer '+data.session.access_token,'Content-Type':'application/json'},
   body:JSON.stringify({organizationId,...(code?{planCode:code}:{})})
  })
  const result=await response.json() as {url?:string;error?:string}
  if(!response.ok||!result.url)throw new Error(result.error||'Billing API request failed')
  if(!result.url.startsWith('https://checkout.stripe.com/')&&!result.url.startsWith('https://billing.stripe.com/'))
   throw new Error('Unexpected billing destination')
  window.location.assign(result.url)
 })
 const active=['active','trialing'].includes(subscription?.status||'')
 return <section className="admin-panels">
   {acceptToken&&<form className="card workspace-form" onSubmit={accept}><h2>Accept organization invitation</h2><p>Only the user whose verified email matches the invitation can join.</p><button className="primary" disabled={busy}>Accept invitation</button></form>}
   <div className="card"><div className="card-head"><div><h2>Team and accountant access</h2><p>Members can belong to multiple businesses, each with a separate role.</p></div></div>
    <div className="table-wrap"><table><thead><tr><th>Email</th><th>Role</th><th>Joined</th><th>Actions</th></tr></thead><tbody>{members.map(m=><tr key={m.user_id}><td className="strong">{m.email}</td><td className="capitalize">{m.role}</td><td>{m.joined_at.slice(0,10)}</td><td>{canManage&&m.role!=='owner'?<div className="row-actions"><select aria-label={'Role for '+m.email} disabled={busy||role!=='owner'&&m.role==='administrator'} value={m.role} onChange={e=>changeRole(m.user_id,e.target.value)}>{roles.filter(r=>role==='owner'||r!=='administrator').map(r=><option key={r} value={r}>{r}</option>)}</select><button type="button" disabled={busy||role!=='owner'&&m.role==='administrator'} onClick={()=>remove(m.user_id)}>Remove</button></div>:'Protected'}</td></tr>)}</tbody></table></div>
   </div>
   {canManage&&<form className="card workspace-form" onSubmit={invite}><h2>Invite a team member</h2><div className="workspace-fields"><label>Email<input type="email" required value={email} onChange={e=>setEmail(e.target.value)}/></label><label>Role<select value={newRole} onChange={e=>setNewRole(e.target.value)}>{roles.filter(r=>role==='owner'||r!=='administrator').map(r=><option key={r} value={r}>{r}</option>)}</select></label><button className="primary" disabled={busy}>Create invitation</button></div>
   {invitationLink&&<div className="invitation-token"><label>Private invitation URL<input value={invitationLink} readOnly/></label><button type="button" onClick={()=>void navigator.clipboard.writeText(invitationLink)}>Copy link</button><p>Share securely. Only the intended verified email can redeem it; the token expires after seven days.</p></div>}
   <h3>Pending invitations</h3><div className="table-wrap"><table><thead><tr><th>Email</th><th>Role</th><th>Expires</th><th>Status</th><th>Action</th></tr></thead><tbody>{invitations.map(i=><tr key={i.id}><td>{i.invited_email}</td><td>{i.role}</td><td>{i.expires_at.slice(0,10)}</td><td>{i.accepted_at?'Accepted':i.revoked_at?'Revoked':'Pending'}</td><td>{!i.accepted_at&&!i.revoked_at&&<button type="button" className="link-button" disabled={busy} onClick={()=>revoke(i.id)}>Revoke</button>}</td></tr>)}</tbody></table></div></form>}
   <div className="card workspace-form"><h2>Subscription and feature access</h2><p>Current plan: <strong>{subscription?.plan_code||'Unsubscribed'}</strong>, status: <strong>{subscription?.status||'none'}</strong>.</p><p>Member seats: {members.length} of {String(entitlements?.users||1)}. Subscription limits are enforced on invitation acceptance.</p>
   {subscription?.current_period_end&&<p>Current period ends: {subscription.current_period_end.slice(0,10)}.</p>}
   {subscription?.cancel_at_period_end&&<p>Subscription is scheduled for cancellation at period end.</p>}
   <div className="plan-cards">{plans.map(p=><div key={p.code} className="plan-card"><h3>{p.title}</h3><strong>${Number(p.monthly_price_cad).toFixed(2)} CAD/mo</strong><p>{p.features.users} users · {p.features.receipt_ocr_monthly} OCR pages/mo</p>{role==='owner'&&<button type="button" disabled={busy} onClick={()=>billing('checkout',p.code)}>{active?'Manage or change plan through portal':'Choose plan'}</button>}</div>)}</div>
   {role==='owner'&&<button type="button" className="primary" disabled={busy} onClick={()=>billing('portal')}>Manage billing in Stripe</button>}
   <p className="muted">Proposed subscription pricing. Stripe products and prices must be configured by the operator; your accountant data remains accessible in read-only/export workflows if a subscription expires.</p></div>
   {canSeeAudit&&<div className="card"><div className="card-head"><div><h2>Recent audit events</h2><p>Latest 100 membership, billing, journal and document events.</p></div></div><div className="table-wrap"><table><thead><tr><th>Time</th><th>Action</th><th>Entity</th></tr></thead><tbody>{audit.map(e=><tr key={e.id}><td>{new Date(e.occurred_at).toLocaleString('en-CA')}</td><td>{e.action}</td><td>{e.entity_type}</td></tr>)}{audit.length===0&&<tr><td colSpan={3}><div className="empty">No audit events yet.</div></td></tr>}</tbody></table></div></div>}
 </section>
}
