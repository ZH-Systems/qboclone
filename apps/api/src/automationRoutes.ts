import type {FastifyInstance,FastifyReply} from 'fastify'
import type {SupabaseClient} from '@supabase/supabase-js'
import {createHash,randomUUID,timingSafeEqual} from 'node:crypto'
import {createInvoicePdf,type InvoiceInfo} from './invoicePdf.js'
import {bearerToken,requireOrganizationId,requireOrganizationRole,scopedSupabase} from './operations.js'
import type {ServerConfig} from './config.js'

const bucket='receipts'
const contentTypes=['application/pdf','image/png','image/jpeg'] as const
type AllowedType=typeof contentTypes[number]
const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
type DocumentRow={id:string;document_number:string;organization_id:string;contact_id:string;
 status:string;document_type:string;issue_date:string;due_date:string;memo:string;
 subtotal:number;tax_total:number;total:number}
function bodyObject(value:unknown):Record<string,unknown>{
 if(!Buffer.isBuffer(value))throw new Error('JSON body required')
 const data:unknown=JSON.parse(value.toString('utf8'))
 if(data===null||typeof data!=='object'||Array.isArray(data))throw new Error('Expected JSON object')
 return data as Record<string,unknown>
}
function routeFailure(reply:FastifyReply,e:unknown){
 const message=e instanceof Error?e.message:'Unexpected request failure'
 if(/(Not authorized|role required)/i.test(message))return reply.code(403).send({error:'Not authorized for organization'})
 if(/(Invalid|required|not found|Select|must|only)/i.test(message))return reply.code(400).send({error:message})
 return reply.code(500).send({error:'Integration request failed'})
}
function validMagic(buffer:Buffer,mime:AllowedType):boolean{
 if(mime==='application/pdf')return buffer.subarray(0,5).toString('ascii')==='%PDF-'
 if(mime==='image/png')return buffer.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10]))
 return buffer.length>3&&buffer[0]===255&&buffer[1]===216&&buffer[2]===255
}
function paramsObject(params:unknown):Record<string,string>{
 return params as Record<string,string>
}
function isUuid(v:unknown):v is string{return typeof v==='string'&&uuid.test(v)}
function filename(value:unknown):string{
 const name=typeof value==='string'?value.trim():''
 if(name.length<1||name.length>255||/[\r\n]/.test(name))throw new Error('Invalid original filename')
 return name.replace(/[\\/]/g,'_')
}
async function pdfDetails(db:SupabaseClient,org:string,documentId:string):Promise<InvoiceInfo>{
 const [docResult,orgResult]=await Promise.all([
  db.from('financial_documents').select('id,document_number,organization_id,contact_id,status,document_type,issue_date,due_date,memo,subtotal,tax_total,total')
   .eq('organization_id',org).eq('id',documentId).maybeSingle(),
  db.from('organizations').select('name,base_currency').eq('id',org).maybeSingle()
 ])
 if(docResult.error||orgResult.error||!docResult.data||!orgResult.data)throw new Error('Invoice or business not found')
 const doc=docResult.data as DocumentRow
 if(doc.document_type!=='invoice'||doc.status!=='posted')throw new Error('Only posted invoices can be rendered')
 const [contact,lines]=await Promise.all([
  db.from('contacts').select('display_name,email').eq('organization_id',org).eq('id',doc.contact_id).maybeSingle(),
  db.from('financial_document_lines').select('description,quantity,unit_price,amount,tax_amount')
   .eq('organization_id',org).eq('document_id',doc.id).order('position')
 ])
 if(contact.error||lines.error||!contact.data)throw new Error('Invoice components not found')
 return {
  number:doc.document_number,issueDate:doc.issue_date,dueDate:doc.due_date,
  memo:doc.memo||'',subtotal:Number(doc.subtotal),taxTotal:Number(doc.tax_total),
  total:Number(doc.total),currency:orgResult.data.base_currency,
  organization:orgResult.data.name,customer:contact.data.display_name,
  customerEmail:contact.data.email,
  lines:(lines.data||[]).map(row=>({
    description:row.description,quantity:Number(row.quantity),unitPrice:Number(row.unit_price),
    amount:Number(row.amount),taxAmount:Number(row.tax_amount)
  }))
 }
}
export function suggestReceiptFields(text:string):Record<string,unknown>{
 const lines=text.split(/\r?\n/).map(l=>l.trim()).filter(Boolean)
 const totalPattern=/(?:^|\b)(?:grand\s+total|amount\s+due|total)\s*[:$\s]+(?:CAD\s*)?\$?\s*([0-9][0-9,]*\.\d{2})\b/i
 const matches=lines.map(l=>totalPattern.exec(l)).filter((m):m is RegExpExecArray=>!!m)
 const parsed=matches.length?matches[matches.length-1][1].replace(/,/g,''):null
 const vendor=lines.find(l=>/[a-z]/i.test(l)&&!/(receipt|invoice|date|tax|total|hst|gst)/i.test(l))||null
 return {vendor_candidate:vendor?.slice(0,150)||null,total_candidate:parsed,
  date_candidate:null,confidence:'unverified',requires_user_review:true}
}
async function visionExtract(apiKey:string,mime:AllowedType,bytes:Buffer):Promise<string>{
 const pdf=mime==='application/pdf'
 const data=pdf?{requests:[{inputConfig:{content:bytes.toString('base64'),mimeType:mime},
  features:[{type:'DOCUMENT_TEXT_DETECTION'}]}]}:
  {requests:[{image:{content:bytes.toString('base64')},features:[{type:'DOCUMENT_TEXT_DETECTION'}]}]}
 const endpoint=pdf?'https://vision.googleapis.com/v1/files:annotate':'https://vision.googleapis.com/v1/images:annotate'
 const response=await fetch(endpoint,{method:'POST',headers:{'Content-Type':'application/json','X-goog-api-key':apiKey},
  body:JSON.stringify(data),signal:AbortSignal.timeout(30000)})
 if(!response.ok)throw new Error('OCR provider request failed')
 const result=await response.json() as {responses?:Array<{
  fullTextAnnotation?:{text?:string};responses?:Array<{fullTextAnnotation?:{text?:string}}> }>}
 const text=pdf?(result.responses?.[0]?.responses||[]).map(p=>p.fullTextAnnotation?.text||'').join('\n'):
  result.responses?.[0]?.fullTextAnnotation?.text||''
 return text.slice(0,20000)
}
export async function registerAutomationRoutes(app:FastifyInstance,db:SupabaseClient,config:ServerConfig){
 async function authenticated(header:string|undefined,org:string,allowedRoles:string[]){
  const token=bearerToken(header)
  const {data,error}=await db.auth.getUser(token)
  if(error||!data.user)throw new Error('Invalid authenticated session')
  await requireOrganizationRole(db,data.user.id,org,allowedRoles)
  return {token,user:data.user.id}
 }
 app.post('/automation/recurring/run',{config:{rateLimit:{max:10,timeWindow:'1 minute'}}},async(req,reply)=>{
  const secret=req.headers['x-worker-secret']
  if(!config.workerSecret||typeof secret!=='string'){
   return reply.code(401).send({error:'Worker credentials required'})
  }
  const a=Buffer.from(secret),b=Buffer.from(config.workerSecret)
  if(a.length!==b.length||!timingSafeEqual(a,b))return reply.code(401).send({error:'Invalid worker credential'})
  try{
   const {data,error}=await db.rpc('run_due_recurring_documents',{
    p_as_of:new Date().toISOString().slice(0,10),p_limit:100})
   if(error)throw error
   return data
  }catch(e){req.log.error(e);return reply.code(500).send({error:'Scheduler failed'})}
 })
 app.post('/automation/reminders/run',{config:{rateLimit:{max:4,timeWindow:'1 minute'}}},async(req,reply)=>{
  const provided=req.headers['x-worker-secret']
  if(!config.workerSecret||typeof provided!=='string')
   return reply.code(401).send({error:'Worker credentials required'})
  const a=Buffer.from(provided),b=Buffer.from(config.workerSecret)
  if(a.length!==b.length||!timingSafeEqual(a,b))
   return reply.code(401).send({error:'Invalid worker credential'})
  if(!config.emailApiKey||!config.emailFrom)
   return reply.code(503).send({error:'Invitation email provider is not configured'})
  const {data:claims,error}=await db.rpc('claim_due_invoice_reminders',{p_limit:20})
  if(error){req.log.error(error);return reply.code(500).send({error:'Reminder claim failed'})}
  let sent=0,failed=0
  for(const claim of (claims||[]) as {organization_id:string;invoice_id:string;contact_email:string;
   invoice_number:string;organization_name:string}[]){
   let successful=false
   let messageId:string|null=null
   try{
    const details=await pdfDetails(db,claim.organization_id,claim.invoice_id)
    if(details.customerEmail?.toLowerCase()!==claim.contact_email.toLowerCase())
     throw new Error('Customer email changed after reminder claim')
    const pdf=await createInvoicePdf(details)
    const response=await fetch('https://api.resend.com/emails',{
     method:'POST',headers:{Authorization:'Bearer '+config.emailApiKey,'Content-Type':'application/json'},
     body:JSON.stringify({from:config.emailFrom,to:[claim.contact_email],
      subject:'Payment reminder: '+claim.invoice_number,
      text:'The attached invoice is overdue. If payment has already been made, please disregard this reminder.',
      attachments:[{filename:'invoice-'+claim.invoice_number+'.pdf',
       content:Buffer.from(pdf).toString('base64')}]}),
     signal:AbortSignal.timeout(12000)})
    const body=await response.json().catch(()=>({})) as {id?:string}
    successful=response.ok
    messageId=body.id||null
    if(!response.ok)throw new Error('Email provider rejected reminder')
    sent++
   }catch(e){req.log.error({invoiceId:claim.invoice_id,error:e},'Automatic reminder failed');failed++}
   const {error:finishError}=await db.rpc('finish_invoice_reminder',{
    p_org:claim.organization_id,p_invoice:claim.invoice_id,
    p_succeeded:successful,p_provider_id:messageId})
   if(finishError)req.log.error({invoiceId:claim.invoice_id,error:finishError},
    'Reminder delivery state could not be persisted')
  }
  return {claimed:(claims||[]).length,sent,failed}
 })
 app.post('/invoices/:id/pdf',async(req,reply)=>{
  try{
   const id=paramsObject(req.params).id
   if(!isUuid(id))throw new Error('Invalid invoice identifier')
   const org=requireOrganizationId(bodyObject(req.body).organizationId)
   await authenticated(req.headers.authorization,org,['owner','administrator','accountant','bookkeeper','viewer'])
   const document=await pdfDetails(db,org,id)
   const pdf=await createInvoicePdf(document)
   return reply.header('Content-Type','application/pdf').header('Cache-Control','private,no-store')
    .header('Content-Disposition','attachment; filename="invoice-'+document.number+'.pdf"').send(Buffer.from(pdf))
  }catch(e){return routeFailure(reply,e)}
 })
 app.post('/invoices/:id/send',{config:{rateLimit:{max:15,timeWindow:'1 hour'}}},async(req,reply)=>{
  try{
   const id=paramsObject(req.params).id
   if(!isUuid(id))throw new Error('Invalid invoice identifier')
   const data=bodyObject(req.body)
   const org=requireOrganizationId(data.organizationId)
   const kind=data.kind==='payment_reminder'?'payment_reminder':'invoice'
   const {token}=await authenticated(req.headers.authorization,org,
    ['owner','administrator','accountant','bookkeeper'])
   if(!config.emailApiKey||!config.emailFrom)throw new Error('Email integration is not configured')
   const doc=await pdfDetails(db,org,id)
   if(!doc.customerEmail)throw new Error('Invoice customer has no email address')
   if(kind==='payment_reminder'){
    const scoped=scopedSupabase(config.supabaseUrl,config.serviceRoleKey,token)
    const {data:balance,error}=await scoped.rpc('document_outstanding',{
     p_organization_id:org,p_document_id:id})
    if(error||Number(balance)<=0||doc.dueDate>=new Date().toISOString().slice(0,10))
     throw new Error('Reminders require an overdue invoice with a positive outstanding balance')
   }
   const pdf=await createInvoicePdf(doc)
   const subject=(kind==='payment_reminder'?'Payment reminder: ':'Invoice ')+doc.number
   const message={from:config.emailFrom,to:[doc.customerEmail],subject,
    text:'Please find the invoice attached. Contact '+doc.organization+' with any questions.',
    attachments:[{filename:'invoice-'+doc.number+'.pdf',content:Buffer.from(pdf).toString('base64')}]}
   const response=await fetch('https://api.resend.com/emails',{
    method:'POST',headers:{Authorization:'Bearer '+config.emailApiKey,'Content-Type':'application/json'},
    body:JSON.stringify(message),signal:AbortSignal.timeout(12000)})
   const body=await response.json().catch(()=>({})) as {id?:string}
   const scoped=scopedSupabase(config.supabaseUrl,config.serviceRoleKey,token)
   const {error:logError}=await scoped.rpc('record_document_delivery',{
    p_org:org,p_document:id,p_email:doc.customerEmail,p_kind:kind,
    p_status:response.ok?'sent':'failed',p_message_id:body.id||null})
   if(logError)req.log.error({error:logError.message},'Invoice delivery audit failed')
   if(!response.ok)throw new Error('Email provider rejected delivery')
   return {submitted:true,provider_message_id:body.id||null}
  }catch(e){return routeFailure(reply,e)}
 })
 for(const mime of contentTypes){
  app.addContentTypeParser(mime,{parseAs:'buffer',bodyLimit:8388608},(_req,body,done)=>done(null,body))
 }
 app.post('/organizations/:org/receipts',{config:{rateLimit:{max:30,timeWindow:'1 hour'}},
  bodyLimit:8388608},async(req,reply)=>{
  try{
   const org=requireOrganizationId(paramsObject(req.params).org)
   const {token}=await authenticated(req.headers.authorization,org,
    ['owner','administrator','accountant','bookkeeper'])
   const mime=req.headers['content-type']?.split(';')[0].trim()
   if(!contentTypes.includes(mime as AllowedType)||!Buffer.isBuffer(req.body))
    throw new Error('Invalid receipt content type')
   const bytes=req.body as Buffer
   if(bytes.length<1||bytes.length>8388608||!validMagic(bytes,mime as AllowedType))
    throw new Error('Invalid receipt file signature or size')
   const name=filename(req.headers['x-original-filename'])
   const id=randomUUID()
   const path='organizations/'+org+'/'+id
   const {error:uploadError}=await db.storage.from(bucket).upload(path,bytes,{
    contentType:mime,upsert:false,cacheControl:'private'})
   if(uploadError)throw new Error('Private receipt storage upload failed')
   const scoped=scopedSupabase(config.supabaseUrl,config.serviceRoleKey,token)
   const {error}=await scoped.rpc('register_receipt_document',{
    p_org:org,p_receipt_id:id,p_path:path,p_filename:name,p_mime:mime,
    p_sha256:createHash('sha256').update(bytes).digest('hex'),p_size:bytes.length})
   if(error){await db.storage.from(bucket).remove([path]);throw new Error(error.message)}
   return {id,mime_type:mime,bytes:bytes.length}
  }catch(e){return routeFailure(reply,e)}
 })
 app.post('/organizations/:org/receipts/:id/open',async(req,reply)=>{
  try{
   const route=paramsObject(req.params),org=requireOrganizationId(route.org)
   if(!isUuid(route.id))throw new Error('Invalid receipt identifier')
   await authenticated(req.headers.authorization,org,
    ['owner','administrator','accountant','bookkeeper','viewer'])
   const {data,error}=await db.from('receipt_documents').select('storage_path')
    .eq('organization_id',org).eq('id',route.id).maybeSingle()
   if(error||!data)throw new Error('Receipt not found')
   const {data:link,error:linkError}=await db.storage.from(bucket)
    .createSignedUrl(data.storage_path,60)
   if(linkError||!link)throw new Error('Receipt preview unavailable')
   return {url:link.signedUrl,expires_in_seconds:60}
  }catch(e){return routeFailure(reply,e)}
 })
 app.post('/organizations/:org/receipts/:id/ocr',{
  config:{rateLimit:{max:12,timeWindow:'1 hour'}}},async(req,reply)=>{
  try{
   const route=paramsObject(req.params),org=requireOrganizationId(route.org)
   if(!isUuid(route.id))throw new Error('Invalid receipt identifier')
   await authenticated(req.headers.authorization,org,
    ['owner','administrator','accountant','bookkeeper'])
   if(!config.googleVisionApiKey)throw new Error('OCR provider is not configured')
   if(req.headers['x-external-ocr-consent']!=='true')
    throw new Error('External OCR consent is required')
   const {data:receipt,error}=await db.from('receipt_documents')
    .select('storage_path,mime_type,extraction_status,extraction_data').eq('organization_id',org).eq('id',route.id).maybeSingle()
   if(error||!receipt)throw new Error('Receipt not found')
   const {data:blob,error:downloadError}=await db.storage.from(bucket).download(receipt.storage_path)
   if(downloadError||!blob)throw new Error('Receipt could not be read from private storage')
   if(receipt.extraction_status==='completed'){
    return {receipt_id:route.id,...(receipt.extraction_data as Record<string,unknown>),cached:true}
   }
   const bytes=Buffer.from(await blob.arrayBuffer())
   const {error:reserveError}=await db.rpc('begin_receipt_ocr',{p_org:org,p_receipt:route.id})
   if(reserveError)throw new Error(reserveError.message)
   let result:Record<string,unknown>
   try{
    const ocr=await visionExtract(config.googleVisionApiKey,receipt.mime_type as AllowedType,bytes)
    const suggestions=suggestReceiptFields(ocr)
    result={text:ocr,suggestions,provider:'google_cloud_vision',human_verified:false}
    const {error:saveError}=await db.rpc('save_receipt_ocr_result',{
     p_org:org,p_receipt:route.id,p_status:'completed',p_data:result})
    if(saveError)throw saveError
   }catch(providerError){
    const {error:failError}=await db.rpc('save_receipt_ocr_result',{
     p_org:org,p_receipt:route.id,p_status:'failed',
     p_data:{message:'OCR provider request failed. Retry after verifying the integration.'}})
    if(failError)req.log.error({error:failError.message},'Could not release OCR reservation')
    throw providerError
   }
   return {receipt_id:route.id,...result}
  }catch(e){return routeFailure(reply,e)}
 })
}
