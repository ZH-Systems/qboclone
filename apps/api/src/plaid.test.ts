import {describe,it,expect} from 'vitest'
import {encryptProviderToken,decryptProviderToken,encryptionKey,verifyWebhookToken,sanitizePlaidPage} from './plaid.js'
describe('provider bank credentials',()=>{
 const key=encryptionKey('ab'.repeat(32))
 it('encrypts random non-deterministic authenticated tokens',()=>{
  const a=encryptProviderToken('access-sandbox-123',key)
  const b=encryptProviderToken('access-sandbox-123',key)
  expect(a).not.toEqual(b)
  expect(decryptProviderToken(a,key)).toBe('access-sandbox-123')
  const tampered=a.split('.')
  tampered[2]=(tampered[2][0]==='A'?'B':'A')+tampered[2].slice(1)
  expect(()=>decryptProviderToken(tampered.join('.'),key)).toThrow()
 })
 it('rejects malformed keys and unauthenticated webhooks',()=>{
  expect(()=>encryptionKey('example')).toThrow()
  expect(verifyWebhookToken('correct','correct')).toBe(true)
  expect(verifyWebhookToken('wrong','correct')).toBe(false)
 })
 it('validates incremental provider response pages',()=>{
  expect(sanitizePlaidPage({added:[],modified:[],removed:[],next_cursor:'c',has_more:false}).next_cursor).toBe('c')
  expect(()=>sanitizePlaidPage({added:[{transaction_id:'a',account_id:'b',name:'n',date:'2026-11-10',amount:1.003}],modified:[],removed:[],next_cursor:'',has_more:false})).toThrow()
 })
})
