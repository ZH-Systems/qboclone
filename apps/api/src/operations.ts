import type {SupabaseClient} from '@supabase/supabase-js'
import {createClient} from '@supabase/supabase-js'

export type ExportTable = { name:string; columns:string; data: Record<string,unknown>[] }
export const EXPORT_TABLES:ReadonlyArray<{name:string;columns:string}>=[
 {name:'organizations',columns:'id,name,base_currency,created_at'},
 {name:'organization_members',columns:'organization_id,user_id,role,created_at'},
 {name:'organization_invitations',columns:'id,organization_id,invited_email,role,created_at,expires_at,accepted_at,revoked_at'},
 {name:'organization_subscriptions',columns:'organization_id,plan_code,status,current_period_end,cancel_at_period_end,updated_at'},
 {name:'accounts',columns:'id,organization_id,code,name,account_type,normal_balance,is_active,created_at'},
 {name:'fiscal_periods',columns:'id,organization_id,start_date,end_date,is_locked'},
 {name:'contacts',columns:'id,organization_id,contact_kind,display_name,email,created_at'},
 {name:'financial_documents',columns:'id,organization_id,contact_id,document_type,document_number,issue_date,due_date,memo,status,source_document_id,subtotal,tax_total,total,journal_entry_id,posted_at,created_at'},
 {name:'financial_document_lines',columns:'id,organization_id,document_id,position,description,quantity,unit_price,tax_rate_bps,amount,tax_amount,account_id,tax_code_id,tax_classification,recoverable_tax'},
 {name:'document_payments',columns:'id,organization_id,document_id,amount,payment_date,reference,journal_entry_id,created_at'},
 {name:'payment_refunds',columns:'id,organization_id,original_payment_id,refund_date,amount,reason,journal_entry_id,created_at'},
 {name:'document_writeoffs',columns:'id,organization_id,document_id,entry_date,amount,reason,journal_entry_id,created_at'},
 {name:'customer_deposits',columns:'id,organization_id,customer_id,received_on,amount,reference,journal_entry_id,created_at'},
 {name:'deposit_applications',columns:'id,organization_id,deposit_id,invoice_id,applied_on,amount,journal_entry_id,created_at'},
 {name:'deposit_refunds',columns:'id,organization_id,deposit_id,refunded_on,amount,reason,journal_entry_id,created_at'},
 {name:'year_end_closures',columns:'id,organization_id,fiscal_period_id,closing_journal_id,retained_earnings_account_id,closed_at,closed_by'},
 {name:'opening_balance_imports',columns:'organization_id,journal_entry_id,opening_date,created_by,created_at'},
 {name:'accounting_adjustments',columns:'organization_id,journal_entry_id,category,explanation,created_at,created_by'},
 {name:'journal_entries',columns:'id,organization_id,entry_date,memo,reference,source_kind,created_at,created_by'},
 {name:'journal_lines',columns:'id,organization_id,journal_entry_id,account_id,debit,credit'},
 {name:'journal_reversals',columns:'organization_id,original_journal_id,reversing_journal_id,reason,reversed_at,reversed_by'},
 {name:'tax_codes',columns:'id,organization_id,code,label,transaction_kind,classification,rate_bps,recoverable_bps,active,effective_from,effective_until'},
 {name:'bank_statements',columns:'id,organization_id,bank_account_id,start_date,end_date,opening_balance,closing_balance,status,reconciled_at'},
 {name:'bank_transactions',columns:'id,organization_id,statement_id,line_number,transaction_date,description,reference,signed_amount,matched_journal_entry_id'},
 {name:'recurring_document_rules',columns:'id,organization_id,source_document_id,cadence,next_run_date,due_offset_days,active,created_at'},
 {name:'recurring_document_runs',columns:'id,organization_id,rule_id,occurrence_date,document_id,processed_at'},
 {name:'receipt_documents',columns:'id,organization_id,original_filename,mime_type,content_sha256,content_size,extraction_status,extraction_data,created_at'},
 {name:'receipt_document_links',columns:'organization_id,receipt_id,financial_document_id,linked_at'},
 {name:'document_deliveries',columns:'id,organization_id,document_id,recipient_email,delivery_kind,message_id,status,sent_at'},
 {name:'import_review_batches',columns:'id,organization_id,source_system,entity_kind,source_filename,rows_previewed,rows_imported,created_at'},
 {name:'organization_usage_monthly',columns:'organization_id,month_start,metric,units'},
 {name:'audit_events',columns:'id,organization_id,actor_user_id,action,entity_type,entity_id,details,occurred_at'}
]
const ORDER_COLUMNS:Record<string,string>={organization_members:'user_id',journal_reversals:'original_journal_id',organization_usage_monthly:'month_start',opening_balance_imports:'organization_id',accounting_adjustments:'journal_entry_id',receipt_document_links:'receipt_id'}
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
export function requireOrganizationId(value:unknown):string{
 if(typeof value!=='string'||!uuid.test(value))throw new Error('Invalid organization identifier')
 return value
}
export function bearerToken(value:string|undefined):string{
 const match=/^Bearer ([^\s]+)$/.exec(value||'')
 if(!match)throw new Error('Bearer token required')
 return match[1]
}
export async function requireOrganizationRole(
 db:SupabaseClient,userId:string,orgId:string,roles:ReadonlyArray<string>):Promise<void>{
 const {data,error}=await db.from('organization_members').select('role')
  .eq('organization_id',orgId).eq('user_id',userId).maybeSingle()
 if(error)throw new Error('Permission lookup failed')
 if(!data||!roles.includes(data.role))throw new Error('Not authorized for this organization')
}
export function scopedSupabase(url:string,serviceKey:string,jwt:string):SupabaseClient{
 // Authenticated JWT must override the service credential's Authorization header.
 // This ensures RPCs authenticate via auth.uid() rather than elevated service_role.
 return createClient(url,serviceKey,{
  global:{headers:{Authorization:'Bearer '+jwt}},
  auth:{persistSession:false,autoRefreshToken:false}
 })
}
export function csvEscape(value:unknown):string{
 const raw=value===null||value===undefined?'':typeof value==='string'?value:JSON.stringify(value)
 const normalized=/^[=+@\-\t\r]/.test(raw)?"'"+raw:raw
 return /[",\r\n]/.test(normalized)?'"'+normalized.replace(/"/g,'""')+'"':normalized
}
/** Retrieves whitelisted data, never silently truncates accounting exports.
 * Export limits are operational safety caps, not a substitute for streaming at scale.
 */
export async function buildOrganizationExport(db:SupabaseClient,orgId:string,limitPerTable=10000){
 if(limitPerTable<1||limitPerTable>100000)throw new Error('Invalid export row limit')
 const result:ExportTable[]=[]
 for(const definition of EXPORT_TABLES){
  const rows:Record<string,unknown>[]=[]
  for(let offset=0;offset<=limitPerTable;offset+=500){
   const query=db.from(definition.name).select(definition.columns)
     .eq(definition.name==='organizations'?'id':'organization_id',orgId)
     .order(ORDER_COLUMNS[definition.name]||'id',{ascending:true})
     .range(offset,Math.min(offset+499,limitPerTable))
   const {data,error}=await query
   if(error)throw new Error('Export failed for '+definition.name)
   const batch=(data||[]) as unknown as Record<string,unknown>[]
   rows.push(...batch)
   if(batch.length<500)break
  }
  if(rows.length>limitPerTable)throw new Error(
   'Export row limit exceeded for '+definition.name+'; request a server-side archival export')
  result.push({...definition,data:rows})
 }
 return {version:1,organization_id:orgId,generated_at:new Date().toISOString(),tables:result}
}
