# Milestone 10: Production integration, security and readiness

## Delivery status

**Engineering delivery:** Provider authorization security, API container packaging, production configuration validation, real-staging security probes, release-attestation workflow, operational runbook and updated README roadmap.

**External acceptance:** **NOT COMPLETE.** This repository has no access to production Supabase, Plaid, Intuit, Stripe, Resend or OCR credentials and no evidence of an independent CPA audit, penetration test, production restore, pilot migration or live bank connection. Do not promote an environment to general availability solely because CI passes.

## Architecture and deployment boundaries

- Frontend: Vercel-hosted React/Vite SPA, only Supabase publishable and public API URL values use `VITE_`.
- Backend: dedicated long-running Fastify service deployed from `Dockerfile.api`, behind a TLS reverse proxy. The container runs as the unprivileged `node` user, read-only filesystem, no privileges, no host-network port exposure by default.
- Data: managed, separately backed-up Supabase PostgreSQL/Auth/Storage, private `receipts` bucket. RLS and server role checks are both mandatory.
- Scheduling: GitHub Actions worker calls only server-side authenticated endpoints with a secret, bank feeds/reminders remain opt-in.
- External accounts: Plaid Link for bank feeds, Intuit OAuth for QuickBooks migration, Stripe for billing, Resend for email and optional Google Vision for OCR. Never accept account passwords or tokenize provider access in the SPA.
- Direct connections: no live bank/institution contract or real provider token has been activated by this milestone.

## Provider authorization hardening

Migrations `20261110400000_provider_claim_security.sql` and `20261110410000_bank_reauthorization.sql` add atomic, one-time claims to the Plaid Link exchange, Intuit OAuth callback and Plaid consent-renewal completion.

- `claim_bank_link_session(session,organization,user)` succeeds exactly once for an unexpired session belonging to the authenticated user and organization. No client can invoke it directly.
- `claim_qbo_oauth_state(sha256)` succeeds exactly once for an unexpired, 256-bit unpredictable OAuth state hash; it returns the trusted tenant/user association.
- Both claims are consumed **before** exchanging credentials. If the provider exchange fails, the user must initiate a fresh authorization. This is deliberate replay prevention, not an implicit retry.
- Provider access/refresh tokens remain AES-256-GCM encrypted server-side; never log raw callback URLs, authorization codes, access tokens or exchanged credentials.

**Residual risks:** Callback claims and provider token writes are not a distributed transaction. Failed persistence after provider exchange may orphan a connection, requiring operator cleanup/provider revocation. Intuit rotating refresh tokens also require per-connection concurrency coordination before high-traffic production rollout. These scenarios must be exercised during staging acceptance.

## Plaid webhook authenticity and consent renewal

Bank-authorization expiry is not an application exception users should work around manually. The Bank Feeds workspace now exposes **Renew bank consent** when an existing connection requires reauthorization. The backend creates a Plaid Link **update-mode** token using the existing encrypted access token. After successful Link completion, the backend consumes a one-time, tenant-bound renewal claim, checks the connected Item against Plaid /item/get, and only reactivates the existing bank feed when it is healthy. Plaid documents this flow as the recommended recovery for `ITEM_LOGIN_REQUIRED`. The Item access token remains unchanged. <https://plaid.com/docs/link/update-mode/>

The server route `POST /bank-feeds/plaid-webhook` verifies the Plaid-Verification ES256 JWT against the provider's public key, enforces a five-minute timestamp window, and compares the SHA-256 of the **original raw body** before handling any event. Unverified events cannot alter bank connection status or queue a sync. Confirmed authorization-expiry events request reauthorization; recognized transaction update events queue the next sync. <https://plaid.com/docs/api/webhooks/webhook-verification/>

**Provider setup:** Configure the webhook HTTPS URL in the Plaid developer dashboard, enable Plaid signature verification key retrieval, and run authorized sandbox webhook fixtures before production. Webhook delivery/replay is not certified until real events and consent renewal have been exercised. The existing scheduled polling mechanism remains a fallback.

**Residual:** Provider-signed JWT validation alone is not an exactly-once delivery system. The webhook handler updates only deterministic connection state; it does not post financial journals or store sensitive webhook text. Per-institution pagination, duplicate Items, consent revocations and provider rate limits require live integration exercises.

## Build and rollout

**Runtime:** Node 22, PostgreSQL 17 integration CI, Docker Compose v2.24+ for the example deployment. The repository **does not currently contain an npm lockfile**, so `npm install` resolves allowed semver ranges at build time. Before audit-grade production releases, generate, review and commit `package-lock.json`, migrate all jobs to `npm ci`, and pin base images/actions by digest or vetted immutable versions. Current Docker packaging is build-tested but **not reproducible/immutable**.

1. Provision a dedicated staging Supabase project. Apply all migrations in `supabase/migrations` in ascending filename order and run a staging backup/restore before application deployment.
2. Provision private Storage bucket `receipts`, enable MFA/policies, configure authorized redirect URLs and verified-email domain, verify negative cross-tenant RLS using real Supabase Auth.
3. Copy `apps/api/.env.example` to `apps/api/.env.staging`. Store only synthetic staging credentials in a locked-down file with mode 0600. The file is gitignored; do not use customer production credentials. Set `DEPLOYMENT_ENV=staging`.
4. Run `docker compose -f compose.api.staging.yml build` and `docker compose -f compose.api.staging.yml up -d`. API is bound to `127.0.0.1:3000`. Configure TLS proxy to forward only trusted HTTPS routes, set `TRUSTED_PROXY_CIDRS` to actual proxy addresses, add access logs without authorization headers.
5. Configure Vercel with `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, and `VITE_BILLING_API_URL` pointing to staging API HTTPS origin. No server-role, OAuth or worker secrets in frontend builds.
6. Create **two disposable** staging tenant organizations and synthetic authenticated users with explicit separate roles. Populate minimum financial and bank evidence fixtures. Configure `staging` GitHub Environment secrets described below.
7. Trigger the manual `staging-acceptance.yml` workflow. It runs TypeScript/tests/build and actually probes /health, /ready, missing/invalid worker authorization, OAuth callback rejection, unsigned Stripe webhook rejection, and negative tenant RLS against both real Supabase tenants.
8. Perform the provider acceptance matrix manually with sandbox or development accounts (below). Record links to run IDs and evidence, not raw tokens, in release tickets.
9. Require protected `production` GitHub Environment approval, a **successful staging acceptance run for the exact release commit**, and all manual signoff variables. `release-readiness.yml` verifies the live API /health and /ready before passing its gate. No workflow in this milestone deploys automatically.
10. Promote only after change-control approval and a separate restore/rollback rehearsal. Any failed validation blocks rollout.

### Staging environment secrets

- `QBOCLONE_STAGING_API_URL`
- `QBOCLONE_STAGING_SUPABASE_URL`
- `QBOCLONE_STAGING_SUPABASE_ANON_KEY`
- `QBOCLONE_STAGING_ORG_A`, `QBOCLONE_STAGING_ORG_B`
- `QBOCLONE_STAGING_TEST_JWT_A`, `QBOCLONE_STAGING_TEST_JWT_B`

JWTs must be short-lived and rotated after testing. The test users must have access only to their respective synthetic organizations. Never use production staff credentials.

### Backend environment flags and secrets

```env
DEPLOYMENT_ENV=staging
SUPABASE_URL=https://your-staging-project.supabase.co
SUPABASE_SERVICE_ROLE_KEY=<staging-server-only>
WEB_APP_ORIGIN=https://staging-ledger.example.ca
STRIPE_SECRET_KEY=sk_test_<test>
STRIPE_WEBHOOK_SECRET=whsec_<test>
PORT=3000
TRUSTED_PROXY_CIDRS=127.0.0.1/32
AUTOMATION_WORKER_SECRET=<at-least-32-random-bytes>
BANK_TOKEN_ENCRYPTION_KEY=<64-hex-characters>
PLAID_ENV=sandbox
PLAID_CLIENT_ID=<Plaid-client-id>
PLAID_SECRET=<Plaid-secret>
QBO_SANDBOX=true
QBO_CLIENT_ID=<Intuit-client-id>
QBO_CLIENT_SECRET=<Intuit-secret>
QBO_REDIRECT_URI=https://staging-api.example.ca/qbo/connect/callback
RESEND_API_KEY=<staging-only>
INVITATION_EMAIL_FROM=Ledger North <staging@verified-domain.example>
GOOGLE_VISION_API_KEY=<optional-with-explicit-consent>
```

For production, set `DEPLOYMENT_ENV=production`, genuine `sk_live_` Stripe key, production Plaid credentials and `PLAID_ENV=production` **if enabling feeds**, `QBO_SANDBOX=false` for live Intuit, valid TLS origins and worker secret. The API rejects partial/mismatched live-provider credentials at startup. Configure a secrets manager, enforce staff MFA, restrict deploy permissions and document key recovery. Incomplete provider configuration disables that integration, not the whole application.

## Live acceptance matrix

| Integration | Required evidence | External dependency |
|---|---|---|
| Supabase Auth/RLS | Two real synthetic users cannot query each other's tenant, credential tables denied, MFA and password reset tested | Staging Supabase |
| Stripe | Test checkout, subscription renewals/failed payments, cancellation, signed webhook replay/out-of-order | Stripe account + signing secret |
| Plaid | Sandbox Link, valid account exchange, transaction added/changed/removed, repeated cursor, disconnect, reauth and institution mismatch | Approved Plaid account |
| Intuit | Sandbox OAuth, expired state replay, token refresh, source pagination, financial reports, and accountant-approved source-to-target reconciliation | Intuit developer app |
| Resend | Verified sender, invitation and invoice delivery, bounced/rejected email handling | Verified Resend sending domain |
| OCR | Explicit consent, private receipt, extraction, monthly quota, third-party processor disclosure and failure rollback | Google Cloud Vision project |
| PostgreSQL | PITR and offsite encrypted backup actually restored to isolated Supabase instance; application balances and RLS verified | Production-like managed backup infrastructure |
| Canadian accounting | Parallel books across at least one close, tax-classification review, foreign settlement and inventory variation cases | Qualified Canadian CPA |
| Privacy/security | Privacy impact assessment, customer data rights, third-party retention/data residency, independent penetration test and remediation | Legal/security assessor |

## Incident response and deployment rollback

1. Alert and freeze: disable new QBO/Plaid integrations in the backend, stop affected scheduler jobs, freeze production deploy approvals; do not delete journals or accounting audit data.
2. Triage and preserve: capture sanitized errors, request/correlation IDs, affected tenant IDs, timestamps and relevant webhook IDs. Never capture full bearer tokens or banking credentials.
3. Containment: revoke compromised provider credentials using provider controls, rotate server-only secret material, revoke sessions when needed, isolate affected tenant or API instance.
4. Restore: only use a **verified** offsite snapshot/PITR in a **new** isolated environment. Verify source ledger balances, RLS, Auth and Storage after restoration, and document RPO/RTO.
5. Reconciliation: compare all journals, invoices, payments, bank imports, provider cursors, webhook events and source-to-target balances from the incident interval. Use reversals/correcting entries, never silently rewrite posted journals.
6. Recovery approval: security lead and Canadian accounting owner authorize traffic restoration and write the postmortem, including any applicable privacy notification.

**Rollback limitation:** Restoring an older database does not roll back Stripe subscriptions, bank-provider cursors, customer emails or accounting documents already transmitted externally. A deployment rollback requires forward reconciliation of those external side effects.

## Milestones beyond 10

Milestone 11 is independent Canadian CPA parallel-book acceptance and synthetic-to-pilot business onboarding. Milestone 12 is commercial rollout, support operations, pricing, incident ownership and audited go-live. Additional engineering gaps (full PST/QST posting, inventory returns, FX revaluation, payroll and incomplete historical QuickBooks classes) remain explicit scope decisions, not silently declared complete.

**Production readiness is blocked until external acceptances are recorded.**
