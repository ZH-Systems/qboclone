import {useCallback,useEffect,useState,type FormEvent} from 'react'
import {supabase} from './lib/supabase'
import AdditionalAccountingWorkflows,{type ExtraAccountingTab} from './AdditionalAccountingWorkflows'
import InventoryWorkspace from './InventoryWorkspace'
import {asDecimal,parseMoney,formatMoney,validateJournal,type JournalLine} from './lib/accounting'

type Props={organizationId:string;role:string;notify:(message:string,isError?:boolean)=>void}
type Period={id:string;start_date:string;end_date:string;is_locked:boolean}
type Account={id:string;code:string;name:string;account_type:string}
type Payment={id:string;document_id:string;amount:number;payment_date:string}
type Refund={original_payment_id:string;amount:number}
type Document={id:string;document_number:string;document_type:string;status:string}
type TaxRow={province_code:string;classification:string;transaction_kind:string;taxable_base:number;tax_amount:number;recoverable_itc:number;unclassified_lines:number}
type BalanceRow={account_code:string;account_name:string;category:string;amount:number}
type AgingRow={document_id:string;document_number:string;contact_name:string;due_date:string;outstanding:number;days_past_due:number;aging_bucket:string}
type CashRow={bank_account_id:string;account_code:string;account_name:string;opening_balance:number;inflows:number;outflows:number;closing_balance:number}
const today=()=>new Date().toLocaleDateString('sv-SE',{timeZone:'America/Toronto'})
const amount=(value:number|string)=>formatMoney(Math.round(Number(value)*100))
const provinces=['AB','BC','MB','NB','NL','NT','NS','NU','ON','PE','QC','SK','YT']
const blank=():JournalLine[]=>[{account_id:'',debit:'',credit:'0'},{account_id:'',debit:'0',credit:''}]
type Tab='closing'|'refunds'|'tax'|'reports'|'adjustments'|'inventory'|ExtraAccountingTab

export default function AdvancedAccountingWorkspace({organizationId,role,notify}:Props){
 const [tab,setTab]=useState<Tab>('reports')
 const [periods,setPeriods]=useState<Period[]>([])
 const [accounts,setAccounts]=useState<Account[]>([])
 const [payments,setPayments]=useState<Payment[]>([])
 const [refunds,setRefunds]=useState<Refund[]>([])
 const [documents,setDocuments]=useState<Document[]>([])
 const [balances,setBalances]=useState<BalanceRow[]>([])
 const [receivables,setReceivables]=useState<AgingRow[]>([])
 const [payables,setPayables]=useState<AgingRow[]>([])
 const [cash,setCash]=useState<CashRow[]>([])
 const [taxRows,setTaxRows]=useState<TaxRow[]>([])
 const [busy,setBusy]=useState(false)
 const [start,setStart]=useState(today().slice(0,4)+'-01-01')
 const [end,setEnd]=useState(today())
 const [periodId,setPeriodId]=useState('')
 const [paymentId,setPaymentId]=useState('')
 const [refundAmount,setRefundAmount]=useState('')
 const [refundDate,setRefundDate]=useState(today())
 const [refundReason,setRefundReason]=useState('')
 const [refundKey,setRefundKey]=useState<string|null>(null)
 const [adjustDate,setAdjustDate]=useState(today())
 const [adjustReason,setAdjustReason]=useState('')
 const [adjustType,setAdjustType]=useState('accrual')
 const [adjustLines,setAdjustLines]=useState<JournalLine[]>(blank)
 const [adjustKey,setAdjustKey]=useState<string|null>(null)
 const [province,setProvince]=useState('ON')
 const [taxDate,setTaxDate]=useState(today())
 const [classification,setClassification]=useState('taxable')
 const [taxKind,setTaxKind]=useState('sale')
 const [taxRecoverability,setTaxRecoverability]=useState('0')
 const [taxCode,setTaxCode]=useState('')
 const [taxLabel,setTaxLabel]=useState('')
 const [previewRate,setPreviewRate]=useState<number|null>(null)
 const canClose=['owner','administrator','accountant'].includes(role)
 const load=useCallback(async()=>{
  if(!supabase||!organizationId)return
  const [p,a,pay,r,d]=await Promise.all([
   supabase.from('fiscal_periods').select('id,start_date,end_date,is_locked').eq('organization_id',organizationId).order('start_date',{ascending:false}),
   supabase.from('accounts').select('id,code,name,account_type').eq('organization_id',organizationId).order('code'),
   supabase.from('document_payments').select('id,document_id,amount,payment_date').eq('organization_id',organizationId).order('payment_date',{ascending:false}).limit(500),
   supabase.from('payment_refunds').select('original_payment_id,amount').eq('organization_id',organizationId),
   supabase.from('financial_documents').select('id,document_number,document_type,status').eq('organization_id',organizationId).limit(500)
  ])
  for(const result of [p,a,pay,r,d])if(result.error)throw result.error
  setPeriods((p.data||[]) as Period[]);setAccounts((a.data||[]) as Account[])
  setPayments((pay.data||[]) as Payment[]);setRefunds((r.data||[]) as Refund[])
  setDocuments((d.data||[]) as Document[])
 },[organizationId])
 const loadReports=useCallback(async()=>{
  if(!supabase||!organizationId||!start||!end||start>end)return
  const [b,ar,ap,c,t]=await Promise.all([
   supabase.rpc('ledger_balance_sheet',{p_organization_id:organizationId,p_through:end}),
   supabase.rpc('aged_open_documents',{p_organization_id:organizationId,p_as_of:end,p_kind:'invoice'}),
   supabase.rpc('aged_open_documents',{p_organization_id:organizationId,p_as_of:end,p_kind:'bill'}),
   supabase.rpc('bank_cash_movement',{p_organization_id:organizationId,p_from:start,p_through:end}),
   supabase.rpc('gst_hst_tax_summary',{p_organization_id:organizationId,p_start:start,p_end:end})
  ])
  for(const result of [b,ar,ap,c,t])if(result.error)throw result.error
  setBalances((b.data||[]) as BalanceRow[])
  setReceivables((ar.data||[]) as AgingRow[])
  setPayables((ap.data||[]) as AgingRow[])
  setCash((c.data||[]) as CashRow[])
  setTaxRows((t.data||[]) as TaxRow[])
 },[organizationId,start,end])
 useEffect(()=>{setPeriods([]);setAccounts([]);setPayments([]);setRefunds([]);setDocuments([])
  void load().catch(e=>notify(e.message,true))},[load])
 useEffect(()=>{if(tab==='reports')void loadReports().catch(e=>notify(e.message,true))},[tab,loadReports])
 useEffect(()=>{if(tab!=='tax'||!supabase)return;setPreviewRate(null)
  void supabase.rpc('canadian_gst_hst_rate',{p_province:province,p_supply_date:taxDate,p_classification:classification})
   .then(({data,error})=>{if(error)notify(error.message,true);else setPreviewRate(Number(data))})},
  [tab,province,taxDate,classification])
 const run=async(work:()=>Promise<void>)=>{setBusy(true)
  try{await work()}catch(e){notify(e instanceof Error?e.message:String(e),true)}finally{setBusy(false)}
 }
 const closeYear=(e:FormEvent)=>{e.preventDefault();void run(async()=>{
  if(!supabase||!periodId)return
  if(!window.confirm('Finalize this financial year? This permanently locks the period in the current version.'))return
  const {data,error}=await supabase.rpc('close_financial_year',{p_organization_id:organizationId,p_period_id:periodId})
  if(error)throw error
  await load();notify('Financial year closed. Net income: '+amount(Number(data?.net_income||0)))
 })}
 const remaining=(p:Payment)=>Number(p.amount)-refunds.filter(r=>r.original_payment_id===p.id).reduce((s,r)=>s+Number(r.amount),0)
 const payment=payments.find(p=>p.id===paymentId)
 const refund=(e:FormEvent)=>{e.preventDefault();void run(async()=>{
  if(!supabase||!paymentId)throw new Error('Select an original payment')
  const cents=parseMoney(refundAmount);if(cents<=0)throw new Error('Refund must exceed zero')
  const key=refundKey||crypto.randomUUID();setRefundKey(key)
  const {error}=await supabase.rpc('refund_document_payment',{
   p_organization_id:organizationId,p_payment_id:paymentId,p_amount:(cents/100).toFixed(2),
   p_refund_date:refundDate,p_reason:refundReason.trim(),p_idempotency_key:key
  })
  if(error)throw error
  setRefundKey(null);setRefundAmount('');setRefundReason('');setPaymentId('')
  await load();notify('Payment refund posted; record a credit note if the original sale is being reversed.')
 })}
 const adjustment=(e:FormEvent)=>{e.preventDefault();void run(async()=>{
  if(!supabase)return
  validateJournal(adjustLines)
  if(adjustReason.trim().length<10)throw new Error('Explanation must contain at least ten characters')
  const key=adjustKey||crypto.randomUUID();setAdjustKey(key)
  const {error}=await supabase.rpc('post_adjusting_journal',{
   p_organization_id:organizationId,p_entry_date:adjustDate,p_category:adjustType,
   p_explanation:adjustReason.trim(),p_idempotency_key:key,
   p_lines:adjustLines.map(l=>({account_id:l.account_id,
    debit:asDecimal(l.debit||'0'),credit:asDecimal(l.credit||'0')}))
  })
  if(error)throw error
  setAdjustKey(null);setAdjustReason('');setAdjustLines(blank());notify('Balanced adjusting journal posted.')
 })}
 const addTax=(e:FormEvent)=>{e.preventDefault();void run(async()=>{
  if(!supabase)return
  const {error}=await supabase.rpc('create_canadian_tax_code',{
   p_organization_id:organizationId,p_code:taxCode.trim(),p_label:taxLabel.trim(),
   p_kind:taxKind,p_province:province,p_classification:classification,
   p_supply_date:taxDate,p_recoverable_bps:taxKind==='purchase'?Number(taxRecoverability):0
  })
  if(error)throw error
  setTaxCode('');setTaxLabel('');notify('Jurisdiction-tagged tax code created.')
 })}
 const assets=balances.filter(x=>x.category==='asset').reduce((s,r)=>s+Number(r.amount),0)
 const liabEquity=balances.filter(x=>x.category!=='asset').reduce((s,r)=>s+Number(r.amount),0)
 const totalTax=taxRows.filter(r=>r.transaction_kind==='sale').reduce((s,r)=>s+Number(r.tax_amount),0)
 const totalItc=taxRows.reduce((s,r)=>s+Number(r.recoverable_itc),0)
 return <section className="advanced-accounting">
  <div className="advanced-tabs" role="group" aria-label="Advanced accounting sections">
   {([['reports','Financial statements'],['closing','Year-end close'],['refunds','Payment refunds'],['adjustments','Adjustments'],['opening','Opening balances'],['deposits','Customer deposits'],['writeoffs','Bad debt'],['inventory','FIFO inventory'],['tax','Canadian tax rules']] as [Tab,string][]).map(([id,title])=>
    <button type="button" key={id} className={tab===id?'selected':''} onClick={()=>setTab(id)}>{title}</button>)}
  </div>
  {tab==='reports'&&<>
   <div className="card workspace-form"><h2>Accounting reports</h2><p>Reports use all posted journal history. Historical aging is calculated as of the selected date.</p>
    <div className="workspace-fields"><label>From<input type="date" value={start} onChange={e=>setStart(e.target.value)}/></label><label>Through<input type="date" min={start} value={end} onChange={e=>setEnd(e.target.value)}/></label><button type="button" className="primary" disabled={busy||start>end} onClick={()=>void loadReports().catch(e=>notify(e.message,true))}>Refresh</button></div>
   </div>
   <div className="card"><div className="card-head"><div><h2>Balance sheet as of {end}</h2><p>Unclosed earnings are disclosed as equity; posted closing journals transfer earnings to retained earnings.</p></div></div>
    <div className="table-wrap"><table><thead><tr><th>Account</th><th>Category</th><th>Balance (CAD)</th></tr></thead><tbody>
     {balances.map(r=><tr key={r.account_code}><td>{r.account_code} · {r.account_name}</td><td>{r.category}</td><td>{amount(r.amount)}</td></tr>)}
     <tr><td><strong>Assets</strong></td><td/><td><strong>{amount(assets)}</strong></td></tr>
     <tr><td><strong>Liabilities + equity</strong></td><td/><td><strong>{amount(liabEquity)}</strong></td></tr>
     <tr><td><strong>Out of balance</strong></td><td/><td><strong>{amount(assets-liabEquity)}</strong></td></tr>
    </tbody></table></div>
   </div>
   {([['Receivables aging',receivables],['Payables aging',payables]] as [string,AgingRow[]][]).map(([title,items])=>
    <div className="card" key={title}><div className="card-head"><h2>{title}</h2></div><div className="table-wrap"><table><thead><tr><th>Document</th><th>Contact</th><th>Due</th><th>Bucket</th><th>Outstanding</th></tr></thead><tbody>{items.map(r=>
      <tr key={r.document_id}><td>{r.document_number}</td><td>{r.contact_name}</td><td>{r.due_date}</td><td>{r.aging_bucket.replace('_','–')}</td><td>{amount(r.outstanding)}</td></tr>)}
     <tr><td colSpan={4}><strong>Total</strong></td><td><strong>{amount(items.reduce((s,r)=>s+Number(r.outstanding),0))}</strong></td></tr>
     </tbody></table></div></div>)}
   <div className="card"><div className="card-head"><h2>GST/HST accrual reconciliation</h2></div><p className="advanced-note">For review only, this is not a filed GST/HST return. Manual and unspecified tax lines require classification. Provincial PST/QST are excluded.</p>
    <div className="table-wrap"><table><thead><tr><th>Province</th><th>Classification</th><th>Direction</th><th>Base</th><th>Tax</th><th>ITCs</th><th>Unclassified</th></tr></thead><tbody>{taxRows.map((r,i)=><tr key={i}><td>{r.province_code}</td><td>{r.classification}</td><td>{r.transaction_kind}</td><td>{amount(r.taxable_base)}</td><td>{amount(r.tax_amount)}</td><td>{amount(r.recoverable_itc)}</td><td>{r.unclassified_lines}</td></tr>)}
    <tr><td colSpan={4}><strong>Collected tax less recorded ITCs</strong></td><td colSpan={3}><strong>{amount(totalTax-totalItc)}</strong></td></tr></tbody></table></div>
   </div>
   <div className="card"><div className="card-head"><h2>Bank cash movement</h2></div><p className="advanced-note">This is a bank account movement report, not a GAAP cash flow statement.</p><div className="table-wrap"><table><thead><tr><th>Bank account</th><th>Opening</th><th>In</th><th>Out</th><th>Closing</th></tr></thead><tbody>{cash.map(r=><tr key={r.bank_account_id}><td>{r.account_code} · {r.account_name}</td><td>{amount(r.opening_balance)}</td><td>{amount(r.inflows)}</td><td>{amount(r.outflows)}</td><td>{amount(r.closing_balance)}</td></tr>)}</tbody></table></div></div>
  </>}
  {tab==='closing'&&<div className="card workspace-form"><h2>Financial year close</h2>
   <p>Posts a balanced revenue/expense clearing journal to Retained Earnings and permanently locks the period against ordinary reopening or journal reversal. Enter all adjustments first.</p>
   <form onSubmit={closeYear} className="workspace-fields"><label>Fiscal period<select required value={periodId} onChange={e=>setPeriodId(e.target.value)}><option value="">Select period</option>{periods.map(p=><option key={p.id} value={p.id}>{p.start_date} to {p.end_date} ({p.is_locked?'locked':'open'})</option>)}</select></label><button className="primary" disabled={!canClose||busy||!periodId}>Finalize selected financial year</button></form>
   {!canClose&&<p>Only the owner, an administrator or an accountant can complete year-end closing.</p>}
  </div>}
  {tab==='refunds'&&<form className="card workspace-form" onSubmit={refund}><h2>Refund a posted payment</h2>
   <p>Creates the opposite bank and receivable/payable movement, restoring the invoice or bill balance. Issue a credit note afterwards if the underlying sale or purchase is also being reversed.</p>
   <div className="workspace-fields"><label>Original payment<select required value={paymentId} onChange={e=>{setPaymentId(e.target.value);setRefundKey(null)}}><option value="">Choose a payment</option>{payments.filter(p=>remaining(p)>0).map(p=><option key={p.id} value={p.id}>{documents.find(d=>d.id===p.document_id)?.document_number||'Document'} · {amount(remaining(p))} refundable</option>)}</select></label><label>Refund amount (CAD)<input required inputMode="decimal" value={refundAmount} onChange={e=>{setRefundAmount(e.target.value);setRefundKey(null)}}/></label><label>Date<input type="date" required value={refundDate} onChange={e=>{setRefundDate(e.target.value);setRefundKey(null)}}/></label><label>Reason<input required minLength={3} maxLength={500} value={refundReason} onChange={e=>{setRefundReason(e.target.value);setRefundKey(null)}}/></label></div>
   {payment&&<p>Maximum remaining refund: {amount(remaining(payment))}</p>}<button disabled={busy} className="primary">Post refund</button>
  </form>}
  {tab==='adjustments'&&<form className="card workspace-form" onSubmit={adjustment}><h2>Accountant adjusting entry</h2>
   <p>Posts a balanced, audited journal in an open fiscal period. Examples include accruals, corrections and reclassifications.</p>
   <div className="workspace-fields"><label>Date<input required type="date" value={adjustDate} onChange={e=>{setAdjustDate(e.target.value);setAdjustKey(null)}}/></label><label>Category<select value={adjustType} onChange={e=>setAdjustType(e.target.value)}>{['accrual','deferral','reclassification','correction','other'].map(x=><option key={x} value={x}>{x}</option>)}</select></label><label>Detailed explanation<input required minLength={10} maxLength={500} value={adjustReason} onChange={e=>{setAdjustReason(e.target.value);setAdjustKey(null)}}/></label></div>
   {adjustLines.map((line,i)=><div className="advanced-journal-row" key={i}>
    <label>Account<select required value={line.account_id} onChange={e=>{setAdjustKey(null);setAdjustLines(adjustLines.map((x,j)=>i===j?{...x,account_id:e.target.value}:x))}}><option value="">Choose account</option>{accounts.map(a=><option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}</select></label>
    <label>Debit<input inputMode="decimal" value={line.debit} onChange={e=>{setAdjustKey(null);setAdjustLines(adjustLines.map((x,j)=>i===j?{...x,debit:e.target.value}:x))}}/></label>
    <label>Credit<input inputMode="decimal" value={line.credit} onChange={e=>{setAdjustKey(null);setAdjustLines(adjustLines.map((x,j)=>i===j?{...x,credit:e.target.value}:x))}}/></label></div>)}
   <div className="workspace-toolbar"><button type="button" onClick={()=>setAdjustLines([...adjustLines,{account_id:'',debit:'0',credit:'0'}])}>Add line</button><button type="submit" className="primary" disabled={!canClose||busy}>Post adjustment</button></div>
  </form>}
  {(['opening','deposits','writeoffs'] as Tab[]).includes(tab)&&<AdditionalAccountingWorkflows organizationId={organizationId} role={role} mode={tab as ExtraAccountingTab} notify={notify}/>}
  {tab==='inventory'&&<InventoryWorkspace organizationId={organizationId} role={role} notify={notify}/>}
  {tab==='tax'&&<form className="card workspace-form" onSubmit={addTax}><h2>Canadian GST/HST rate configuration</h2>
   <p className="advanced-note">Select the actual place of supply manually. The system looks up GST/HST rates by province and effective date; it does not determine whether a sale is taxable or exempt, assess special supplies, or calculate separate PST/QST.</p>
   <div className="workspace-fields"><label>Place-of-supply province<select value={province} onChange={e=>setProvince(e.target.value)}>{provinces.map(p=><option key={p} value={p}>{p}</option>)}</select></label><label>Supply date<input type="date" required value={taxDate} onChange={e=>setTaxDate(e.target.value)}/></label><label>Classification<select value={classification} onChange={e=>setClassification(e.target.value)}>{['taxable','zero_rated','exempt','out_of_scope'].map(c=><option key={c} value={c}>{c}</option>)}</select></label><label>Direction<select value={taxKind} onChange={e=>setTaxKind(e.target.value)}><option value="sale">Sale</option><option value="purchase">Purchase</option></select></label><label>Code<input required maxLength={24} value={taxCode} onChange={e=>setTaxCode(e.target.value)} placeholder="ON-HST-2026"/></label><label>Label<input required maxLength={120} value={taxLabel} onChange={e=>setTaxLabel(e.target.value)}/></label><label>Recoverable ITC basis points<input type="number" min="0" max="10000" required disabled={taxKind!=='purchase'} value={taxKind==='purchase'?taxRecoverability:'0'} onChange={e=>setTaxRecoverability(e.target.value)}/></label></div>
   <p>Configured federal GST/HST rate: <strong>{previewRate===null?'Unavailable':(previewRate/100).toFixed(2)+'%'}</strong>.</p><button className="primary" disabled={busy||previewRate===null}>Create dated tax code</button>
  </form>}
 </section>
}
