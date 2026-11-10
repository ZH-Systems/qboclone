import {useCallback,useEffect,useState,type FormEvent} from 'react'
import {supabase} from './lib/supabase'

type PlatformOrganization={
 id:string;name:string;created_at:string;owner_email:string|null;member_count:number
}
const base=(import.meta.env.VITE_BILLING_API_URL||'/api').replace(/\/$/,'')
async function authHeader():Promise<HeadersInit>{
 if(!supabase)throw new Error('Supabase is not configured')
 const {data,error}=await supabase.auth.getSession()
 if(error||!data.session)throw new Error('Sign in required')
 return {Authorization:'Bearer '+data.session.access_token}
}
export async function isPlatformAdmin():Promise<boolean>{
 try{
  const response=await fetch(base+'/platform/admin/status',{headers:await authHeader()})
  return response.ok && (await response.json() as {isSuperAdmin:boolean}).isSuperAdmin===true
 }catch{return false}
}
export default function PlatformAdministration({onProvision}:{onProvision:()=>Promise<void>}){
 const [organizations,setOrganizations]=useState<PlatformOrganization[]>([])
 const [name,setName]=useState('')
 const [ownerEmail,setOwnerEmail]=useState('')
 const [busy,setBusy]=useState(false)
 const [error,setError]=useState('')
 const [notice,setNotice]=useState('')
 const refresh=useCallback(async()=>{
  const response=await fetch(base+'/platform/organizations',{headers:await authHeader()})
  const body=await response.json() as {organizations?:PlatformOrganization[];error?:string}
  if(!response.ok)throw new Error(body.error||'Unable to load organizations')
  setOrganizations(body.organizations||[])
 },[])
 useEffect(()=>{void refresh().catch(e=>setError(String(e)))},[refresh])
 const provision=(e:FormEvent)=>{e.preventDefault();void (async()=>{
  setError('');setNotice('');setBusy(true)
  try {
   const response=await fetch(base+'/platform/organizations',{
    method:'POST',headers:{...await authHeader(),'Content-Type':'application/json'},
    body:JSON.stringify({name:name.trim(),ownerEmail:ownerEmail.trim().toLowerCase()})
   })
   const body=await response.json() as {organizationId?:string;error?:string}
   if(!response.ok||!body.organizationId)throw new Error(body.error||'Organization provisioning failed')
   setName('');setOwnerEmail('')
   await refresh()
   await onProvision()
   setNotice('Organization created and assigned to its verified owner.')
  }catch(e){setError(e instanceof Error?e.message:String(e))}
  finally{setBusy(false)}
 })()}
 return <section className="card workspace-form">
  <h2>Platform administration</h2>
  <p>Create businesses for existing verified users. Provisioning grants the specified account ownership of the new organization; platform administrators do not automatically gain access to its financial data.</p>
  <form onSubmit={provision} className="workspace-fields">
   <label>Business name<input required minLength={2} maxLength={150} value={name} onChange={e=>setName(e.target.value)}/></label>
   <label>Verified owner email<input required type="email" value={ownerEmail} onChange={e=>setOwnerEmail(e.target.value)}/></label>
   <button className="primary" type="submit" disabled={busy}>{busy?'Provisioning…':'Provision organization'}</button>
  </form>
  {error&&<p className="error" role="alert">{error}</p>}
  {notice&&<p className="notice" role="status">{notice}</p>}
  <h3>Organizations</h3>
  <div className="table-wrap"><table><thead><tr><th>Business</th><th>Owner email</th><th>Members</th><th>Created</th></tr></thead>
  <tbody>{organizations.map(o=><tr key={o.id}><td>{o.name}</td><td>{o.owner_email||'Unassigned'}</td><td>{o.member_count}</td><td>{new Date(o.created_at).toLocaleDateString('en-CA')}</td></tr>)}
  {organizations.length===0&&<tr><td colSpan={4}>No organizations available.</td></tr>}</tbody></table></div>
  <p className="muted">The list displays at most 500 organizations. Platform access is granted only by a privileged SQL administrator.</p>
 </section>
}
