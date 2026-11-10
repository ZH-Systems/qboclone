# Ledger North (working name)

A Canada-first, multi-tenant accounting SaaS. This repository contains the first **functional foundation**, not a production-ready alternative to QuickBooks.

## What is implemented

- React + TypeScript + Vite application with responsive dashboard, sign-up/login and multiple businesses per account.
- Supabase Auth, tenant-visible organization and membership records, and row-level security.
- Company bootstrap RPC creating a standard chart of accounts and a calendar-year fiscal period.
- Chart of accounts viewer and account creation.
- Double-entry journal posting RPC validating organization access, accounting period, active accounts, cent precision, balanced debits/credits and idempotency.
- Recent journal browsing and a limited dashboard preview.
- Unit tests for journal validation.

**Do not use the application for actual accounting, financial reporting or tax filing yet.** See [architecture and limitations](docs/ARCHITECTURE.md).

## Development setup

1. Create a Supabase project intended for development only.
2. Apply [the initial migration](supabase/migrations/20261110000000_ledger_foundation.sql) with Supabase CLI or the SQL editor.
3. Enable email/password authentication under Supabase Auth.
4. Copy `.env.example` to `apps/web/.env.local` and fill `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY`.
5. From the repository root, run:

```bash
npm install
npm run dev
```

Run checks with:

```bash
npm run verify
```

The Vite development server exposes the web app locally. Only the Supabase **publishable/anon** key belongs in frontend environment variables. Never expose a service-role key.

## Vercel deployment

Import this repository as a Vercel project. Set Root Directory to `apps/web`, Framework Preset to Vite, Build Command to `npm run build`, and Output Directory to `dist`. Set the two `VITE_` environment variables in the Vercel dashboard. Deploy once the database migration has run.

## Milestone 2 development branch

A follow-up milestone adds customer/vendor records, invoice and bill drafts/posting, source-linked credits, partial payments, independent posting idempotency namespaces, manual journal reversals, fiscal-period controls, and ledger-backed trial balance / P&L / balance-sheet summaries. See [Milestone 2 specification and QA acceptance tests](docs/MILESTONE_2.md).

Do **not** apply migration 2 or use financial data in production until the migrations, permission policies and accounting assertions have been validated in a test Supabase instance.

## Milestone 3 development branch

The next milestone implements tenant-defined tax codes and tax snapshots, configurable document posting accounts, draft editing/voiding, bank statement CSV staging, journal matching, and controlled reconciliation. See [the Milestone 3 documentation](docs/MILESTONE_3.md).

**Do not** treat the current tax configuration as a validated CRA compliance system or use it for production filings. The new migrations and tests must run in development first.

## Milestone 4: SaaS billing and organization administration

Milestone 4 adds team roles, verified-email invitations, accountant access, subscription plan records, Stripe test-mode checkout and customer portal via a **dedicated server-only Fastify API**, Stripe-signed subscription webhooks, seat-limit enforcement, and recent audit events. See [Milestone 4 deployment and security notes](docs/MILESTONE_4.md).

Additional local development commands:

```bash
npm install
npm run api:dev   # Server-only Stripe and Supabase secrets in apps/api/.env
npm run dev       # React/Vite frontend with VITE_BILLING_API_URL
npm run verify    # Web and API typecheck, tests and builds
```

The backend is a separate deployment, not a Vercel frontend function. Never place Stripe secrets or Supabase service-role credentials in `VITE_` environment variables.

**Commercial readiness:** current tenant data, financial logic, tax setup, bank imports and subscription operations require independent validation. Do not use this development version for regulatory filings or real business books yet.

## Milestone 5: Operational hardening

The latest development milestone adds server-enforced bank import quotas, Resend invitation emails, authenticated organization JSON exports, account password recovery, expanded immutable audit history, API rate limits, health/readiness endpoints and backup/restore testing.

- [Milestone 5 implementation and validation](docs/MILESTONE_5.md)
- [Operations and recovery runbook](docs/OPERATIONS_RUNBOOK.md)

The production deployment requires configured Supabase Auth, Resend and Stripe test-mode integrations. CI validates PostgreSQL and application code but does not substitute for an actual Supabase/Stripe/Resend integration test or regulatory review.

## Scope for next phase

- Financial reporting over complete journals
- Reversing journals, explicit period locking
- Invoicing and accounts receivable
- Vendor bills, expenses and accounts payable
- Canadian GST/HST handling, independently verified
- Audited tenant isolation and accounting integration tests
- Stripe subscription management
- Import/reconciliation and receipt processing

## Developer note

PostgreSQL database functions form the write boundary for ledger operations. Review every schema migration before deployment. Posted journals are not directly writable by regular authenticated users; elevated DB administration remains a separate trust boundary.
