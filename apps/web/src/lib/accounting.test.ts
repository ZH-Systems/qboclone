import { describe, expect, it } from 'vitest'
import { parseMoney, validateJournal } from './accounting'

describe('financial input validation', () => {
  it('uses integer cents for amounts', () => { expect(parseMoney('12.34')).toBe(1234); expect(parseMoney('0.01')).toBe(1) })
  it('rejects invalid precision', () => expect(() => parseMoney('12.345')).toThrow())
  it('rejects invalid values', () => expect(() => parseMoney('-1')).toThrow())
  it('requires balanced journals', () => {
    expect(validateJournal([{ account_id: 'a', debit: '100.00', credit: '0' }, { account_id: 'b', debit: '0', credit: '100.00' }])).toBe(10000)
    expect(() => validateJournal([{ account_id: 'a', debit: '100.00', credit: '0' }, { account_id: 'b', debit: '0', credit: '99.99' }])).toThrow('balance')
  })
})
