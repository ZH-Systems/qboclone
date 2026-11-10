import {describe,expect,it} from 'vitest'
import {suggestReceiptFields} from './automationRoutes.js'
describe('unverified receipt OCR hints',()=>{
 it('recognizes labeled totals without claiming verification',()=>{
  const fields=suggestReceiptFields('Local Cafe\nCoffee\nHST 0.65\nTOTAL $5.65')
  expect(fields.total_candidate).toBe('5.65')
  expect(fields.vendor_candidate).toBe('Local Cafe')
  expect(fields.requires_user_review).toBe(true)
  expect(fields.confidence).toBe('unverified')
 })
 it('does not invent missing totals or dates',()=>{
  const fields=suggestReceiptFields('Receipt number 1234\nThank you')
  expect(fields.total_candidate).toBeNull()
  expect(fields.date_candidate).toBeNull()
 })
})
