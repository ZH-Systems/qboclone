import {PDFDocument,StandardFonts,rgb} from 'pdf-lib'

export type InvoiceInfo={
 number:string;issueDate:string;dueDate:string;memo:string;subtotal:number;
 taxTotal:number;total:number;currency:string;organization:string;
 customer:string;customerEmail:string|null;
 lines:{description:string;quantity:number;unitPrice:number;taxAmount:number;amount:number}[]
}
const printable=(value:string):string=>value.normalize('NFKD')
 .replace(/[\u0300-\u036f]/g,'').replace(/[^\x20-\x7E]/g,'?')
const dollars=(v:number):string=>new Intl.NumberFormat('en-CA',{
 minimumFractionDigits:2,maximumFractionDigits:2}).format(v)
function wordsByWidth(value:string,max:number,width:(s:string)=>number):string[]{
 const text=printable(value).replace(/\s+/g,' ').trim()
 const output:string[]=[];let line=''
 for(const raw of text.split(' ')){
  if(!raw)continue
  let word=raw
  while(width(word)>max){
   let k=1;while(k<word.length&&width(word.slice(0,k+1))<=max)k++
   const chunk=word.slice(0,k)
   if(line){output.push(line);line=''}
   output.push(chunk);word=word.slice(k)
  }
  const candidate=line?line+' '+word:word
  if(width(candidate)>max&&line){output.push(line);line=word}
  else line=candidate
 }
 if(line)output.push(line)
 return output.length?output:['']
}
/** Generates an invoice PDF from persisted, posted invoice snapshots, never browser inputs. */
export async function createInvoicePdf(info:InvoiceInfo):Promise<Uint8Array>{
 const pdf=await PDFDocument.create()
 const font=await pdf.embedFont(StandardFonts.Helvetica)
 const bold=await pdf.embedFont(StandardFonts.HelveticaBold)
 let page=pdf.addPage([612,792])
 let y=746
 const draw=(value:string,x:number,yAt:number,size=10,heavy=false)=>{
  page.drawText(printable(value),{x,y:yAt,size,font:heavy?bold:font,color:rgb(0.13,0.21,0.32)})
 }
 const nextPage=()=>{page=pdf.addPage([612,792]);y=745;
  draw(printable(info.organization),48,y,13,true);y-=32}
 const safe=(needed:number)=>{if(y-needed<72)nextPage()}
 draw(info.organization,48,y,20,true);y-=38
 draw('INVOICE '+info.number,48,y,16,true);y-=25
 draw('Issued: '+info.issueDate+'     Due: '+info.dueDate,48,y);y-=23
 draw('Bill to: '+info.customer,48,y,11,true);y-=18
 if(info.customerEmail){draw(info.customerEmail,48,y);y-=18}
 if(info.memo){for(const part of wordsByWidth(info.memo,490,s=>font.widthOfTextAtSize(s,10))){
  safe(20);draw(part,48,y);y-=16}}
 y-=18
 draw('Description',48,y,11,true);draw('Quantity',320,y,10,true)
 draw('Unit',410,y,10,true);draw('Line',515,y,10,true);y-=14
 page.drawLine({start:{x:48,y},end:{x:564,y},thickness:1,color:rgb(0.84,0.88,0.93)})
 y-=17
 for(const item of info.lines){
  const lines=wordsByWidth(item.description,255,s=>font.widthOfTextAtSize(s,9))
  safe(lines.length*14+14)
  for(let i=0;i<lines.length;i++){draw(lines[i],48,y,9)
   if(i===0){draw(String(item.quantity),320,y,9);draw(dollars(item.unitPrice),410,y,9);
    draw(dollars(item.amount+item.taxAmount),510,y,9)}
   y-=14}
  y-=9
 }
 safe(120);y-=13
 page.drawLine({start:{x:325,y},end:{x:565,y},thickness:1,color:rgb(0.84,0.88,0.93)})
 y-=23
 draw('Subtotal',360,y);draw(dollars(info.subtotal),503,y);y-=20
 draw('GST/HST or sales tax',360,y);draw(dollars(info.taxTotal),503,y);y-=24
 draw('TOTAL '+info.currency,360,y,12,true);draw(dollars(info.total),503,y,12,true)
 y-=42
 safe(55);draw('Accounting copy. Contact the issuer with any questions.',48,y,9)
 pdf.setTitle('Invoice '+printable(info.number))
 pdf.setAuthor(printable(info.organization))
 pdf.setCreationDate(new Date())
 return pdf.save()
}
