import {describe,it,expect} from 'vitest'
import {normalizeQbo,qboQuery} from './qboNormalize.js'
describe('QuickBooks migration normalization',()=>{
 it('preserves source entity and maps accounts without losing the original',()=>{
  const raw={Id:'12',Name:'Checking',AccountType:'Bank',AcctNum:'1010'}
  const mapped=normalizeQbo('Account',raw)
  expect(mapped?.record).toMatchObject({source_id:'12',code:'1010',type:'asset',raw})
 })
 it('maps invoice lines with explicit review-only tax classification',()=>{
  const mapped=normalizeQbo('Invoice',{Id:'9',CustomerRef:{value:'3'},TxnDate:'2026-11-01',
   DueDate:'2026-11-30',TotalAmt:113,Line:[{Description:'Work',
    Amount:100,SalesItemLineDetail:{UnitPrice:100,Qty:1}}]})
  expect(mapped?.record.contact_source_id).toBe('3')
  expect(mapped?.record.lines).toHaveLength(1)
  expect((mapped?.record.lines as Record<string,unknown>[])[0].tax_rate_bps).toBe(0)
 })
 it('does not discard historical journal lines and payment allocations',()=>{
  const raw={Id:'55',TxnDate:'2026-01-01',Line:[{Amount:50,PostingType:'Debit'}]}
  expect(normalizeQbo('JournalEntry',raw)?.record.raw).toBe(raw)
  expect(normalizeQbo('Payment',{Id:'p1',TxnDate:'2026-10-02',TotalAmt:50,
   Line:[{Amount:50,LinkedTxn:[{TxnId:'9'}]}]})?.record.allocations)
   .toEqual([{source_document_id:'9',amount:50}])
 })
 it('rejects unsupported dynamic type in source query',()=>{
  expect(()=>qboQuery('CompanyInfo' as never,1)).toThrow()
 })
})
