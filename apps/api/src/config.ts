export type ServerConfig={
  supabaseUrl:string; serviceRoleKey:string; stripeKey:string;
  webhookSecret:string; webOrigin:string; port:number
}
export function readConfig(env:NodeJS.ProcessEnv=process.env):ServerConfig{
  const required=(key:string)=>{const value=env[key]?.trim();if(!value)throw new Error('Missing server environment variable: '+key);return value}
  const port=Number(env.PORT||3000)
  if(!Number.isInteger(port)||port<1||port>65535)throw new Error('Invalid PORT')
  const origin=required('WEB_APP_ORIGIN')
  if(!/^https?:\/\/[^/]+$/.test(origin))throw new Error('WEB_APP_ORIGIN must be a single web origin without a path')
  return {supabaseUrl:required('SUPABASE_URL'),serviceRoleKey:required('SUPABASE_SERVICE_ROLE_KEY'),
    stripeKey:required('STRIPE_SECRET_KEY'),webhookSecret:required('STRIPE_WEBHOOK_SECRET'),
    webOrigin:origin,port}
}
