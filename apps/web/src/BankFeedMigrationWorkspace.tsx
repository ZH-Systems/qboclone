import {useCallback,useEffect,useState,type FormEvent} from 'react'
import {supabase} from './lib/supabase'
import {formatMoney} from './lib/accounting'
type Props={organizationId:string;role:string;notify:(message:string,error?:boolean)=>void}
type FeedAccount={connection_id:string;feed_account_id:string;provider_account_id:string;account_name:string;ledger_account_id:string|null;status:string;last_synced_at:string|null}
type FeedRow={id:string;feed_account_id:string;description:string;booking_date:string;amount:number;pending:boolean;removed:boolean}
type LedgerAccount={id:string;code:string;name:string;is_bank_account:boolean}
type Statement={id:string;bank_account_id:string;start_date:string;end_date:string;status:string}
type Migration={id:string;state:string;source_system:string;source_company_id:string|null;created_at:string;source_as_of:string|null;financial_cutover_approved_at:string|null}
type SourceReport={id:string;report_type:string;period_start:string;period_end:string;content_sha256:string}
type Control={control_name:string;source_amount:number;target_amount:number;difference:number;reviewed_at:string}
type Qbo={realm_id:string;status:string;connected_at:string}
const types=['Account','Customer','Vendor','TaxCode','Invoice','Bill','CreditMemo','VendorCredit',
 'Payment','BillPayment','JournalEntry','Attachable','Purchase','Deposit','SalesReceipt',
 'RefundReceipt','Transfer','Estimate','PurchaseOrder','Item'] as const
type PlaidHandler={open:()=>void;destroy:()=>void}
declare global{interface Window{Plaid?:{create:(options:{
 token:string;onSuccess:(publicToken:string)=>void;onExit:(error:unknown)=>void
 })=>PlaidHandler}}}
const apiBase=(import.meta.env.VITE_BILLING_API_URL||'').replace(/\/$/,'')
const money=(v:number)=>formatMoney(Math.round(v*100))
async function requireToken():Promise<string>{
 if(!supabase)throw new Error('Supabase unavailable')
 const {data,error}=await supabase.auth.getSession()
 if(error||!data.session)throw new Error('Sign in again')
 return data.session.access_token
}
async function callApi(path:string,body:Record<string,unknown>):Promise<Record<string,unknown>>{
 if(!apiBase)throw new Error('VITE_BILLING_API_URL is not configured')
 const token=await requireToken()
 const response=await fetch(apiBase+path,{
  method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},
  body:JSON.stringify(body)})
 const data=await response.json() as Record<string,unknown>
 if(!response.ok)throw new Error(String(data.error||'Integration request failed'))
 return data
}
function loadPlaid():Promise<void>{
 if(window.Plaid)return Promise.resolve()
 return new Promise((resolve,reject)=>{
  const script=document.createElement('script')
  script.src='https://cdn.plaid.com/link/v2/stable/link-initialize.js'
  script.async=true
  script.onload=()=>window.Plaid?resolve():reject(new Error('Plaid Link could not initialize'))
  script.onerror=()=>reject(new Error('Plaid Link JavaScript failed to load'))
  document.head.appendChild(script)
 })
}
export default function BankFeedMigrationWorkspace({organizationId,role,notify}:Props){
 const [tab,setTab]=useState<'feeds'|'migration'>('feeds')
 const [overview,setOverview]=useState<FeedAccount[]>([])
 const [transactions,setTransactions]=useState<FeedRow[]>([])
 const [accounts,setAccounts]=useState<LedgerAccount[]>([])
 const [statements,setStatements]=useState<Statement[]>([])
 const [selectedStatement,setSelectedStatement]=useState('')
 const [selectedFeedIds,setSelectedFeedIds]=useState<string[]>([])
 const [connections,setConnections]=useState<Qbo[]>([])
 const [batches,setBatches]=useState<Migration[]>([])
 const [selectedBatch,setSelectedBatch]=useState('')
 const [selectedConnection,setSelectedConnection]=useState('')
 const [typeSelect,setTypeSelect]=useState<string[]>([...types])
 const [report,setReport]=useState<Record<string,unknown>|null>(null)
 const [progress,setProgress]=useState('')
 const [busy,setBusy]=useState(false)
 const [sourceFile,setSourceFile]=useState<File|null>(null)
 const [sourceReports,setSourceReports]=useState<SourceReport[]>([])
 const [controls,setControls]=useState<Control[]>([])
 const [reportType,setReportType]=useState('TrialBalance')
 const [reportStart,setReportStart]=useState(new Date().toISOString().slice(0,4)+'-01-01')
 const [reportEnd,setReportEnd]=useState(new Date().toISOString().slice(0,10))
 const [controlName,setControlName]=useState('trial_balance')
 const [controlReportId,setControlReportId]=useState('')
 const [sourceAmount,setSourceAmount]=useState('')
 const [targetAmount,setTargetAmount]=useState('')
 const [controlNotes,setControlNotes]=useState('')
 const canManage=['owner','administrator','accountant'].includes(role)
 const load=useCallback(async()=>{
  if(!supabase||!organizationId)return
  const [f,t,a,q,b,st,sr,cr]=await Promise.all([
   supabase.rpc('bank_feed_overview',{p_org:organizationId}),
   supabase.from('bank_feed_transactions').select('id,feed_account_id,description,booking_date,amount,pending,removed')
    .eq('organization_id',organizationId).order('booking_date',{ascending:false}).limit(100),
   supabase.from('accounts').select('id,code,name,is_bank_account').eq('organization_id',organizationId).eq('is_bank_account',true),
   supabase.rpc('qbo_connection_overview',{p_org:organizationId}),
   supabase.from('migration_batches').select('id,state,source_system,source_company_id,source_as_of,financial_cutover_approved_at,created_at')
    .eq('organization_id',organizationId).order('created_at',{ascending:false}).limit(40),
   supabase.from('bank_statements').select('id,bank_account_id,start_date,end_date,status')
    .eq('organization_id',organizationId).eq('status','open').order('end_date',{ascending:false}).limit(100),
   supabase.from('migration_source_reports').select('id,report_type,period_start,period_end,content_sha256')
    .eq('organization_id',organizationId).limit(150),
   supabase.from('migration_reconciliation_signoffs').select('control_name,source_amount,target_amount,difference,reviewed_at')
    .eq('organization_id',organizationId).limit(150)
  ])
  for(const result of [f,t,a,q,b,st,sr,cr])if(result.error)throw result.error
  setOverview((f.data||[]) as FeedAccount[]);setTransactions((t.data||[]) as FeedRow[])
  setAccounts((a.data||[]) as LedgerAccount[]);setConnections((q.data||[]) as Qbo[])
  setBatches((b.data||[]) as Migration[]);setStatements((st.data||[]) as Statement[])
  setSourceReports((sr.data||[]) as SourceReport[]);setControls((cr.data||[]) as Control[])
 },[organizationId])
 useEffect(()=>{setReport(null);setBatches([]);setOverview([]);void load().catch(e=>notify(e.message,true))},[load])
 const run=(work:()=>Promise<void>)=>{setBusy(true);void work().catch(e=>notify(
  e instanceof Error?e.message:String(e),true)).finally(()=>setBusy(false))}
 const connectBank=()=>run(async()=>{
  await loadPlaid()
  const {sessionId,linkToken}=await callApi('/bank-feeds/link-token',{organizationId})
  if(typeof sessionId!=='string'||typeof linkToken!=='string')throw new Error('Invalid Plaid link response')
  if(!window.Plaid)throw new Error('Plaid Link unavailable')
  const handler=window.Plaid.create({token:linkToken,
   onSuccess:publicToken=>{void callApi('/bank-feeds/exchange',{
    organizationId,sessionId,publicToken}).then(()=>load()).then(()=>
    notify('Bank account connected. Map each account to a ledger bank account.'))
    .catch(e=>notify(e instanceof Error?e.message:String(e),true)).finally(()=>handler.destroy())},
   onExit:error=>{handler.destroy();if(error)notify('Bank authorization canceled or failed',true)}
  })
  handler.open()
 })
 const synchronize=(connectionId:string)=>run(async()=>{
  const result=await callApi('/bank-feeds/sync',{organizationId,connectionId})
  await load();notify('Feed synchronized: '+result.updated+' updated, '+result.removed+' removed.')
 })
 const promote=()=>run(async()=>{
  if(!supabase||!selectedStatement||!selectedFeedIds.length)throw new Error('Select a statement and posted feed rows')
  const {data,error}=await supabase.rpc('promote_bank_feed_transactions',{
   p_org:organizationId,p_statement:selectedStatement,p_feed_transaction_ids:selectedFeedIds})
  if(error)throw error
  setSelectedFeedIds([]);await load()
  notify(Number(data?.imported||0)+' feed transactions staged for review in Bank reconciliation.')
 })
 const disconnect=(connectionId:string)=>run(async()=>{
  if(!window.confirm('Disconnect this institution? Imported staging records remain for audit.'))return
  await callApi('/bank-feeds/disconnect',{organizationId,connectionId})
  await load();notify('Bank connection disconnected and provider token revoked.')
 })
 const mapAccount=(feedId:string,ledger:string)=>run(async()=>{
  if(!supabase)return
  const {error}=await supabase.rpc('map_bank_feed_account',{
   p_org:organizationId,p_feed_account:feedId,p_ledger_account:ledger||null})
  if(error)throw error
  await load();notify('Bank feed mapped to ledger bank account.')
 })
 const connectQuickBooks=()=>run(async()=>{
  const {url}=await callApi('/qbo/connect/start',{organizationId})
  if(typeof url!=='string'||!url.startsWith('https://appcenter.intuit.com/'))
   throw new Error('Invalid QuickBooks consent URL')
  window.location.assign(url)
 })
 const createBatch=(event:FormEvent)=>{event.preventDefault();run(async()=>{
  if(!supabase||!selectedConnection)throw new Error('Connect a QuickBooks company first')
  const {data,error}=await supabase.rpc('create_migration_batch',{
   p_org:organizationId,p_source:'quickbooks_online',
   p_company_id:selectedConnection,p_as_of:new Date().toISOString().slice(0,10)})
  if(error)throw error
  setSelectedBatch(String(data));await load()
  notify('Migration batch created. Source data can now be staged without financial posting.')
 })}
 const stageQuickBooks=()=>run(async()=>{
  if(!selectedBatch)throw new Error('Select a migration batch')
  let total=0
  for(const entity of typeSelect){
   let start=1;let pageCount=0
   for(;pageCount<200;pageCount++){
    setProgress('Reading '+entity+' records from row '+start)
    const result=await callApi('/qbo/migration/page',{
     organizationId,batchId:selectedBatch,entity,start})
    total+=Number(result.staged||0)
    if(!result.hasMore)break
    start=Number(result.nextStart)
   }
   if(pageCount>=200)throw new Error('Page limit reached for '+entity+', review staged data before continuing')
  }
  await load();setProgress('Source extraction completed, '+total+' records staged.')
  notify('QuickBooks extraction completed. Review source records and discrepancies.')
 })
 const preview=()=>run(async()=>{
  if(!supabase||!selectedBatch)throw new Error('Select a migration batch')
  const {data,error}=await supabase.rpc('review_migration_batch',{
   p_org:organizationId,p_batch:selectedBatch})
  if(error)throw error
  const progressResult=await supabase.rpc('migration_batch_progress',{p_org:organizationId,p_batch:selectedBatch})
  if(progressResult.error)throw progressResult.error
  setReport({...data,progress:progressResult.data} as Record<string,unknown>)
 })
 const approve=()=>run(async()=>{
  if(!supabase||!selectedBatch)throw new Error('Select a migration batch')
  if(!window.confirm('Approve the source record review? This does NOT post historical financial documents or journals.'))return
  const {error}=await supabase.rpc('approve_migration_batch',{p_org:organizationId,p_batch:selectedBatch})
  if(error)throw error
  await load();notify('Migration reviewed and approved for safe import.')
 })
 const importSafe=()=>run(async()=>{
  if(!supabase||!selectedBatch)throw new Error('Select a migration batch')
  if(!window.confirm('Import mapped accounts, contacts, and draft invoices/bills? Financial posting is not automatic.'))return
  const {data,error}=await supabase.rpc('apply_reviewed_migration',{
   p_org:organizationId,p_batch:selectedBatch})
  if(error)throw error
  await load();notify('Safe import step complete, '+Number(data?.imported_this_batch||0)+' records.')
 })
 const postFinancials=()=>run(async()=>{
  if(!supabase||!selectedBatch)throw new Error('Select a migration batch')
  if(!window.confirm('This posts accountant-approved source invoices/bills and payment allocations to the ledger. Confirm source tax and account mappings first.'))return
  const {data,error}=await supabase.rpc('post_approved_migration_financials',{
   p_org:organizationId,p_batch:selectedBatch})
  if(error)throw error
  await load();notify(Number(data?.posted_this_batch||0)+' financial source items posted.')
 })
 const captureReport=()=>run(async()=>{
  if(!selectedBatch)throw new Error('Select a migration batch')
  const result=await callApi('/qbo/migration/report',{
   organizationId,batchId:selectedBatch,reportType,startDate:reportStart,endDate:reportEnd})
  await load();notify('Archived '+reportType+' report, SHA-256 '+String(result.sha256).slice(0,12)+'.')
 })
 const recordControl=(e:FormEvent)=>{e.preventDefault();run(async()=>{
  if(!supabase||!selectedBatch||!controlReportId)throw new Error('Choose a source report and batch')
  const {error}=await supabase.rpc('record_migration_reconciliation',{
   p_org:organizationId,p_batch:selectedBatch,p_control:controlName,
   p_source:sourceAmount,p_target:targetAmount,p_source_report:controlReportId,
   p_notes:controlNotes})
  if(error)throw error
  await load();notify('Accountant reconciliation recorded against live target ledger.')
 })}
 const acceptCutover=()=>run(async()=>{
  if(!supabase||!selectedBatch)throw new Error('Select a migration batch')
  if(!window.confirm('Finalize accountant signoff? Six evidenced reconciliations must agree with the live ledger.'))return
  const {error}=await supabase.rpc('accept_migration_financial_cutover',{
   p_org:organizationId,p_batch:selectedBatch})
  if(error)throw error
  await load();notify('Financial cutover evidence accepted. Commercial launch controls remain separate.')
 })
 const stageJson=()=>run(async()=>{
  if(!supabase||!selectedBatch||!sourceFile)throw new Error('Select a batch and JSON source file')
  if(sourceFile.size>10*1024*1024)throw new Error('JSON source bundle must be under 10 MiB')
  const raw=JSON.parse(await sourceFile.text()) as unknown
  if(!raw||typeof raw!=='object'||Array.isArray(raw))throw new Error('JSON bundle must be an object keyed by entity type')
  const supported=['account','customer','vendor','tax_code','invoice','bill','credit_note','vendor_credit',
   'payment','bill_payment','journal','opening_balance','attachment','bank_transaction']
  let inserted=0
  for(const [kind,records] of Object.entries(raw)){
   if(!supported.includes(kind)||!Array.isArray(records))throw new Error('Invalid migration collection: '+kind)
   for(let offset=0;offset<records.length;offset+=100){
    const {data,error}=await supabase.rpc('stage_migration_records',{
     p_org:organizationId,p_batch:selectedBatch,p_kind:kind,p_records:records.slice(offset,offset+100)})
    if(error)throw error
    inserted+=Number(data||0)
   }
  }
  notify('Staged '+inserted+' lossless source records, pending review.')
 })
 const feedConnections=[...new Set(overview.map(x=>x.connection_id))]
 return <section className="automation-workspace">
  <div className="advanced-tabs">
   <button className={tab==='feeds'?'selected':''} onClick={()=>setTab('feeds')}>Direct bank feeds</button>
   <button className={tab==='migration'?'selected':''} onClick={()=>setTab('migration')}>Complete source migration</button>
  </div>
  {tab==='feeds'&&<>
   <div className="card workspace-form"><h2>Connect Canadian bank accounts</h2>
    <p>Bank connections use Plaid's hosted authentication. The API encrypts access tokens and stages posted or pending bank transactions. All journal matching and reconciliation require approval.</p>
    <button className="primary" onClick={connectBank} disabled={busy||!canManage||!apiBase}>Connect institution with Plaid</button>
   </div>
   <div className="card"><div className="card-head"><h2>Linked institutions</h2></div>
    <div className="table-wrap"><table><thead><tr><th>Connection</th><th>Account</th><th>Ledger mapping</th><th>Last sync</th><th/></tr></thead>
    <tbody>{overview.map((f,i)=><tr key={f.feed_account_id||f.connection_id+'-'+i}>
     <td>{f.status}</td><td>{f.account_name||'Account selection pending'}</td>
     <td><select disabled={!canManage||!f.feed_account_id||busy} value={f.ledger_account_id||''}
     onChange={e=>mapAccount(f.feed_account_id,e.target.value)}>
      <option value="">Unmapped, review only</option>
      {accounts.map(a=><option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}
     </select></td>
     <td>{f.last_synced_at?.slice(0,16)||'Not yet synced'}</td>
     <td><button disabled={!canManage||busy} onClick={()=>synchronize(f.connection_id)}>Sync</button>
      <button disabled={!canManage||busy} onClick={()=>disconnect(f.connection_id)}>Disconnect</button></td>
    </tr>)}</tbody></table></div>
   </div>
   <div className="card"><div className="card-head"><h2>Imported transaction staging</h2></div>
    <div className="workspace-fields" style={{padding:'14px'}}>
     <label>Open bank statement<select value={selectedStatement} onChange={e=>{setSelectedStatement(e.target.value);setSelectedFeedIds([])}}><option value="">Choose statement</option>{statements.map(st=><option key={st.id} value={st.id}>{st.start_date} to {st.end_date} · {accounts.find(a=>a.id===st.bank_account_id)?.name||'Bank'}</option>)}</select></label>
     <button className="primary" disabled={!canManage||busy||!selectedStatement||!selectedFeedIds.length} onClick={promote}>Stage selected rows ({selectedFeedIds.length})</button>
    </div>
    <div className="table-wrap"><table><thead><tr><th>Select</th><th>Date</th><th>Description</th><th>Amount (CAD)</th><th>State</th></tr></thead>
    <tbody>{transactions.map(t=><tr key={t.id}><td><input type="checkbox" disabled={t.pending||t.removed||!selectedStatement||!canManage}
    checked={selectedFeedIds.includes(t.id)} onChange={e=>setSelectedFeedIds(prev=>e.target.checked?[...prev,t.id]:prev.filter(x=>x!==t.id))}/></td><td>{t.booking_date}</td><td>{t.description}</td>
     <td>{money(t.amount)}</td><td>{t.removed?'Removed by bank':t.pending?'Pending':'Posted at bank, unmatched'}</td></tr>)}
    </tbody></table></div><p>Bank feed staging does not alter the general ledger.</p>
   </div>
  </>}
  {tab==='migration'&&<>
   <div className="card workspace-form"><h2>Connect QuickBooks Online</h2>
    <p>Authorizes read-only extraction through the Intuit OAuth flow. All source entities retain their original JSON in migration staging. Historical financial posting is intentionally blocked until verified.</p>
    <button className="primary" disabled={busy||!canManage||!apiBase} onClick={connectQuickBooks}>Connect QuickBooks Online</button>
    <form className="workspace-fields" onSubmit={createBatch}>
     <label>Connected company<select required value={selectedConnection} onChange={e=>setSelectedConnection(e.target.value)}>
      <option value="">Select QuickBooks company</option>{connections.filter(c=>c.status==='active').map(c=>
       <option key={c.realm_id} value={c.realm_id}>{c.realm_id}</option>)}</select></label>
     <button disabled={!canManage||busy||!selectedConnection} className="primary">Create migration batch</button>
    </form>
   </div>
   <div className="card workspace-form"><h2>Stage full source accounting records</h2>
    <label>Migration batch<select value={selectedBatch} onChange={e=>{setSelectedBatch(e.target.value);setReport(null)}}>
     <option value="">Select batch</option>{batches.map(b=><option key={b.id} value={b.id}>
      {b.source_system} · {b.created_at.slice(0,10)} · {b.state}</option>)}</select></label>
    <p>Select entity collections. All extracted source JSON remains available for reconciliation. Postings are never executed by extraction.</p>
    <div className="source-entity-grid">{types.map(t=><label key={t}>
     <input type="checkbox" checked={typeSelect.includes(t)} onChange={e=>setTypeSelect(old=>
      e.target.checked?[...old,t]:old.filter(x=>x!==t))}/> {t}</label>)}</div>
    <button className="primary" disabled={busy||!canManage||!selectedBatch||!typeSelect.length} onClick={stageQuickBooks}>Stage selected QuickBooks entities</button>
    {progress&&<p role="status">{progress}</p>}
    <label>Alternative source JSON bundle<input type="file" accept=".json,application/json" onChange={e=>setSourceFile(e.target.files?.[0]||null)}/></label>
    <button disabled={!canManage||busy||!sourceFile||!selectedBatch} onClick={stageJson}>Stage JSON source bundle</button>
   </div>
   <div className="card workspace-form"><h2>Migration preflight and approval</h2>
    <p>Preflight checks source references and GL discrepancies. Imported contacts, accounts and invoices/bills are safe drafts. Bank feeds, historical journals, tax codes, payments, attachments and other source transactions remain archived for accountant mapping. Do not finalize go-live until balance and completeness controls pass.</p>
    <div className="workspace-toolbar"><button disabled={busy||!selectedBatch} onClick={preview}>Review records</button>
     <button disabled={busy||!selectedBatch||!canManage} onClick={approve}>Approve source review</button>
     <button disabled={busy||!selectedBatch||!canManage} onClick={importSafe}>Import mapped safe records</button>
     <button disabled={busy||!selectedBatch||!canManage} onClick={postFinancials}>Post approved financials (up to 50)</button></div>
    {report&&<pre className="migration-review">{JSON.stringify(report,null,2)}</pre>}
   </div>
   <div className="card workspace-form"><h2>Accountant cutover reconciliation</h2>
    <p>Capture original QuickBooks reports and verify each reported balance against the live target ledger. The server recalculates target balances and rejects mismatches. Financial cutover requires six evidenced controls with differences at most $0.01, all open source invoices/bills and allocated payments posted, and a signed-off import batch.</p>
    <div className="workspace-fields">
     <label>QuickBooks report<select value={reportType} onChange={e=>setReportType(e.target.value)}>
      {['TrialBalance','BalanceSheet','ProfitAndLoss','AgedReceivables','AgedPayables'].map(t=><option key={t} value={t}>{t}</option>)}</select></label>
     <label>Start date<input type="date" value={reportStart} onChange={e=>setReportStart(e.target.value)}/></label>
     <label>As-of date<input type="date" value={reportEnd} onChange={e=>setReportEnd(e.target.value)}/></label>
    </div>
    <button disabled={!canManage||busy||!selectedBatch} onClick={captureReport}>Capture source report</button>
    <form onSubmit={recordControl} className="workspace-fields">
     <label>Control<select value={controlName} onChange={e=>setControlName(e.target.value)}>
      {['trial_balance','accounts_receivable','accounts_payable','bank_cash','gst_hst','historic_profit_loss'].map(t=><option key={t} value={t}>{t}</option>)}</select></label>
     <label>Source report<select required value={controlReportId} onChange={e=>setControlReportId(e.target.value)}>
      <option value="">Select captured report</option>{sourceReports.map(r=><option key={r.id} value={r.id}>{r.report_type} · {r.period_end}</option>)}</select></label>
     <label>Source balance (CAD)<input required inputMode="decimal" value={sourceAmount} onChange={e=>setSourceAmount(e.target.value)}/></label>
     <label>Target balance (CAD)<input required inputMode="decimal" value={targetAmount} onChange={e=>setTargetAmount(e.target.value)}/></label>
     <label>Accountant review notes<input required minLength={10} value={controlNotes} onChange={e=>setControlNotes(e.target.value)}/></label>
     <button className="primary" disabled={busy||!canManage||!selectedBatch}>Record balance control</button>
    </form>
    <div className="table-wrap"><table><thead><tr><th>Control</th><th>Source</th><th>Target</th><th>Difference</th></tr></thead>
     <tbody>{controls.map(c=><tr key={c.control_name}><td>{c.control_name}</td><td>{money(Number(c.source_amount))}</td>
      <td>{money(Number(c.target_amount))}</td><td>{money(Number(c.difference))}</td></tr>)}</tbody></table></div>
    <button className="primary" disabled={!selectedBatch||!canManage||busy} onClick={acceptCutover}>Accept reconciled migration cutover</button>
   </div>
  </>}
 </section>
}
