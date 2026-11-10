import 'dotenv/config'
import Fastify from 'fastify'
import cors from '@fastify/cors'
import rateLimit from '@fastify/rate-limit'
import helmet from '@fastify/helmet'
import {createHash} from 'node:crypto'
import Stripe from 'stripe'
import {createClient} from '@supabase/supabase-js'
import {readConfig} from './config.js'
import {bearerToken,requireOrganizationId,requireOrganizationRole,scopedSupabase,buildOrganizationExport} from './operations.js'
import {sendInvitationEmail} from './email.js'
import {requireOwner,resolvePrice,subscriptionOrganization,subscriptionPrice,paymentStatus,subscriptionPeriodEnd} from './billing.js'
const config=readConfig()
const stripe=new Stripe(config.stripeKey)
const db=createClient(config.supabaseUrl,config.serviceRoleKey,{auth:{persistSession:false,autoRefreshToken:false}})
const app=Fastify({logger:{redact:['req.headers.authorization','req.headers.stripe-signature','req.body']},bodyLimit:1024*1024,trustProxy:config.trustedProxyCidrs})
await app.register(cors,{origin:config.webOrigin,methods:['GET','POST'],allowedHeaders:['Authorization','Content-Type']})
await app.register(helmet,{contentSecurityPolicy:false})
await app.register(rateLimit,{global:false})

async function userFromBearer(header:string|undefined):Promise<string>{
  const match=/^Bearer (\S+)$/.exec(header||'')
  if(!match)throw new Error('Bearer token required')
  const {data,error}=await db.auth.getUser(match[1])
  if(error||!data.user)throw new Error('Invalid authenticated session')
  return data.user.id
}
function isUuid(value:unknown):value is string {
  return typeof value==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
}
function routeError(reply:any,e:unknown){
  const msg=e instanceof Error?e.message:'Unexpected server error'
  if(/(Not authorized|owner role required)/i.test(msg))return reply.code(403).send({error:'Insufficient organization permissions'})
  if(/not configured/i.test(msg))return reply.code(503).send({error:'The requested provider integration is not configured'})
  if(/(required|Invalid|Unknown)/i.test(msg))return reply.code(400).send({error:msg})
  app.log.error(e)
  return reply.code(500).send({error:'Billing operation failed'})
}
app.get('/health',async()=>({status:'ok'}))
app.get('/ready',async(_req,reply)=>{
  const {error}=await db.from('subscription_plans').select('code').limit(1)
  if(error)return reply.code(503).send({status:'unavailable'})
  return {status:'ready'}
})

// Explicit raw-body handling for Stripe's cryptographic signature verification.
app.removeContentTypeParser('application/json')
app.addContentTypeParser('application/json',{parseAs:'buffer'},(_req,body,done)=>done(null,body))
function jsonInput(raw:unknown):Record<string,unknown>{
  if(!Buffer.isBuffer(raw))throw new Error('Invalid JSON payload')
  const obj=JSON.parse(raw.toString('utf8')) as unknown
  if(!obj||typeof obj!=='object'||Array.isArray(obj))throw new Error('Invalid JSON object')
  return obj as Record<string,unknown>
}

/** Sends invitations without returning raw bearer tokens to the browser. */
app.post('/organizations/invite-email',{config:{rateLimit:{max:8,timeWindow:'1 minute'}}},async(req,reply)=>{
 try{
  const jwt=bearerToken(req.headers.authorization)
  const user=await userFromBearer(req.headers.authorization)
  const input=jsonInput(req.body)
  const org=requireOrganizationId(input.organizationId)
  const email=typeof input.email==='string'?input.email.trim().toLowerCase():''
  const role=typeof input.role==='string'?input.role:''
  await requireOrganizationRole(db,user,org,['owner','administrator'])
  if(!config.emailApiKey||!config.emailFrom)throw new Error('Invitation email provider not configured')
  const {data:business,error:orgError}=await db.from('organizations').select('name').eq('id',org).single()
  if(orgError||!business)throw new Error('Organization lookup failed')
  const scoped=scopedSupabase(config.supabaseUrl,config.serviceRoleKey,jwt)
  const {data:token,error}=await scoped.rpc('invite_organization_member',{
    p_org:org,p_email:email,p_role:role
  })
  if(error||typeof token!=='string')throw new Error(error?.message||'Invitation could not be created')
  try{
   await sendInvitationEmail({apiKey:config.emailApiKey,from:config.emailFrom,
     webOrigin:config.webOrigin},email,business.name,role,token)
  }catch(mailError){
   // An undelivered bearer token must not remain active.
   const digest=createHash('sha256').update(token).digest('hex')
   const {data:invitation}=await db.from('organization_invitations').select('id')
     .eq('organization_id',org).eq('token_hash',digest).maybeSingle()
   if(invitation){
    const {error:revokeError}=await scoped.rpc('revoke_organization_invitation',{
      p_org:org,p_invitation:invitation.id
    })
    if(revokeError)req.log.error({message:'Failed to revoke an undelivered invitation',invitationId:invitation.id})
   }
   throw mailError
  }
  return {sent:true}
 }catch(e){return routeError(reply,e)}
})

/** Server-filtered tenant data export with an explicit nontruncating row cap. */
app.post('/organizations/export',{config:{rateLimit:{max:2,timeWindow:'1 hour'}}},async(req,reply)=>{
 try{
  const jwt=bearerToken(req.headers.authorization)
  const user=await userFromBearer(req.headers.authorization)
  const org=requireOrganizationId(jsonInput(req.body).organizationId)
  await requireOrganizationRole(db,user,org,['owner','administrator','accountant'])
  const payload=await buildOrganizationExport(db,org,10000)
  if(Buffer.byteLength(JSON.stringify(payload),'utf8')>20*1024*1024)
   return reply.code(413).send({error:'Export exceeds 20 MiB; use archival export'})
  const scoped=scopedSupabase(config.supabaseUrl,config.serviceRoleKey,jwt)
  const {error}=await scoped.rpc('record_organization_export',{p_organization_id:org})
  if(error)throw new Error('Unable to record export audit event')
  return reply.header('Content-Type','application/json; charset=utf-8')
   .header('Content-Disposition','attachment; filename="organization-'+org+'.json"')
   .header('Cache-Control','private, no-store')
   .send(payload)
 }catch(e){
  if(e instanceof Error&&e.message.includes('Export row limit exceeded'))
   return reply.code(413).send({error:e.message})
  return routeError(reply,e)
 }
})

app.post('/billing/checkout',async(req,reply)=>{
  try{
    const user=await userFromBearer(req.headers.authorization)
    const input=jsonInput(req.body),org=input.organizationId,plan=input.planCode
    if(!isUuid(org)||typeof plan!=='string')throw new Error('Invalid organization or plan')
    await requireOwner(db,user,org)
    const price=await resolvePrice(db,plan)
    const {data:existing,error}=await db.from('organization_subscriptions')
      .select('stripe_customer_id,stripe_subscription_id,status').eq('organization_id',org).maybeSingle()
    if(error)throw new Error('Subscription lookup failed')
    if(existing?.stripe_subscription_id&&['active','trialing','past_due','unpaid'].includes(existing.status))
      throw new Error('Existing subscription should be managed through billing portal')
    let customerId:string|undefined=existing?.stripe_customer_id||undefined
    if(!customerId){
      const {data:who,error:e}=await db.auth.admin.getUserById(user)
      if(e||!who.user)throw new Error('User lookup failed')
      const customer=await stripe.customers.create({email:who.user.email||undefined,metadata:{organization_id:org}},
        {idempotencyKey:'customer:'+org})
      customerId=customer.id
    }
    const session=await stripe.checkout.sessions.create({
      mode:'subscription',customer:customerId,client_reference_id:org,
      line_items:[{price,quantity:1}],subscription_data:{metadata:{organization_id:org}},
      success_url:config.webOrigin+'/?billing=success',cancel_url:config.webOrigin+'/?billing=canceled',
      metadata:{organization_id:org}
    })
    if(!session.url)throw new Error('Stripe checkout returned no URL')
    return {url:session.url}
  }catch(e){return routeError(reply,e)}
})
app.post('/billing/portal',async(req,reply)=>{
  try{
    const user=await userFromBearer(req.headers.authorization)
    const {organizationId:org}=jsonInput(req.body)
    if(!isUuid(org))throw new Error('Invalid organization')
    await requireOwner(db,user,org)
    const {data,error}=await db.from('organization_subscriptions')
      .select('stripe_customer_id').eq('organization_id',org).maybeSingle()
    if(error||!data?.stripe_customer_id)throw new Error('No subscription billing customer exists')
    const session=await stripe.billingPortal.sessions.create({customer:data.stripe_customer_id,
      return_url:config.webOrigin+'/?billing=returned'})
    return {url:session.url}
  }catch(e){return routeError(reply,e)}
})
app.post('/stripe/webhook',{config:{rawBody:true}},async(req,reply)=>{
  const signature=req.headers['stripe-signature']
  if(typeof signature!=='string'||!Buffer.isBuffer(req.body))return reply.code(400).send({error:'Raw signed request required'})
  let event:Stripe.Event
  try{event=stripe.webhooks.constructEvent(req.body,signature,config.webhookSecret)}
  catch{return reply.code(400).send({error:'Invalid Stripe webhook signature'})}
  if(!['customer.subscription.created','customer.subscription.updated','customer.subscription.deleted'].includes(event.type))
    return {received:true,ignored:true}
  try{
    const sub=event.data.object as Stripe.Subscription
    const org=await subscriptionOrganization(db,sub)
    const price=subscriptionPrice(sub)
    const {data,error}=await db.rpc('apply_stripe_subscription_event',{
      p_event_id:event.id,p_event_created:event.created,p_org:org,
      p_customer:typeof sub.customer==='string'?sub.customer:sub.customer.id,
      p_subscription:sub.id,p_price:price,p_status:paymentStatus(event,sub),
      p_period_end:subscriptionPeriodEnd(sub),p_cancel_at_period_end:sub.cancel_at_period_end,
      p_event_type:event.type
    })
    if(error)throw error
    return {received:true,applied:data}
  }catch(e){
    req.log.error(e,'Verified Stripe event could not be processed')
    return reply.code(500).send({error:'Webhook processing failed, Stripe should retry'})
  }
})
await app.listen({host:'0.0.0.0',port:config.port})
