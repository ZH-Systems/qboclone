import {describe,it,expect} from 'vitest'
import type {SupabaseClient} from '@supabase/supabase-js'
import {bearerToken,csvEscape,requireOrganizationId,EXPORT_TABLES,buildOrganizationExport} from './operations.js'
import {invitationUrl} from './email.js'
describe('milestone 5 security boundaries',()=>{
 it('rejects invalid bearer tokens',()=>{
  expect(()=>bearerToken('Basic secret')).toThrow()
  expect(bearerToken('Bearer demo-token')).toBe('demo-token')
 })
 it('requires strict UUIDs',()=>{
  expect(()=>requireOrganizationId('arbitrary-org')).toThrow()
  expect(requireOrganizationId('11111111-1111-4111-8111-111111111111')).toContain('1111')
 })
 it('escapes formula injection and CSV punctuation',()=>{
  expect(csvEscape('=SUM(1,1)')).toBe("\"'=SUM(1,1)\"")
  expect(csvEscape('name,other')).toBe('"name,other"')
 })
 it('keeps invitation token in URL fragment, not request path',()=>{
  const link=invitationUrl('https://bookkeeper.example','a'.repeat(64))
  expect(new URL(link).pathname).toBe('/')
  expect(new URL(link).hash).toBe('#invite='+'a'.repeat(64))
 })
 it('exports only organization-scoped tables using explicit field allowlists',async()=>{
  const calls:{table:string;field:string;org:string;order:string}[]=[]
  let tableName=''
  const mock={from(table:string){tableName=table;return {select(_columns:string){return {
   eq(field:string,org:string){return {order(order:string){return {
    range(_offset:number,_last:number){calls.push({table:tableName,field,org,order});return Promise.resolve({data:[],error:null})}
   }}}}
  }}}}} as unknown as SupabaseClient
  const org='11111111-1111-4111-8111-111111111111'
  const result=await buildOrganizationExport(mock,org)
  expect(result.tables).toHaveLength(EXPORT_TABLES.length)
  expect(calls).toHaveLength(EXPORT_TABLES.length)
  expect(calls.every(call=>call.org===org)).toBe(true)
  expect(calls.find(call=>call.table==='organizations')?.field).toBe('id')
  expect(calls.filter(call=>call.table!=='organizations').every(call=>call.field==='organization_id')).toBe(true)
 })
 it('rejects partial exports instead of silently truncating financial tables',async()=>{
  const mock={from(){return {select(){return {eq(){return {order(){return {
   range(){return Promise.resolve({data:[{id:1},{id:2}],error:null})}
  }}}}}}}}} as unknown as SupabaseClient
  await expect(buildOrganizationExport(mock,'11111111-1111-4111-8111-111111111111',1))
   .rejects.toThrow('Export row limit exceeded')
 })
 it('never selects the invitation token hash in tenant export',()=>{
  expect(EXPORT_TABLES.some(t=>t.columns.includes('token_hash'))).toBe(false)
 })
})
