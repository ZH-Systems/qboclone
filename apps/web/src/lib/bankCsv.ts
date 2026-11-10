/** RFC 4180-style CSV parsing with escaped quotes; avoids naive comma splitting.
 * Expected header: date,description,amount[,reference].
 * Imports are staged with stable 1-based row indexes, including repeated amounts.
 */
export type BankCsvRow = {
  line_number: number
  date: string
  description: string
  amount: string
  reference: string | null
}
export function parseSignedMoney(value: string): string {
  const clean = value.trim()
  const match = /^(-?)(0|[1-9]\d*)(?:\.(\d{1,2}))?$/.exec(clean)
  if (!match) throw new Error('Bank amounts must be signed CAD amounts with up to two decimals.')
  const dollars = Number(match[2])
  const cents = dollars * 100 + Number((match[3] || '').padEnd(2, '0'))
  if (!Number.isSafeInteger(cents)) throw new Error('Bank amount is too large.')
  return (match[1] === '-' ? '-' : '') + (cents / 100).toFixed(2)
}
function decodeCsv(text: string): string[][] {
  const records: string[][] = []
  let record: string[] = []
  let field = ''
  let quoted = false
  let afterQuote = false
  const normalized = text.replace(/^\uFEFF/, '')
  for (let i = 0; i < normalized.length; i++) {
    const ch = normalized[i]
    if (quoted) {
      if (ch === '"' && normalized[i+1] === '"') { field += '"'; i++ }
      else if (ch === '"') { quoted = false; afterQuote = true }
      else field += ch
      continue
    }
    if (ch === '"') {
      if (field !== '' || afterQuote) throw new Error('Malformed CSV quote.')
      quoted = true
    } else if (ch === ',') {
      record.push(field); field = ''; afterQuote = false
    } else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && normalized[i+1] === '\n') i++
      record.push(field); field = ''; afterQuote = false
      if (record.some(x => x.length)) records.push(record)
      record = []
    } else {
      if (afterQuote && ch.trim()) throw new Error('Unexpected character after CSV quote.')
      if (afterQuote && !ch.trim()) continue
      field += ch
    }
  }
  if (quoted) throw new Error('Unterminated quoted CSV field.')
  record.push(field)
  if (record.some(x => x.length)) records.push(record)
  return records
}
export function parseBankCsv(csv: string): BankCsvRow[] {
  const records = decodeCsv(csv)
  if (records.length < 2) throw new Error('CSV must contain a header and transaction rows.')
  const headers = records[0].map(h => h.trim().toLowerCase())
  const indexes = ['date','description','amount'].map(n => headers.indexOf(n))
  if (indexes.some(n => n === -1)) throw new Error('CSV must contain date, description and amount columns.')
  const optionalReference = headers.indexOf('reference')
  if (new Set(headers).size !== headers.length) throw new Error('Duplicate CSV headers.')
  if (records.length > 100001) throw new Error('Import exceeds 100,000 rows.')
  return records.slice(1).map((cells, i) => {
    if (cells.length !== headers.length) throw new Error('Wrong CSV field count on row ' + (i+2))
    const date = cells[indexes[0]].trim()
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || Number.isNaN(Date.parse(date + 'T00:00:00Z')))
      throw new Error('Invalid ISO date on row ' + (i+2))
    const description = cells[indexes[1]].trim()
    if (description.length < 1 || description.length > 500) throw new Error('Invalid description on row ' + (i+2))
    const amount = parseSignedMoney(cells[indexes[2]])
    if (Number(amount) === 0) throw new Error('Zero amount on row ' + (i+2))
    const reference = optionalReference === -1 ? null : cells[optionalReference].trim() || null
    if (reference && reference.length > 200) throw new Error('Reference too long on row ' + (i+2))
    return {line_number:i+1,date,description,amount,reference}
  })
}
