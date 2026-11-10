import { useCallback, useEffect, useState, type FormEvent } from 'react'
import { supabase } from './lib/supabase'
import { formatMoney, parseMoney } from './lib/accounting'

type Contact = { id: string; display_name: string; email: string | null; contact_kind: 'customer' | 'vendor' }
type DocType = 'invoice' | 'bill' | 'credit_note' | 'vendor_credit'
type TaxCode = {id:string;code:string;label:string;transaction_kind:string;rate_bps:number;recoverable_bps:number}
type AccountOption = {id:string;code:string;name:string;account_type:string}
type Document = {
  id: string; document_number: string; document_type: DocType; contact_id: string;
  issue_date: string; due_date: string; memo: string; status: 'draft' | 'posted' | 'void';
  subtotal: number; tax_total: number; total: number; source_document_id: string | null;
  journal_entry_id: string | null
}
type Payment = { document_id: string; amount: number }
type AccountBalance = { account_id: string; account_code: string; account_name: string; account_type: string; total_debits: number; total_credits: number; net_debit: number }
type ProfitLine = { account_code: string; account_name: string; account_type: string; amount: number }
export type Row = { description: string; quantity: string; unit_price: string; tax_rate_bps: string; account_id?: string; tax_code_id?: string }
export type WorkspaceTab = 'contacts' | 'sales' | 'purchases' | 'reports'
type Props = { orgId: string; tab: WorkspaceTab; notify: (message: string, isError?: boolean) => void }
const day = () => new Date().toLocaleDateString('sv-SE', {timeZone:'America/Toronto'})
const money = (value: number | string) => formatMoney(Math.round(Number(value) * 100))
const lineDefaults = (): Row[] => [{description:'',quantity:'1',unit_price:'0.00',tax_rate_bps:'0'}]
export function validRate(text: string) {
  if (!/^\d+$/.test(text) || Number(text)>2500) throw new Error('Enter tax rate in basis points (0 to 2500).')
  return Number(text)
}
export function totalLines(lines: Row[]) {
  return lines.reduce((sum, line) => {
    const quantity = Number(line.quantity)
    if (!/^(0|[1-9]\d*)(\.\d{1,3})?$/.test(line.quantity) || quantity<=0 || quantity>1000000) throw new Error('Quantity requires up to three decimals.')
    const amount = Math.round(quantity * parseMoney(line.unit_price) )
    const tax = Math.round(amount * validRate(line.tax_rate_bps) / 10000)
    return sum + amount + tax
  },0)
}
export function AccountingWorkspace({orgId,tab,notify}: Props) {
  const [contacts,setContacts] = useState<Contact[]>([])
  const [taxCodes,setTaxCodes] = useState<TaxCode[]>([])
  const [accountOptions,setAccountOptions] = useState<AccountOption[]>([])
  const [editId,setEditId] = useState<string|null>(null)
  const [voidId,setVoidId] = useState<string|null>(null)
  const [voidReason,setVoidReason] = useState('')
  const [documents,setDocuments] = useState<Document[]>([])
  const [payments,setPayments] = useState<Payment[]>([])
  const [report,setReport] = useState<AccountBalance[]>([])
  const [profit,setProfit] = useState<ProfitLine[]>([])
  const [periodStart,setPeriodStart] = useState(day().slice(0,4)+'-01-01')
  const [asOf,setAsOf] = useState(day())
  const [kind,setKind] = useState<'customer'|'vendor'>('customer')
  const [name,setName] = useState('')
  const [email,setEmail] = useState('')
  const [docType,setDocType] = useState<DocType>('invoice')
  const [contactId,setContactId] = useState('')
  const [issueDate,setIssueDate] = useState(day())
  const [dueDate,setDueDate] = useState(day())
  const [memo,setMemo] = useState('')
  const [sourceId,setSourceId] = useState('')
  const [lines,setLines] = useState<Row[]>(lineDefaults)
  const [busy,setBusy] = useState(false)
  const [showCreate,setShowCreate] = useState(false)
  const [paymentDoc,setPaymentDoc] = useState<string | null>(null)
  const [paymentAmount,setPaymentAmount] = useState('')
  const [paymentReference,setPaymentReference] = useState('')
  const [paymentDate,setPaymentDate] = useState(day())
  const [paymentKey,setPaymentKey] = useState<string|null>(null)
  const [reportBusy,setReportBusy] = useState(false)

  const refresh = useCallback(async () => {
    if(!supabase || !orgId) return
    const [c,d,p,t,a] = await Promise.all([
      supabase.from('contacts').select('id,display_name,email,contact_kind').eq('organization_id',orgId).order('display_name'),
      supabase.from('financial_documents').select('id,document_number,document_type,contact_id,issue_date,due_date,memo,status,subtotal,tax_total,total,source_document_id,journal_entry_id').eq('organization_id',orgId).order('created_at',{ascending:false}).limit(500),
      supabase.from('document_payments').select('document_id,amount').eq('organization_id',orgId),
      supabase.from('tax_codes').select('id,code,label,transaction_kind,rate_bps,recoverable_bps').eq('organization_id',orgId),
      supabase.from('accounts').select('id,code,name,account_type').eq('organization_id',orgId).order('code')
    ])
    if(c.error) throw c.error
    if(d.error) throw d.error
    if(p.error) throw p.error
    if(t.error) throw t.error
    if(a.error) throw a.error
    setTaxCodes((t.data||[]) as TaxCode[])
    setAccountOptions((a.data||[]) as AccountOption[])
    setContacts((c.data||[]) as Contact[])
    setDocuments((d.data||[]) as Document[])
    setPayments((p.data||[]) as Payment[])
  },[orgId])
  const refreshReports = useCallback(async () => {
    if(!supabase || !orgId) return
    setReportBusy(true)
    try {
      const [a,b] = await Promise.all([
        supabase.rpc('ledger_trial_balance',{p_organization_id:orgId,p_through:asOf}),
        supabase.rpc('ledger_profit_loss',{p_organization_id:orgId,p_from:periodStart,p_through:asOf})
      ])
      if(a.error) throw a.error
      if(b.error) throw b.error
      setReport((a.data||[]) as AccountBalance[])
      setProfit((b.data||[]) as ProfitLine[])
    } finally {setReportBusy(false)}
  },[orgId,asOf,periodStart])
  useEffect(()=>{setContacts([]);setDocuments([]);setPayments([]);void refresh().catch(e=>notify(e.message,true))},[refresh])
  useEffect(()=>{if(tab==='reports') void refreshReports().catch(e=>notify(e.message,true))},[tab,refreshReports])
  const action = async (job:()=>Promise<void>)=>{
    setBusy(true)
    try {await job()}catch(e){notify(e instanceof Error?e.message:String(e),true)}finally{setBusy(false)}
  }
  const createContact = (e:FormEvent)=>{e.preventDefault();void action(async()=>{
    if(!supabase) return
    const {error}=await supabase.rpc('create_contact',{p_organization_id:orgId,p_kind:kind,p_name:name.trim(),p_email:email.trim()||null})
    if(error)throw error
    setName('');setEmail('');await refresh();notify('Contact created.')
  })}
  const createDocument = (e:FormEvent)=>{e.preventDefault();void action(async()=>{
    if(!supabase) return
    if(totalLines(lines)<=0) throw new Error('Document total must exceed zero.')
    if(!contactId)throw new Error('Select a customer or vendor.')
    if((docType==='credit_note'||docType==='vendor_credit')&&!sourceId)throw new Error('Select a posted source document for this credit.')
    const {error}=await supabase.rpc(editId?'replace_financial_draft':'create_financial_document',{
      p_organization_id:orgId,...(editId?{p_document_id:editId}:{p_contact_id:contactId,p_type:docType,
      p_issue_date:issueDate,p_source_document_id:sourceId||null}),p_due_date:dueDate,p_memo:memo.trim(),
      p_lines:lines.map(line=>({description:line.description.trim(),quantity:line.quantity,unit_price:line.unit_price,tax_rate_bps:validRate(line.tax_rate_bps),account_id:line.account_id||null,tax_code_id:line.tax_code_id||null}))
    })
    if(error)throw error
    setShowCreate(false);setEditId(null);setLines(lineDefaults());setMemo('');setSourceId('')
    await refresh();notify('Document draft saved. Review and post when ready.')
  })}
  const editDocument=(doc:Document)=>void action(async()=>{
    if(!supabase)return
    const {data,error}=await supabase.from('financial_document_lines').select('description,quantity,unit_price,tax_rate_bps,account_id,tax_code_id').eq('organization_id',orgId).eq('document_id',doc.id).order('position')
    if(error)throw error
    setDocType(doc.document_type);setContactId(doc.contact_id);setIssueDate(doc.issue_date);setDueDate(doc.due_date);setMemo(doc.memo);setSourceId(doc.source_document_id||'');setEditId(doc.id)
    setLines((data||[]).map(l=>({description:l.description,quantity:String(l.quantity),unit_price:String(l.unit_price),tax_rate_bps:String(l.tax_rate_bps),account_id:l.account_id||'',tax_code_id:l.tax_code_id||''})))
    setShowCreate(true)
  })
  const voidDocument=(e:FormEvent)=>{e.preventDefault();void action(async()=>{
    if(!supabase||!voidId)return
    const {error}=await supabase.rpc('void_financial_draft',{p_organization_id:orgId,p_document_id:voidId,p_reason:voidReason.trim()})
    if(error)throw error
    setVoidId(null);setVoidReason('');await refresh();notify('Draft voided.')
  })}
  const postDocument=(id:string)=>void action(async()=>{
    if(!supabase)return
    const {error}=await supabase.rpc('post_financial_document',{p_organization_id:orgId,p_document_id:id})
    if(error)throw error
    await refresh();notify('Document posted to the general ledger.')
  })
  const recordPayment=(e:FormEvent)=>{e.preventDefault();void action(async()=>{
    if(!supabase||!paymentDoc)return
    const key=paymentKey||crypto.randomUUID();setPaymentKey(key)
    const {error}=await supabase.rpc('record_document_payment',{
      p_organization_id:orgId,p_document_id:paymentDoc,
      p_amount:(parseMoney(paymentAmount)/100).toFixed(2),
      p_payment_date:paymentDate,p_reference:paymentReference.trim()||null,p_idempotency_key:key
    })
    if(error)throw error
    setPaymentDoc(null);setPaymentKey(null);setPaymentAmount('');setPaymentReference('')
    await refresh();notify('Payment posted and allocated.')
  })}
  const incoming=tab==='sales'
  const documentKind: 'sale'|'purchase' = docType==='invoice'||docType==='credit_note'?'sale':'purchase'
  const credit=docType==='credit_note'||docType==='vendor_credit'
  const choices=contacts.filter(c=>c.contact_kind===(docType==='invoice'||docType==='credit_note'?'customer':'vendor'))
  const outstanding=(doc:Document):number=>{
    const credits=documents.filter(d=>d.source_document_id===doc.id&&d.status==='posted').reduce((sum,c)=>sum+Number(c.total),0)
    const allocated=payments.filter(p=>p.document_id===doc.id).reduce((sum,p)=>sum+Number(p.amount),0)
    return Math.max(0,Number(doc.total)-credits-allocated)
  }
  const activeDocuments=documents.filter(d=>incoming?['invoice','credit_note'].includes(d.document_type):['bill','vendor_credit'].includes(d.document_type))
  const revenue=profit.filter(x=>x.account_type==='revenue').reduce((s,x)=>s+Number(x.amount),0)
  const expenses=profit.filter(x=>x.account_type==='expense').reduce((s,x)=>s+Number(x.amount),0)
  const cumulativeAssets=report.filter(r=>r.account_type==='asset').reduce((s,r)=>s+Number(r.net_debit),0)
  const cumulativeLiabilities=report.filter(r=>r.account_type==='liability').reduce((s,r)=>s-Number(r.net_debit),0)
  const cumulativeEquity=report.filter(r=>r.account_type==='equity').reduce((s,r)=>s-Number(r.net_debit),0)
  const cumulativeEarnings=report.filter(r=>r.account_type==='revenue').reduce((s,r)=>s-Number(r.net_debit),0)-report.filter(r=>r.account_type==='expense').reduce((s,r)=>s+Number(r.net_debit),0)
  const openingDateValid=periodStart<=asOf
  return <section className="accounting-workspace">
    {tab==='contacts'&&<><div className="card"><div className="card-head"><div><h2>Customers and vendors</h2><p>Contacts are scoped to the selected business.</p></div><span className="type-pill">{contacts.length} contacts</span></div><div className="table-wrap"><table><thead><tr><th>Name</th><th>Type</th><th>Email</th></tr></thead><tbody>{contacts.map(c=><tr key={c.id}><td className="strong">{c.display_name}</td><td className="capitalize">{c.contact_kind}</td><td>{c.email||'—'}</td></tr>)}{contacts.length===0&&<tr><td colSpan={3}><div className="empty">No contacts yet.</div></td></tr>}</tbody></table></div></div><form className="card workspace-form" onSubmit={createContact}><h2>Add a contact</h2><div className="workspace-fields"><label>Type<select value={kind} onChange={e=>setKind(e.target.value as 'customer'|'vendor')}><option value="customer">Customer</option><option value="vendor">Vendor</option></select></label><label>Display name<input required minLength={2} maxLength={180} value={name} onChange={e=>setName(e.target.value)}/></label><label>Email (optional)<input type="email" value={email} onChange={e=>setEmail(e.target.value)}/></label></div><button className="primary" disabled={busy}>Create contact</button></form></>}
    {(tab==='sales'||tab==='purchases')&&<><div className="card"><div className="card-head"><div><h2>{incoming?'Invoices and credit notes':'Bills and vendor credits'}</h2><p>Every posted document creates a balanced general-ledger entry.</p></div><button className="primary" onClick={()=>{setEditId(null);setDocType(incoming?'invoice':'bill');setContactId('');setSourceId('');setLines(lineDefaults());setShowCreate(true)}}>New {incoming?'invoice':'bill'}</button></div><div className="table-wrap"><table><thead><tr><th>Number</th><th>Contact</th><th>Issue date</th><th>Total (CAD)</th><th>Outstanding</th><th>Status</th><th>Actions</th></tr></thead><tbody>{activeDocuments.map(d=><tr key={d.id}><td className="strong">{d.document_number}</td><td>{contacts.find(c=>c.id===d.contact_id)?.display_name||'Unknown'}</td><td>{d.issue_date}</td><td className="mono">{money(d.total)}</td><td className="mono">{d.document_type==='invoice'||d.document_type==='bill'?money(outstanding(d)):'—'}</td><td><span className="type-pill">{d.status}</span></td><td><div className="row-actions">{d.status==='draft'&&<><button type="button" onClick={()=>editDocument(d)} disabled={busy}>Edit</button><button type="button" onClick={()=>postDocument(d.id)} disabled={busy}>Post</button><button type="button" onClick={()=>{setVoidId(d.id);setVoidReason('')}} disabled={busy}>Void</button></>}{d.status==='posted'&&['invoice','bill'].includes(d.document_type)&&outstanding(d)>0&&<><button type="button" onClick={()=>{setPaymentDoc(d.id);setPaymentKey(null);setPaymentAmount((outstanding(d)).toFixed(2))}}>Record payment</button><button type="button" onClick={()=>{setEditId(null);setDocType(d.document_type==='invoice'?'credit_note':'vendor_credit');setContactId(d.contact_id);setSourceId(d.id);setLines(lineDefaults());setShowCreate(true)}}>Issue credit</button></>}</div></td></tr>)}{activeDocuments.length===0&&<tr><td colSpan={7}><div className="empty">No financial documents yet. Create a contact to get started.</div></td></tr>}</tbody></table></div></div>{showCreate&&<div className="modal-backdrop" onMouseDown={e=>{if(e.target===e.currentTarget)setShowCreate(false)}}><div className="modal" role="dialog" aria-modal="true" aria-label="Create financial document"><div className="modal-header"><div><span className="eyebrow">DRAFT DOCUMENT</span><h2>{editId?'Edit draft':'Create '+docType.replace('_',' ')}</h2></div><button aria-label="Close" className="close" onClick={()=>setShowCreate(false)}>×</button></div><form className="workspace-create" onSubmit={createDocument}><div className="workspace-fields"><label>Type<select disabled={!!editId} value={docType} onChange={e=>{setDocType(e.target.value as DocType);setContactId('');setSourceId('')}}><option value={incoming?'invoice':'bill'}>{incoming?'Invoice':'Vendor bill'}</option><option value={incoming?'credit_note':'vendor_credit'}>{incoming?'Credit note':'Vendor credit'}</option></select></label><label>{incoming?'Customer':'Vendor'}<select required disabled={!!editId} value={contactId} onChange={e=>{setContactId(e.target.value);setSourceId('')}}><option value="">Select contact</option>{choices.map(c=><option key={c.id} value={c.id}>{c.display_name}</option>)}</select></label><label>Issue date<input type="date" required disabled={!!editId} value={issueDate} onChange={e=>setIssueDate(e.target.value)}/></label><label>Due date<input type="date" required value={dueDate} min={issueDate} onChange={e=>setDueDate(e.target.value)}/></label></div>{credit&&<label>Posted source document<select required disabled={!!editId} value={sourceId} onChange={e=>setSourceId(e.target.value)}><option value="">Select source document</option>{documents.filter(d=>d.contact_id===contactId&&d.status==='posted'&&d.document_type===(docType==='credit_note'?'invoice':'bill')&&outstanding(d)>0).map(d=><option key={d.id} value={d.id}>{d.document_number} (outstanding {money(outstanding(d))})</option>)}</select></label>}<label>Memo<input maxLength={500} value={memo} onChange={e=>setMemo(e.target.value)}/></label><h3>Line items</h3><p className="workspace-disclaimer">Tax rate is a manually selected estimate in basis points, for example 1300 = 13%. This is not automatic GST/HST compliance.</p>{lines.map((line,i)=><div className="workspace-line" key={i}><label>Description<input required maxLength={250} value={line.description} onChange={e=>setLines(lines.map((v,n)=>n===i?{...v,description:e.target.value}:v))}/></label><label>Quantity<input inputMode="decimal" required value={line.quantity} onChange={e=>setLines(lines.map((v,n)=>n===i?{...v,quantity:e.target.value}:v))}/></label><label>Unit price<input inputMode="decimal" required value={line.unit_price} onChange={e=>setLines(lines.map((v,n)=>n===i?{...v,unit_price:e.target.value}:v))}/></label><label>Tax code<select value={line.tax_code_id||''} onChange={e=>{const t=taxCodes.find(t=>t.id===e.target.value);setLines(lines.map((v,n)=>n===i?{...v,tax_code_id:e.target.value,tax_rate_bps:t?String(t.rate_bps):v.tax_rate_bps}:v))}}><option value="">Manual rate</option>{taxCodes.filter(t=>t.transaction_kind===documentKind).map(t=><option key={t.id} value={t.id}>{t.code} · {t.label}</option>)}</select></label><label>Tax bps<input inputMode="numeric" required disabled={!!line.tax_code_id} value={line.tax_rate_bps} onChange={e=>setLines(lines.map((v,n)=>n===i?{...v,tax_rate_bps:e.target.value}:v))}/></label><label>Posting account<select value={line.account_id||''} onChange={e=>setLines(lines.map((v,n)=>n===i?{...v,account_id:e.target.value}:v))}><option value="">Default account</option>{accountOptions.filter(a=>a.account_type===(documentKind==='sale'?'revenue':'expense')).map(a=><option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}</select></label></div>)}<div className="workspace-toolbar"><button type="button" className="link-button" onClick={()=>setLines([...lines,...lineDefaults()])}>+ Add line</button><strong>Estimated total: {(()=>{try{return formatMoney(totalLines(lines))}catch{return 'Invalid input'}})()}</strong></div><div className="modal-actions"><button type="button" onClick={()=>setShowCreate(false)}>Cancel</button><button className="primary" disabled={busy}>{editId?'Save changes':'Save draft'}</button></div></form></div></div>}{voidId&&<div className="modal-backdrop" onMouseDown={e=>{if(e.target===e.currentTarget)setVoidId(null)}}><div className="modal payment-modal" role="dialog" aria-modal="true" aria-label="Void draft"><div className="modal-header"><h2>Void unposted draft</h2><button type="button" className="close" onClick={()=>setVoidId(null)}>×</button></div><form onSubmit={voidDocument}><p>This preserves the document number and audit reference. Posted documents cannot be voided here.</p><label>Reason<input required minLength={3} maxLength={500} value={voidReason} onChange={e=>setVoidReason(e.target.value)}/></label><div className="modal-actions"><button type="button" onClick={()=>setVoidId(null)}>Cancel</button><button className="primary" disabled={busy}>Void draft</button></div></form></div></div>}{paymentDoc&&<div className="modal-backdrop" onMouseDown={e=>{if(e.target===e.currentTarget)setPaymentDoc(null)}}><div className="modal payment-modal" role="dialog" aria-modal="true" aria-label="Record payment"><div className="modal-header"><h2>Record payment</h2><button aria-label="Close" className="close" onClick={()=>setPaymentDoc(null)}>×</button></div><form className="workspace-create" onSubmit={recordPayment}><label>Amount (CAD)<input required inputMode="decimal" value={paymentAmount} onChange={e=>{setPaymentKey(null);setPaymentAmount(e.target.value)}}/></label><label>Payment date<input type="date" required value={paymentDate} onChange={e=>{setPaymentKey(null);setPaymentDate(e.target.value)}}/></label><label>Reference<input maxLength={100} value={paymentReference} onChange={e=>{setPaymentKey(null);setPaymentReference(e.target.value)}}/></label><p className="workspace-disclaimer">Payment is posted against the company's Operating Bank account. Actual bank reconciliation is not yet implemented.</p><div className="modal-actions"><button type="button" onClick={()=>setPaymentDoc(null)}>Cancel</button><button className="primary" disabled={busy}>Post payment</button></div></form></div></div>}</>}
    {tab==='reports'&&<><div className="card workspace-form"><h2>Ledger-backed financial reports</h2><p>All posted journal history is included, independent of the dashboard's recent activity limit.</p><div className="workspace-fields"><label>Period start<input type="date" value={periodStart} onChange={e=>setPeriodStart(e.target.value)}/></label><label>Through date<input type="date" value={asOf} onChange={e=>setAsOf(e.target.value)}/></label><button type="button" className="primary" disabled={reportBusy||!openingDateValid} onClick={()=>void refreshReports().catch(e=>notify(e.message,true))}>Refresh reports</button></div>{!openingDateValid&&<p className="error">Period start must be before or equal to the through date.</p>}</div><div className="workspace-reports"><div className="card"><div className="card-head"><div><h2>Balance sheet summary</h2><p>Balances as at {asOf}. Earnings are cumulative from journal history, until formal year-end closing is implemented.</p></div></div><div className="table-wrap"><table><thead><tr><th>Category</th><th>CAD</th></tr></thead><tbody><tr><td>Assets</td><td>{money(cumulativeAssets)}</td></tr><tr><td>Liabilities</td><td>{money(cumulativeLiabilities)}</td></tr><tr><td>Recorded equity</td><td>{money(cumulativeEquity)}</td></tr><tr><td>Cumulative earnings</td><td>{money(cumulativeEarnings)}</td></tr><tr><td><strong>Liabilities + equity + cumulative earnings</strong></td><td><strong>{money(cumulativeLiabilities+cumulativeEquity+cumulativeEarnings)}</strong></td></tr><tr><td><strong>Out of balance</strong></td><td><strong>{money(cumulativeAssets-cumulativeLiabilities-cumulativeEquity-cumulativeEarnings)}</strong></td></tr></tbody></table></div></div><div className="card"><div className="card-head"><div><h2>Trial balance</h2><p>As at {asOf}, debit-positive net balances.</p></div></div><div className="table-wrap"><table><thead><tr><th>Code</th><th>Account</th><th>Debits</th><th>Credits</th><th>Net debit</th></tr></thead><tbody>{report.map(r=><tr key={r.account_id}><td>{r.account_code}</td><td>{r.account_name}</td><td>{money(r.total_debits)}</td><td>{money(r.total_credits)}</td><td>{money(r.net_debit)}</td></tr>)}<tr><td colSpan={4}><strong>Net trial balance</strong></td><td><strong>{money(report.reduce((s,r)=>s+Number(r.net_debit),0))}</strong></td></tr></tbody></table></div></div><div className="card"><div className="card-head"><div><h2>Profit and loss</h2><p>{periodStart} to {asOf}</p></div></div><div className="table-wrap"><table><thead><tr><th>Account</th><th>Category</th><th>Amount</th></tr></thead><tbody>{profit.map(p=><tr key={p.account_code}><td>{p.account_name}</td><td className="capitalize">{p.account_type}</td><td>{money(p.amount)}</td></tr>)}<tr><td colSpan={2}><strong>Net operating result</strong></td><td><strong>{money(revenue-expenses)}</strong></td></tr></tbody></table></div></div></div></>}
  </section>
}
