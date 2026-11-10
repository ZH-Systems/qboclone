import {describe,expect,it} from 'vitest'
import {PDFDocument} from 'pdf-lib'
import {createInvoicePdf} from './invoicePdf.js'
describe('invoice PDF rendering',()=>{
 it('creates a valid multi-page PDF using persisted document snapshots',async()=>{
  const bytes=await createInvoicePdf({
   number:'INV-001',issueDate:'2026-11-10',dueDate:'2026-11-24',
   memo:'Monthly consulting services',subtotal:100,taxTotal:13,total:113,
   currency:'CAD',organization:'Test Business',customer:'Example Buyer',
   customerEmail:'example@example.invalid',
   lines:Array.from({length:90},(_,i)=>({
    description:'Professional consulting service '+i,quantity:1,
    unitPrice:1,taxAmount:0,amount:1
   }))
  })
  expect(Buffer.from(bytes).subarray(0,5).toString()).toBe('%PDF-')
  const pdf=await PDFDocument.load(bytes)
  expect(pdf.getPageCount()).toBeGreaterThan(1)
 })
})
