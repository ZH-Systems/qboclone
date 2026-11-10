import type {FastifyInstance} from 'fastify'
import type {SupabaseClient} from '@supabase/supabase-js'
import type {ServerConfig} from './config.js'

function requiredIdentity(header: string | undefined): string {
  const token = /^Bearer (\S+)$/.exec(header || '')?.[1]
  if (!token) throw new Error('Authentication required')
  return token
}
function bodyObject(body: unknown): Record<string,unknown> {
  if (!Buffer.isBuffer(body)) throw new Error('Invalid JSON payload')
  const object:unknown = JSON.parse(body.toString('utf8'))
  if (!object || typeof object !== 'object' || Array.isArray(object)) throw new Error('Invalid JSON payload')
  return object as Record<string,unknown>
}
function userError(reply: any,error: unknown) {
  const message=error instanceof Error?error.message:'Unexpected error'
  if (/authorization required|not authorized/i.test(message)) return reply.code(403).send({error:'Platform administrator access required'})
  if (/Authentication required/i.test(message)) return reply.code(401).send({error:'Authentication required'})
  if (/Business name|Valid owner email|Owner must|Invalid JSON/i.test(message)) return reply.code(400).send({error:message})
  return reply.code(500).send({error:'Platform administration request failed'})
}

export async function registerPlatformAdminRoutes(app:FastifyInstance,db:SupabaseClient,_config:ServerConfig) {
  async function actor(authorization: string|undefined):Promise<string> {
    const token=requiredIdentity(authorization)
    const {data:auth,error:authError}=await db.auth.getUser(token)
    if(authError || !auth.user || !auth.user.email_confirmed_at)
      throw new Error('Authentication required')
    const {data:enabled,error}=await db.rpc('platform_admin_status',{p_actor:auth.user.id})
    if(error)throw error
    if(enabled!==true)throw new Error('Platform administrator authorization required')
    return auth.user.id
  }
  app.get('/platform/admin/status',async(req,reply)=>{
    try { await actor(req.headers.authorization);return {isSuperAdmin:true} }
    catch(error) {
      if(error instanceof Error && /Authentication required/.test(error.message))
        return reply.code(401).send({isSuperAdmin:false})
      if(error instanceof Error && /authorization required/.test(error.message))
        return reply.code(403).send({isSuperAdmin:false})
      return userError(reply,error)
    }
  })
  app.get('/platform/organizations',async(req,reply)=>{
    try {
      const user=await actor(req.headers.authorization)
      const {data,error}=await db.rpc('platform_list_organizations',{p_actor:user})
      if(error)throw error
      return {organizations:data||[]}
    }catch(error){return userError(reply,error)}
  })
  app.post('/platform/organizations',{config:{rateLimit:{max:8,timeWindow:'1 hour'}}},async(req,reply)=>{
    try {
      const user=await actor(req.headers.authorization)
      const input=bodyObject(req.body)
      if(typeof input.name!=='string' || input.name.trim().length<2 || input.name.trim().length>150)
        throw new Error('Business name must contain 2 to 150 characters')
      if(typeof input.ownerEmail!=='string' || input.ownerEmail.trim().length>320 ||
         !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(input.ownerEmail.trim()))
        throw new Error('Valid owner email required')
      const {data,error}=await db.rpc('platform_provision_organization',{
        p_actor:user,p_name:input.name.trim(),p_owner_email:input.ownerEmail.trim().toLowerCase()
      })
      if(error)throw error
      return reply.code(201).send({organizationId:data})
    }catch(error){return userError(reply,error)}
  })
}
