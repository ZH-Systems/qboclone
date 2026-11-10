// Live staging acceptance probes. Not a replacement for an external audit.
// All identities must be synthetic, distinct tenant members.
import assert from 'node:assert/strict'
import {createClient} from '@supabase/supabase-js'

const required=(name)=>{
 const value=process.env[name]?.trim()
 if(!value)throw new Error('Missing staging verification input: '+name)
 return value
}
const api=required('STAGING_API_URL')
const supabaseUrl=required('STAGING_SUPABASE_URL')
const publishableKey=required('STAGING_SUPABASE_ANON_KEY')
const orgA=required('STAGING_ORG_A'),orgB=required('STAGING_ORG_B')
const jwtA=required('STAGING_TEST_JWT_A'),jwtB=required('STAGING_TEST_JWT_B')
if(!api.startsWith('https://')||!supabaseUrl.startsWith('https://')||
 !/^[a-f0-9-]{36}$/i.test(orgA)|| !/^[a-f0-9-]{36}$/i.test(orgB)||
 orgA===orgB)throw new Error('Staging requires HTTPS and two distinct test organizations')

async function probe(path,options,expected){
 const response=await fetch(api.replace(/\/$/,'')+path,{
  ...options,signal:AbortSignal.timeout(15000),redirect:'manual'
 })
 if(expected===true)assert(response.ok,path+' returned '+response.status)
 else assert(!response.ok,path+' unexpectedly allowed unauthenticated access')
 return response
}
const health=await probe('/health',undefined,true)
const ready=await probe('/ready',undefined,true)
assert.equal((await health.json()).status,'ok')
assert.equal((await ready.json()).status,'ready')
for(const [path,method] of [
 ['/bank-feeds/sync-due','POST'],
 ['/automation/recurring/run','POST'],
 ['/automation/reminders/run','POST'],
 ['/qbo/connect/callback','GET'],
 ['/stripe/webhook','POST']]){
 await probe(path,{method,headers:{'Content-Type':'application/json'},body:method==='POST'?'{}':undefined},false)
}
const standardHeaders={'Content-Type':'application/json'}
await probe('/bank-feeds/sync',{
 method:'POST',headers:standardHeaders,
 body:JSON.stringify({organizationId:orgA,connectionId:orgA})
},false)
await probe('/organizations/export',{
 method:'POST',headers:standardHeaders,body:JSON.stringify({organizationId:orgA})
},false)

const scoped=jwt=>createClient(supabaseUrl,publishableKey,{
 global:{headers:{Authorization:'Bearer '+jwt}},
 auth:{persistSession:false,autoRefreshToken:false}
})
for(const [jwt,own,other] of [[jwtA,orgA,orgB],[jwtB,orgB,orgA]]){
 const db=scoped(jwt)
 const ownRow=await db.from('organizations').select('id').eq('id',own).maybeSingle()
 assert.ifError(ownRow.error)
 assert.equal(ownRow.data?.id,own,'Synthetic test user must access own org')
 for(const table of ['organizations','financial_documents','journal_entries',
   'inventory_products','bank_feed_accounts','migration_batches',
   'receipt_documents','vendor_advances','foreign_document_payments']){
  const result=await db.from(table).select('organization_id', {head:false}).eq('organization_id',other).limit(1)
  // organizations uses id rather than organization_id.
  if(table==='organizations'){
   const cross=await db.from('organizations').select('id').eq('id',other)
   assert.ifError(cross.error)
   assert.equal(cross.data?.length,0,'Cross-tenant organization exposed')
   continue
  }
  if(result.error)throw new Error(table+' RLS query failed: '+result.error.message)
  assert.equal(result.data?.length,0,table+' exposed cross-tenant rows')
 }
 for(const table of ['bank_feed_connections','qbo_connections','qbo_oauth_states','bank_feed_link_sessions']){
  const attempt=await db.from(table).select('*').limit(1)
  assert(attempt.error,'Authenticated user should never query server-only table '+table)
 }
}
console.log('Staging health, worker denial, OAuth denial and cross-tenant RLS smoke tests passed.')
