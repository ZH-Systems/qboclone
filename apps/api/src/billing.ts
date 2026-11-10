import type Stripe from 'stripe'
import type {SupabaseClient} from '@supabase/supabase-js'
type Plan={code:string;stripe_price_id:string|null;active:boolean}
type Membership={role:string}
export async function requireOwner(db:SupabaseClient,userId:string,organizationId:string){
  const {data,error}=await db.from('organization_members').select('role').eq('organization_id',organizationId).eq('user_id',userId).maybeSingle()
  if(error)throw new Error('Membership verification failed')
  if((data as Membership|null)?.role!=='owner')throw new Error('Organization owner role required')
}
export async function resolvePrice(db:SupabaseClient,code:string):Promise<string>{
  if(!['starter','business','professional'].includes(code))throw new Error('Unknown plan code')
  const {data,error}=await db.from('subscription_plans').select('code,stripe_price_id,active').eq('code',code).maybeSingle()
  if(error)throw new Error('Plan lookup failed')
  const plan=data as Plan|null
  if(!plan?.active||!plan.stripe_price_id)throw new Error('Stripe price has not been configured for this plan')
  return plan.stripe_price_id
}
export async function subscriptionOrganization(db:SupabaseClient,sub:Stripe.Subscription):Promise<string>{
  const org=sub.metadata?.organization_id
  if(!org||!/^[0-9a-f]{8}-[0-9a-f-]{27,}$/i.test(org))throw new Error('Subscription has no valid organization mapping')
  const {data,error}=await db.from('organizations').select('id').eq('id',org).maybeSingle()
  if(error||!data)throw new Error('Subscription organization not found')
  return org
}
export function subscriptionPrice(sub:Stripe.Subscription):string{
  const items=sub.items.data
  if(items.length!==1||!items[0]?.price?.id)throw new Error('Exactly one managed Stripe subscription item is required')
  return items[0].price.id
}
export function paymentStatus(event:Stripe.Event,sub:Stripe.Subscription){
  return event.type==='customer.subscription.deleted'?'canceled':sub.status
}
