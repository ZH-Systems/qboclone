export type Account = { id: string; code: string; name: string; account_type: string; normal_balance: string }
export type JournalLine = { account_id: string; debit: string; credit: string }
export type Journal = { id: string; entry_date: string; memo: string; reference: string | null; created_at: string; journal_lines: { debit: number; credit: number; account_id: string }[] }

export function parseMoney(input: string): number {
  if (!/^(0|[1-9]\d*)(\.\d{1,2})?$/.test(input.trim())) throw new Error('Enter a non-negative amount with at most two decimal places.')
  const [whole, fraction = ''] = input.trim().split('.')
  const cents = Number(whole) * 100 + Number(fraction.padEnd(2, '0'))
  if (!Number.isSafeInteger(cents)) throw new Error('Amount is too large.')
  return cents
}
export function formatMoney(cents: number) {
  return new Intl.NumberFormat('en-CA', { style: 'currency', currency: 'CAD' }).format(cents / 100)
}
export function validateJournal(lines: JournalLine[]) {
  if (lines.length < 2) throw new Error('A journal requires at least two lines.')
  let debit = 0
  let credit = 0
  for (const line of lines) {
    if (!line.account_id) throw new Error('Select an account for every journal line.')
    const d = parseMoney(line.debit)
    const c = parseMoney(line.credit)
    if ((d > 0) === (c > 0)) throw new Error('Each journal line must contain either a debit or a credit.')
    debit += d
    credit += c
  }
  if (debit !== credit) throw new Error('Debits and credits must balance.')
  if (debit === 0) throw new Error('Journal amount must exceed zero.')
  return debit
}
export function asDecimal(input: string) {
  const cents = parseMoney(input)
  return (cents / 100).toFixed(2)
}
