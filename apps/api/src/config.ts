export type ServerConfig={
  supabaseUrl:string; serviceRoleKey:string; stripeKey:string;
  webhookSecret:string; webOrigin:string; port:number;
  emailApiKey:string|null; emailFrom:string|null;
  trustedProxyCidrs:string[]|false;
  googleVisionApiKey:string|null; workerSecret:string|null;
  plaidClientId:string|null;plaidSecret:string|null;plaidEnv:'sandbox'|'development'|'production';
  bankTokenEncryptionKey:string|null;qboClientId:string|null;qboClientSecret:string|null;
  qboRedirectUri:string|null;qboSandbox:boolean;
  deploymentEnv:'development'|'staging'|'production'
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
  const deploymentEnv=env.DEPLOYMENT_ENV||'development'
  if(!['development','staging','production'].includes(deploymentEnv))
    throw new Error('DEPLOYMENT_ENV must be development, staging or production')
  const supabaseUrl=required('SUPABASE_URL')
  const parsedSupabase=new URL(supabaseUrl)
  if(parsedSupabase.origin!==supabaseUrl||!['https:','http:'].includes(parsedSupabase.protocol))
    throw new Error('SUPABASE_URL must be an origin without path')
  const production=deploymentEnv==='production'
  if(production){
    if(parsedSupabase.protocol!=='https:')throw new Error('Production Supabase must use HTTPS')
    if(!/^sk_live_/.test(required('STRIPE_SECRET_KEY')))
      throw new Error('Production requires a live Stripe key')
    if(!/^whsec_/.test(required('STRIPE_WEBHOOK_SECRET')))
      throw new Error('Production requires a Stripe webhook signature secret')
    if(!env.TRUSTED_PROXY_CIDRS?.trim())
      throw new Error('Production must set TRUSTED_PROXY_CIDRS')
    if(!env.AUTOMATION_WORKER_SECRET||Buffer.byteLength(env.AUTOMATION_WORKER_SECRET,'utf8')<32)
      throw new Error('Production automation worker secret must be at least 32 bytes')
    if(env.BANK_TOKEN_ENCRYPTION_KEY&& !/^[a-f0-9]{64}$/i.test(env.BANK_TOKEN_ENCRYPTION_KEY))
      throw new Error('Invalid production provider-token encryption key')
    if(env.PLAID_CLIENT_ID||env.PLAID_SECRET){
      if(env.PLAID_ENV!=='production'||!env.PLAID_CLIENT_ID||!env.PLAID_SECRET||
        !env.BANK_TOKEN_ENCRYPTION_KEY)
        throw new Error('Production Plaid requires complete production credentials and encryption')
    }
    if(env.QBO_CLIENT_ID||env.QBO_CLIENT_SECRET){
      if(env.QBO_SANDBOX!=='false'||!env.QBO_CLIENT_ID||!env.QBO_CLIENT_SECRET||
        !env.QBO_REDIRECT_URI?.startsWith('https://')||!env.BANK_TOKEN_ENCRYPTION_KEY)
        throw new Error('Production QuickBooks requires live OAuth, HTTPS redirect and encryption')
    }
  }
  return {deploymentEnv:deploymentEnv as ServerConfig['deploymentEnv'],supabaseUrl,serviceRoleKey:required('SUPABASE_SERVICE_ROLE_KEY'),
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
