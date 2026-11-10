import type {FastifyInstance,FastifyReply} from 'fastify'
import type {SupabaseClient} from '@supabase/supabase-js'
import {randomUUID} from 'node:crypto'
import {bearerToken,requireOrganizationRole,requireOrganizationId} from './operations.js'
import type {ServerConfig} from './config.js'
import {plaidRequest,encryptionKey,encryptProviderToken,decryptProviderToken,sanitizePlaidPage,classifySyncError,verifyWebhookToken,plaidWebhookKeyId,verifyPlaidWebhook,
 type PlaidWebhookJwk,
 type PlaidClientConfig,type PlaidPage,type PlaidAccount} from './plaid.js'

type BankConfig=ServerConfig&{plaidClientId:string|null;plaidSecret:string|null;
 plaidEnv:'sandbox'|'development'|'production';bankTokenEncryptionKey:string|null}
function input(raw:unknown):Record<string,unknown>{
 if(!Buffer.isBuffer(raw))throw new Error('JSON body required')
 const data:unknown=JSON.parse(raw.toString('utf8'))
 if(!data||typeof data!=='object'||Array.isArray(data))throw new Error('JSON object required')
 return data as Record<string,unknown>
}
function errorReply(reply:FastifyReply,e:unknown){
 const msg=e instanceof Error?e.message:'Unexpected bank integration error'
 if(/Not authorized/.test(msg))return reply.code(403).send({error:'Insufficient bank connection permissions'})
 if(/not configured|not enabled/.test(msg))return reply.code(503).send({error:msg})
 if(/Invalid|missing|required|not found|expired|replay|unavailable|unsupported/i.test(msg))
  return reply.code(400).send({error:msg})
 return reply.code(502).send({error:'Bank provider operation failed'})
}
function plaidConfig(config:BankConfig):PlaidClientConfig{
 if(!config.plaidClientId||!config.plaidSecret||!config.bankTokenEncryptionKey)
  throw new Error('Plaid bank feed is not configured')
 return {clientId:config.plaidClientId,secret:config.plaidSecret,
  environment:config.plaidEnv,tokenEncryptionKey:encryptionKey(config.bankTokenEncryptionKey)}
}
async function member(db:SupabaseClient,header:string|undefined,org:string,roles:string[]){
 const token=bearerToken(header)
 const {data,error}=await db.auth.getUser(token)
 if(error||!data.user)throw new Error('Invalid login token')
 await requireOrganizationRole(db,data.user.id,org,roles)
 return data.user.id
}
const manageRoles=['owner','administrator','accountant']
async function syncConnection(db:SupabaseClient,plaid:PlaidClientConfig,connection:{
 id:string;organization_id:string;encrypted_token:string;sync_cursor:string|null
}):Promise<{pages:number;updated:number;removed:number}>{
 const token=decryptProviderToken(connection.encrypted_token,plaid.tokenEncryptionKey)
 let cursor=connection.sync_cursor,pages=0,updated=0,removed=0
 for(;pages<100;pages++){
  const page=sanitizePlaidPage(await plaidRequest<PlaidPage>(plaid,'/transactions/sync',{
   access_token:token,cursor:cursor||undefined,count:500}))
  // The cursor advances only after the database accepted this exact batch.
  const {data,error}=await db.rpc('apply_bank_feed_sync',{
   p_connection:connection.id,p_expected_cursor:cursor,p_next_cursor:page.next_cursor,
   p_added:page.added,p_modified:page.modified,p_removed:page.removed})
  if(error)throw new Error('Bank feed persistence failed: '+error.message)
  cursor=page.next_cursor
  updated+=Number(data?.updated||0);removed+=Number(data?.removed||0)
  if(!page.has_more)return {pages:pages+1,updated,removed}
 }
 throw new Error('Provider sync exceeded 100 pages, re-run the worker to continue')
}
export async function registerBankRoutes(app:FastifyInstance,db:SupabaseClient,config:BankConfig){
 app.post('/bank-feeds/link-token',{config:{rateLimit:{max:6,timeWindow:'1 hour'}}},async(req,reply)=>{
  try{
   const org=requireOrganizationId(input(req.body).organizationId)
   const user=await member(db,req.headers.authorization,org,manageRoles)
   const plaid=plaidConfig(config)
   const sessionId=randomUUID()
   const {error:insertError}=await db.from('bank_feed_link_sessions').insert({
    id:sessionId,organization_id:org,user_id:user,
    expires_at:new Date(Date.now()+15*60000).toISOString()})
   if(insertError)throw insertError
   const linkResponse=await plaidRequest<{link_token:string}>(plaid,'/link/token/create',{
    client_name:'Ledger North',language:'en',country_codes:['CA'],products:['transactions'],
    user:{client_user_id:sessionId}})
   return {sessionId,linkToken:linkResponse.link_token}
  }catch(e){req.log.error({error:e instanceof Error?e.message:'bank token request'},'Bank link token request failed')
   return errorReply(reply,e)}
 })
 app.post('/bank-feeds/exchange',{config:{rateLimit:{max:6,timeWindow:'1 hour'}}},async(req,reply)=>{
  try{
   const payload=input(req.body),org=requireOrganizationId(payload.organizationId)
   const user=await member(db,req.headers.authorization,org,manageRoles)
   const sessionId=payload.sessionId,publicToken=payload.publicToken
   if(typeof sessionId!=='string'||!/^[0-9a-f-]{36}$/i.test(sessionId)||
    typeof publicToken!=='string'||publicToken.length<8||publicToken.length>1024)
    throw new Error('Invalid bank connection authorization')
   const plaid=plaidConfig(config)
   // Claim BEFORE token exchange. CAS RPC makes replay/concurrent use impossible.
   const {data:claimed,error:claimError}=await db.rpc('claim_bank_link_session',{
    p_session:sessionId,p_organization:org,p_user:user})
   if(claimError||claimed!==true)throw new Error('Bank connection session expired or already used')
   const exchange=await plaidRequest<{access_token:string;item_id:string}>(
    plaid,'/item/public_token/exchange',{public_token:publicToken})
   if(!exchange.access_token||!exchange.item_id)throw new Error('Bank provider exchange failed')
   const accountResponse=await plaidRequest<{accounts:PlaidAccount[]}>(
    plaid,'/accounts/get',{access_token:exchange.access_token})
   if(!Array.isArray(accountResponse.accounts)||accountResponse.accounts.length>100)
    throw new Error('Invalid bank account list')
   const encrypted=encryptProviderToken(exchange.access_token,plaid.tokenEncryptionKey)
   const {data:connection,error:connError}=await db.from('bank_feed_connections').insert({
    organization_id:org,provider:'plaid',provider_item_id:exchange.item_id,
    encrypted_token:encrypted,created_by:user}).select('id').single()
   if(connError||!connection)throw new Error('Bank item already connected or could not be stored')
   const accounts=accountResponse.accounts.filter(account=>account.account_id).map(account=>({
    organization_id:org,connection_id:connection.id,provider_account_id:account.account_id,
    display_name:account.name,mask_last4:account.mask||null,
    currency_code:account.iso_currency_code||account.unofficial_currency_code||'CAD'}))
   if(accounts.length){
    const {error:accountsError}=await db.from('bank_feed_accounts').insert(accounts)
    if(accountsError){
     await db.from('bank_feed_connections').update({status:'disconnected'}).eq('id',connection.id)
     throw new Error('Could not store linked bank accounts')
    }
   }
   // Never return a Plaid access token, even encrypted.
   return {connectionId:connection.id,accounts:accounts.map(a=>({id:a.provider_account_id,name:a.display_name,mask:a.mask_last4}))}
  }catch(e){req.log.warn({category:'bank_exchange_failed'},'Bank exchange failed')
   return errorReply(reply,e)}
 })
 app.post('/bank-feeds/sync',{config:{rateLimit:{max:4,timeWindow:'1 minute'}}},async(req,reply)=>{
  try{
   const payload=input(req.body),org=requireOrganizationId(payload.organizationId)
   await member(db,req.headers.authorization,org,manageRoles)
   const id=payload.connectionId
   if(typeof id!=='string')throw new Error('Connection ID required')
   const {data,error}=await db.from('bank_feed_connections').select('*')
    .eq('organization_id',org).eq('id',id).eq('status','active').maybeSingle()
   if(error||!data)throw new Error('Bank connection unavailable')
   const stats=await syncConnection(db,plaidConfig(config),data)
   return stats
  }catch(e){req.log.error({error:e instanceof Error?e.message:'bank sync'},'Bank sync failed')
   return errorReply(reply,e)}
 })
 app.post('/bank-feeds/sync-due',{config:{rateLimit:{max:3,timeWindow:'1 minute'}}},async(req,reply)=>{
  if(!verifyWebhookToken(req.headers['x-worker-secret'] as string|undefined,config.workerSecret||''))
   return reply.code(401).send({error:'Worker secret required'})
  let count=0,failed=0
  const {data,error}=await db.from('bank_feed_connections').select('*')
   .eq('status','active').order('last_synced_at',{ascending:true,nullsFirst:true}).limit(20)
  if(error)return reply.code(500).send({error:'Bank feed queue unavailable'})
  try{
   const plaid=plaidConfig(config)
   for(const connection of data||[]){
    try{await syncConnection(db,plaid,connection);count++}
    catch(e){
     failed++
     const classification=classifySyncError(e)
     if(classification==='requires_reauth')await db.from('bank_feed_connections')
      .update({status:'requires_reauth',last_error_code:'REAUTH_REQUIRED'}).eq('id',connection.id)
     req.log.error({connectionId:connection.id,reason:classification},'Bank sync failed')
    }
   }
   return {synced:count,failed}
  }catch(e){return errorReply(reply,e)}
 })
 app.post('/bank-feeds/disconnect',{config:{rateLimit:{max:6,timeWindow:'1 hour'}}},async(req,reply)=>{
  try{
   const payload=input(req.body),org=requireOrganizationId(payload.organizationId)
   await member(db,req.headers.authorization,org,manageRoles)
   if(typeof payload.connectionId!=='string')throw new Error('Connection ID required')
   const {data,error}=await db.from('bank_feed_connections').select('*')
    .eq('organization_id',org).eq('id',payload.connectionId).maybeSingle()
   if(error||!data)throw new Error('Bank connection not found')
   if(data.status==='disconnected')return {disconnected:true}
   const plaid=plaidConfig(config)
   await plaidRequest(plaid,'/item/remove',{
    access_token:decryptProviderToken(data.encrypted_token,plaid.tokenEncryptionKey)})
   const {error:updateError}=await db.from('bank_feed_connections')
    .update({status:'disconnected',encrypted_token:'revoked'}).eq('id',data.id)
   if(updateError)throw updateError
   return {disconnected:true}
  }catch(e){return errorReply(reply,e)}
 })
 app.post('/bank-feeds/reconnect-token',{config:{rateLimit:{max:6,timeWindow:'1 hour'}}},async(req,reply)=>{
  try{
   const payload=input(req.body),org=requireOrganizationId(payload.organizationId)
   const user=await member(db,req.headers.authorization,org,manageRoles)
   if(typeof payload.connectionId!=='string')throw new Error('Connection ID required')
   const {data:connection,error}=await db.from('bank_feed_connections').select('*')
    .eq('organization_id',org).eq('id',payload.connectionId)
    .eq('provider','plaid').neq('status','disconnected').maybeSingle()
   if(error||!connection)throw new Error('Bank connection unavailable')
   const plaid=plaidConfig(config)
   const sessionId=randomUUID()
   const response=await plaidRequest<{link_token:string}>(plaid,'/link/token/create',{
    access_token:decryptProviderToken(connection.encrypted_token,plaid.tokenEncryptionKey),
    client_name:'Ledger North',language:'en',country_codes:['CA'],
    user:{client_user_id:user}
   })
   if(typeof response.link_token!=='string'||!response.link_token)
    throw new Error('Invalid Plaid update-mode response')
   const {error:sessionError}=await db.from('bank_feed_update_sessions').insert({
    id:sessionId,organization_id:org,connection_id:connection.id,user_id:user,
    expires_at:new Date(Date.now()+15*60000).toISOString()
   })
   if(sessionError)throw new Error('Could not store Plaid update-mode session')
   return {sessionId,linkToken:response.link_token}
  }catch(e){return errorReply(reply,e)}
 })
 app.post('/bank-feeds/reconnect-complete',{config:{rateLimit:{max:6,timeWindow:'1 hour'}}},async(req,reply)=>{
  try{
   const payload=input(req.body),org=requireOrganizationId(payload.organizationId)
   const user=await member(db,req.headers.authorization,org,manageRoles)
   const connectionId=payload.connectionId,sessionId=payload.sessionId
   if(typeof connectionId!=='string'||typeof sessionId!=='string')
    throw new Error('Connection and update-session IDs required')
   const plaid=plaidConfig(config)
   const {data:claimed,error:claimError}=await db.rpc('claim_bank_update_session',{
    p_id:sessionId,p_org:org,p_user:user,p_connection:connectionId})
   if(claimError||claimed!==true)throw new Error('Bank reauthorization session expired or already used')
   const {data:connection,error}=await db.from('bank_feed_connections').select('*')
    .eq('organization_id',org).eq('id',connectionId).neq('status','disconnected').maybeSingle()
   if(error||!connection)throw new Error('Bank connection unavailable')
   const response=await plaidRequest<{item?:{item_id?:string;error?:unknown}}>(
    plaid,'/item/get',{access_token:decryptProviderToken(connection.encrypted_token,plaid.tokenEncryptionKey)})
   if(response.item?.item_id!==connection.provider_item_id||response.item?.error)
    throw new Error('Provider has not restored this bank connection yet')
   const {error:updateError}=await db.from('bank_feed_connections')
    .update({status:'active',last_error_code:null,last_synced_at:null})
    .eq('organization_id',org).eq('id',connectionId)
   if(updateError)throw new Error('Bank reauthorization result could not be saved')
   return {reconnected:true}
  }catch(e){return errorReply(reply,e)}
 })
 app.post('/bank-feeds/plaid-webhook',{config:{rateLimit:{max:120,timeWindow:'1 minute'}}},async(req,reply)=>{
  const signature=req.headers['plaid-verification']
  if(typeof signature!=='string'||!Buffer.isBuffer(req.body)||req.body.length>50000)
   return reply.code(401).send({error:'Signed Plaid webhook required'})
  try{
   const plaid=plaidConfig(config)
   const kid=plaidWebhookKeyId(signature)
   const response=await plaidRequest<{key:PlaidWebhookJwk}>(
    plaid,'/webhook_verification_key/get',{key_id:kid})
   if(!verifyPlaidWebhook(req.body,signature,response.key))
    return reply.code(401).send({error:'Plaid webhook signature rejected'})
   const event=input(req.body)
   const itemId=event.item_id,kind=event.webhook_type,code=event.webhook_code
   if(typeof itemId!=='string'||itemId.length>200||
    typeof kind!=='string'||typeof code!=='string')
    return reply.code(400).send({error:'Invalid Plaid webhook payload'})
   const {data:connection,error}=await db.from('bank_feed_connections')
    .select('id,status').eq('provider','plaid').eq('provider_item_id',itemId).maybeSingle()
   if(error)return reply.code(503).send({error:'Bank event lookup unavailable'})
   if(!connection||connection.status==='disconnected')return {received:true,ignored:true}
   if(kind==='ITEM'&&(['PENDING_DISCONNECT','PENDING_EXPIRATION'].includes(code)||
    (code==='ERROR'&&(event.error as Record<string,unknown>|undefined)?.error_code==='ITEM_LOGIN_REQUIRED'))){
    const {error:saveError}=await db.from('bank_feed_connections')
     .update({status:'requires_reauth',last_error_code:code}).eq('id',connection.id)
    if(saveError)return reply.code(503).send({error:'Bank status update unavailable'})
   }else if(kind==='TRANSACTIONS'&&
    ['DEFAULT_UPDATE','HISTORICAL_UPDATE','INITIAL_UPDATE','TRANSACTIONS_REMOVED','SYNC_UPDATES_AVAILABLE'].includes(code)){
    const {error:saveError}=await db.from('bank_feed_connections')
     .update({last_synced_at:null}).eq('id',connection.id)
    if(saveError)return reply.code(503).send({error:'Bank sync enqueue unavailable'})
   }
   return {received:true}
  }catch(e){
   req.log.warn({category:'plaid_webhook_verification'},'Plaid webhook could not be verified or processed')
   return reply.code(503).send({error:'Webhook verification unavailable'})
  }
 })

}
