import {useCallback,useEffect,useState,type FormEvent} from 'react'
import {supabase} from './lib/supabase'
type FiscalPeriod={id:string;start_date:string;end_date:string;is_locked:boolean}
type Props={organizationId:string;role:string;notify:(message:string,isError?:boolean)=>void}
export default function FiscalPeriods({organizationId,role,notify}:Props){
  const [periods,setPeriods]=useState<FiscalPeriod[]>([])
  const [start,setStart]=useState(()=>new Date().getFullYear()+1+'-01-01')
  const [end,setEnd]=useState(()=>new Date().getFullYear()+1+'-12-31')
  const [busy,setBusy]=useState(false)
  const canManage=['owner','administrator','accountant'].includes(role)
  const refresh=useCallback(async()=>{
    if(!supabase||!organizationId)return
    const {data,error}=await supabase.from('fiscal_periods').select('id,start_date,end_date,is_locked')
      .eq('organization_id',organizationId).order('start_date',{ascending:false})
    if(error)throw error
    setPeriods((data||[]) as FiscalPeriod[])
  },[organizationId])
  useEffect(()=>{void refresh().catch(e=>notify(e.message,true))},[refresh])
  const create=(e:FormEvent)=>{e.preventDefault();setBusy(true);void (async()=>{
    try{
      if(!supabase)return
      const {error}=await supabase.rpc('create_fiscal_period',{p_organization_id:organizationId,p_start:start,p_end:end})
      if(error)throw error
      await refresh();notify('Fiscal period created.')
    }catch(e){notify(e instanceof Error?e.message:String(e),true)}finally{setBusy(false)}
  })()}
  const toggle=(period:FiscalPeriod)=>{setBusy(true);void (async()=>{
    try{
      if(!supabase)return
      const {error}=await supabase.rpc('set_fiscal_period_lock',{p_organization_id:organizationId,p_period_id:period.id,p_locked:!period.is_locked})
      if(error)throw error
      await refresh();notify(period.is_locked?'Fiscal period reopened.':'Fiscal period locked.')
    }catch(e){notify(e instanceof Error?e.message:String(e),true)}finally{setBusy(false)}
  })()}
  return <section className="period-admin"><h2>Fiscal periods</h2><p className="muted">Journal posting is prohibited in locked or undefined periods. Changes to period locks are serialized against posting.</p>
    <div className="table-wrap"><table><thead><tr><th>Start</th><th>End</th><th>State</th><th>Action</th></tr></thead><tbody>{periods.map(p=><tr key={p.id}><td>{p.start_date}</td><td>{p.end_date}</td><td>{p.is_locked?'Locked':'Open'}</td><td>{canManage&&<button className="link-button" disabled={busy} onClick={()=>toggle(p)}>{p.is_locked?'Reopen':'Lock period'}</button>}</td></tr>)}</tbody></table></div>
    {canManage&&<form onSubmit={create} className="period-form"><h3>Add fiscal period</h3><label>Start<input type="date" required value={start} onChange={e=>setStart(e.target.value)}/></label><label>End<input type="date" required value={end} onChange={e=>setEnd(e.target.value)} min={start}/></label><button className="primary" disabled={busy}>Create period</button></form>}
  </section>
}
