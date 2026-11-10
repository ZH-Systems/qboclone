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
