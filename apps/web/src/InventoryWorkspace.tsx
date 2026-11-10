import {useCallback,useEffect,useState,type FormEvent} from 'react'
import {supabase} from './lib/supabase'
import {formatMoney,parseMoney} from './lib/accounting'

type Props={organizationId:string;role:string;notify:(message:string,isError?:boolean)=>void}
type Product={id:string;sku:string;name:string;active:boolean}
type Stock={product_id:string;sku:string;name:string;quantity:number;cost:number}
type Document={id:string;document_number:string;document_type:string;issue_date:string;status:string}
type Line={id:string;document_id:string;description:string;quantity:number;amount:number}
type Movement={id:string;product_id:string;quantity:number;total_cost?:number;initial_cost?:number;issued_on?:string;received_on?:string}
type Opening={organization_id:string;opening_date:string;journal_entry_id:string}
type Batch={id:string;source_system:string;state:string;created_at:string}
type OpeningLot={product_id:string;quantity:string;total_cost:string}
const today=()=>new Date().toLocaleDateString('sv-SE',{timeZone:'America/Toronto'})
const money=(v:number)=>formatMoney(Math.round(Number(v)*100))
export default function InventoryWorkspace({organizationId,role,notify}:Props){
 const [products,setProducts]=useState<Product[]>([])
 const [stock,setStock]=useState<Stock[]>([])
 const [documents,setDocuments]=useState<Document[]>([])
 const [lines,setLines]=useState<Line[]>([])
 const [receipts,setReceipts]=useState<Movement[]>([])
 const [issues,setIssues]=useState<Movement[]>([])
 const [busy,setBusy]=useState(false)
 const [opening,setOpening]=useState<Opening|null>(null)
 const [openingRegistered,setOpeningRegistered]=useState(false)
 const [openingLots,setOpeningLots]=useState<OpeningLot[]>([{product_id:'',quantity:'',total_cost:''}])
 const [batches,setBatches]=useState<Batch[]>([])
 const [selectedBatch,setSelectedBatch]=useState('')
 const [sku,setSku]=useState('')
 const [productName,setProductName]=useState('')
 const [receiptProduct,setReceiptProduct]=useState('')
 const [billLine,setBillLine]=useState('')
 const [issueProduct,setIssueProduct]=useState('')
 const [invoiceLine,setInvoiceLine]=useState('')
 const [date,setDate]=useState(today())
 const [keys,setKeys]=useState<Record<string,string>>({})
 const canManage=['owner','administrator','accountant','bookkeeper'].includes(role)
 const getKey=(name:string)=>keys[name]||crypto.randomUUID()
 const load=useCallback(async()=>{
  if(!supabase||!organizationId)return
  const [p,d,l,rc,iss,st,o,registered,b]=await Promise.all([
   supabase.from('inventory_products').select('id,sku,name,active').eq('organization_id',organizationId).order('sku'),
   supabase.from('financial_documents').select('id,document_number,document_type,issue_date,status')
    .eq('organization_id',organizationId).eq('status','posted').order('issue_date',{ascending:false}).limit(500),
   supabase.from('financial_document_lines').select('id,document_id,description,quantity,amount')
    .eq('organization_id',organizationId).limit(2000),
   supabase.from('inventory_receipts').select('id,product_id,quantity,initial_cost,received_on')
    .eq('organization_id',organizationId).order('received_on',{ascending:false}).limit(200),
   supabase.from('inventory_issues').select('id,product_id,quantity,total_cost,issued_on')
    .eq('organization_id',organizationId).order('issued_on',{ascending:false}).limit(200),
   supabase.rpc('inventory_stock_summary',{p_org:organizationId}),
   supabase.from('opening_balance_imports').select('organization_id,opening_date,journal_entry_id')
    .eq('organization_id',organizationId).maybeSingle(),
   supabase.from('inventory_opening_batches').select('id').eq('organization_id',organizationId).maybeSingle(),
   supabase.from('migration_batches').select('id,source_system,state,created_at').eq('organization_id',organizationId)
    .order('created_at',{ascending:false}).limit(60)
  ])
  for(const item of [p,d,l,rc,iss,st,o,registered,b])if(item.error)throw item.error
  setProducts((p.data||[]) as Product[]);setDocuments((d.data||[]) as Document[])
  setLines((l.data||[]) as Line[]);setReceipts((rc.data||[]) as Movement[])
  setIssues((iss.data||[]) as Movement[]);setStock((st.data||[]) as Stock[])
  setOpening((o.data||null) as Opening|null)
  setOpeningRegistered(Boolean(registered.data))
  setBatches((b.data||[]) as Batch[])
 },[organizationId])
 useEffect(()=>{void load().catch(e=>notify(e.message,true))},[load])
 const run=(keyName:string,operation:(key:string)=>Promise<void>)=>{
  const key=getKey(keyName);setKeys(v=>({...v,[keyName]:key}));setBusy(true)
  void operation(key).then(async()=>{setKeys(v=>({...v,[keyName]:''}));await load()})
   .catch(e=>notify(e instanceof Error?e.message:String(e),true)).finally(()=>setBusy(false))
 }
 const create=(e:FormEvent)=>{e.preventDefault();run('product',async()=>{
  if(!supabase)throw new Error('Authentication unavailable')
  const {error}=await supabase.rpc('create_inventory_product',{
   p_org:organizationId,p_sku:sku,p_name:productName})
  if(error)throw error
  setSku('');setProductName('');notify('Inventory SKU created.')
 })}
 const receive=(e:FormEvent)=>{e.preventDefault();run('receipt',async(key)=>{
  if(!supabase||!receiptProduct||!billLine)throw new Error('Select a product and posted supplier bill line')
  const {error}=await supabase.rpc('receive_inventory_bill_line',{
   p_org:organizationId,p_product:receiptProduct,p_line:billLine,
   p_date:date,p_key:key})
  if(error)throw error
  setBillLine('');notify('Bill line reclassified to inventory asset at actual cost.')
 })}
 const issue=(e:FormEvent)=>{e.preventDefault();run('issue',async(key)=>{
  if(!supabase||!issueProduct||!invoiceLine)throw new Error('Select a product and posted customer invoice line')
  const {error}=await supabase.rpc('issue_inventory_invoice_line',{
   p_org:organizationId,p_product:issueProduct,p_line:invoiceLine,
   p_date:date,p_key:key})
  if(error)throw error
  setInvoiceLine('');notify('FIFO stock issued, inventory credited and COGS posted.')
 })}
 const registerOpening=(e:FormEvent)=>{e.preventDefault();run('stock-opening',async(key)=>{
  if(!supabase||!opening)throw new Error('Import the opening balance sheet, including account 1400, first')
  const lots=openingLots.map(l=>({product_id:l.product_id,quantity:l.quantity,
   total_cost:(parseMoney(l.total_cost)/100).toFixed(2)}))
  const {error}=await supabase.rpc('register_inventory_opening_lots',{
   p_org:organizationId,p_date:opening.opening_date,p_lots:lots,p_key:key})
  if(error)throw error
  notify('FIFO opening lots linked to the existing opening inventory asset journal.')
 })}
 const importProducts=(e:FormEvent)=>{e.preventDefault();run('qbo-products',async()=>{
  if(!supabase||!selectedBatch)throw new Error('Choose an accountant-approved QuickBooks migration batch')
  const {data,error}=await supabase.rpc('import_qbo_inventory_products',{
   p_org:organizationId,p_batch:selectedBatch,p_limit:100})
  if(error)throw error
  notify(String(data?.mapped_products||0)+' source inventory SKUs mapped. Opening quantities still require valuation review.')
 })}
 const billIds=new Set(documents.filter(d=>d.document_type==='bill').map(d=>d.id))
 const invoiceIds=new Set(documents.filter(d=>d.document_type==='invoice').map(d=>d.id))
 const label=(line:Line)=>{const d=documents.find(x=>x.id===line.document_id)
  return (d?.document_number||'Document')+' · '+line.description+' · '+line.quantity+' units'}
 const historical=[...receipts.map(r=>({...r,kind:'Received',when:r.received_on||'',cost:r.initial_cost||0})),
  ...issues.map(r=>({...r,kind:'COGS issued',when:r.issued_on||'',cost:r.total_cost||0}))]
  .sort((a,b)=>b.when.localeCompare(a.when)).slice(0,80)
 return <section className="advanced-extras">
  <div className="card workspace-form"><h2>FIFO inventory valuation</h2>
   <p>Perpetual FIFO stock records are linked to posted purchasing and sales documents. Sales and purchases must be entered as normal invoices or bills first. Only CAD valuations are supported.</p>
   <div className="table-wrap"><table><thead><tr><th>SKU</th><th>Product</th><th>On hand</th><th>Book value (CAD)</th></tr></thead>
   <tbody>{stock.map(p=><tr key={p.product_id}><td>{p.sku}</td><td>{p.name}</td><td>{Number(p.quantity).toFixed(3)}</td><td>{money(p.cost)}</td></tr>)}
   {stock.length===0&&<tr><td colSpan={4}>No tracked inventory products.</td></tr>}</tbody></table></div>
  </div>
  <div className="card workspace-form"><h2>QuickBooks inventory SKU migration</h2>
   <p>Map reviewed QuickBooks Inventory Items to tenant inventory SKUs. Original source IDs remain linked in the migration archive. This does not create opening balances or recognize COGS.</p>
   <form onSubmit={importProducts} className="workspace-fields">
    <label>Reviewed migration batch<select required value={selectedBatch} onChange={e=>setSelectedBatch(e.target.value)}>
     <option value="">Choose QBO batch</option>{batches.filter(b=>b.source_system==='quickbooks_online'&&['in_progress','completed'].includes(b.state)).map(b=><option key={b.id} value={b.id}>{b.created_at.slice(0,10)} · {b.state}</option>)}
    </select></label>
    <button className="primary" disabled={busy||!canManage}>Map up to 100 source SKUs</button>
   </form>
  </div>
  {opening&&!openingRegistered&&receipts.length===0&&issues.length===0&&<form className="card workspace-form" onSubmit={registerOpening}>
   <h2>Register FIFO opening inventory lots</h2>
   <p>Effective date: {opening.opening_date}. Register every opening lot with quantity and total CAD book value. The combined value must match the inventory asset account in your existing opening-balance journal exactly.</p>
   {openingLots.map((l,i)=><div className="advanced-journal-row" key={i}>
    <label>SKU<select required value={l.product_id} onChange={e=>setOpeningLots(old=>old.map((x,j)=>j===i?{...x,product_id:e.target.value}:x))}>
     <option value="">Choose product</option>{products.filter(p=>p.active).map(p=><option key={p.id} value={p.id}>{p.sku}</option>)}
    </select></label>
    <label>Quantity<input required inputMode="decimal" value={l.quantity} onChange={e=>setOpeningLots(old=>old.map((x,j)=>j===i?{...x,quantity:e.target.value}:x))}/></label>
    <label>Total CAD cost<input required inputMode="decimal" value={l.total_cost} onChange={e=>setOpeningLots(old=>old.map((x,j)=>j===i?{...x,total_cost:e.target.value}:x))}/></label>
   </div>)}
   <div className="workspace-toolbar">
    <button type="button" onClick={()=>setOpeningLots(old=>[...old,{product_id:'',quantity:'',total_cost:''}])}>Add opening lot</button>
    <button className="primary" disabled={busy||!canManage}>Register valued opening stock</button>
   </div>
  </form>}
  <form className="card workspace-form" onSubmit={create}><h2>Create an inventory product</h2>
   <div className="workspace-fields"><label>SKU<input required maxLength={80} value={sku} onChange={e=>setSku(e.target.value)} placeholder="PRODUCT-001"/></label>
    <label>Product name<input required maxLength={180} value={productName} onChange={e=>setProductName(e.target.value)}/></label></div>
   <button className="primary" disabled={busy||!canManage}>Create SKU</button>
  </form>
  <form className="card workspace-form" onSubmit={receive}><h2>Receive a posted supplier bill line</h2>
   <p>Reclassifies the billed amount plus nonrecoverable tax from expense into Inventory Asset. Each bill line can be received only once, with its exact billed quantity.</p>
   <div className="workspace-fields"><label>SKU<select required value={receiptProduct} onChange={e=>setReceiptProduct(e.target.value)}><option value="">Choose SKU</option>{products.filter(p=>p.active).map(p=><option key={p.id} value={p.id}>{p.sku} · {p.name}</option>)}</select></label>
    <label>Supplier bill line<select required value={billLine} onChange={e=>setBillLine(e.target.value)}><option value="">Choose posted bill line</option>{lines.filter(l=>billIds.has(l.document_id)).map(l=><option key={l.id} value={l.id}>{label(l)}</option>)}</select></label>
    <label>Receipt date<input required type="date" value={date} onChange={e=>setDate(e.target.value)}/></label></div>
   <button className="primary" disabled={busy||!canManage}>Receive into FIFO stock</button>
  </form>
  <form className="card workspace-form" onSubmit={issue}><h2>Issue stock for a posted customer invoice</h2>
   <p>Consumes oldest remaining inventory lots and posts Inventory Asset credit against Cost of Goods Sold debit. A line cannot be issued twice or when available stock is insufficient.</p>
   <div className="workspace-fields"><label>SKU<select required value={issueProduct} onChange={e=>setIssueProduct(e.target.value)}><option value="">Choose SKU</option>{products.filter(p=>p.active).map(p=><option key={p.id} value={p.id}>{p.sku} · {p.name}</option>)}</select></label>
    <label>Invoice line<select required value={invoiceLine} onChange={e=>setInvoiceLine(e.target.value)}><option value="">Choose posted invoice line</option>{lines.filter(l=>invoiceIds.has(l.document_id)).map(l=><option key={l.id} value={l.id}>{label(l)}</option>)}</select></label>
    <label>Issue date<input required type="date" value={date} onChange={e=>setDate(e.target.value)}/></label></div>
   <button className="primary" disabled={busy||!canManage}>Issue inventory and post COGS</button>
  </form>
  <div className="card"><div className="card-head"><h2>Recent inventory journal movements</h2></div>
   <div className="table-wrap"><table><thead><tr><th>Date</th><th>Product</th><th>Movement</th><th>Quantity</th><th>Book cost</th></tr></thead>
   <tbody>{historical.map(h=><tr key={h.id}><td>{h.when}</td><td>{products.find(p=>p.id===h.product_id)?.sku||'SKU'}</td><td>{h.kind}</td><td>{Number(h.quantity).toFixed(3)}</td><td>{money(h.cost)}</td></tr>)}</tbody></table></div>
  </div>
  <p className="advanced-note">Initial implementation excludes returns, landed cost allocation, physical counts, shrinkage, manufacturing, negative inventory and sales tax advice. These require reviewed journal workflows. Inventory movement dates must be chronologically validated.</p>
 </section>
}
