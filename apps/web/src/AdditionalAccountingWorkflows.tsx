import {useCallback,useEffect,useState,type FormEvent} from 'react'
import {supabase} from './lib/supabase'
import {formatMoney,parseMoney} from './lib/accounting'

export type ExtraAccountingTab='opening'|'deposits'|'writeoffs'
type Props={organizationId:string;mode:ExtraAccountingTab;role:string;notify:(message:string,isError?:boolean)=>void}
type Account={id:string;code:string;name:string;account_type:string}
type Contact={id:string;display_name:string;contact_kind:string}
type Doc={id:string;document_number:string;contact_id:string;document_type:string;status:string;total:number}
type Deposit={id:string;customer_id:string;amount:number;received_on:string}
type DepApplication={deposit_id:string;amount:number}
type DepRefund={deposit_id:string;amount:number}
type OpeningRow={account_id:string;debit:string;credit:string}
const today=()=>new Date().toLocaleDateString('sv-SE',{timeZone:'America/Toronto'})
const money=(value:number|string)=>formatMoney(Math.round(Number(value)*100))
const blank=():OpeningRow[]=>[{account_id:'',debit:'100.00',credit:'0.00'}]

export default function AdditionalAccountingWorkflows({organizationId,mode,role,notify}:Props){
 const [accounts,setAccounts]=useState<Account[]>([])
 const [contacts,setContacts]=useState<Contact[]>([])
 const [documents,setDocuments]=useState<Doc[]>([])
 const [deposits,setDeposits]=useState<Deposit[]>([])
 const [applications,setApplications]=useState<DepApplication[]>([])
 const [depositRefunds,setDepositRefunds]=useState<DepRefund[]>([])
 const [busy,setBusy]=useState(false)
 const [openingDate,setOpeningDate]=useState(today().slice(0,4)+'-01-01')
 const [openingRows,setOpeningRows]=useState<OpeningRow[]>(blank)
 const [openingRecorded,setOpeningRecorded]=useState(false)
 const [customerId,setCustomerId]=useState('')
 const [depositId,setDepositId]=useState('')
 const [invoiceId,setInvoiceId]=useState('')
 const [depositAmount,setDepositAmount]=useState('')
 const [allocationAmount,setAllocationAmount]=useState('')
 const [returnAmount,setReturnAmount]=useState('')
 const [depositRef,setDepositRef]=useState('')
 const [reason,setReason]=useState('')
 const [date,setDate]=useState(today())
 const [writeoffInvoice,setWriteoffInvoice]=useState('')
 const [writeoffAmount,setWriteoffAmount]=useState('')
 const [writeoffReason,setWriteoffReason]=useState('')
 const [keys,setKeys]=useState<Record<string,string>>({})
 const canManage=['owner','administrator','accountant'].includes(role)
 const getKey=(name:string)=>keys[name]||crypto.randomUUID()
 const resetKey=(name:string)=>setKeys(k=>({...k,[name]:''}))
 const load=useCallback(async()=>{
  if(!supabase||!organizationId)return
  const [a,c,d,p,ap,r,o]=await Promise.all([
   supabase.from('accounts').select('id,code,name,account_type').eq('organization_id',organizationId).order('code'),
   supabase.from('contacts').select('id,display_name,contact_kind').eq('organization_id',organizationId),
   supabase.from('financial_documents').select('id,document_number,contact_id,document_type,status,total').eq('organization_id',organizationId).order('created_at',{ascending:false}).limit(500),
   supabase.from('customer_deposits').select('id,customer_id,amount,received_on').eq('organization_id',organizationId).order('created_at',{ascending:false}),
   supabase.from('deposit_applications').select('deposit_id,amount').eq('organization_id',organizationId),
   supabase.from('deposit_refunds').select('deposit_id,amount').eq('organization_id',organizationId),
   supabase.from('opening_balance_imports').select('organization_id').eq('organization_id',organizationId).maybeSingle()
  ])
  for(const result of [a,c,d,p,ap,r,o])if(result.error)throw result.error
  setAccounts((a.data||[]) as Account[]);setContacts((c.data||[]) as Contact[])
  setDocuments((d.data||[]) as Doc[]);setDeposits((p.data||[]) as Deposit[])
  setApplications((ap.data||[]) as DepApplication[])
  setDepositRefunds((r.data||[]) as DepRefund[]);setOpeningRecorded(!!o.data)
 },[organizationId])
 useEffect(()=>{setDeposits([]);setDocuments([]);setOpeningRecorded(false);
  void load().catch(e=>notify(e.message,true))},[load])
 const run=async(name:string,task:(key:string)=>Promise<void>)=>{
  setBusy(true);const key=getKey(name);setKeys(k=>({...k,[name]:key}))
  try{await task(key);resetKey(name)}catch(e){notify(e instanceof Error?e.message:String(e),true)}finally{setBusy(false)}
 }
 const opening=(e:FormEvent)=>{e.preventDefault();void run('opening',async()=>{
  if(!supabase)throw new Error('Authentication unavailable')
  const lines=openingRows.map(r=>({account_id:r.account_id,
   debit:(parseMoney(r.debit||'0')/100).toFixed(2),
   credit:(parseMoney(r.credit||'0')/100).toFixed(2)}))
  const {error}=await supabase.rpc('import_opening_balances',{
   p_organization_id:organizationId,p_opening_date:openingDate,p_lines:lines
  })
  if(error)throw error
  await load();notify('Opening balances posted and offset to Owner Equity.')
 })}
 const receive=(e:FormEvent)=>{e.preventDefault();void run('deposit',async(key)=>{
  if(!supabase||!customerId)throw new Error('Select a customer')
  const {error}=await supabase.rpc('receive_customer_deposit',{
   p_organization_id:organizationId,p_customer_id:customerId,p_received_on:date,
   p_amount:(parseMoney(depositAmount)/100).toFixed(2),p_reference:depositRef||null,
   p_idempotency_key:key
  })
  if(error)throw error
  setDepositAmount('');setDepositRef('');await load();notify('Deposit recorded as a liability, not revenue.')
 })}
 const apply=(e:FormEvent)=>{e.preventDefault();void run('apply',async(key)=>{
  if(!supabase||!depositId||!invoiceId)throw new Error('Choose a deposit and invoice')
  const {error}=await supabase.rpc('apply_customer_deposit',{
   p_organization_id:organizationId,p_deposit_id:depositId,p_invoice_id:invoiceId,
   p_amount:(parseMoney(allocationAmount)/100).toFixed(2),p_applied_on:date,p_idempotency_key:key
  })
  if(error)throw error
  setAllocationAmount('');await load();notify('Deposit allocated against the posted invoice.')
 })}
 const returnDeposit=(e:FormEvent)=>{e.preventDefault();void run('return',async(key)=>{
  if(!supabase||!depositId)throw new Error('Choose a deposit')
  const {error}=await supabase.rpc('refund_customer_deposit',{
   p_organization_id:organizationId,p_deposit_id:depositId,
   p_amount:(parseMoney(returnAmount)/100).toFixed(2),p_refunded_on:date,
   p_reason:reason.trim(),p_idempotency_key:key
  })
  if(error)throw error
  setReturnAmount('');setReason('');await load();notify('Unused deposit returned with a balanced bank journal.')
 })}
 const writeoff=(e:FormEvent)=>{e.preventDefault();void run('writeoff',async(key)=>{
  if(!supabase||!writeoffInvoice)throw new Error('Select a posted invoice')
  const {error}=await supabase.rpc('writeoff_unpaid_invoice',{
   p_organization_id:organizationId,p_invoice_id:writeoffInvoice,
   p_amount:(parseMoney(writeoffAmount)/100).toFixed(2),p_entry_date:date,
   p_reason:writeoffReason.trim(),p_idempotency_key:key
  })
  if(error)throw error
  setWriteoffAmount('');setWriteoffReason('');await load()
  notify('Bad debt written off against AR. Review GST/HST bad-debt relief separately.')
 })}
 const remaining=(d:Deposit)=>Number(d.amount)-
  applications.filter(x=>x.deposit_id===d.id).reduce((s,x)=>s+Number(x.amount),0)-
  depositRefunds.filter(x=>x.deposit_id===d.id).reduce((s,x)=>s+Number(x.amount),0)
 const activeDeposit=deposits.find(d=>d.id===depositId)
 const invoiceChoices=documents.filter(d=>d.document_type==='invoice'&&d.status==='posted'&&
  (!activeDeposit||d.contact_id===activeDeposit.customer_id))
 return <section className="advanced-extras">
  {mode==='opening'&&<form className="card workspace-form" onSubmit={opening}>
   <h2>One-time opening balances</h2><p>Opening balances must be entered before any existing ledger activity. The date must match the start of an open fiscal period. The system offsets nonbalancing assets and liabilities to Owner Equity.</p>
   {openingRecorded?<p>Opening balances are already recorded for this organization. Correct them through a formal adjusting journal.</p>:<>
    <div className="workspace-fields"><label>Opening date<input required type="date" value={openingDate} onChange={e=>setOpeningDate(e.target.value)}/></label></div>
    {openingRows.map((line,i)=><div key={i} className="advanced-journal-row">
     <label>Balance sheet account<select required value={line.account_id} onChange={e=>setOpeningRows(openingRows.map((x,j)=>i===j?{...x,account_id:e.target.value}:x))}><option value="">Choose account</option>{accounts.filter(a=>['asset','liability','equity'].includes(a.account_type)&&a.code!=='3000').map(a=><option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}</select></label>
     <label>Debit<input inputMode="decimal" value={line.debit} onChange={e=>setOpeningRows(openingRows.map((x,j)=>i===j?{...x,debit:e.target.value}:x))}/></label>
     <label>Credit<input inputMode="decimal" value={line.credit} onChange={e=>setOpeningRows(openingRows.map((x,j)=>i===j?{...x,credit:e.target.value}:x))}/></label>
    </div>)}
    <div className="workspace-toolbar"><button type="button" onClick={()=>setOpeningRows([...openingRows,...blank()])}>Add account</button><button className="primary" disabled={busy||!canManage}>Import opening balances</button></div>
   </>}
  </form>}
  {mode==='deposits'&&<>
   <form className="card workspace-form" onSubmit={receive}><h2>Receive customer deposit</h2><p>Deposits are held in the Customer Deposits liability account until allocated to an invoice or returned.</p>
    <div className="workspace-fields"><label>Customer<select required value={customerId} onChange={e=>{setCustomerId(e.target.value);resetKey('deposit')}}><option value="">Choose customer</option>{contacts.filter(c=>c.contact_kind==='customer').map(c=><option key={c.id} value={c.id}>{c.display_name}</option>)}</select></label><label>Amount (CAD)<input required inputMode="decimal" value={depositAmount} onChange={e=>{setDepositAmount(e.target.value);resetKey('deposit')}}/></label><label>Date<input required type="date" value={date} onChange={e=>setDate(e.target.value)}/></label><label>Reference<input maxLength={100} value={depositRef} onChange={e=>setDepositRef(e.target.value)}/></label></div>
    <button disabled={busy} className="primary">Post customer deposit</button>
   </form>
   <div className="card workspace-form"><h2>Deposit allocation and returns</h2>
    <label>Customer deposit<select value={depositId} onChange={e=>{setDepositId(e.target.value);setInvoiceId('');resetKey('apply')}}><option value="">Select deposit</option>{deposits.filter(d=>remaining(d)>0).map(d=><option key={d.id} value={d.id}>{contacts.find(c=>c.id===d.customer_id)?.display_name||'Customer'} · {money(remaining(d))} available</option>)}</select></label>
    {activeDeposit&&<><p>Available deposit balance: {money(remaining(activeDeposit))}</p>
    <form onSubmit={apply} className="advanced-inline-form"><h3>Apply to an invoice</h3><div className="workspace-fields"><label>Posted customer invoice<select required value={invoiceId} onChange={e=>setInvoiceId(e.target.value)}><option value="">Select invoice</option>{invoiceChoices.map(d=><option key={d.id} value={d.id}>{d.document_number}</option>)}</select></label><label>Amount<input required inputMode="decimal" value={allocationAmount} onChange={e=>{setAllocationAmount(e.target.value);resetKey('apply')}}/></label><button className="primary" disabled={busy}>Apply deposit</button></div></form>
    <form onSubmit={returnDeposit} className="advanced-inline-form"><h3>Return unused deposit</h3><div className="workspace-fields"><label>Amount<input required inputMode="decimal" value={returnAmount} onChange={e=>{setReturnAmount(e.target.value);resetKey('return')}}/></label><label>Reason<input required minLength={3} maxLength={500} value={reason} onChange={e=>{setReason(e.target.value);resetKey('return')}}/></label><button className="primary" disabled={busy}>Post deposit refund</button></div></form>
    </>}
   </div>
  </>}
  {mode==='writeoffs'&&<form className="card workspace-form" onSubmit={writeoff}>
   <h2>Bad-debt write-off</h2><p>Reduces an invoice receivable and records Bad Debt Expense. It does not automatically reclaim previously remitted GST/HST; assess bad-debt tax relief independently.</p>
   <div className="workspace-fields"><label>Posted customer invoice<select required value={writeoffInvoice} onChange={e=>{setWriteoffInvoice(e.target.value);resetKey('writeoff')}}><option value="">Choose invoice</option>{documents.filter(d=>d.document_type==='invoice'&&d.status==='posted').map(d=><option key={d.id} value={d.id}>{d.document_number} · {money(d.total)} original total</option>)}</select></label><label>Write-off amount (CAD)<input required inputMode="decimal" value={writeoffAmount} onChange={e=>{setWriteoffAmount(e.target.value);resetKey('writeoff')}}/></label><label>Posting date<input required type="date" value={date} onChange={e=>setDate(e.target.value)}/></label><label>Detailed reason<input required minLength={10} maxLength={500} value={writeoffReason} onChange={e=>{setWriteoffReason(e.target.value);resetKey('writeoff')}}/></label></div>
   <button disabled={busy} className="primary">Post bad-debt write-off</button>
  </form>}
 </section>
}
