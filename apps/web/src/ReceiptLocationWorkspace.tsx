import {useCallback,useEffect,useState,type FormEvent} from 'react'
import {supabase} from './lib/supabase'

type Fence={id:string;name:string;latitude:number;longitude:number;radius_m:number;dwell_seconds:number;enabled:boolean}
type Review={id:string;classification:string;status:string;merchant_candidate:string|null;total_candidate:number|null;receipt_id:string;created_at:string}
type Props={organizationId:string;role:string;notify:(message:string,isError?:boolean)=>void}
const empty=()=>({id:'',name:'',latitude:'',longitude:'',radius_m:'150',dwell_seconds:'300',enabled:true})
export default function ReceiptLocationWorkspace({organizationId,role,notify}:Props){
 const [fences,setFences]=useState<Fence[]>([])
 const [reviews,setReviews]=useState<Review[]>([])
 const [form,setForm]=useState(empty())
 const [busy,setBusy]=useState(false)
 const owner=role==='owner'
 const writer=['owner','administrator','accountant','bookkeeper'].includes(role)
 const load=useCallback(async()=>{
  if(!supabase||!organizationId)return
  const [f,r]=await Promise.all([
   supabase.from('receipt_geofences').select('id,name,latitude,longitude,radius_m,dwell_seconds,enabled')
    .eq('organization_id',organizationId).order('created_at'),
   supabase.from('receipt_intake_reviews').select('id,classification,status,merchant_candidate,total_candidate,receipt_id,created_at')
    .eq('organization_id',organizationId).order('created_at',{ascending:false}).limit(100)
  ])
  if(f.error)throw f.error
  if(r.error)throw r.error
  setFences((f.data||[]) as Fence[])
  setReviews((r.data||[]) as Review[])
 },[organizationId])
 useEffect(()=>{void load().catch(e=>notify(e.message,true))},[load])
 const run=(job:()=>Promise<void>)=>{
  setBusy(true)
  void job().catch(e=>notify(e instanceof Error?e.message:String(e),true)).finally(()=>setBusy(false))
 }
 const save=(event:FormEvent)=>{event.preventDefault();run(async()=>{
  if(!supabase||!owner)throw new Error('Only the organization principal can configure locations')
  const lat=Number(form.latitude),lng=Number(form.longitude),radius=Number(form.radius_m),dwell=Number(form.dwell_seconds)
  if(!form.latitude||!form.longitude||!Number.isFinite(lat)||!Number.isFinite(lng))throw new Error('Valid coordinates required')
  const {error}=await supabase.rpc('save_receipt_geofence',{
   p_org:organizationId,p_id:form.id||null,p_name:form.name,p_latitude:lat,p_longitude:lng,
   p_radius_m:radius,p_dwell_seconds:dwell,p_enabled:form.enabled
  })
  if(error)throw error
  setForm(empty());await load();notify('Receipt reminder location saved.')
 })}
 const remove=(id:string)=>run(async()=>{
  if(!supabase||!owner)throw new Error('Owner role required')
  if(!window.confirm('Delete this reminder location?'))return
  const {error}=await supabase.rpc('delete_receipt_geofence',{p_org:organizationId,p_id:id})
  if(error)throw error
  setForm(empty());await load();notify('Location deleted. Mobile devices must resynchronize.')
 })
 const status=(id:string,next:'reviewed'|'rejected')=>run(async()=>{
  if(!supabase||!writer)throw new Error('Write access required')
  const {error}=await supabase.rpc('set_receipt_intake_status',{
   p_org:organizationId,p_review:id,p_status:next
  })
  if(error)throw error
  await load();notify('Receipt review status saved. Financial posting is a separate accounting operation.')
 })
 return <section className="automation-workspace">
  <div className="card workspace-form">
   <h2>Location-based receipt reminders</h2>
   <p>Organization owner sets geofences. Employees enable geofencing in the iOS/Android app. After entering the radius and remaining for the configured duration, the device schedules a receipt-capture reminder. Timing is approximate.</p>
   {owner&&<form onSubmit={save} className="workspace-form">
    <div className="workspace-fields">
     <label>Location name<input required maxLength={120} value={form.name} onChange={e=>setForm({...form,name:e.target.value})}/></label>
     <label>Latitude<input required type="number" step="any" min={-90} max={90} value={form.latitude} onChange={e=>setForm({...form,latitude:e.target.value})}/></label>
     <label>Longitude<input required type="number" step="any" min={-180} max={180} value={form.longitude} onChange={e=>setForm({...form,longitude:e.target.value})}/></label>
     <label>Radius, metres<input required type="number" min={100} max={1000} value={form.radius_m} onChange={e=>setForm({...form,radius_m:e.target.value})}/></label>
     <label>Stay duration, seconds<input required type="number" min={60} max={3600} value={form.dwell_seconds} onChange={e=>setForm({...form,dwell_seconds:e.target.value})}/></label>
     <label><input type="checkbox" checked={form.enabled} onChange={e=>setForm({...form,enabled:e.target.checked})}/> Enabled</label>
    </div>
    <div className="workspace-toolbar"><button className="primary" disabled={busy}>{form.id?'Update location':'Add location'}</button><button type="button" onClick={()=>setForm(empty())}>Clear</button></div>
   </form>}
   <div className="table-wrap"><table><thead><tr><th>Location</th><th>Coordinates</th><th>Radius</th><th>Dwell</th><th>Status</th>{owner&&<th>Actions</th>}</tr></thead><tbody>
    {fences.map(f=><tr key={f.id}><td>{f.name}</td><td>{f.latitude}, {f.longitude}</td><td>{f.radius_m} m</td><td>{Math.round(f.dwell_seconds/60)} min</td><td>{f.enabled?'Enabled':'Disabled'}</td>{owner&&<td><button type="button" onClick={()=>setForm({id:f.id,name:f.name,latitude:String(f.latitude),longitude:String(f.longitude),radius_m:String(f.radius_m),dwell_seconds:String(f.dwell_seconds),enabled:f.enabled})}>Edit</button><button type="button" disabled={busy} onClick={()=>remove(f.id)}>Delete</button></td>}</tr>)}
    {fences.length===0&&<tr><td colSpan={owner?6:5}>No receipt reminder locations configured.</td></tr>}
   </tbody></table></div>
   <p className="muted">iOS monitoring supports 20 active regions per device. Locations are tenant-scoped, no periodic GPS coordinates are uploaded.</p>
  </div>
  <div className="card workspace-form">
   <h2>Mobile receipt review inbox</h2>
   <p>Incoming payment evidence and expense receipts remain unposted pending verification. OCR is advisory. Confirm amounts, tax codes and invoice/bank references before creating any financial transaction.</p>
   <div className="table-wrap"><table><thead><tr><th>Submitted</th><th>Destination</th><th>Merchant</th><th>OCR total</th><th>Status</th><th>Receipt</th>{writer&&<th>Review</th>}</tr></thead><tbody>
    {reviews.map(r=><tr key={r.id}><td>{new Date(r.created_at).toLocaleDateString()}</td><td>{r.classification==='expense'?'Expense':'Incoming payment'}</td><td>{r.merchant_candidate||'Needs verification'}</td><td>{r.total_candidate==null?'Unverified':'$'+Number(r.total_candidate).toFixed(2)}</td><td>{r.status}</td><td><code>{r.receipt_id.slice(0,8)}</code></td>{writer&&<td>{r.status==='needs_review'&&<><button disabled={busy} type="button" onClick={()=>status(r.id,'reviewed')}>Mark reviewed</button><button disabled={busy} type="button" onClick={()=>status(r.id,'rejected')}>Reject</button></>}</td>}</tr>)}
    {reviews.length===0&&<tr><td colSpan={writer?7:6}>No mobile receipt reviews yet.</td></tr>}
   </tbody></table></div>
  </div>
 </section>
}
