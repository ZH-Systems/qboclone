# Milestone 4: Commercial SaaS administration and Stripe Billing

## Included
- Organization member listing with verified email, membership role and join date.
- Owner and administrator invitations with seven-day expiry, single-use cryptographic bearer token, SHA-256 digest, verified-email redemption, revoke, remove and role changes.
- Accountant membership is tenant-scoped, with no privilege to manage other users.
- Subscription catalog: Starter CAD 15/month, Business CAD 35/month, Professional CAD 65/month. Prices are **proposed** and require real Stripe Price IDs.
- Server-only Fastify billing API with authenticated checkout, customer portal, signed Stripe subscription webhooks and durable database event deduplication.
- Server-derived entitlements, automatic membership seat caps at invite acceptance.
- Append-only audit rows for membership and selected financial transitions.
- PostgreSQL regression suite with tenant access, billing event idempotency, stale event handling and membership authorization.
- Web UI for account owner billing, plans, users, invitations and recent audit events.

## Run locally
1. Create a **development** Supabase project and apply all ordered SQL migrations, ending at `20261110110000_member_limits_and_audit.sql`.
2. Create three recurring monthly Stripe products/prices **in Stripe test mode**. Update the private `public.subscription_plans.stripe_price_id` mapping via Supabase SQL Editor with those Price IDs. Do not make this a public client-writable table.
3. In `apps/api/.env` (server only), configure `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, and `WEB_APP_ORIGIN`.
4. In `apps/web/.env.local`, set `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, and `VITE_BILLING_API_URL=http://localhost:3000`.
5. From repo root:
   ```bash
   npm install
   npm run api:dev
   ```
   In a second terminal, `npm run dev`.
6. Configure Stripe webhook endpoint as `https://your-api.example.com/stripe/webhook`, subscribing to `customer.subscription.created`, `customer.subscription.updated`, and `customer.subscription.deleted`. For local testing, run Stripe CLI forwarding to `http://localhost:3000/stripe/webhook` and set its generated signing secret.
7. Run `npm run verify`; CI additionally runs SQL regression scripts after migration application.

## Deployment
Web: Vercel, root directory `apps/web`, as previously configured.

Backend API: a Node 22 hosting service, such as a container instance. The Dockerfile is `apps/api/Dockerfile` with **repository root as Docker build context**, because it copies workspace dependencies. Set the API's server-only secrets in your host's secret manager. Configure the API hostname and exact production `WEB_APP_ORIGIN`. Never publish Supabase service-role or Stripe private keys in a `VITE_` variable.

All `/billing/*` API routes require a valid Supabase session JWT AND owner membership. Stripe callbacks require an HMAC signature verified against the raw webhook body. An event is applied through a database function callable only by the service role.

## Invitation security
The invitation creation RPC returns a single-use token. The frontend creates a URL fragment (`#invite=<token>`) to keep that token out of normal HTTP request paths. Share the URL privately; it remains a sensitive bearer credential until redeemed or revoked. The accepting user must sign in with the exact verified email address. Invitees may belong to multiple organizations. The server rechecks seat limits when the invitation is accepted.

**No outbound email is sent automatically** in this milestone. An administrator must securely share the generated URL. Invitation tokens should not be logged, tracked, or included in analytics.

## Billing and entitlement limitations
- Subscription **customer and subscription events** are authoritative, not local frontend state.
- An organization must be billed before it may add additional members. Current database enforcement covers **seat caps at invitation redemption**, not every future paid feature.
- Stripe customer objects are created with an organization idempotency key; subscriptions are linked via server-set metadata.
- The webhook checks event IDs and creation timestamps, but independent subscriptions or exact-second event ordering still require reconciliation engineering.
- There is no automatic webhook retry queue except Stripe's delivery retries; monitor failed events.
- There is no handling of failed/incomplete checkout expiry beyond the subscription status.
- Organization owners can open Stripe Customer Portal. It must be configured with allowed actions and products in Stripe Dashboard.
- No complete offboarding/read-only tenant shutdown, prorated usage billing, multi-organization volume billing, tax collection setup, or plan upgrade quota enforcement beyond invitations.
- No automatic Canadian sales tax charging setup in Stripe Billing. Configure and legally validate tax behaviour separately before collecting subscriptions.
- The API supplies `current_period_end` as null until the Stripe version's item-level period field is mapped and validated.

## Validation and production gates
- GitHub web and API CI must pass typecheck, unit tests and production builds.
- GitHub PostgreSQL 17 migration and Milestone 1-4 regression chain must pass.
- Execute migrations and flows against a **real disposable Supabase project**. The CI database uses a synthetic Auth compatibility schema and is not a replacement for Supabase integration tests.
- Validate Stripe test-mode checkout, webhook replay, out-of-order delivery, portal and cancellation paths.
- Independently security-review all `SECURITY DEFINER` functions, invitation access, service-role grants, billing tenant association and role escalation.
- Externalize operational email sending, subscription-grace policies, audit-retention policies and recovery runbooks.
- Do not onboard real accounting businesses before CPA review, threat modeling, data recovery exercises, and Canadian compliance checks.

## Next milestone
Commercial-readiness hardening: owner-managed Stripe price provisioning, outbound invite email, billing and entitlement enforcement across premium features, complete audit coverage, paginated search, usage metering, account recovery, privacy export and automated backups.
