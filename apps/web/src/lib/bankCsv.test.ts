import {describe,it,expect} from 'vitest'
import {parseBankCsv,parseSignedMoney} from './bankCsv'
describe('bank statement import',()=>{
 it('handles a standard bank statement',()=>{
  const lines=parseBankCsv('date,description,amount,reference\n2026-11-01,Sale,113.00,INV-1\n2026-11-02,Supplier,-24.50,BILL-1')
  expect(lines).toHaveLength(2)
  expect(lines[1]).toEqual({line_number:2,date:'2026-11-02',description:'Supplier',amount:'-24.50',reference:'BILL-1'})
 })
 it('supports escaped commas and quoted newlines',()=>{
  const lines=parseBankCsv('date,description,amount\n2026-11-01,"Groceries, supplies",5\n2026-11-02,"Two""quoted"" words",-1.23')
  expect(lines[0].description).toBe('Groceries, supplies')
  expect(lines[1].description).toContain('"quoted"')
 })
 it('rejects invalid amounts',()=>{
  expect(parseSignedMoney('-12.34')).toBe('-12.34')
  expect(()=>parseSignedMoney('12.345')).toThrow()
  expect(()=>parseBankCsv('date,description,amount\n2026-11-01,A,0')).toThrow()
 })
 it('rejects malformed records',()=>{
  expect(()=>parseBankCsv('date,description,amount\n2026-11-01,"Bad,2')).toThrow()
  expect(()=>parseBankCsv('date,description,amount\n2026-11-01,Bad')).toThrow()
 })
})
