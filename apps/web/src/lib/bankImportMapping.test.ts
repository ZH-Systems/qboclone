import {describe,it,expect} from 'vitest'
import {normalizeBankStatement} from './bankImportMapping'
const base={date:'Txn Date',description:'Narrative',amount:'',debit:'Withdrawal',
 credit:'Deposit',reference:'Reference',dateFormat:'dmy' as const}
describe('bank CSV mapping',()=>{
 it('normalizes debit/credit columns with manual DMY date format',()=>{
  const input='Txn Date,Narrative,Withdrawal,Deposit,Reference\n10/11/2026,"Bank fee, monthly",12.50,,FEE-1\n11/11/2026,Sale,,100.00,SALE-1'
  const normalized=normalizeBankStatement(input,base)
  expect(normalized).toContain('2026-11-10,"Bank fee, monthly",-12.50,FEE-1')
  expect(normalized).toContain('2026-11-11,Sale,100.00,SALE-1')
 })
 it('requires explicit date ordering and rejects impossible dates',()=>{
  expect(()=>normalizeBankStatement('Txn Date,Narrative,Withdrawal,Deposit,Reference\n31/02/2026,X,3,,',
   base)).toThrow('Impossible')
 })
 it('does not silently infer unknown columns',()=>{
  expect(()=>normalizeBankStatement('Date,Value\n2026-11-10,20',base)).toThrow('Missing mapped')
 })
})
