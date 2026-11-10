import { describe, expect, it } from 'vitest'
import { totalLines, validRate, type Row } from './AccountingWorkspace'

const line = (overrides: Partial<Row> = {}): Row => ({
  description: 'Accounting service',
  quantity: '1',
  unit_price: '100.00',
  tax_rate_bps: '1300',
  ...overrides
})

describe('financial document input validation', () => {
  it('calculates Canadian 13 percent tax from user-provided basis points', () => {
    expect(totalLines([line()])).toBe(11300)
  })
  it('handles quantities with three decimal places', () => {
    expect(totalLines([line({ quantity: '0.250', unit_price: '100.00', tax_rate_bps: '0' })])).toBe(2500)
  })
  it('sums multiple lines including tax', () => {
    expect(totalLines([line(), line({unit_price: '50.00',tax_rate_bps:'0'})])).toBe(16300)
  })
  it('rejects negative amounts, excessive tax rates and fractional cents', () => {
    expect(() => totalLines([line({unit_price:'-1.00'})])).toThrow()
    expect(() => totalLines([line({unit_price:'1.001'})])).toThrow()
    expect(() => validRate('2501')).toThrow()
    expect(() => validRate('13.5')).toThrow()
  })
  it('rejects invalid quantities and supports zero tax', () => {
    expect(() => totalLines([line({quantity:'0'})])).toThrow()
    expect(() => totalLines([line({quantity:'1.0001'})])).toThrow()
    expect(totalLines([line({tax_rate_bps:'0'})])).toBe(10000)
  })
})
