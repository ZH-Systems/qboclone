export type MailConfig={apiKey:string;from:string;webOrigin:string}
export function invitationUrl(webOrigin:string,token:string){
 if(!/^[a-f0-9]{64}$/.test(token))throw new Error('Invalid invitation token')
 return webOrigin+'/#invite='+token
}
export async function sendInvitationEmail(
 config:MailConfig,to:string,organizationName:string,role:string,token:string
):Promise<void>{
 if(!config.apiKey||!config.from)throw new Error('Email provider is not configured')
 const link=invitationUrl(config.webOrigin,token)
 const body={
  from:config.from,to:[to],subject:'Invitation to '+organizationName,
  text:'You have been invited to '+organizationName+' as '+role+'.\n\n'+
    'Open the following secure invitation link to join with your verified email. '+
    'This link expires after seven days.\n\n'+link+'\n\n'+
    'If you were not expecting this invitation, you may ignore this email.'
 }
 const response=await fetch('https://api.resend.com/emails',{
  method:'POST',headers:{Authorization:'Bearer '+config.apiKey,'Content-Type':'application/json'},
  body:JSON.stringify(body),signal:AbortSignal.timeout(10000)
 })
 if(!response.ok)throw new Error('Invitation email delivery provider rejected the request')
}
