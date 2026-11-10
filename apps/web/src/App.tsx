import { useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from 'react'
import type { Session } from '@supabase/supabase-js'
import { ArrowDownRight, ArrowUpRight, BookOpen, Building2, CheckCircle2, ChevronDown, CircleDollarSign, FileText, LayoutDashboard, LockKeyhole, LogOut, Menu, Plus, Settings, ShieldCheck, Wallet } from 'lucide-react'
import { supabase, configured } from './lib/supabase'
import { AccountingWorkspace, type WorkspaceTab } from './AccountingWorkspace'
import FiscalPeriods from './FiscalPeriods'
import TaxBankWorkspace from './TaxBankWorkspace'
import BusinessAdministration from './BusinessAdministration'
import { asDecimal, formatMoney, parseMoney, validateJournal, type Account, type Journal, type JournalLine } from './lib/accounting'

type Organization = { id: string; name: string; base_currency: string }
type Membership = { organization_id: string; organizations: Organization | Organization[] | null; role: string }
type Page = 'overview' | 'accounts' | 'journals' | 'settings' | WorkspaceTab | 'tax' | 'banking'
const nav: { label: string; id: Page; icon: typeof LayoutDashboard }[] = [
  { label: 'Overview', id: 'overview', icon: LayoutDashboard },
  { label: 'Contacts', id: 'contacts', icon: Building2 },
  { label: 'Sales & invoices', id: 'sales', icon: ArrowUpRight },
  { label: 'Bills & purchases', id: 'purchases', icon: ArrowDownRight },
  { label: 'Chart of accounts', id: 'accounts', icon: BookOpen },
  { label: 'Journal entries', id: 'journals', icon: FileText },
  { label: 'Financial reports', id: 'reports', icon: Wallet },
  { label: 'Tax configuration', id: 'tax', icon: Settings },
  { label: 'Bank reconciliation', id: 'banking', icon: Wallet },
  { label: 'Settings', id: 'settings', icon: Settings }
]
const defaults = (): JournalLine[] => [{ account_id: '', debit: '', credit: '0' }, { account_id: '', debit: '0', credit: '' }]
const initialDate = () => new Date().toLocaleDateString('sv-SE', { timeZone: 'America/Toronto' })
function App() {
  const [session, setSession] = useState<Session | null>(null)
  const [loadingAuth, setLoadingAuth] = useState(true)
  const [inviteFromHash, setInviteFromHash] = useState(()=>new URLSearchParams(window.location.hash.slice(1)).get('invite')||'')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [newName, setNewName] = useState('')
  const [memberships, setMemberships] = useState<Membership[]>([])
  const [orgId, setOrgId] = useState('')
  const [page, setPage] = useState<Page>('overview')
  const [accounts, setAccounts] = useState<Account[]>([])
  const [journals, setJournals] = useState<Journal[]>([])
  const [showEntry, setShowEntry] = useState(false)
  const [reverseId, setReverseId] = useState<string | null>(null)
  const [reverseReason, setReverseReason] = useState('')
  const [memo, setMemo] = useState('')
  const [reference, setReference] = useState('')
  const [date, setDate] = useState(initialDate())
  const [lines, setLines] = useState<JournalLine[]>(defaults)
  const [newAccount, setNewAccount] = useState({ code: '', name: '', account_type: 'expense' })
  const pendingPostKey = useRef<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const selected = memberships.find(m => m.organization_id === orgId)
  const org = selected && (Array.isArray(selected.organizations) ? selected.organizations[0] : selected.organizations)

  const refreshMemberships = useCallback(async () => {
    if (!supabase) return
    const { data, error } = await supabase.from('organization_members').select('organization_id,role,organizations(id,name,base_currency)').order('created_at')
    if (error) throw error
    const next = (data || []) as unknown as Membership[]
    setMemberships(next)
    setOrgId(current => next.some(m => m.organization_id === current) ? current : (next[0]?.organization_id || ''))
  }, [])
  const refreshBooks = useCallback(async () => {
    if (!supabase || !orgId) { setAccounts([]); setJournals([]); return }
    const [a,j] = await Promise.all([
      supabase.from('accounts').select('id,code,name,account_type,normal_balance').eq('organization_id', orgId).order('code'),
      supabase.from('journal_entries').select('id,entry_date,memo,reference,created_at,journal_lines(account_id,debit,credit)').eq('organization_id', orgId).order('entry_date',{ascending:false}).limit(100)
    ])
    if (a.error) throw a.error
    if (j.error) throw j.error
    setAccounts((a.data || []) as Account[])
    setJournals((j.data || []) as Journal[])
  }, [orgId])
  useEffect(() => {
    if (!supabase) { setLoadingAuth(false); return }
    const client = supabase
    client.auth.getSession().then(({data}) => { setSession(data.session); setLoadingAuth(false) })
    const {data:sub} = client.auth.onAuthStateChange((_event,s) => setSession(s))
    return () => sub.subscription.unsubscribe()
  }, [])
  useEffect(() => { if (session) refreshMemberships().catch(e=>setError(e.message)); else {setMemberships([]); setOrgId('')} }, [session,refreshMemberships])
  useEffect(() => { refreshBooks().catch(e=>setError(e.message)) }, [refreshBooks])
  const summaries = useMemo(() => {
    const sums = new Map<string, number>()
    for (const j of journals) for (const line of j.journal_lines) {
      const acc = accounts.find(a => a.id === line.account_id)
      if (!acc) continue
      const net = Math.round(Number(line.debit)*100) - Math.round(Number(line.credit)*100)
      sums.set(acc.id, (sums.get(acc.id) || 0) + (acc.normal_balance === 'debit' ? net : -net))
    }
    const total = (types: string[]) => accounts.filter(a=>types.includes(a.account_type)).reduce((sum,a)=>sum + (sums.get(a.id)||0),0)
    return { assets: total(['asset']), liabilities: total(['liability']), revenue: total(['revenue']), expenses: total(['expense']), equity: total(['equity']), count: journals.length }
  }, [accounts,journals])
  const task = async (action: () => Promise<void>) => {
    setError('');setNotice('');setBusy(true)
    try { await action() } catch(e) { setError(e instanceof Error ? e.message : String(e)) } finally { setBusy(false) }
  }
  const acceptInvite = ()=>void task(async()=>{
    if(!supabase||!inviteFromHash)return
    const {error}=await supabase.rpc('accept_organization_invitation',{p_token:inviteFromHash})
    if(error)throw error
    setInviteFromHash('');window.history.replaceState(null,'',window.location.pathname+window.location.search)
    await refreshMemberships();setNotice('Organization invitation accepted.')
  })
  const login = (e: FormEvent) => {e.preventDefault();void task(async()=> {
    if (!supabase) return
    const {error} = await supabase.auth.signInWithPassword({email,password})
    if (error) throw error
  })}
  const signUp = () => void task(async()=> {
    if (!supabase) return
    const {error} = await supabase.auth.signUp({email,password})
    if (error) throw error
    setNotice('Registration submitted. Verify your email if confirmation is enabled, then sign in.')
  })
  const createOrg = (e: FormEvent) => {e.preventDefault();void task(async()=> {
    if (!supabase) return
    const {error} = await supabase.rpc('create_organization', {p_name:newName.trim()})
    if (error) throw error
    setNewName('')
    await refreshMemberships()
    setNotice('Business created with a standard chart of accounts.')
  })}
  const reverseJournal = (e: FormEvent) => {e.preventDefault();void task(async()=> {
    if (!supabase || !reverseId) return
    const {error} = await supabase.rpc('reverse_manual_journal',{p_organization_id:orgId,p_journal_id:reverseId,p_reversal_date:date,p_reason:reverseReason.trim()})
    if(error) throw error
    setReverseId(null);setReverseReason('');await refreshBooks();setNotice('Manual journal reversed.')
  })}
  const createAccount = (e: FormEvent) => {e.preventDefault();void task(async()=> {
    if (!supabase) return
    const {error} = await supabase.rpc('create_account', {p_organization_id:orgId,p_code:newAccount.code.trim(),p_name:newAccount.name.trim(),p_type:newAccount.account_type})
    if (error) throw error
    setNewAccount({code:'',name:'',account_type:'expense'})
    await refreshBooks()
    setNotice('Account created.')
  })}
  const postJournal = (e: FormEvent) => {e.preventDefault();void task(async()=> {
    if (!supabase) return
    validateJournal(lines)
    const {error} = await supabase.rpc('post_journal',{p_organization_id:orgId,p_entry_date:date,p_memo:memo.trim(),p_reference:reference.trim()||null,p_idempotency_key:(pendingPostKey.current ||= crypto.randomUUID()),p_lines:lines.map(l=>({account_id:l.account_id,debit:asDecimal(l.debit||'0'),credit:asDecimal(l.credit||'0')}))})
    if(error) throw error
    pendingPostKey.current = null
    setShowEntry(false);setLines(defaults());setMemo('');setReference('')
    await refreshBooks()
    setNotice('Balanced journal posted successfully.')
  })}
  if (!configured) return <main className="setup"><div className="logoMark"><CircleDollarSign size={25}/></div><h1>Ledger North</h1><p>Configure Supabase to start using the application.</p><code>VITE_SUPABASE_URL</code><code>VITE_SUPABASE_ANON_KEY</code><p className="muted">Set environment variables in Vercel and apply the migration in Supabase first. No credentials are committed to the repository.</p></main>
  if (loadingAuth) return <main className="setup"><p>Loading account…</p></main>
  if (!session) return <main className="auth"><section className="auth-panel"><div className="brand"><div className="logoMark"><CircleDollarSign size={24}/></div><span>Ledger North</span></div><span className="eyebrow">CANADA-FIRST ACCOUNTING</span><h1>Clarity for every balance.</h1><p>Modern accounting for Canadian businesses. Your books, securely organized in one place.</p><div className="auth-features"><span><ShieldCheck size={17}/> Tenant-isolated data</span><span><BookOpen size={17}/> Double-entry ledger</span><span><LockKeyhole size={17}/> Controlled financial posting</span></div></section><section className="auth-form"><form onSubmit={login} className="form-card"><h2>Welcome back</h2><p>Sign in to manage your books.</p><label>Email address<input required type="email" autoComplete="email" value={email} onChange={e=>setEmail(e.target.value)} placeholder="you@business.ca"/></label><label>Password<input required type="password" minLength={8} autoComplete="current-password" value={password} onChange={e=>setPassword(e.target.value)} placeholder="Your password"/></label><button disabled={busy} className="primary" type="submit">Sign in</button><button disabled={busy} type="button" className="text-button" onClick={signUp}>Create an account</button>{error&&<p className="error">{error}</p>}{notice&&<p className="notice">{notice}</p>}</form></section></main>
  return <div className="app"><aside className="sidebar"><div className="brand"><div className="logoMark"><CircleDollarSign size={22}/></div><span>Ledger North</span></div><div className="workspace-label">YOUR WORKSPACE</div><div className="org-select"><Building2 size={18}/><select value={orgId} onChange={e=>{setOrgId(e.target.value);setPage('overview')}} aria-label="Select business">{memberships.map(m=>{const o=Array.isArray(m.organizations)?m.organizations[0]:m.organizations;return <option key={m.organization_id} value={m.organization_id}>{o?.name || 'Business'}</option>})}</select><ChevronDown size={14}/></div><div className="nav-heading">WORKSPACE</div><nav>{nav.map(item=><button key={item.id} className={page===item.id?'nav-active':''} onClick={()=>setPage(item.id)}><item.icon size={18}/>{item.label}</button>)}</nav><div className="sidebar-bottom"><div className="sidebar-note"><ShieldCheck size={17}/><div><strong>Accounting foundation</strong><small>Early development preview</small></div></div><button className="signout" onClick={()=>void supabase?.auth.signOut()}><LogOut size={17}/> Sign out</button></div></aside><div className="content"><header className="topbar"><div><span className="topbar-muted">Workspace</span><span className="slash">/</span><strong>{org?.name || 'Get started'}</strong></div><div className="profile-circle">{session.user.email?.charAt(0).toUpperCase() || 'U'}</div></header><main className="main">{inviteFromHash&&<div className="alert notice"><span>You have an organization invitation. The invited email must match your verified sign-in address.</span><button className="primary" disabled={busy} onClick={acceptInvite}>Accept invitation</button></div>}{error&&<div className="alert error">{error}<button onClick={()=>setError('')}>×</button></div>}{notice&&<div className="alert notice">{notice}<button onClick={()=>setNotice('')}>×</button></div>}{!org ? <section className="welcome"><div className="welcome-icon"><Building2 size={28}/></div><h1>Set up your first business</h1><p>Create an organization to initialize its isolated ledger and standard Canadian chart of accounts.</p><form onSubmit={createOrg} className="create-org"><label>Registered business name<input required minLength={2} maxLength={150} value={newName} onChange={e=>setNewName(e.target.value)} placeholder="Example: North Shore Consulting Inc."/></label><button className="primary" disabled={busy}>Create business <Plus size={17}/></button></form></section> : <><div className="heading"><div><span className="eyebrow">{org.name.toUpperCase()} · CAD</span><h1>{page==='overview'?'Overview':page==='accounts'?'Chart of accounts':page==='journals'?'Journal entries':page==='contacts'?'Contacts':page==='sales'?'Sales & invoices':page==='purchases'?'Bills & purchases':page==='reports'?'Financial reports':page==='tax'?'Tax configuration':page==='banking'?'Bank reconciliation':'Business settings'}</h1><p>{page==='overview'?'Your accounting at a glance.':page==='accounts'?'The accounts that organize your general ledger.':page==='journals'?'An auditable record of posted financial events.':page==='contacts'?'Manage customers and vendors.':page==='sales'?'Create and post invoices and credit notes.':page==='purchases'?'Manage vendor bills, credits and payments.':page==='reports'?'Reports from your complete posted ledger.':page==='tax'?'Manage manually verified tax codes and classifications.':page==='banking'?'Import statements and match posted journals.':'Manage your workspace and organization.'}</p></div>{page==='journals'&&<button className="primary" onClick={()=>{pendingPostKey.current=null;setShowEntry(true)}}><Plus size={17}/> New journal entry</button>}</div>{(page==='tax'||page==='banking')&&<TaxBankWorkspace organizationId={orgId} mode={page} notify={(message,isError)=>{if(isError)setError(message);else setNotice(message)}}/>}{(['contacts','sales','purchases','reports'] as Page[]).includes(page)&&<AccountingWorkspace orgId={orgId} tab={page as WorkspaceTab} notify={(message,isError)=>{if(isError)setError(message);else setNotice(message)}}/>}{page==='overview'&&<><div className="metrics"><Metric label="Total assets" value={formatMoney(summaries.assets)} icon={<Wallet size={19}/>} /><Metric label="Total liabilities" value={formatMoney(summaries.liabilities)} icon={<ArrowDownRight size={19}/>} /><Metric label="Revenue" value={formatMoney(summaries.revenue)} icon={<ArrowUpRight size={19}/>} /><Metric label="Expenses" value={formatMoney(summaries.expenses)} icon={<CircleDollarSign size={19}/>} /></div><div className="overview-grid"><div className="card"><div className="card-head"><div><h2>Recent journal entries</h2><p>Latest postings in your ledger</p></div><button className="link-button" onClick={()=>setPage('journals')}>View all →</button></div><JournalTable journals={journals.slice(0,5)}/></div><div className="card quick-actions"><h2>Quick actions</h2><p>Start managing your financial records.</p><button onClick={()=>setShowEntry(true)}><FileText size={18}/> Post a journal entry <Plus size={16}/></button><button onClick={()=>setPage('accounts')}><BookOpen size={18}/> View chart of accounts <ArrowUpRight size={16}/></button><div className="preview-note"><ShieldCheck size={18}/><span>All postings are validated against a balanced double-entry ledger.</span></div></div></div></>}{page==='accounts'&&<div className="card"><div className="card-head"><div><h2>Accounts</h2><p>{accounts.length} accounts in the chart</p></div></div><div className="table-wrap"><table><thead><tr><th>Code</th><th>Account name</th><th>Type</th><th>Normal balance</th></tr></thead><tbody>{accounts.map(a=><tr key={a.id}><td className="mono">{a.code}</td><td className="strong">{a.name}</td><td><span className="type-pill">{a.account_type}</span></td><td className="capitalize">{a.normal_balance}</td></tr>)}</tbody></table></div><form className="account-form" onSubmit={createAccount}><h3>Add an account</h3><input required placeholder="Account code" maxLength={20} value={newAccount.code} onChange={e=>setNewAccount({...newAccount,code:e.target.value})}/><input required placeholder="Account name" maxLength={150} value={newAccount.name} onChange={e=>setNewAccount({...newAccount,name:e.target.value})}/><select value={newAccount.account_type} onChange={e=>setNewAccount({...newAccount,account_type:e.target.value})}>{['asset','liability','equity','revenue','expense'].map(t=><option key={t} value={t}>{t}</option>)}</select><button className="primary" disabled={busy}><Plus size={16}/> Add</button></form></div>}{page==='journals'&&<div className="card"><div className="card-head"><div><h2>Posted journals</h2><p>Recent entries, newest first</p></div><span className="status"><CheckCircle2 size={15}/> Immutable postings</span></div><JournalTable journals={journals} onReverse={id=>{setReverseId(id);setReverseReason('')}}/></div>}{page==='settings'&&<div className="card settings-card"><h2>Organization details</h2><div><span>Business name</span><strong>{org.name}</strong></div><div><span>Base currency</span><strong>{org.base_currency}</strong></div><div><span>Your role</span><strong className="capitalize">{selected?.role}</strong></div><div><span>Organization identifier</span><code>{org.id}</code></div><FiscalPeriods organizationId={orgId} role={selected?.role || 'viewer'} notify={(message,isError)=>{if(isError)setError(message);else setNotice(message)}}/><BusinessAdministration organizationId={orgId} role={selected?.role||'viewer'} notify={(message,isError)=>{if(isError)setError(message);else setNotice(message)}}/><p className="muted">Subscription management will be added in future phases.</p><form onSubmit={createOrg} className="new-business"><h3>Add another business</h3><input required minLength={2} maxLength={150} value={newName} onChange={e=>setNewName(e.target.value)} placeholder="Business name"/><button disabled={busy} className="primary">Create organization</button></form></div>}</> }</main></div>{showEntry&&<div className="modal-backdrop" role="presentation" onMouseDown={e=>{if(e.target===e.currentTarget)setShowEntry(false)}}><div className="modal" role="dialog" aria-modal="true" aria-label="New journal entry"><div className="modal-header"><div><span className="eyebrow">GENERAL LEDGER</span><h2>New journal entry</h2></div><button className="close" aria-label="Close" onClick={()=>setShowEntry(false)}>×</button></div><form onSubmit={postJournal}><div className="form-grid"><label>Date<input type="date" required value={date} onChange={e=>setDate(e.target.value)}/></label><label>Reference<input value={reference} maxLength={80} onChange={e=>setReference(e.target.value)} placeholder="Optional"/></label></div><label>Memo<input required minLength={3} maxLength={500} value={memo} onChange={e=>setMemo(e.target.value)} placeholder="Describe this financial transaction"/></label><div className="line-heading"><h3>Journal lines</h3><button type="button" className="link-button" onClick={()=>setLines([...lines,{account_id:'',debit:'0',credit:'0'}])}>+ Add line</button></div><div className="journal-inputs"><span>Account</span><span>Debit (CAD)</span><span>Credit (CAD)</span></div>{lines.map((l,i)=><div className="journal-inputs" key={i}><select required value={l.account_id} onChange={e=>setLines(lines.map((x,n)=>n===i?{...x,account_id:e.target.value}:x))}><option value="">Select account</option>{accounts.map(a=><option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}</select><input inputMode="decimal" value={l.debit} onChange={e=>setLines(lines.map((x,n)=>n===i?{...x,debit:e.target.value}:x))}/><input inputMode="decimal" value={l.credit} onChange={e=>setLines(lines.map((x,n)=>n===i?{...x,credit:e.target.value}:x))}/></div>)}<div className="journal-total"><span>Debits: {formatMoney(lines.reduce((s,l)=>{try{return s+parseMoney(l.debit||'0')}catch{return s}},0))}</span><span>Credits: {formatMoney(lines.reduce((s,l)=>{try{return s+parseMoney(l.credit||'0')}catch{return s}},0))}</span></div><div className="modal-actions"><button type="button" onClick={()=>setShowEntry(false)}>Cancel</button><button disabled={busy} className="primary"><CheckCircle2 size={17}/> Post journal</button></div></form></div></div>}{reverseId&&<div className="modal-backdrop" onMouseDown={e=>{if(e.target===e.currentTarget)setReverseId(null)}}><div className="modal payment-modal" role="dialog" aria-modal="true" aria-label="Reverse manual journal"><div className="modal-header"><h2>Reverse manual journal</h2><button className="close" onClick={()=>setReverseId(null)} aria-label="Close">×</button></div><form onSubmit={reverseJournal}><p>Only standalone manual journals can be reversed here. Posted invoices, bills, payments and credit documents cannot be reversed through this workflow.</p><label>Reversal date<input required type="date" value={date} onChange={e=>setDate(e.target.value)}/></label><label>Reason<input required minLength={3} maxLength={500} value={reverseReason} onChange={e=>setReverseReason(e.target.value)}/></label><div className="modal-actions"><button type="button" onClick={()=>setReverseId(null)}>Cancel</button><button disabled={busy} className="primary">Reverse journal</button></div></form></div></div>}</div>
}
function Metric({label,value,icon}:{label:string;value:string;icon:React.ReactNode}){return <div className="metric"><div className="metric-top"><span>{label}</span><span className="metric-icon">{icon}</span></div><strong>{value}</strong><small>From recent loaded ledger entries</small></div>}
function JournalTable({journals,onReverse}:{journals:Journal[];onReverse?:(id:string)=>void}){return <div className="table-wrap"><table><thead><tr><th>Date</th><th>Reference</th><th>Description</th><th>Amount</th><th>Status</th>{onReverse&&<th>Actions</th>}</tr></thead><tbody>{journals.length?journals.map(j=><tr key={j.id}><td className="mono">{j.entry_date}</td><td className="mono">{j.reference||'—'}</td><td className="strong">{j.memo}</td><td className="mono">{formatMoney(j.journal_lines.reduce((s,l)=>s+Math.round(Number(l.debit)*100),0))}</td><td><span className="status"><CheckCircle2 size={14}/> Posted</span></td>{onReverse&&<td><button type="button" className="link-button" onClick={()=>onReverse(j.id)}>Reverse</button></td>}</tr>):<tr><td colSpan={onReverse?6:5}><div className="empty">No journal entries yet. Create your first balanced entry to begin.</div></td></tr>}</tbody></table></div>}
export default App
