import {describe,it,expect} from 'vitest'
import {createHash,createPublicKey,generateKeyPairSync,sign} from 'node:crypto'
import {plaidWebhookKeyId,verifyPlaidWebhook,type PlaidWebhookJwk} from './plaid.js'

const {privateKey}=generateKeyPairSync('ec',{namedCurve:'prime256v1'})
const publicJwk=createPublicKey(privateKey).export({format:'jwk'})
const key:PlaidWebhookJwk={
 kty:'EC',crv:'P-256',alg:'ES256',kid:'sandbox-test-signing-key',use:'sig',
 x:String(publicJwk.x),y:String(publicJwk.y)
}
function signedWebhook(raw:Buffer,iat=Math.trunc(Date.now()/1000)){
 const header=Buffer.from(JSON.stringify({alg:'ES256',kid:key.kid,typ:'JWT'})).toString('base64url')
 const payload=Buffer.from(JSON.stringify({
  iat,request_body_sha256:createHash('sha256').update(raw).digest('hex')
 })).toString('base64url')
 const signed=header+'.'+payload
 const signature=sign('sha256',Buffer.from(signed),{
  key:privateKey,dsaEncoding:'ieee-p1363'
 }).toString('base64url')
 return signed+'.'+signature
}
describe('signed Plaid webhook security',()=>{
 const body=Buffer.from('{"webhook_type":"TRANSACTIONS","item_id":"test","webhook_code":"SYNC_UPDATES_AVAILABLE"}')
 it('validates a genuine ES256 signature and exact raw body',()=>{
  const jwt=signedWebhook(body)
  expect(plaidWebhookKeyId(jwt)).toBe(key.kid)
  expect(verifyPlaidWebhook(body,jwt,key)).toBe(true)
 })
 it('rejects body modification, invalid JWT, wrong signing key and expired timestamps',()=>{
  const jwt=signedWebhook(body)
  expect(verifyPlaidWebhook(Buffer.concat([body,Buffer.from(' ')]),jwt,key)).toBe(false)
  expect(verifyPlaidWebhook(body,jwt,{...key,kid:'different-kid'})).toBe(false)
  expect(verifyPlaidWebhook(body,'bad.token',key)).toBe(false)
  expect(verifyPlaidWebhook(body,signedWebhook(body,Math.trunc(Date.now()/1000)-600),key)).toBe(false)
 })
 it('rejects altered JWT algorithm headers even when a signature is present',()=>{
  const jwt=signedWebhook(body),parts=jwt.split('.')
  parts[0]=Buffer.from(JSON.stringify({alg:'none',kid:key.kid})).toString('base64url')
  expect(verifyPlaidWebhook(body,parts.join('.'),key)).toBe(false)
 })
})
