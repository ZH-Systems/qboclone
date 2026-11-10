import {createCipheriv,createDecipheriv,randomBytes,createHash,timingSafeEqual,createPublicKey,verify as cryptoVerify} from 'node:crypto'
export type PlaidTransaction={transaction_id:string;account_id:string;date:string;name:string;amount:number;pending?:boolean}
export type PlaidPage={added:PlaidTransaction[];modified:PlaidTransaction[];removed:{transaction_id:string}[];next_cursor:string;has_more:boolean}
export type PlaidAccount={account_id:string;name:string;mask:string|null;iso_currency_code:string|null;unofficial_currency_code:string|null}
export type PlaidClientConfig={clientId:string;secret:string;environment:'sandbox'|'development'|'production';tokenEncryptionKey:Buffer}
export function encryptionKey(value:string):Buffer{
 if(!/^[0-9a-f]{64}$/i.test(value))throw new Error('BANK_TOKEN_ENCRYPTION_KEY must be a 64-digit hexadecimal AES-256 key')
 return Buffer.from(value,'hex')
}
export function encryptProviderToken(token:string,key:Buffer):string{
 if(!token||key.length!==32)throw new Error('Invalid provider token encryption')
 const iv=randomBytes(12),cipher=createCipheriv('aes-256-gcm',key,iv)
 const encrypted=Buffer.concat([cipher.update(token,'utf8'),cipher.final()])
 return ['v1',iv.toString('base64url'),cipher.getAuthTag().toString('base64url'),encrypted.toString('base64url')].join('.')
}
export function decryptProviderToken(token:string,key:Buffer):string{
 const parts=token.split('.')
 if(parts.length!==4||parts[0]!=='v1'||key.length!==32)throw new Error('Invalid encrypted credential')
 const iv=Buffer.from(parts[1],'base64url'),tag=Buffer.from(parts[2],'base64url')
 if(iv.length!==12||tag.length!==16)throw new Error('Invalid encrypted credential')
 const decipher=createDecipheriv('aes-256-gcm',key,iv)
 decipher.setAuthTag(tag)
 return Buffer.concat([decipher.update(Buffer.from(parts[3],'base64url')),decipher.final()]).toString('utf8')
}
export function verifyWebhookToken(provided:string|undefined,secret:string):boolean{
 if(!provided||!secret)return false
 const a=Buffer.from(provided),b=Buffer.from(secret)
 return a.length===b.length&&timingSafeEqual(a,b)
}
export function plaidApiBase(env:PlaidClientConfig['environment']):string{
 return 'https://'+({sandbox:'sandbox',development:'development',production:'production'}[env])+'.plaid.com'
}
export async function plaidRequest<T>(config:PlaidClientConfig,endpoint:string,params:Record<string,unknown>):Promise<T>{
 const response=await fetch(plaidApiBase(config.environment)+endpoint,{
  method:'POST',headers:{'Content-Type':'application/json'},
  body:JSON.stringify({...params,client_id:config.clientId,secret:config.secret}),
  signal:AbortSignal.timeout(25000)
 })
 const parsed=await response.json().catch(()=>({})) as Record<string,unknown>
 if(!response.ok){const error=typeof parsed.error_code==='string'?parsed.error_code:'PROVIDER_REQUEST_FAILED'
  throw new Error('Plaid API error: '+error)}
 return parsed as T
}
export function sanitizePlaidPage(page:PlaidPage):PlaidPage{
 if(!page||!Array.isArray(page.added)||!Array.isArray(page.modified)||!Array.isArray(page.removed)
 ||typeof page.next_cursor!=='string'||page.next_cursor.length>5000
 ||typeof page.has_more!=='boolean')throw new Error('Unexpected provider sync response')
 for(const transaction of [...page.added,...page.modified]){
  if(!transaction.transaction_id||!transaction.account_id||!transaction.date||
   !transaction.name||!Number.isFinite(transaction.amount)||
   Math.abs(transaction.amount)>999999999999||
   !Number.isInteger(Math.round(transaction.amount*100))||
   Math.abs(transaction.amount*100-Math.round(transaction.amount*100))>0.000001)
   throw new Error('Invalid provider transaction amount or identifiers')
 }
 return page
}
export function classifySyncError(error:unknown):string{
 const message=error instanceof Error?error.message:String(error)
 return /ITEM_LOGIN_REQUIRED|INVALID_ACCESS_TOKEN|ITEM_NOT_SUPPORTED|ACCESS_NOT_GRANTED/.test(message)
  ?'requires_reauth':'temporary_error'
}
export function clientRequestKey(org:string,providerAccountId:string):string{
 return createHash('sha256').update(org+':'+providerAccountId).digest('hex')
}

export type PlaidWebhookJwk={kty:string;crv:string;alg:string;kid:string;use:string;x:string;y:string;
 created_at?:number;expired_at?:number}
function decodeJwtObject(segment:string):Record<string,unknown>{
 const value:unknown=JSON.parse(Buffer.from(segment,'base64url').toString('utf8'))
 if(!value||typeof value!=='object'||Array.isArray(value))
  throw new Error('Invalid Plaid webhook JWT content')
 return value as Record<string,unknown>
}
export function plaidWebhookKeyId(signatureJwt:string):string{
 const parts=signatureJwt.split('.')
 if(parts.length!==3)throw new Error('Missing Plaid webhook JWT')
 const header=decodeJwtObject(parts[0])
 if(header.alg!=='ES256'||typeof header.kid!=='string'||header.kid.length>200||
  header.kid.length<8)throw new Error('Invalid Plaid webhook signature algorithm or key')
 return header.kid
}
export function verifyPlaidWebhook(raw:Buffer,jwt:string,jwk:PlaidWebhookJwk,nowMs=Date.now()):boolean{
 if(!Buffer.isBuffer(raw)||raw.length>50000||raw.length===0)return false
 try{
  const parts=jwt.split('.')
  if(parts.length!==3)return false
  const kid=plaidWebhookKeyId(jwt)
  if(jwk.alg!=='ES256'||jwk.kty!=='EC'||jwk.crv!=='P-256'||jwk.use!=='sig'||
   jwk.kid!==kid||typeof jwk.x!=='string'||typeof jwk.y!=='string')return false
  const claims=decodeJwtObject(parts[1])
  const iat=claims.iat
  if(typeof iat!=='number'||!Number.isInteger(iat)||
   Math.abs(nowMs-iat*1000)>300000)return false
  const rawDigest=createHash('sha256').update(raw).digest()
  if(typeof claims.request_body_sha256!=='string'||!/^[a-f0-9]{64}$/.test(claims.request_body_sha256))
   return false
  const advertisedDigest=Buffer.from(claims.request_body_sha256,'hex')
  if(!timingSafeEqual(rawDigest,advertisedDigest))return false
  const publicKey=createPublicKey({key:{kty:'EC',crv:'P-256',x:jwk.x,y:jwk.y},format:'jwk'})
  const signature=Buffer.from(parts[2],'base64url')
  if(signature.length!==64)return false
  return cryptoVerify('sha256',Buffer.from(parts[0]+'.'+parts[1]),
   {key:publicKey,dsaEncoding:'ieee-p1363'},signature)
 }catch{return false}
}
