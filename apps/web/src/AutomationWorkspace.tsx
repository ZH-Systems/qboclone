import {useCallback,useEffect,useState,type FormEvent} from 'react'
import {supabase} from './lib/supabase'
import {parseCsvRecords,previewContacts,type ImportedContact} from './lib/importCsv'
import {formatMoney} from './lib/accounting'
type Props={organizationId:string;role:string;notify:(message:string,isError?:boolean)=>void}
type Doc={id:string;document_number:string;document_type:string;status:string;total:number;contact_id:string;due_date:string}
type Rule={id:string;source_document_id:string;cadence:string;next_run_date:string;active:boolean;due_offset_days:number}
type Receipt={id:string;original_filename:string;mime_type:string;extraction_status:string;
 extraction_data:{text?:string;suggestions?:Record<string,unknown>}|null;created_at:string}
type ImportBatch={id:string;source_system:string;entity_kind:string;rows_previewed:number;rows_imported:number;created_at:string}
const today=()=>new Date().toLocaleDateString('sv-SE',{timeZone:'America/Toronto'})
const apiUrl=(import.meta.env.VITE_BILLING_API_URL||'').replace(/\/$/,'')
const allRoles=['owner','administrator','accountant','bookkeeper']
const money=(value:number)=>formatMoney(Math.round(Number(value)*100))
export default function AutomationWorkspace({organizationId,role,notify}:Props){
 const [tab,setTab]=useState<'recurring'|'deliveries'|'receipts'|'imports'>('recurring')
 const [documents,setDocuments]=useState<Doc[]>([])
 const [rules,setRules]=useState<Rule[]>([])
 const [receipts,setReceipts]=useState<Receipt[]>([])
 const [imports,setImports]=useState<ImportBatch[]>([])
 const [busy,setBusy]=useState(false)
 const [sourceId,setSourceId]=useState('')
 const [cadence,setCadence]=useState('monthly')
 const [firstRun,setFirstRun]=useState(today())
 const [dueOffset,setDueOffset]=useState('14')
 const [invoiceId,setInvoiceId]=useState('')
 const [receiptFile,setReceiptFile]=useState<File|null>(null)
 const [receiptId,setReceiptId]=useState('')
 const [attachDoc,setAttachDoc]=useState('')
 const [ocrConsent,setOcrConsent]=useState(false)
 const [csvName,setCsvName]=useState('')
 const [csvRaw,setCsvRaw]=useState('')
 const [csvType,setCsvType]=useState('customers')
 const [csvSource,setCsvSource]=useState('quickbooks_csv')
 const [nameColumn,setNameColumn]=useState('Name')
 const [emailColumn,setEmailColumn]=useState('Email')
 const [contactPreview,setContactPreview]=useState<ImportedContact[]>([])
 const canWrite=allRoles.includes(role)
 const load=useCallback(async()=>{
  if(!supabase||!organizationId)return
  const [d,r,rc,b]=await Promise.all([
   supabase.from('financial_documents').select('id,document_number,document_type,status,total,contact_id,due_date')
    .eq('organization_id',organizationId).order('created_at',{ascending:false}).limit(500),
   supabase.from('recurring_document_rules').select('id,source_document_id,cadence,next_run_date,active,due_offset_days')
    .eq('organization_id',organizationId).order('next_run_date',{ascending:true}).limit(200),
   supabase.from('receipt_documents').select('id,original_filename,mime_type,extraction_status,extraction_data,created_at')
    .eq('organization_id',organizationId).order('created_at',{ascending:false}).limit(100),
   supabase.from('import_review_batches').select('id,source_system,entity_kind,rows_previewed,rows_imported,created_at')
    .eq('organization_id',organizationId).order('created_at',{ascending:false}).limit(30)
  ])
  for(const item of [d,r,rc,b])if(item.error)throw item.error
  setDocuments((d.data||[]) as Doc[]);setRules((r.data||[]) as Rule[])
  setReceipts((rc.data||[]) as Receipt[]);setImports((b.data||[]) as ImportBatch[])
 },[organizationId])
 useEffect(()=>{void load().catch(e=>notify(e.message,true))},[load])
 const run=(task:()=>Promise<void>)=>{setBusy(true);void task().catch(e=>notify(e instanceof Error?e.message:String(e),true)).finally(()=>setBusy(false))}
 const session=async()=>{if(!supabase)throw new Error('Authentication unavailable')
  const {data,error}=await supabase.auth.getSession()
  if(error||!data.session)throw new Error('Please sign in again')
  return data.session.access_token}
 const api=async(path:string,data:Record<string,unknown>):Promise<Response>=>{
  if(!apiUrl)throw new Error('Server API URL is not configured')
  const token=await session()
  return fetch(apiUrl+path,{method:'POST',
   headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},
   body:JSON.stringify(data)})
 }
 const asJsonError=async(response:Response)=>{
  if(!response.ok){const error=await response.json().catch(()=>({error:'Request failed'})) as {error?:string}
   throw new Error(error.error||'Request failed')}
 }
 const createRule=(e:FormEvent)=>{e.preventDefault();run(async()=>{
  if(!supabase)return
  const {error}=await supabase.rpc('create_recurring_document_rule',{
   p_org:organizationId,p_source_document:sourceId,p_cadence:cadence,
   p_first_date:firstRun,p_due_offset:Number(dueOffset)})
  if(error)throw error
  await load();notify('Recurring schedule created. The worker creates drafts, not posted invoices.')
 })}
 const toggleRule=(rule:Rule)=>run(async()=>{
  if(!supabase)return
  const {error}=await supabase.rpc('set_recurring_document_rule_active',{
   p_org:organizationId,p_rule:rule.id,p_active:!rule.active})
  if(error)throw error
  await load();notify('Recurring schedule updated.')
 })
 const openPdf=()=>run(async()=>{
  if(!invoiceId)throw new Error('Select a posted invoice')
  const response=await api('/invoices/'+invoiceId+'/pdf',{organizationId})
  await asJsonError(response)
  const blob=await response.blob();const url=URL.createObjectURL(blob)
  const a=document.createElement('a');a.href=url;a.download='invoice.pdf'
  document.body.appendChild(a);a.click();a.remove()
  URL.revokeObjectURL(url);notify('Invoice PDF prepared.')
 })
 const sendInvoice=(kind:'invoice'|'payment_reminder')=>run(async()=>{
  if(!invoiceId)throw new Error('Select a posted invoice')
  const response=await api('/invoices/'+invoiceId+'/send',{organizationId,kind})
  await asJsonError(response)
  notify(kind==='invoice'?'Invoice submitted to email provider.':'Payment reminder submitted to email provider.')
 })
 const uploadReceipt=()=>run(async()=>{
  if(!receiptFile||!apiUrl)throw new Error('Select a receipt file and configure the server API')
  const token=await session()
  const response=await fetch(apiUrl+'/organizations/'+organizationId+'/receipts',{
   method:'POST',headers:{Authorization:'Bearer '+token,
    'Content-Type':receiptFile.type,'X-Original-Filename':receiptFile.name},
   body:receiptFile})
  await asJsonError(response)
  const body=await response.json() as {id:string}
  setReceiptId(body.id);setReceiptFile(null)
  await load();notify('Receipt uploaded into private storage.')
 })
 const openReceipt=(id:string)=>run(async()=>{
  const response=await api('/organizations/'+organizationId+'/receipts/'+id+'/open',{})
  await asJsonError(response)
  const data=await response.json() as {url:string}
  if(!/^https:\/\//.test(data.url))throw new Error('Invalid receipt URL')
  window.open(data.url,'_blank','noopener,noreferrer')
 })
 const extractReceipt=(id:string)=>run(async()=>{
  if(!apiUrl||!ocrConsent)throw new Error('Explicit consent is required to send the receipt to Google Cloud Vision')
  const token=await session()
  const response=await fetch(apiUrl+'/organizations/'+organizationId+'/receipts/'+id+'/ocr',{
   method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json',
    'X-External-OCR-Consent':'true'},body:'{}'})
  await asJsonError(response)
  await load();notify('OCR extraction completed. All extracted amounts must be reviewed before posting.')
 })
 const linkReceipt=()=>run(async()=>{
  if(!supabase||!receiptId||!attachDoc)throw new Error('Choose a receipt and financial document')
  const {error}=await supabase.rpc('link_receipt_document',{
   p_org:organizationId,p_receipt:receiptId,p_document:attachDoc})
  if(error)throw error
  notify('Receipt linked to financial document.')
 })
 const handleCsvFile=(file:File|null)=>run(async()=>{
  if(!file)return
  if(file.size>1024*1024)throw new Error('Contact CSV must be under 1 MiB')
  const raw=await file.text()
  const records=parseCsvRecords(raw)
  if(records.length<2)throw new Error('CSV must contain a header and at least one contact')
  setCsvName(file.name);setCsvRaw(raw);setContactPreview([])
 })
 const previewCsv=()=>run(async()=>{
  const data=previewContacts(csvRaw,nameColumn,emailColumn)
  setContactPreview(data.rows)
  notify('Validated '+data.rows.length+' contacts. Review the preview before importing.')
 })
 const importCsv=()=>run(async()=>{
  if(!supabase||!contactPreview.length)throw new Error('Preview valid contacts before importing')
  const {data,error}=await supabase.rpc('import_contact_review_rows',{
   p_org:organizationId,p_source:csvSource,p_kind:csvType,
   p_filename:csvName||'contacts.csv',p_rows:contactPreview})
  if(error)throw error
  setContactPreview([]);setCsvRaw('')
  await load();notify(String(data?.imported||0)+' new contacts imported.')
 })
 const eligible=documents.filter(d=>d.status==='posted'&&d.document_type==='invoice')
 const sources=documents.filter(d=>['draft','posted'].includes(d.status)&&['invoice','bill'].includes(d.document_type))
 const chosen=receipts.find(r=>r.id===receiptId)
 return <section className="automation-workspace">
 <div className="advanced-tabs">{([['recurring','Recurring'],['deliveries','Invoice delivery'],['receipts','Receipts & OCR'],['imports','QuickBooks CSV imports']] as const).map(([id,label])=>
  <button key={id} type="button" className={tab===id?'selected':''} onClick={()=>setTab(id)}>{label}</button>)}</div>
 {tab==='recurring'&&<>
 <form className="card workspace-form" onSubmit={createRule}><h2>Recurring invoice and bill drafts</h2>
  <p>The scheduled worker duplicates document snapshots into new drafts. A person must review and post each document. Tax codes expiring on the run date pause the schedule.</p>
  <div className="workspace-fields"><label>Source invoice or bill<select required value={sourceId} onChange={e=>setSourceId(e.target.value)}><option value="">Choose source</option>{sources.map(d=><option key={d.id} value={d.id}>{d.document_number} · {d.document_type} · {money(d.total)}</option>)}</select></label>
  <label>Frequency<select value={cadence} onChange={e=>setCadence(e.target.value)}><option value="monthly">Monthly</option><option value="weekly">Weekly</option></select></label>
  <label>Next issue date<input required type="date" min={today()} value={firstRun} onChange={e=>setFirstRun(e.target.value)}/></label>
  <label>Days until due<input required type="number" min="0" max="365" value={dueOffset} onChange={e=>setDueOffset(e.target.value)}/></label></div>
  <button type="submit" className="primary" disabled={busy||!canWrite}>Create schedule</button>
 </form>
 <div className="card"><div className="card-head"><h2>Recurring schedules</h2></div><div className="table-wrap"><table><thead><tr><th>Source</th><th>Cadence</th><th>Next run</th><th>Status</th><th/></tr></thead><tbody>
 {rules.map(r=><tr key={r.id}><td>{documents.find(d=>d.id===r.source_document_id)?.document_number||'Document'}</td><td>{r.cadence}</td><td>{r.next_run_date}</td><td>{r.active?'Active':'Paused'}</td><td><button type="button" disabled={busy||!canWrite} onClick={()=>toggleRule(r)}>{r.active?'Pause':'Resume'}</button></td></tr>)}
 {rules.length===0&&<tr><td colSpan={5}>No recurring schedules configured.</td></tr>}
 </tbody></table></div></div></>}
 {tab==='deliveries'&&<div className="card workspace-form"><h2>Invoice PDFs and customer email</h2>
 <p>Attachments are generated from posted invoice records and delivered only to the customer's saved email address. Reminder delivery requires an overdue, unpaid invoice.</p>
 <label>Posted invoice<select value={invoiceId} onChange={e=>setInvoiceId(e.target.value)}><option value="">Choose invoice</option>{eligible.map(d=><option key={d.id} value={d.id}>{d.document_number} · {money(d.total)} · due {d.due_date}</option>)}</select></label>
 <div className="workspace-toolbar"><button type="button" disabled={!invoiceId||busy||!apiUrl} onClick={openPdf}>Download PDF</button>
 <button type="button" disabled={!invoiceId||busy||!canWrite||!apiUrl} onClick={()=>sendInvoice('invoice')}>Send invoice email</button>
 <button type="button" disabled={!invoiceId||busy||!canWrite||!apiUrl} onClick={()=>sendInvoice('payment_reminder')}>Send overdue reminder</button></div>
 </div>}
 {tab==='receipts'&&<>
 <div className="card workspace-form"><h2>Private receipt upload</h2><p>Up to 8 MiB per PDF, PNG or JPEG. Files are kept in a private Supabase Storage bucket. Upload alone does not run OCR or post accounting entries.</p>
 <label>Receipt file<input type="file" accept=".pdf,.png,.jpg,.jpeg,application/pdf,image/png,image/jpeg" onChange={e=>setReceiptFile(e.target.files?.[0]||null)}/></label>
 <button type="button" className="primary" disabled={!receiptFile||!canWrite||busy||!apiUrl} onClick={uploadReceipt}>Upload receipt</button></div>
 <div className="card workspace-form"><h2>Review uploaded receipts</h2>
 <label>Receipt<select value={receiptId} onChange={e=>setReceiptId(e.target.value)}><option value="">Choose receipt</option>{receipts.map(r=><option key={r.id} value={r.id}>{r.original_filename} · {r.extraction_status}</option>)}</select></label>
 {chosen&&<><div className="workspace-toolbar"><button type="button" disabled={busy||!apiUrl} onClick={()=>openReceipt(chosen.id)}>View receipt</button></div>
  <label className="ocr-consent"><input type="checkbox" checked={ocrConsent} onChange={e=>setOcrConsent(e.target.checked)}/> I authorize sending this receipt to Google Cloud Vision for OCR processing.</label>
  <button type="button" disabled={!ocrConsent||busy||!apiUrl||!canWrite} onClick={()=>extractReceipt(chosen.id)}>Run OCR, review only</button>
  {chosen.extraction_data?.suggestions&&<div className="ocr-preview"><strong>Unverified OCR suggestions</strong><pre>{JSON.stringify(chosen.extraction_data.suggestions,null,2)}</pre><p>Do not post an expense without validating receipt values, tax treatment and the vendor.</p></div>}
  <label>Attach to financial document<select value={attachDoc} onChange={e=>setAttachDoc(e.target.value)}><option value="">Select invoice or bill</option>{documents.map(d=><option key={d.id} value={d.id}>{d.document_number} · {d.document_type}</option>)}</select></label>
  <button type="button" disabled={!attachDoc||busy||!canWrite} onClick={linkReceipt}>Link receipt to document</button>
 </>}</div>
 </>}
 {tab==='imports'&&<>
 <div className="card workspace-form"><h2>Review and import contacts from CSV</h2>
 <p>QuickBooks exported customer/vendor CSV or a generic CSV. You choose the name and email columns, review valid rows, then import. Duplicate name-and-email pairs are skipped; no automatic account merging occurs.</p>
 <label>CSV file<input type="file" accept=".csv,text/csv" onChange={e=>void handleCsvFile(e.target.files?.[0]||null)}/></label>
 <div className="workspace-fields">
 <label>Source<select value={csvSource} onChange={e=>setCsvSource(e.target.value)}><option value="quickbooks_csv">QuickBooks CSV</option><option value="generic_csv">Generic CSV</option></select></label>
 <label>Import as<select value={csvType} onChange={e=>setCsvType(e.target.value)}><option value="customers">Customers</option><option value="vendors">Vendors</option></select></label>
 <label>Name column<input value={nameColumn} onChange={e=>setNameColumn(e.target.value)}/></label>
 <label>Email column (optional)<input value={emailColumn} onChange={e=>setEmailColumn(e.target.value)}/></label></div>
 <div className="workspace-toolbar"><button type="button" disabled={busy||!csvRaw} onClick={previewCsv}>Preview mapped rows</button><button type="button" className="primary" disabled={busy||!contactPreview.length||!canWrite} onClick={importCsv}>Confirm import ({contactPreview.length})</button></div>
 {csvRaw&&<p>Detected headers: {parseCsvRecords(csvRaw)[0]?.join(' · ')}</p>}
 {contactPreview.length>0&&<div className="table-wrap"><table><thead><tr><th>Contact</th><th>Email</th></tr></thead><tbody>{contactPreview.slice(0,25).map((r,i)=><tr key={i}><td>{r.name}</td><td>{r.email||'None'}</td></tr>)}</tbody></table><p>Previewing first 25 of {contactPreview.length} rows.</p></div>}
 </div>
 <div className="card"><div className="card-head"><h2>Previous imports</h2></div><div className="table-wrap"><table><thead><tr><th>Source</th><th>Type</th><th>Previewed</th><th>Imported</th><th>Date</th></tr></thead><tbody>{imports.map(b=><tr key={b.id}><td>{b.source_system}</td><td>{b.entity_kind}</td><td>{b.rows_previewed}</td><td>{b.rows_imported}</td><td>{b.created_at.slice(0,10)}</td></tr>)}</tbody></table></div></div>
 </>}
 </section>
}
