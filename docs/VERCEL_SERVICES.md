# Single-project Vercel Services deployment

The root `vercel.json` defines two public services on one domain:

| Service | Directory | Framework | Public paths |
| --- | --- | --- | --- |
| `web` | `apps/web` | Vite | `/*` |
| `api` | `apps/api` | Fastify | `/api/*` |

**Bindings: none.** The React SPA calls the public same-origin API via `/api`; it cannot use a server-only Vercel service binding. All API routes require their existing authentication or signed webhook/worker authorization as applicable.

## Import

1. Import `ZH-Systems/qboclone` into Vercel as one **Services** project, using the **repository root**. Do not configure `apps/web` as the overall project Root Directory.
2. Verify Vercel detects the two services from `vercel.json`. Choose the Services framework/preset if asked. A version of the Vercel CLI supporting Services is necessary.
3. Configure browser-safe values: `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, and optionally `VITE_BILLING_API_URL=/api`. Do not put any secret in a `VITE_` environment variable.
4. Configure the API's **server-only** variables from `apps/api/.env.example` in the deployment: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `WEB_APP_ORIGIN`, and enabled provider/worker credentials. Stripe Billing is disabled by default. Leave `STRIPE_ENABLED=false` and omit `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` until ready to activate billing. Set `STRIPE_ENABLED=true` only with a real secret key and signed webhook secret (live credentials when `DEPLOYMENT_ENV=production`). When disabled, checkout, billing portal and Stripe webhook endpoints return HTTP 503 without blocking the rest of the API. Set `WEB_APP_ORIGIN=https://YOUR-DOMAIN`, without a trailing slash or path. Configure the environment's approved `DEPLOYMENT_ENV` and `TRUSTED_PROXY_CIDRS` according to `docs/MILESTONE_10.md`; production validation intentionally fails closed.
5. If using Intuit, configure `QBO_REDIRECT_URI=https://YOUR-DOMAIN/api/qbo/connect/callback`, then register exactly this address in the Intuit developer console. Configure provider webhook endpoints `https://YOUR-DOMAIN/api/stripe/webhook` and `https://YOUR-DOMAIN/api/bank-feeds/plaid-webhook`. Callback requests are externally initiated, so the API's routed paths must be public. Do not create a service binding for them.
6. Apply the entire SQL migration chain in order to an isolated Supabase staging project. Verify Auth, private Storage, RLS, and provider settings before enabling integrations.
7. Deploy. Probe `https://YOUR-DOMAIN/api/health` and `https://YOUR-DOMAIN/api/ready`, then run `docs/MILESTONE_10.md` staging acceptance against the actual service URL. A passing health probe does not imply financial or security certification.

## Routing behavior

Vercel Services route `/api/*` to `api` while keeping the public prefix on incoming URLs. On Vercel, Fastify's `rewriteUrl` removes one leading `/api` before matching existing handlers, so `/api/health` resolves to the existing `/health` handler. The raw body is not modified; Stripe and Plaid signature verification remain active. Queries on the Intuit callback route are preserved. In standalone Docker mode, `VERCEL` is absent and existing unprefixed routes remain unchanged.

The three browser API callers default to `/api` if `VITE_BILLING_API_URL` is unset. For local development, Vite's proxy removes the prefix and forwards to the existing local API listener on port 3000:

```sh
npm install
npm run api:dev
# In another terminal
npm run dev
npm run verify
```

Neither the frontend nor Fastify calls another Vercel service from server-side application code, therefore **no internal bindings** are declared.

## Known restrictions

- Vercel deploys Fastify into Functions, which have request-size, execution-time, file-system and lifecycle limitations. Test large financial exports, receipt uploads, OCR jobs, bank-sync workers, and webhooks against a real staging deployment; do not assume container behavior is identical.
- Preview deployments require correct `WEB_APP_ORIGIN`, allowed OAuth redirects and webhook endpoints. Avoid enabling provider workflows in arbitrary preview URLs.
- Keep the existing Docker API deployment as a fallback for workloads that exceed Functions limits.
- This is an engineering deployment pathway, not commercial go-live authorization. Independent CPA/security review, provider staging and restore drills remain mandatory.
