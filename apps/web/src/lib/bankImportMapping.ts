import {parseCsvRecords} from './importCsv'
import {parseBankCsv} from './bankCsv'
export type BankColumnMap={
 date:string;description:string;amount:string;debit:string;credit:string;
 reference:string;dateFormat:'iso'|'mdy'|'dmy'
}
const escape=(s:string)=>/[",\r\n]/.test(s)?'"'+s.replace(/"/g,'""')+'"':s
function normalizeDate(s:string,format:BankColumnMap['dateFormat']):string{
 const raw=s.trim()
 let y:number,m:number,d:number
 if(format==='iso'){
  const match=/^(\d{4})[-/](\d{1,2})[-/](\d{1,2})$/.exec(raw)
  if(!match)throw new Error('Expected ISO YYYY-MM-DD dates')
  y=Number(match[1]);m=Number(match[2]);d=Number(match[3])
 }else{
  const match=/^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$/.exec(raw)
  if(!match)throw new Error('Expected four-digit year in bank statement date')
  y=Number(match[3])
  m=Number(format==='mdy'?match[1]:match[2])
  d=Number(format==='mdy'?match[2]:match[1])
 }
 const date=new Date(Date.UTC(y,m-1,d))
 if(date.getUTCFullYear()!==y||date.getUTCMonth()!==m-1||date.getUTCDate()!==d)
  throw new Error('Impossible calendar date in bank statement')
 return y.toString().padStart(4,'0')+'-'+String(m).padStart(2,'0')+'-'+String(d).padStart(2,'0')
}
function cents(value:string):number{
 let v=value.trim().replace(/\s|CAD|\$/gi,'')
 let negative=false
 if(/^\(.+\)$/.test(v)){negative=true;v=v.slice(1,-1)}
 if(v.startsWith('-')){negative=true;v=v.slice(1)}
 v=v.replace(/,/g,'')
 if(!/^\d+(?:\.\d{1,2})?$/.test(v))throw new Error('Invalid bank amount: '+value.slice(0,24))
 const [whole,part='']=v.split('.')
 const amount=Number(whole)*100+Number(part.padEnd(2,'0'))
 if(!Number.isSafeInteger(amount))throw new Error('Bank amount exceeds safe precision')
 return negative?-amount:amount
}
/** Maps explicitly chosen local bank CSV columns to the application's canonical import.
 * Does not guess ambiguous date formats or create ledger journal entries.
 */
export function normalizeBankStatement(raw:string,mapping:BankColumnMap):string{
 const rows=parseCsvRecords(raw)
 if(rows.length<2||rows.length>100001)throw new Error('Bank CSV must contain 1 to 100,000 rows')
 const headers=rows[0].map(x=>x.trim())
 if(new Set(headers.map(x=>x.toLowerCase())).size!==headers.length)throw new Error('Duplicate bank CSV headers')
 const col=(name:string,required:boolean)=>{
  const index=headers.findIndex(h=>h.toLowerCase()===name.trim().toLowerCase())
  if(required&&index<0)throw new Error('Missing mapped bank column: '+name)
  return index
 }
 const date=col(mapping.date,true),description=col(mapping.description,true)
 const amt=col(mapping.amount,false),debit=col(mapping.debit,false),credit=col(mapping.credit,false)
 const ref=col(mapping.reference,false)
 const split=!mapping.amount.trim()
 if(split&&(debit<0||credit<0))throw new Error('Choose signed Amount or separate Debit and Credit columns')
 if(!split&&amt<0)throw new Error('Choose a valid signed amount column')
 const output=['date,description,amount,reference']
 for(const [index,row] of rows.slice(1).entries()){
  if(row.length!==headers.length)throw new Error('Bank CSV column mismatch on row '+(index+2))
  const dateValue=normalizeDate(row[date],mapping.dateFormat)
  const text=row[description].trim()
  if(!text||text.length>500)throw new Error('Bank description is missing or too long on row '+(index+2))
  let n:number
  if(!split)n=cents(row[amt])
  else{
   const inValue=row[credit].trim()?cents(row[credit]):0
   const outValue=row[debit].trim()?cents(row[debit]):0
   if(inValue<0||outValue<0)throw new Error('Debit and credit columns must contain positive values')
   n=inValue-outValue
  }
  if(!n)throw new Error('Zero bank amount on row '+(index+2))
  const formatted=(n<0?'-':'')+(Math.abs(n)/100).toFixed(2)
  output.push([dateValue,text,formatted,ref>=0?row[ref].trim():''].map(escape).join(','))
 }
 const standardized=output.join('\n')
 parseBankCsv(standardized)
 return standardized
}
