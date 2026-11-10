import type {FastifyInstance,FastifyReply} from 'fastify'
import type {SupabaseClient} from '@supabase/supabase-js'
import {randomBytes,createHash} from 'node:crypto'
import {encryptProviderToken,decryptProviderToken,encryptionKey} from './plaid.js'
import {QBO_TYPES,qboQuery,normalizeQboPage,type QboType} from './qboNormalize.js'
import {bearerToken,requireOrganizationId,requireOrganizationRole,scopedSupabase} from './operations.js'
import type {ServerConfig} from './config.js'
type QboConfig=ServerConfig&{qboClientId:string|null;qboClientSecret:string|null;
 qboRedirectUri:string|null;qboSandbox:boolean;bankTokenEncryptionKey:string|null}
type Credentials={clientId:string;clientSecret:string;redirectUri:string;key:Buffer;sandbox:boolean}
type OAuthTokens={access_token:string;refresh_token:string;expires_in:number;x_refresh_token_expires_in?:number}
type SourceConnection={id:string;organization_id:string;realm_id:string;
 encrypted_access_token:string;encrypted_refresh_token:string;access_expires_at:string;status:string}
function authConfig(config:QboConfig):Credentials{
 if(!config.qboClientId||!config.qboClientSecret||!config.qboRedirectUri||!config.bankTokenEncryptionKey)
 throw new Error('QuickBooks OAuth is not configured')
 if(!config.qboRedirectUri.startsWith('https://')&&!config.qboRedirectUri.startsWith('http://localhost:'))
 throw new Error('QuickBooks callback requires HTTPS')
 return {clientId:config.qboClientId,clientSecret:config.qboClientSecret,
 redirectUri:config.qboRedirectUri,sandbox:config.qboSandbox,key:encryptionKey(config.bankTokenEncryptionKey)}
}
function rawJson(raw:unknown):Record<string,unknown>{
 if(!Buffer.isBuffer(raw))throw new Error('Expected JSON request')
 const data:unknown=JSON.parse(raw.toString('utf8'))
 if(!data||Array.isArray(data)||typeof data!=='object')throw new Error('Expected JSON object')
 return data as Record<string,unknown>
}
async function verifyUser(db:SupabaseClient,authorization:string|undefined,org:string){
 const token=bearerToken(authorization)
 const {data,error}=await db.auth.getUser(token)
 if(error||!data.user)throw new Error('Invalid authenticated session')
 await requireOrganizationRole(db,data.user.id,org,['owner','administrator','accountant'])
 return {id:data.user.id,token}
}
function safeReply(reply:FastifyReply,error:unknown){
 const msg=error instanceof Error?error.message:'QuickBooks operation failed'
 if(/Not authorized/.test(msg))return reply.code(403).send({error:'Organization permission denied'})
 if(/Invalid|not configured|Missing|not found|expired|unsupported|already/.test(msg))
  return reply.code(400).send({error:msg})
 return reply.code(502).send({error:'QuickBooks provider request failed'})
}
async function oauthToken(config:Credentials,params:URLSearchParams):Promise<OAuthTokens>{
 const credentials=Buffer.from(config.clientId+':'+config.clientSecret).toString('base64')
 const response=await fetch('https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer',{
  method:'POST',headers:{Authorization:'Basic '+credentials,
   'Content-Type':'application/x-www-form-urlencoded',Accept:'application/json'},
  body:params.toString(),signal:AbortSignal.timeout(20000)})
 if(!response.ok)throw new Error('QuickBooks OAuth token exchange failed')
 const data=await response.json() as OAuthTokens
 if(!data.access_token||!data.refresh_token)throw new Error('Invalid QuickBooks token response')
 return data
}
function encoded(tokens:OAuthTokens,config:Credentials){
 return {encrypted_access_token:encryptProviderToken(tokens.access_token,config.key),
  encrypted_refresh_token:encryptProviderToken(tokens.refresh_token,config.key),
  access_expires_at:new Date(Date.now()+Math.max(60,tokens.expires_in-120)*1000).toISOString(),
  refresh_expires_at:tokens.x_refresh_token_expires_in?
   new Date(Date.now()+tokens.x_refresh_token_expires_in*1000).toISOString():null}
}
async function validAccess(db:SupabaseClient,config:Credentials,connection:SourceConnection):Promise<string>{
 if(new Date(connection.access_expires_at).getTime()>Date.now()+60000)
  return decryptProviderToken(connection.encrypted_access_token,config.key)
 const refresh=decryptProviderToken(connection.encrypted_refresh_token,config.key)
 const tokens=await oauthToken(config,new URLSearchParams({grant_type:'refresh_token',refresh_token:refresh}))
 const data=encoded(tokens,config)
 const {error}=await db.from('qbo_connections').update(data).eq('id',connection.id)
 if(error)throw new Error('QuickBooks refresh-token rotation could not be persisted')
 return tokens.access_token
}
export async function registerQboRoutes(app:FastifyInstance,db:SupabaseClient,config:QboConfig){
 app.post('/qbo/connect/start',{config:{rateLimit:{max:4,timeWindow:'1 hour'}}},async(req,reply)=>{
  try{
   const org=requireOrganizationId(rawJson(req.body).organizationId)
   const user=await verifyUser(db,req.headers.authorization,org)
   const qbo=authConfig(config)
   const state=randomBytes(32).toString('base64url')
   const digest=createHash('sha256').update(state).digest('hex')
   const {error}=await db.from('qbo_oauth_states').insert({
    state_hash:digest,organization_id:org,user_id:user.id,
    expires_at:new Date(Date.now()+10*60000).toISOString()})
   if(error)throw new Error('QuickBooks authorization state could not be saved')
   const url=new URL('https://appcenter.intuit.com/connect/oauth2')
   url.searchParams.set('client_id',qbo.clientId)
   url.searchParams.set('response_type','code')
   url.searchParams.set('scope','com.intuit.quickbooks.accounting')
   url.searchParams.set('redirect_uri',qbo.redirectUri)
   url.searchParams.set('state',state)
   return {url:url.toString()}
  }catch(e){return safeReply(reply,e)}
 })
 app.get('/qbo/connect/callback',async(req,reply)=>{
  const query=req.query as Record<string,string|undefined>
  const state=query.state||'',code=query.code||'',realm=query.realmId||''
  if(!state||!code||!realm||code.length>3000||realm.length>100)
   return reply.code(400).send({error:'Invalid QuickBooks callback'})
  const digest=createHash('sha256').update(state).digest('hex')
  try{
   const qbo=authConfig(config)
   // Atomically claim OAuth state before exchanging a single-use authorization
   // code. On exchange failure the user must explicitly restart OAuth.
   const {data:states,error:stateError}=await db.rpc('claim_qbo_oauth_state',{p_sha256:digest})
   const session=Array.isArray(states)?states[0]:undefined
   if(stateError||!session)throw new Error('QuickBooks authorization expired or already used')
   const tokens=await oauthToken(qbo,new URLSearchParams({grant_type:'authorization_code',
    code,redirect_uri:qbo.redirectUri}))
   const {error:saveError}=await db.from('qbo_connections').upsert({
    organization_id:session.organization_id,realm_id:realm,created_by:session.user_id,
    status:'active',...encoded(tokens,qbo)}, {onConflict:'organization_id,realm_id'})
   if(saveError)throw new Error('QuickBooks company connection could not be stored')
   return reply.redirect(config.webOrigin+'/?integration=qbo-connected')
  }catch(e){return safeReply(reply,e)}
 })
 app.post('/qbo/migration/page',{config:{rateLimit:{max:60,timeWindow:'1 minute'}}},async(req,reply)=>{
  try{
   const payload=rawJson(req.body),org=requireOrganizationId(payload.organizationId)
   const user=await verifyUser(db,req.headers.authorization,org)
   const batchId=payload.batchId,entity=payload.entity,start=payload.start
   if(typeof batchId!=='string'||typeof entity!=='string'||
    !QBO_TYPES.includes(entity as QboType)||!Number.isInteger(start)||Number(start)<1)
    throw new Error('Invalid QuickBooks import selection')
   const {data:batch,error:batchError}=await db.from('migration_batches')
    .select('id,source_company_id,state').eq('organization_id',org).eq('id',batchId).maybeSingle()
   if(batchError||!batch||batch.state!=='staged')throw new Error('Migration batch not editable')
   const {data:connection,error:cError}=await db.from('qbo_connections').select('*')
    .eq('organization_id',org).eq('realm_id',batch.source_company_id).eq('status','active').maybeSingle()
   if(cError||!connection)throw new Error('QuickBooks company is not connected')
   const qbo=authConfig(config),access=await validAccess(db,qbo,connection as SourceConnection)
   const endpoint=(qbo.sandbox?'https://sandbox-quickbooks.api.intuit.com':
    'https://quickbooks.api.intuit.com')+'/v3/company/'+encodeURIComponent(connection.realm_id)+
    '/query?query='+encodeURIComponent(qboQuery(entity as QboType,Number(start),100))
   const response=await fetch(endpoint,{method:'GET',headers:{
    Authorization:'Bearer '+access,Accept:'application/json'},signal:AbortSignal.timeout(30000)})
   if(!response.ok)throw new Error('QuickBooks query failed')
   const data=await response.json() as {QueryResponse?:Record<string,unknown>}
   const items=data.QueryResponse?.[entity]
   if(items!==undefined&&!Array.isArray(items))throw new Error('Unexpected QuickBooks entity response')
   const normalized=normalizeQboPage(entity as QboType,(items||[]) as Record<string,unknown>[])
   const grouped=new Map<string,Record<string,unknown>[]>()
   for(const entityRow of normalized){
    const list=grouped.get(entityRow.kind)||[];list.push(entityRow.record);grouped.set(entityRow.kind,list)
   }
   const scoped=scopedSupabase(config.supabaseUrl,config.serviceRoleKey,user.token)
   let staged=0
   for(const [kind,records] of grouped){
    const {data:count,error}=await scoped.rpc('stage_migration_records',{
     p_org:org,p_batch:batchId,p_kind:kind,p_records:records})
    if(error)throw new Error('Failed to stage QuickBooks records: '+error.message)
    staged+=Number(count)
   }
   return {entity,start,read:(items||[]).length,staged,nextStart:Number(start)+100,
    hasMore:(items||[]).length===100}
  }catch(e){req.log.error({message:e instanceof Error?e.message:'QBO pagination'},'QBO import failed')
   return safeReply(reply,e)}
 })
 app.post('/qbo/migration/report',{config:{rateLimit:{max:15,timeWindow:'1 minute'}}},async(req,reply)=>{
  try{
   const payload=rawJson(req.body),org=requireOrganizationId(payload.organizationId)
   const user=await verifyUser(db,req.headers.authorization,org)
   const batchId=payload.batchId,reportType=payload.reportType
   const start=payload.startDate,end=payload.endDate
   const reports=['TrialBalance','BalanceSheet','ProfitAndLoss','AgedReceivables','AgedPayables']
   if(typeof batchId!=='string'||!reports.includes(String(reportType))||
    typeof start!=='string'||typeof end!=='string'||
    !/^\\d{4}-\\d{2}-\\d{2}$/.test(start)||!/^\\d{4}-\\d{2}-\\d{2}$/.test(end)||
    start>end)throw new Error('Invalid QuickBooks report request')
   const {data:batch,error:batchError}=await db.from('migration_batches')
    .select('source_company_id,state').eq('organization_id',org).eq('id',batchId).maybeSingle()
   if(batchError||!batch)throw new Error('Migration batch not found')
   const {data:connection,error:cError}=await db.from('qbo_connections').select('*')
    .eq('organization_id',org).eq('realm_id',batch.source_company_id).eq('status','active').maybeSingle()
   if(cError||!connection)throw new Error('QuickBooks company is not connected')
   const qbo=authConfig(config),access=await validAccess(db,qbo,connection as SourceConnection)
   const url=new URL((qbo.sandbox?'https://sandbox-quickbooks.api.intuit.com':
    'https://quickbooks.api.intuit.com')+'/v3/company/'+encodeURIComponent(connection.realm_id)+
    '/reports/'+encodeURIComponent(String(reportType)))
   url.searchParams.set('start_date',start);url.searchParams.set('end_date',end)
   url.searchParams.set('accounting_method','Accrual')
   const provider=await fetch(url,{headers:{Authorization:'Bearer '+access,Accept:'application/json'},
    signal:AbortSignal.timeout(30000)})
   if(!provider.ok)throw new Error('QuickBooks report was unavailable')
   const raw=await provider.json() as Record<string,unknown>
   const encodedRaw=JSON.stringify(raw)
   if(encodedRaw.length>3500000)throw new Error('Source report is too large for current staging')
   const digest=createHash('sha256').update(encodedRaw).digest('hex')
   const scoped=scopedSupabase(config.supabaseUrl,config.serviceRoleKey,user.token)
   const {data:id,error}=await scoped.rpc('store_migration_source_report',{
    p_org:org,p_batch:batchId,p_report_type:reportType,
    p_start:start,p_end:end,p_document:raw,p_sha256:digest})
   if(error)throw new Error('Could not archive QuickBooks report: '+error.message)
   return {sourceReportId:id,reportType,periodEnd:end,sha256:digest}
  }catch(e){req.log.error({reason:e instanceof Error?e.message:'QBO report failed'},
   'QuickBooks source reporting failed');return safeReply(reply,e)}
 })

}
