import {describe,it,expect} from 'vitest'
import {parseCsvRecords,previewContacts} from './importCsv'
describe('contact CSV import',()=>{
 it('parses quoted names and embedded commas',()=>{
  expect(previewContacts('Name,Email\n"Smith, Jane",Jane@example.com\n',
   'Name','Email').rows).toEqual([{name:'Smith, Jane',email:'jane@example.com'}])
 })
 it('rejects unmatched mapping and malformed lines',()=>{
  expect(()=>previewContacts('Name,Email\nAlpha,a@example.com','Missing','Email')).toThrow()
  expect(()=>parseCsvRecords('Name\n"unfinished')).toThrow()
 })
 it('does not invent email addresses',()=>{
  expect(previewContacts('Name\nExample Business','Name','').rows[0].email).toBeNull()
 })
})
