export type ImportedContact={name:string;email:string|null}
export type ContactImportPreview={headers:string[];rows:ImportedContact[]}
export function parseCsvRecords(raw:string):string[][]{
 const source=raw.replace(/^\uFEFF/,'')
 const records:string[][]=[];let row:string[]=[];let cell=''
 let quote=false;let closed=false
 for(let i=0;i<source.length;i++){
  const ch=source[i]
  if(quote){
   if(ch==='"'&&source[i+1]==='"'){cell+='"';i++}
   else if(ch==='"'){quote=false;closed=true}
   else cell+=ch
  }else if(ch==='"'){
   if(cell||closed)throw new Error('Unexpected CSV quote')
   quote=true
  }else if(ch===','){
   row.push(cell);cell='';closed=false
  }else if(ch==='\n'||ch==='\r'){
   if(ch==='\r'&&source[i+1]==='\n')i++
   row.push(cell);if(row.some(x=>x.trim()))records.push(row)
   row=[];cell='';closed=false
  }else{
   if(closed&&ch.trim())throw new Error('Text after CSV closing quote')
   if(!closed)cell+=ch
  }
 }
 if(quote)throw new Error('Unterminated CSV quoted field')
 row.push(cell);if(row.some(x=>x.trim()))records.push(row)
 return records
}
/** Conservative QuickBooks/generic CSV mapping, no automatic identity merge. */
export function previewContacts(raw:string,nameHeader:string,emailHeader:string):ContactImportPreview{
 const records=parseCsvRecords(raw)
 if(records.length<2||records.length>5001)throw new Error('CSV must contain 1 to 5,000 contact rows')
 const headers=records[0].map(s=>s.trim())
 const nameIndex=headers.findIndex(h=>h.toLowerCase()===nameHeader.toLowerCase())
 const emailIndex=emailHeader?headers.findIndex(h=>h.toLowerCase()===emailHeader.toLowerCase()):-1
 if(nameIndex<0||(emailHeader&&emailIndex<0))throw new Error('Choose valid CSV column names')
 const rows=records.slice(1).map((fields,index)=>{
  if(fields.length!==headers.length)throw new Error('CSV column count mismatch at row '+(index+2))
  const name=fields[nameIndex].trim()
  const email=emailIndex>=0?fields[emailIndex].trim().toLowerCase():null
  if(!name||name.length>150)throw new Error('Invalid contact name at row '+(index+2))
  if(email&&(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)||email.length>255))
   throw new Error('Invalid email at row '+(index+2))
  return {name,email:email||null}
 })
 return {headers,rows}
}
