import {useCallback,useEffect,useState,type FormEvent} from 'react'
import {supabase} from './lib/supabase'
import {parseMoney,formatMoney} from './lib/accounting'
type Tab='vendors'|'foreign'|'provincial'
type Props={organizationId:string;tab:Tab;role:string;notify:(message:string,isError?:boolean)=>void}
type Contact={id:string;display_name:string;contact_kind:string}
type Doc={id:string;contact_id:string;document_number:string;document_type:string;issue_date:string;
 status:string;total:number;document_currency:string;foreign_total:number|null}
type VendorAdvance={id:string;vendor_id:string;amount:number;paid_on:string}
type VendorAllocation={advance_id:string;amount:number}
type VendorRefund={advance_id:string;amount:number}
type TaxPart={component:string;rate_percent:number;amount:number}
const today=()=>new Date().toLocaleDateString('sv-SE',{timeZone:'America/Toronto'})
const money=(v:number)=>formatMoney(Math.round(Number(v)*100))
const cents=(v:string)=>(parseMoney(v)/100).toFixed(2)
const provinces=['AB','BC','MB','NB','NL','NT','NS','NU','ON','PE','QC','SK','YT']
export default function AccountingCompletionWorkspace({organizationId,tab,role,notify}:Props){
 const [contacts,setContacts]=useState<Contact[]>([])
 const [docs,setDocs]=useState<Doc[]>([])
 const [advances,setAdvances]=useState<VendorAdvance[]>([])
 const [allocations,setAllocations]=useState<VendorAllocation[]>([])
 const [refunds,setRefunds]=useState<VendorRefund[]>([])
 const [busy,setBusy]=useState(false)
 const [date,setDate]=useState(today())
 const [vendor,setVendor]=useState('')
 const [vendorAmount,setVendorAmount]=useState('')
 const [advanceRef,setAdvanceRef]=useState('')
 const [advanceId,setAdvanceId]=useState('')
 const [billId,setBillId]=useState('')
 const [applyAmount,setApplyAmount]=useState('')
 const [refundAmount,setRefundAmount]=useState('')
 const [refundReason,setRefundReason]=useState('')
 const [fxDoc,setFxDoc]=useState('')
 const [fxCurrency,setFxCurrency]=useState('USD')
 const [fxTotal,setFxTotal]=useState('')
 const [fxRate,setFxRate]=useState('')
 const [fxPaymentDoc,setFxPaymentDoc]=useState('')
 const [fxPaymentForeign,setFxPaymentForeign]=useState('')
 const [fxCadBook,setFxCadBook]=useState('')
 const [fxBank,setFxBank]=useState('')
 const [taxProvince,setTaxProvince]=useState('QC')
 const [taxBase,setTaxBase]=useState('100.00')
 const [taxDate,setTaxDate]=useState(today())
 const [taxClass,setTaxClass]=useState('taxable')
 const [applyProv,setApplyProv]=useState(true)
 const [taxParts,setTaxParts]=useState<TaxPart[]>([])
 const [keys,setKeys]=useState<Record<string,string>>({})
 const canWrite=['owner','administrator','accountant','bookkeeper'].includes(role)
 const canConfigure=['owner','administrator','accountant'].includes(role)
 const load=useCallback(async()=>{
  if(!supabase||!organizationId)return
  const [c,d,a,ap,r]=await Promise.all([
   supabase.from('contacts').select('id,display_name,contact_kind').eq('organization_id',organizationId),
   supabase.from('financial_documents').select('id,contact_id,document_number,document_type,issue_date,status,total,document_currency,foreign_total')
    .eq('organization_id',organizationId).order('issue_date',{ascending:false}).limit(500),
   supabase.from('vendor_advances').select('id,vendor_id,amount,paid_on')
    .eq('organization_id',organizationId).order('paid_on',{ascending:false}),
   supabase.from('vendor_advance_applications').select('advance_id,amount').eq('organization_id',organizationId),
   supabase.from('vendor_advance_refunds').select('advance_id,amount').eq('organization_id',organizationId)
  ])
  for(const item of [c,d,a,ap,r])if(item.error)throw item.error
  setContacts((c.data||[]) as Contact[]);setDocs((d.data||[]) as Doc[])
  setAdvances((a.data||[]) as VendorAdvance[])
  setAllocations((ap.data||[]) as VendorAllocation[]);setRefunds((r.data||[]) as VendorRefund[])
 },[organizationId])
 useEffect(()=>{void load().catch(e=>notify(e.message,true))},[load])
 const run=(operation:string,task:(key:string)=>Promise<void>)=>{
  const key=keys[operation]||crypto.randomUUID()
  setKeys(k=>({...k,[operation]:key}));setBusy(true)
  void task(key).then(async()=>{setKeys(k=>({...k,[operation]:''}));await load()})
   .catch(e=>notify(e instanceof Error?e.message:String(e),true)).finally(()=>setBusy(false))
 }
 const selectedAdvance=advances.find(a=>a.id===advanceId)
 const available=(a:VendorAdvance)=>Number(a.amount)-
  allocations.filter(x=>x.advance_id===a.id).reduce((s,x)=>s+Number(x.amount),0)-
  refunds.filter(x=>x.advance_id===a.id).reduce((s,x)=>s+Number(x.amount),0)
 const payAdvance=(e:FormEvent)=>{e.preventDefault();run('advance',async(key)=>{
  if(!supabase)throw new Error('Authentication unavailable')
  const {error}=await supabase.rpc('pay_vendor_advance',{
   p_org:organizationId,p_vendor:vendor,p_amount:cents(vendorAmount),
   p_date:date,p_reference:advanceRef||null,p_key:key})
  if(error)throw error
  setVendorAmount('');setAdvanceRef('');notify('Supplier advance paid, recorded as an asset.')
 })}
 const applyAdvance=(e:FormEvent)=>{e.preventDefault();run('allocation',async(key)=>{
  if(!supabase)throw new Error('Authentication unavailable')
  const {error}=await supabase.rpc('apply_vendor_advance',{
   p_org:organizationId,p_advance:advanceId,p_bill:billId,p_amount:cents(applyAmount),
   p_date:date,p_key:key})
  if(error)throw error
  setApplyAmount('');notify('Supplier advance allocated to bill.')
 })}
 const returnAdvance=(e:FormEvent)=>{e.preventDefault();run('return',async(key)=>{
  if(!supabase)throw new Error('Authentication unavailable')
  const {error}=await supabase.rpc('refund_vendor_advance',{
   p_org:organizationId,p_advance:advanceId,p_amount:cents(refundAmount),
   p_date:date,p_reason:refundReason.trim(),p_key:key})
  if(error)throw error
  setRefundAmount('');setRefundReason('');notify('Supplier advance refund posted to bank.')
 })}
 const denominate=(e:FormEvent)=>{e.preventDefault();run('fx-denominate',async()=>{
  if(!supabase)throw new Error('Authentication unavailable')
  const {error}=await supabase.rpc('denominate_draft_in_foreign_currency',{
   p_org:organizationId,p_document:fxDoc,p_currency:fxCurrency.toUpperCase(),
   p_foreign_total:cents(fxTotal),p_book_rate:fxRate})
  if(error)throw error
  notify('Foreign amount recorded for the draft. Post the document from Invoices or Bills.')
 })}
 const fxPay=(e:FormEvent)=>{e.preventDefault();run('fx-payment',async(key)=>{
  if(!supabase)throw new Error('Authentication unavailable')
  const {error}=await supabase.rpc('record_foreign_currency_payment',{
   p_org:organizationId,p_doc:fxPaymentDoc,p_foreign_amount:cents(fxPaymentForeign),
   p_cad_book_amount:cents(fxCadBook),p_bank_cad_amount:cents(fxBank),
   p_date:date,p_reference:'FX bank settlement',p_key:key})
  if(error)throw error
  setFxPaymentForeign('');setFxCadBook('');setFxBank('')
  notify('Foreign payment posted. CAD gain/loss recorded separately.')
 })}
 const previewTaxes=(e:FormEvent)=>{e.preventDefault();run('tax-preview',async()=>{
  if(!supabase)throw new Error('Authentication unavailable')
  const {data,error}=await supabase.rpc('preview_canadian_indirect_taxes',{
   p_province:taxProvince,p_date:taxDate,p_base:cents(taxBase),
   p_federal_classification:taxClass,p_apply_provincial:applyProv})
  if(error)throw error
  setTaxParts((data||[]) as TaxPart[])
 })}
 const draftFX=docs.filter(d=>d.status==='draft'&&['invoice','bill'].includes(d.document_type))
 const payableFX=docs.filter(d=>d.status==='posted'&&d.document_currency!=='CAD')
 return <section className="advanced-extras">
 {tab==='vendors'&&<>
  <form className="card workspace-form" onSubmit={payAdvance}><h2>Pay supplier advance</h2>
   <p>Posts a bank payment into the Supplier Advances asset account. The advance is not a purchase expense until an underlying supplier bill is posted and allocated.</p>
   <div className="workspace-fields">
    <label>Vendor<select required value={vendor} onChange={e=>setVendor(e.target.value)}><option value="">Select vendor</option>{contacts.filter(c=>c.contact_kind==='vendor').map(c=><option key={c.id} value={c.id}>{c.display_name}</option>)}</select></label>
    <label>Amount (CAD)<input required inputMode="decimal" value={vendorAmount} onChange={e=>{setVendorAmount(e.target.value);setKeys(k=>({...k,advance:''}))}}/></label>
    <label>Date<input type="date" required value={date} onChange={e=>setDate(e.target.value)}/></label>
    <label>Reference<input maxLength={100} value={advanceRef} onChange={e=>setAdvanceRef(e.target.value)}/></label>
   </div><button className="primary" disabled={busy||!canWrite}>Pay supplier advance</button>
  </form>
  <div className="card workspace-form"><h2>Allocate or refund supplier advance</h2>
   <label>Open advance<select value={advanceId} onChange={e=>{setAdvanceId(e.target.value);setBillId('')}}><option value="">Select advance</option>{advances.filter(a=>available(a)>0).map(a=><option key={a.id} value={a.id}>{contacts.find(c=>c.id===a.vendor_id)?.display_name||'Vendor'} · {money(available(a))} available</option>)}</select></label>
   {selectedAdvance&&<>
    <form className="advanced-inline-form" onSubmit={applyAdvance}><h3>Allocate to posted bill</h3>
     <div className="workspace-fields"><label>Bill<select required value={billId} onChange={e=>setBillId(e.target.value)}><option value="">Choose bill</option>{docs.filter(d=>d.status==='posted'&&d.document_type==='bill'&&d.contact_id===selectedAdvance.vendor_id).map(d=><option key={d.id} value={d.id}>{d.document_number}</option>)}</select></label>
      <label>CAD amount<input required inputMode="decimal" value={applyAmount} onChange={e=>setApplyAmount(e.target.value)}/></label>
      <button className="primary" disabled={busy||!canWrite}>Allocate advance</button></div>
    </form>
    <form className="advanced-inline-form" onSubmit={returnAdvance}><h3>Receive unused supplier refund</h3>
     <div className="workspace-fields"><label>CAD amount<input required inputMode="decimal" value={refundAmount} onChange={e=>setRefundAmount(e.target.value)}/></label>
      <label>Reason<input required minLength={3} value={refundReason} onChange={e=>setRefundReason(e.target.value)}/></label>
      <button className="primary" disabled={busy||!canWrite}>Record returned advance</button></div>
    </form>
   </>}
  </div>
 </>}
 {tab==='foreign'&&<>
  <form className="card workspace-form" onSubmit={denominate}><h2>Denominate a draft invoice or bill</h2>
   <p>The general ledger stays CAD. Create the invoice or bill using translated CAD line amounts first, then record its foreign currency and source exchange rate before posting.</p>
   <div className="workspace-fields">
    <label>Draft document<select required value={fxDoc} onChange={e=>setFxDoc(e.target.value)}><option value="">Choose draft</option>{draftFX.map(d=><option key={d.id} value={d.id}>{d.document_number} · {money(d.total)} CAD</option>)}</select></label>
    <label>Currency (ISO 4217)<input required maxLength={3} value={fxCurrency} onChange={e=>setFxCurrency(e.target.value.toUpperCase())}/></label>
    <label>Foreign document total<input required inputMode="decimal" value={fxTotal} onChange={e=>setFxTotal(e.target.value)}/></label>
    <label>CAD per unit of foreign currency<input required inputMode="decimal" value={fxRate} onChange={e=>setFxRate(e.target.value)}/></label>
   </div><button className="primary" disabled={busy||!canConfigure}>Save denomination</button>
  </form>
  <form className="card workspace-form" onSubmit={fxPay}><h2>Settle a foreign-denominated invoice or bill</h2>
   <p>Record the foreign amount settled, CAD book receivable/payable cleared and actual CAD transferred at the bank. The difference posts as a realized FX gain or loss. FX refunds and unrealized revaluation are not yet implemented.</p>
   <div className="workspace-fields"><label>Posted foreign invoice/bill<select required value={fxPaymentDoc} onChange={e=>setFxPaymentDoc(e.target.value)}><option value="">Choose document</option>{payableFX.map(d=><option key={d.id} value={d.id}>{d.document_number} · {d.document_currency} {d.foreign_total} · CAD {money(d.total)}</option>)}</select></label>
    <label>Foreign amount settled<input required inputMode="decimal" value={fxPaymentForeign} onChange={e=>setFxPaymentForeign(e.target.value)}/></label>
    <label>CAD book amount cleared<input required inputMode="decimal" value={fxCadBook} onChange={e=>setFxCadBook(e.target.value)}/></label>
    <label>CAD bank movement<input required inputMode="decimal" value={fxBank} onChange={e=>setFxBank(e.target.value)}/></label>
    <label>Settlement date<input required type="date" value={date} onChange={e=>setDate(e.target.value)}/></label>
   </div><button className="primary" disabled={busy||!canWrite}>Post FX settlement</button>
  </form>
 </>}
 {tab==='provincial'&&<form className="card workspace-form" onSubmit={previewTaxes}>
   <h2>Canadian combined indirect-tax preview</h2>
   <p className="advanced-note">An advisory basic-rate estimate only. Select the actual place of supply and whether provincial sales tax applies. Taxability, exemptions, business registration and recoverability must be assessed by a Canadian tax professional. This estimate does not create ledger journals or filing-ready returns.</p>
   <div className="workspace-fields"><label>Province<select value={taxProvince} onChange={e=>setTaxProvince(e.target.value)}>{provinces.map(p=><option key={p} value={p}>{p}</option>)}</select></label>
    <label>Date<input required type="date" value={taxDate} onChange={e=>setTaxDate(e.target.value)}/></label>
    <label>Taxable CAD base<input required inputMode="decimal" value={taxBase} onChange={e=>setTaxBase(e.target.value)}/></label>
    <label>Federal GST/HST classification<select value={taxClass} onChange={e=>setTaxClass(e.target.value)}>{['taxable','zero_rated','exempt','out_of_scope'].map(x=><option key={x} value={x}>{x}</option>)}</select></label>
   </div>
   <label className="ocr-consent"><input type="checkbox" checked={applyProv} onChange={e=>setApplyProv(e.target.checked)}/> Include standard provincial PST/RST/QST where applicable</label>
   <button className="primary" disabled={busy}>Calculate advisory tax components</button>
   {taxParts.length>0&&<div className="table-wrap"><table><thead><tr><th>Tax component</th><th>Rate</th><th>Estimated amount</th></tr></thead><tbody>
    {taxParts.map(p=><tr key={p.component}><td>{p.component}</td><td>{Number(p.rate_percent).toFixed(3)}%</td><td>{money(p.amount)}</td></tr>)}
    <tr><td><strong>Estimated total</strong></td><td/><td><strong>{money(taxParts.reduce((s,p)=>s+Number(p.amount),0))}</strong></td></tr>
   </tbody></table></div>}
 </form>}
 </section>
}