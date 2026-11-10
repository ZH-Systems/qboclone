export type ServerConfig={
  supabaseUrl:string; serviceRoleKey:string; stripeKey:string;
  webhookSecret:string; webOrigin:string; port:number;
  emailApiKey:string|null; emailFrom:string|null;
  trustedProxyCidrs:string[]|false;
  googleVisionApiKey:string|null; workerSecret:string|null;
  plaidClientId:string|null;plaidSecret:string|null;plaidEnv:'sandbox'|'development'|'production';
  bankTokenEncryptionKey:string|null;qboClientId:string|null;qboClientSecret:string|null;
  qboRedirectUri:string|null;qboSandbox:boolean
}
export function readConfig(env:NodeJS.ProcessEnv=process.env):ServerConfig{
  const required=(key:string)=>{const value=env[key]?.trim();if(!value)throw new Error('Missing server environment variable: '+key);return value}
  const port=Number(env.PORT||3000)
  if(!Number.isInteger(port)||port<1||port>65535)throw new Error('Invalid PORT')
  const origin=required('WEB_APP_ORIGIN')
  const parsed=new URL(origin)
  if(parsed.origin!==origin||!['https:','http:'].includes(parsed.protocol))
    throw new Error('WEB_APP_ORIGIN must be a single web origin without a path')
  if(parsed.protocol!=='https:'&&!['localhost','127.0.0.1'].includes(parsed.hostname))
    throw new Error('Remote WEB_APP_ORIGIN must use HTTPS')
  return {supabaseUrl:required('SUPABASE_URL'),serviceRoleKey:required('SUPABASE_SERVICE_ROLE_KEY'),
    stripeKey:required('STRIPE_SECRET_KEY'),webhookSecret:required('STRIPE_WEBHOOK_SECRET'),
    webOrigin:origin,port,
    emailApiKey:env.RESEND_API_KEY?.trim()||null,emailFrom:env.INVITATION_EMAIL_FROM?.trim()||null,
    trustedProxyCidrs:env.TRUSTED_PROXY_CIDRS?.trim()?.split(',').map(x=>x.trim()).filter(Boolean)||false,
    googleVisionApiKey:env.GOOGLE_VISION_API_KEY?.trim()||null,
    workerSecret:env.AUTOMATION_WORKER_SECRET?.trim()||null,
    plaidClientId:env.PLAID_CLIENT_ID?.trim()||null,plaidSecret:env.PLAID_SECRET?.trim()||null,
    plaidEnv:env.PLAID_ENV==='production'?'production':env.PLAID_ENV==='development'?'development':'sandbox',
    bankTokenEncryptionKey:env.BANK_TOKEN_ENCRYPTION_KEY?.trim()||null,
    qboClientId:env.QBO_CLIENT_ID?.trim()||null,qboClientSecret:env.QBO_CLIENT_SECRET?.trim()||null,
    qboRedirectUri:env.QBO_REDIRECT_URI?.trim()||null,qboSandbox:env.QBO_SANDBOX!=='false'}
}
