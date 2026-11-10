import {describe,it,expect} from 'vitest'
import {bearerToken,csvEscape,requireOrganizationId,EXPORT_TABLES} from './operations.js'
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
 it('never selects the invitation token hash in tenant export',()=>{
  expect(EXPORT_TABLES.some(t=>t.columns.includes('token_hash'))).toBe(false)
 })
})
