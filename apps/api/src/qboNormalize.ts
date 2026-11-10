/** QBO read-only export normalization. Source records are always retained
 * verbatim in migration staging. Missing tax or account mappings remain review exceptions. */
export const QBO_TYPES=[
 'Account','Customer','Vendor','TaxCode','Invoice','Bill','CreditMemo','VendorCredit',
 'Payment','BillPayment','JournalEntry','Attachable','Purchase','Deposit',
 'SalesReceipt','RefundReceipt','Transfer','Estimate','PurchaseOrder','Item'] as const
export type QboType=typeof QBO_TYPES[number]
export type MigrationKind='account'|'customer'|'vendor'|'tax_code'|'invoice'|'bill'|
 'credit_note'|'vendor_credit'|'payment'|'bill_payment'|'journal'|'opening_balance'|
 'attachment'|'bank_transaction'|'inventory_item'|'purchase'|'deposit'|'sales_receipt'|
 'refund_receipt'|'transfer'|'estimate'|'purchase_order'
export type SourceRecord={source_id:string;[key:string]:unknown}
const id=(v:unknown):string=>String(v??'').trim()
const val=(v:unknown):string=>typeof v==='string'?v:String(v??'')
const classifyAccount=(raw:Record<string,unknown>):string=>{
 const type=val(raw.AccountType)
 if(['Bank','Accounts Receivable','Other Current Asset','Fixed Asset','Other Asset',
  'Other Current Assets'].includes(type))return 'asset'
 if(['Accounts Payable','Credit Card','Other Current Liability','Long Term Liability',
  'Other Liability'].includes(type))return 'liability'
 if(type==='Equity')return 'equity'
 if(['Income','Other Income'].includes(type))return 'revenue'
 return 'expense'
}
function lines(raw:Record<string,unknown>):Record<string,unknown>[]{
 const entries=Array.isArray(raw.Line)?raw.Line:[]
 return entries.filter((x):x is Record<string,unknown>=>!!x&&typeof x==='object').map(line=>{
  const detail=((line.SalesItemLineDetail||line.ItemBasedExpenseLineDetail||
   line.AccountBasedExpenseLineDetail)||{}) as Record<string,unknown>
  const account=(detail.AccountRef||{}) as Record<string,unknown>
  const price=Number(detail.UnitPrice??line.Amount??0)
  const quantity=Number(detail.Qty??1)
  return {description:val(line.Description||'Imported line'),
   quantity:Number.isFinite(quantity)&&quantity>0?quantity:1,
   unit_price:Number.isFinite(price)&&price>=0?price:0,
   account_source_id:id(account.value)||undefined,
   tax_rate_bps:0,
   raw:line}
 })
}
export function normalizeQbo(type:QboType,source:Record<string,unknown>):{
 kind:MigrationKind;record:SourceRecord
}|null{
 const sid=id(source.Id)
 if(!sid)throw new Error('QBO record has no source ID: '+type)
 const base:SourceRecord={source_id:sid,raw:source}
 if(type==='Account'){
  // Source numeric IDs are not target account codes. Use account number if valid,
  // otherwise a deterministic, unique QBO prefix.
  const number=val(source.AcctNum).trim()
  const code=/^[A-Za-z0-9._-]{1,20}$/.test(number)?number:
   ('QBO'+sid.replace(/[^a-zA-Z0-9]/g,'').slice(0,16))
  return {kind:'account',record:{...base,code,name:val(source.Name).slice(0,150),
   type:classifyAccount(source),fully_qualified_name:source.FullyQualifiedName}}
 }
 if(type==='Customer'||type==='Vendor')
  return {kind:type==='Customer'?'customer':'vendor',
   record:{...base,name:val(source.DisplayName||source.FullyQualifiedName).slice(0,180),
    email:val((source.PrimaryEmailAddr as Record<string,unknown>|undefined)?.Address)||null}}
 if(type==='TaxCode')return {kind:'tax_code',record:base}
 if(['Invoice','Bill','CreditMemo','VendorCredit'].includes(type)){
  const contactRef=(type==='Invoice'||type==='CreditMemo'?source.CustomerRef:source.VendorRef) as Record<string,unknown>|undefined
  const kind=({Invoice:'invoice',Bill:'bill',CreditMemo:'credit_note',VendorCredit:'vendor_credit'} as Record<string,MigrationKind>)[type]
  return {kind,record:{...base,contact_source_id:id(contactRef?.value),
   issue_date:val(source.TxnDate),due_date:val(source.DueDate||source.TxnDate),
   memo:val((source.CustomerMemo as Record<string,unknown>|undefined)?.value||source.PrivateNote).slice(0,500),
   original_number:source.DocNumber,
   total:source.TotalAmt,lines:lines(source)}}
 }
 if(type==='Payment'||type==='BillPayment'){
  const allocations=(Array.isArray(source.Line)?source.Line:[]).flatMap(rawLine=>{
   const row=rawLine as Record<string,unknown>,linked=Array.isArray(row.LinkedTxn)?row.LinkedTxn:[]
   return linked.map(link=>({source_document_id:id((link as Record<string,unknown>).TxnId),
     amount:Number(row.Amount||0)}))
  })
  return {kind:type==='Payment'?'payment':'bill_payment',record:{...base,
   payment_date:val(source.TxnDate),total:source.TotalAmt,allocations}}
 }
 if(type==='JournalEntry')return {kind:'journal',record:{...base,
  date:val(source.TxnDate),
  lines:(Array.isArray(source.Line)?source.Line:[]).map(item=>{
   const line=item as Record<string,unknown>
   const detail=(line.JournalEntryLineDetail||{}) as Record<string,unknown>
   const account=(detail.AccountRef||{}) as Record<string,unknown>
   const amount=Number(line.Amount||0)
   return {account_source_id:id(account.value),
    debit:detail.PostingType==='Debit'?amount:0,
    credit:detail.PostingType==='Credit'?amount:0}
  }),post_as_standalone:false,qbo_raw_journal:true}}
 if(type==='Attachable')return {kind:'attachment',record:base}
 if(type==='Item'){
  const itemType=val(source.Type)
  return {kind:'inventory_item',record:{...base,
   sku:val(source.Sku||source.Name).slice(0,80),
   name:val(source.Name).slice(0,180),
   item_type:itemType,
   quantity_on_hand:Number(source.QtyOnHand??0),
   unit_cost:Number(source.PurchaseCost??0),
   inventory_asset_source_id:id((source.AssetAccountRef as Record<string,unknown>|undefined)?.value)||null
  }}
 }
 if(['Purchase','Deposit','SalesReceipt','RefundReceipt','Transfer','Estimate','PurchaseOrder'].includes(type)){
  const kinds:Record<string,MigrationKind>={Purchase:'purchase',Deposit:'deposit',SalesReceipt:'sales_receipt',
   RefundReceipt:'refund_receipt',Transfer:'transfer',Estimate:'estimate',PurchaseOrder:'purchase_order',
   Item:'inventory_item'}
  return {kind:kinds[type],record:base}
 }
 return null
}
export function normalizeQboPage(type:QboType,items:Record<string,unknown>[]){
 return items.map(row=>normalizeQbo(type,row)).filter((row):row is NonNullable<typeof row>=>row!==null)
}
export function qboQuery(type:QboType,start:number,limit=500):string{
 if(!QBO_TYPES.includes(type)||!Number.isInteger(start)||start<1||limit<1||limit>1000)
  throw new Error('Invalid QuickBooks pagination')
 return 'SELECT * FROM '+type+' STARTPOSITION '+start+' MAXRESULTS '+limit
}
