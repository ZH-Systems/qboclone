import {useCallback,useEffect,useMemo,useState,type FormEvent} from 'react'
import {supabase} from './lib/supabase'
import {formatMoney} from './lib/accounting'
import {parseBankCsv,parseSignedMoney} from './lib/bankCsv'
import {normalizeBankStatement,type BankColumnMap} from './lib/bankImportMapping'
import {parseCsvRecords} from './lib/importCsv'

type Props={organizationId:string;mode:'tax'|'banking';notify:(message:string,isError?:boolean)=>void}
type Account={id:string;code:string;name:string;account_type:string;is_bank_account:boolean}
type TaxCode={id:string;code:string;label:string;transaction_kind:string;classification:string;rate_bps:number;recoverable_bps:number;effective_from:string;effective_until:string|null}
type Statement={id:string;bank_account_id:string;start_date:string;end_date:string;opening_balance:number;closing_balance:number;status:'open'|'reconciled'}
type BankRow={id:string;statement_id:string;line_number:number;transaction_date:string;description:string;reference:string|null;signed_amount:number;matched_journal_entry_id:string|null}
type Journal={id:string;entry_date:string;memo:string;reference:string|null;journal_lines:{account_id:string;debit:number;credit:number}[]}
const today=()=>new Date().toLocaleDateString('sv-SE',{timeZone:'America/Toronto'})
function inputMoney(v:string):string{return parseSignedMoney(v)}
export default function TaxBankWorkspace({organizationId,mode,notify}:Props){
  const [accounts,setAccounts]=useState<Account[]>([])
  const [taxCodes,setTaxCodes]=useState<TaxCode[]>([])
  const [statements,setStatements]=useState<Statement[]>([])
  const [rows,setRows]=useState<BankRow[]>([])
  const [journals,setJournals]=useState<Journal[]>([])
  const [busy,setBusy]=useState(false)
  const [code,setCode]=useState('')
  const [label,setLabel]=useState('')
  const [kind,setKind]=useState('sale')
  const [classification,setClassification]=useState('taxable')
  const [rate,setRate]=useState('1300')
  const [recoverable,setRecoverable]=useState('0')
  const [effectiveFrom,setEffectiveFrom]=useState('2026-01-01')
  const [effectiveUntil,setEffectiveUntil]=useState('')
  const [bankFlagAccount,setBankFlagAccount]=useState('')
  const [accountId,setAccountId]=useState('')
  const [start,setStart]=useState(today().slice(0,8)+'01')
  const [end,setEnd]=useState(today())
  const [opening,setOpening]=useState('0.00')
  const [closing,setClosing]=useState('0.00')
  const [activeStatement,setActiveStatement]=useState('')
  const [csv,setCsv]=useState('')
  const [sourceBankCsv,setSourceBankCsv]=useState('')
  const [bankColumns,setBankColumns]=useState<string[]>([])
  const [bankMapping,setBankMapping]=useState<BankColumnMap>({date:'',description:'',amount:'',debit:'',credit:'',reference:'',dateFormat:'iso'})
  const [selectedMatches,setSelectedMatches]=useState<Record<string,string>>({})
  const [preview,setPreview]=useState('')
  const refresh=useCallback(async()=>{
    if(!supabase||!organizationId)return
    const [a,t,s,j]=await Promise.all([
      supabase.from('accounts').select('id,code,name,account_type,is_bank_account').eq('organization_id',organizationId).order('code'),
      supabase.from('tax_codes').select('id,code,label,transaction_kind,classification,rate_bps,recoverable_bps,effective_from,effective_until').eq('organization_id',organizationId).order('code'),
      supabase.from('bank_statements').select('id,bank_account_id,start_date,end_date,opening_balance,closing_balance,status').eq('organization_id',organizationId).order('end_date',{ascending:false}),
      supabase.from('journal_entries').select('id,entry_date,memo,reference,journal_lines(account_id,debit,credit)').eq('organization_id',organizationId).order('entry_date',{ascending:false}).limit(500)
    ])
    for(const r of [a,t,s,j])if(r.error)throw r.error
    setAccounts((a.data||[]) as Account[])
    setTaxCodes((t.data||[]) as TaxCode[])
    setStatements((s.data||[]) as Statement[])
    setJournals((j.data||[]) as Journal[])
  },[organizationId])
  const refreshRows=useCallback(async()=>{
    if(!supabase||!activeStatement){setRows([]);return}
    const {data,error}=await supabase.from('bank_transactions').select('id,statement_id,line_number,transaction_date,description,reference,signed_amount,matched_journal_entry_id').eq('organization_id',organizationId).eq('statement_id',activeStatement).order('line_number').limit(500)
    if(error)throw error
    setRows((data||[]) as BankRow[])
  },[organizationId,activeStatement])
  useEffect(()=>{setActiveStatement('');setCsv('');setSelectedMatches({});setStatements([]);setTaxCodes([]);void refresh().catch(e=>notify(e.message,true))},[refresh])
  useEffect(()=>{void refreshRows().catch(e=>notify(e.message,true))},[refreshRows])
  const run=async(job:()=>Promise<void>)=>{
    setBusy(true)
    try{await job()}catch(e){notify(e instanceof Error?e.message:String(e),true)}finally{setBusy(false)}
  }
  const createTax=(e:FormEvent)=>{e.preventDefault();void run(async()=>{
    if(!supabase)return
    const {error}=await supabase.rpc('create_tax_code_with_dates',{
      p_organization_id:organizationId,p_code:code.trim(),p_label:label.trim(),p_kind:kind,
      p_classification:classification,p_rate_bps:Number(classification==='taxable'?rate:'0'),
      p_recoverable_bps:kind==='purchase'?Number(recoverable):0,
      p_effective_from:effectiveFrom,p_effective_until:effectiveUntil||null
    })
    if(error)throw error
    setCode('');setLabel('');await refresh();notify('Tax classification created.')
  })}
  const designateBank=()=>void run(async()=>{
    if(!supabase||!bankFlagAccount)throw new Error('Choose an asset account.')
    const {error}=await supabase.rpc('set_bank_account_flag',{p_organization_id:organizationId,p_account_id:bankFlagAccount,p_is_bank:true})
    if(error)throw error
    await refresh();notify('Account designated as a bank account.')
  })
  const createStatement=(e:FormEvent)=>{e.preventDefault();void run(async()=>{
    if(!supabase)return
    const {data,error}=await supabase.rpc('create_bank_statement',{
      p_organization_id:organizationId,p_bank_account_id:accountId,p_start:start,p_end:end,
      p_opening:inputMoney(opening),p_closing:inputMoney(closing)
    })
    if(error)throw error
    await refresh();setActiveStatement(data as string);notify('Bank statement opened.')
  })}
  const current=statements.find(x=>x.id===activeStatement)
  const readBankFile=(file:File|null)=>void run(async()=>{
    if(!file)return
    if(file.size>4*1024*1024)throw new Error('Bank statement CSV is limited to 4 MiB')
    const text=await file.text()
    const records=parseCsvRecords(text)
    if(!records.length)throw new Error('Bank CSV is empty')
    const cols=records[0].map(x=>x.trim())
    setSourceBankCsv(text);setBankColumns(cols)
    const find=(...options:string[])=>cols.find(h=>options.some(x=>x===h.toLowerCase()))||''
    setBankMapping({
     date:find('date','transaction date','txn date'),description:find('description','narrative','details'),
     amount:find('amount','transaction amount'),debit:find('debit','withdrawal','money out'),
     credit:find('credit','deposit','money in'),reference:find('reference','transaction id'),
     dateFormat:'iso'
    })
    notify('Statement file loaded. Confirm the date format and column mapping before normalizing.')
  })
  const normalizeBankFile=()=>void run(async()=>{
    const standardized=normalizeBankStatement(sourceBankCsv,bankMapping)
    setCsv(standardized)
    notify('Mapped '+parseBankCsv(standardized).length+' bank rows to the canonical CSV format. Review before importing.')
  })
  const importCsv=()=>void run(async()=>{
    if(!supabase||!current)return
    if(current.status!=='open')throw new Error('Reconciled statements cannot be changed.')
    const parsed=parseBankCsv(csv)
    for(let offset=0;offset<parsed.length;offset+=500){
      const {error}=await supabase.rpc('import_bank_statement_rows',{
        p_organization_id:organizationId,p_statement_id:current.id,p_rows:parsed.slice(offset,offset+500)
      })
      if(error)throw error
    }
    await refreshRows();notify('CSV rows imported. Duplicate row numbers with different data are rejected.')
  })
  const activeRows=useMemo(()=>rows.filter(r=>!r.matched_journal_entry_id),[rows])
  const candidates=(row:BankRow):Journal[]=>{
    if(!current)return[]
    return journals.filter(j=>Math.round(j.journal_lines.filter(l=>l.account_id===current.bank_account_id)
      .reduce((sum,l)=>sum+(Number(l.debit)-Number(l.credit)),0)*100)===Math.round(Number(row.signed_amount)*100))
  }
  const match=(row:BankRow)=>void run(async()=>{
    if(!supabase||!selectedMatches[row.id])throw new Error('Select a matching journal.')
    const {error}=await supabase.rpc('match_bank_transaction',{
      p_organization_id:organizationId,p_bank_transaction_id:row.id,p_journal_entry_id:selectedMatches[row.id]
    })
    if(error)throw error
    await refreshRows();notify('Bank transaction matched.')
  })
  const unmatch=(row:BankRow)=>void run(async()=>{
    if(!supabase)return
    const {error}=await supabase.rpc('unmatch_bank_transaction',{
      p_organization_id:organizationId,p_transaction_id:row.id
    })
    if(error)throw error
    await refreshRows();notify('Transaction unmatched.')
  })
  const resetImport=()=>void run(async()=>{
    if(!supabase||!current)return
    const {data,error}=await supabase.rpc('reset_open_bank_statement',{p_organization_id:organizationId,p_statement_id:current.id})
    if(error)throw error
    await refreshRows();notify(`${data} staged bank rows cleared. No journal entries were changed.`)
  })
  const reconcile=()=>void run(async()=>{
    if(!supabase||!current)return
    const {error}=await supabase.rpc('reconcile_bank_statement',{
      p_organization_id:organizationId,p_statement_id:current.id
    })
    if(error)throw error
    await refresh();notify('Bank statement reconciled and locked.')
  })
  const importedSum=rows.reduce((sum,r)=>sum+Math.round(Number(r.signed_amount)*100),0)
  return <section className="accounting-workspace">
    {mode==='tax'&&<>
      <div className="card"><div className="card-head"><div><h2>Configured tax classifications</h2><p>Rates and recoverability are organization-defined, not validated Canadian tax guidance.</p></div></div>
      <div className="table-wrap"><table><thead><tr><th>Code</th><th>Description</th><th>Applies to</th><th>Class</th><th>Rate</th><th>Recoverable</th><th>Effective period</th></tr></thead><tbody>{taxCodes.map(t=><tr key={t.id}><td className="strong">{t.code}</td><td>{t.label}</td><td className="capitalize">{t.transaction_kind}</td><td>{t.classification}</td><td>{(t.rate_bps/100).toFixed(2)}%</td><td>{(t.recoverable_bps/100).toFixed(2)}%</td><td>{t.effective_from} to {t.effective_until||'open'}</td></tr>)}{taxCodes.length===0&&<tr><td colSpan={7}><div className="empty">No tax codes defined.</div></td></tr>}</tbody></table></div></div>
      <form className="card workspace-form" onSubmit={createTax}><h2>Create a tax code</h2><p className="workspace-disclaimer">Use only rates and recoverability rules confirmed by your accountant. A zero-rated sale, exempt sale and out-of-scope sale are distinct classifications.</p>
      <div className="workspace-fields"><label>Code<input required value={code} maxLength={24} onChange={e=>setCode(e.target.value)}/></label><label>Label<input required value={label} maxLength={120} onChange={e=>setLabel(e.target.value)}/></label><label>Direction<select value={kind} onChange={e=>setKind(e.target.value)}><option value="sale">Sale</option><option value="purchase">Purchase</option></select></label><label>Classification<select value={classification} onChange={e=>setClassification(e.target.value)}>{['taxable','zero_rated','exempt','out_of_scope'].map(v=><option value={v} key={v}>{v}</option>)}</select></label><label>Rate (basis points)<input required type="number" min="0" max="2500" step="1" disabled={classification!=='taxable'} value={classification==='taxable'?rate:'0'} onChange={e=>setRate(e.target.value)}/></label><label>Recoverable (%) basis points<input required type="number" min="0" max="10000" step="1" disabled={kind!=='purchase'} value={kind==='purchase'?recoverable:'0'} onChange={e=>setRecoverable(e.target.value)}/></label><label>Effective from<input type="date" required value={effectiveFrom} onChange={e=>setEffectiveFrom(e.target.value)}/></label><label>Effective until (optional)<input type="date" min={effectiveFrom} value={effectiveUntil} onChange={e=>setEffectiveUntil(e.target.value)}/></label></div><button disabled={busy} className="primary">Create tax code</button></form>
    </>}
    {mode==='banking'&&<>
      <div className="card workspace-form"><h2>Designate a bank account</h2><p>Only explicit bank accounts are eligible for bank reconciliation.</p><div className="workspace-fields"><label>Asset account<select value={bankFlagAccount} onChange={e=>setBankFlagAccount(e.target.value)}><option value="">Select asset account</option>{accounts.filter(a=>a.account_type==='asset'&&!a.is_bank_account).map(a=><option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}</select></label><button type="button" className="primary" disabled={busy||!bankFlagAccount} onClick={designateBank}>Mark as bank account</button></div></div>
      <form className="card workspace-form" onSubmit={createStatement}><h2>Create a bank statement</h2><p>Import an account statement into staging, then match each line to a previously posted journal.</p>
      <div className="workspace-fields"><label>Asset/bank account<select required value={accountId} onChange={e=>setAccountId(e.target.value)}><option value="">Select bank account</option>{accounts.filter(a=>a.is_bank_account).map(a=><option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}</select></label><label>Start<input type="date" required value={start} onChange={e=>setStart(e.target.value)}/></label><label>End<input type="date" required min={start} value={end} onChange={e=>setEnd(e.target.value)}/></label><label>Opening (CAD)<input required inputMode="decimal" value={opening} onChange={e=>setOpening(e.target.value)}/></label><label>Closing (CAD)<input required inputMode="decimal" value={closing} onChange={e=>setClosing(e.target.value)}/></label></div><button disabled={busy} className="primary">Create statement</button></form>
      <div className="card workspace-form"><h2>Bank statement workspace</h2><label className="field-label">Select statement<select value={activeStatement} onChange={e=>setActiveStatement(e.target.value)}><option value="">Choose a statement</option>{statements.map(s=><option key={s.id} value={s.id}>{s.start_date} to {s.end_date} · {accounts.find(a=>a.id===s.bank_account_id)?.name||'Account'} · {s.status}</option>)}</select></label>
      {current&&<><div className="bank-summary"><span>Opening <strong>{formatMoney(Math.round(Number(current.opening_balance)*100))}</strong></span><span>Imported change <strong>{formatMoney(importedSum)}</strong></span><span>Expected closing <strong>{formatMoney(Math.round(Number(current.closing_balance)*100))}</strong></span><span>Unmatched <strong>{activeRows.length}</strong></span></div>
      {current.status==='open'&&<><p className="workspace-disclaimer">CSV format: date,description,amount,reference. Dates must be YYYY-MM-DD; positive amounts are deposits, negative amounts are withdrawals. Preserve row order when reimporting the same file. Imports are capped at 500 rows per batch.</p>
      <div className="bank-mapper"><h3>Import another bank's CSV format</h3>
      <p>Select column mappings and an explicit date format, then normalize the file. You can review the canonical rows before importing.</p>
      <input type="file" accept=".csv,text/csv" onChange={e=>void readBankFile(e.target.files?.[0]||null)}/>
      {sourceBankCsv&&<div className="workspace-fields">
        {([['date','Transaction date'],['description','Description'],['amount','Signed amount (optional)'],['debit','Debit / withdrawal'],['credit','Credit / deposit'],['reference','Reference (optional)']] as [keyof BankColumnMap,string][]).map(([key,title])=>
          <label key={key}>{title}<select value={bankMapping[key]} onChange={e=>setBankMapping({...bankMapping,[key]:e.target.value})}><option value="">None</option>{bankColumns.map(x=><option key={x} value={x}>{x}</option>)}</select></label>)}
        <label>Date convention<select value={bankMapping.dateFormat} onChange={e=>setBankMapping({...bankMapping,dateFormat:e.target.value as BankColumnMap['dateFormat']})}>
          <option value="iso">YYYY-MM-DD</option><option value="mdy">MM/DD/YYYY</option><option value="dmy">DD/MM/YYYY</option>
        </select></label>
       </div>}
       {sourceBankCsv&&<button type="button" disabled={busy} onClick={normalizeBankFile}>Normalize mapped CSV</button>}
      </div><label className="field-label">Statement CSV<textarea rows={5} value={csv} onChange={e=>setCsv(e.target.value)} placeholder={'date,description,amount,reference\n2026-11-01,Client payment,113.00,INV-001'}/></label><div className="workspace-toolbar"><button className="primary" disabled={busy||!csv.trim()} onClick={importCsv}>Import CSV rows</button><button type="button" disabled={busy||rows.length===0} onClick={resetImport}>Reset imported rows</button><button className="primary" disabled={busy||rows.length===0||activeRows.length>0} onClick={reconcile}>Reconcile statement</button></div></>}
      <div className="table-wrap"><table><thead><tr><th>#</th><th>Date</th><th>Description</th><th>Bank change</th><th>Match</th></tr></thead><tbody>{rows.map(r=><tr key={r.id}><td>{r.line_number}</td><td>{r.transaction_date}</td><td>{r.description}</td><td>{formatMoney(Math.round(Number(r.signed_amount)*100))}</td><td>{r.matched_journal_entry_id?<><span className="status">Matched</span>{current.status==='open'&&<button className="link-button" disabled={busy} onClick={()=>unmatch(r)}>Unmatch</button>}</>:current.status==='open'?<div className="row-actions"><select value={selectedMatches[r.id]||''} onChange={e=>setSelectedMatches({...selectedMatches,[r.id]:e.target.value})}><option value="">Choose journal</option>{candidates(r).map(j=><option key={j.id} value={j.id}>{j.entry_date} · {j.memo.slice(0,42)}</option>)}</select><button disabled={busy||!selectedMatches[r.id]} onClick={()=>match(r)}>Match</button></div>:'Unmatched'}</td></tr>)}{rows.length===0&&<tr><td colSpan={5}><div className="empty">No imported transactions.</div></td></tr>}</tbody></table></div></>}</div>
    </>}
  </section>
}
