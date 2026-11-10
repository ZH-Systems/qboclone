import {describe,expect,it} from 'vitest'
import {readConfig} from './config.js'
import {subscriptionPrice} from './billing.js'
describe('billing boundaries',()=>{
 it('rejects missing server secrets',()=>expect(()=>readConfig({})).toThrow('WEB_APP_ORIGIN'))
 it('loads secrets from server environment only',()=>{
  expect(readConfig({SUPABASE_URL:'https://example.supabase.co',SUPABASE_SERVICE_ROLE_KEY:'abc',
   STRIPE_SECRET_KEY:'sk_test_example',STRIPE_WEBHOOK_SECRET:'whsec_example',
   WEB_APP_ORIGIN:'http://localhost:5173'}).port).toBe(3000)
 })
 it('rejects multiple subscription items',()=>{
  expect(()=>subscriptionPrice({items:{data:[{price:{id:'price_one'}},{price:{id:'price_two'}}]}} as never)).toThrow('Exactly one')
 })
})
