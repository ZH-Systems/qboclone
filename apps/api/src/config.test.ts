import {describe,it,expect} from 'vitest'
import {readConfig} from './config.js'

const base={
 SUPABASE_URL:'https://staging-project.supabase.co',
 SUPABASE_SERVICE_ROLE_KEY:'placeholder-service-role-for-tests',
 STRIPE_SECRET_KEY:'sk_test_example',
 STRIPE_WEBHOOK_SECRET:'whsec_example',
 WEB_APP_ORIGIN:'https://app.example.invalid',
 PORT:'3000',
} as NodeJS.ProcessEnv

describe('server configuration release boundaries',()=>{
 it('allows non-production development without live integrations',()=>{
  expect(readConfig({...base,DEPLOYMENT_ENV:'development'}).deploymentEnv).toBe('development')
 })
 it('defaults to disabled Stripe even when credentials are absent',()=>{
  const {STRIPE_SECRET_KEY,STRIPE_WEBHOOK_SECRET,...noStripe}=base
  const config=readConfig({...noStripe,DEPLOYMENT_ENV:'development'})
  expect(config.stripeEnabled).toBe(false)
  expect(config.stripeKey).toBe(null)
  expect(config.webhookSecret).toBe(null)
 })
 it('rejects enabled Stripe without both credentials and invalid enable flags',()=>{
  expect(()=>readConfig({...base,STRIPE_ENABLED:'yes'})).toThrow(/STRIPE_ENABLED/)
  expect(()=>readConfig({...base,STRIPE_ENABLED:'true',STRIPE_SECRET_KEY:''})).toThrow(/STRIPE_SECRET_KEY/)
  expect(()=>readConfig({...base,STRIPE_ENABLED:'true',STRIPE_WEBHOOK_SECRET:''})).toThrow(/STRIPE_WEBHOOK_SECRET/)
  expect(readConfig({...base,STRIPE_ENABLED:'true'}).stripeEnabled).toBe(true)
 })
 it('rejects non-TLS remote origins',()=>{
  expect(()=>readConfig({...base,WEB_APP_ORIGIN:'http://public.example.invalid'})).toThrow(/HTTPS/)
 })
 it('fails closed without production authorization',()=>{
  expect(()=>readConfig({...base,DEPLOYMENT_ENV:'production',STRIPE_ENABLED:'true'})).toThrow(/live Stripe/)
 })
 it('enforces signed Stripe, minimum worker secret and trusted proxies',()=>{
  const live={...base,DEPLOYMENT_ENV:'production',STRIPE_ENABLED:'true',
   STRIPE_SECRET_KEY:'sk_live_example',STRIPE_WEBHOOK_SECRET:'whsec_example',
   TRUSTED_PROXY_CIDRS:'127.0.0.1/32',AUTOMATION_WORKER_SECRET:'x'.repeat(40)}
  expect(readConfig(live).deploymentEnv).toBe('production')
  expect(()=>readConfig({...live,AUTOMATION_WORKER_SECRET:'too-short'})).toThrow(/32 bytes/)
  expect(()=>readConfig({...live,TRUSTED_PROXY_CIDRS:''})).toThrow(/TRUSTED_PROXY/)
  expect(()=>readConfig({...live,SUPABASE_URL:'http://test.example.invalid'})).toThrow(/HTTPS/)
 })
 it('retains non-Stripe production safety requirements with Stripe disabled',()=>{
  const {STRIPE_SECRET_KEY,STRIPE_WEBHOOK_SECRET,...noStripe}=base
  const live={...noStripe,DEPLOYMENT_ENV:'production',TRUSTED_PROXY_CIDRS:'127.0.0.1/32',
   AUTOMATION_WORKER_SECRET:'x'.repeat(40)}
  expect(readConfig(live).stripeEnabled).toBe(false)
  expect(()=>readConfig({...live,TRUSTED_PROXY_CIDRS:''})).toThrow(/TRUSTED_PROXY/)
 })
 it('rejects mixed sandbox/production Plaid and QuickBooks credentials',()=>{
  const live={...base,DEPLOYMENT_ENV:'production',STRIPE_ENABLED:'true',
   STRIPE_SECRET_KEY:'sk_live_example',TRUSTED_PROXY_CIDRS:'127.0.0.1/32',
   AUTOMATION_WORKER_SECRET:'x'.repeat(40)}
  expect(()=>readConfig({...live,PLAID_CLIENT_ID:'plaid-id',PLAID_SECRET:'plaid-secret',
   PLAID_ENV:'sandbox',BANK_TOKEN_ENCRYPTION_KEY:'ab'.repeat(32)})).toThrow(/Production Plaid/)
  expect(()=>readConfig({...live,QBO_CLIENT_ID:'intuit-id',QBO_CLIENT_SECRET:'secret',
   QBO_SANDBOX:'true',QBO_REDIRECT_URI:'https://api.example.invalid/qbo/connect/callback',
   BANK_TOKEN_ENCRYPTION_KEY:'ab'.repeat(32)})).toThrow(/Production QuickBooks/)
 })
})
