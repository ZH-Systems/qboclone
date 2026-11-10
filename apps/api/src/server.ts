import Fastify from 'fastify'
import cors from '@fastify/cors'
import Stripe from 'stripe'
import {createClient} from '@supabase/supabase-js'
import {readConfig} from './config.js'
import {requireOwner,resolvePrice,subscriptionOrganization,subscriptionPrice,paymentStatus} from './billing.js'
const config=readConfig()
const stripe=new Stripe(config.stripeKey)
const db=createClient(config.supabaseUrl,config.serviceRoleKey,{auth:{persistSession:false,autoRefreshToken:false}})
const app=Fastify({logger:true,bodyLimit:1024*1024})
await app.register(cors,{origin:config.webOrigin,methods:['GET','POST'],allowedHeaders:['Authorization','Content-Type']})

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
  if(/(required|Invalid|Unknown|not configured|owner role)/i.test(msg))return reply.code(400).send({error:msg})
  app.log.error(e)
  return reply.code(500).send({error:'Billing operation failed'})
}
app.get('/health',async()=>({status:'ok'}))

// Explicit raw-body handling for Stripe's cryptographic signature verification.
app.removeContentTypeParser('application/json')
app.addContentTypeParser('application/json',{parseAs:'buffer'},(_req,body,done)=>done(null,body))
function jsonInput(raw:unknown):Record<string,unknown>{
  if(!Buffer.isBuffer(raw))throw new Error('Invalid JSON payload')
  const obj=JSON.parse(raw.toString('utf8')) as unknown
  if(!obj||typeof obj!=='object'||Array.isArray(obj))throw new Error('Invalid JSON object')
  return obj as Record<string,unknown>
}
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
      p_period_end:null,p_cancel_at_period_end:sub.cancel_at_period_end,
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
