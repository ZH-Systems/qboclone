# Ledger North (working name)

A Canada-first, multi-tenant accounting SaaS with a developed accounting core and integration adapters. **Not authorized for production accounting, statutory filing, or live customer banking until launch acceptance gates pass.**

## Current capabilities

The repository implements an integrated **development** platform:

- React, TypeScript, Vite, Supabase Auth/PostgreSQL/Storage, tenant organizations and database RLS.
- Double-entry CAD ledger, locked periods, trial balance, P&L, balance sheet, AR/AP, invoices and bills, payments, credits and refunds.
- Canadian GST/HST calculations, **advisory** provincial PST/RST/QST previews, financial reporting and year-end controls.
- Bank CSV reconciliation, Plaid Link and incremental feed staging, with human-reviewed posting.
- Intuit QuickBooks Online OAuth and source record archive, accountant-reviewed staged imports and cutover controls.
- Recurring drafts, opt-in reminders, invoice PDFs/email, receipts and consent-based OCR.
- FIFO inventory and COGS, supplier advances, foreign-denominated CAD settlements with realized FX gains/losses.
- Stripe subscription scaffolding, organization administration, audit trails, tenant exports and CI tests.

**Known unsupported production cases:** native foreign-currency GL and revaluation, inventory returns/adjustments, payroll, complete PST/QST invoice postings/remittance, some QBO historical entities, provider outage handling and independent compliance validation.

See the [architecture](docs/ARCHITECTURE.md) and [operational readiness](docs/MILESTONE_10.md) before enabling real accounts.

## Development setup

1. Create a Supabase project intended for development only.
2. Apply **all** migrations in `supabase/migrations` in filename order to a disposable development Supabase project. Do not apply just the initial migration.
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

## Milestone 2: Financial document foundation

Milestone 2 adds customer/vendor records, invoice and bill drafts/posting, source-linked credits, partial payments, independent posting idempotency namespaces, manual journal reversals, fiscal-period controls, and ledger-backed trial balance / P&L / balance-sheet summaries. See [Milestone 2 specification and QA acceptance tests](docs/MILESTONE_2.md).

Do **not** apply migration 2 or use financial data in production until the migrations, permission policies and accounting assertions have been validated in a test Supabase instance.

## Milestone 3: Tax snapshots and bank reconciliation

Milestone 3 implements tenant-defined tax codes and tax snapshots, configurable document posting accounts, draft editing/voiding, bank statement CSV staging, journal matching, and controlled reconciliation. See [the Milestone 3 documentation](docs/MILESTONE_3.md).

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

Milestone 5 adds server-enforced bank import quotas, Resend invitation emails, authenticated organization JSON exports, account password recovery, expanded immutable audit history, API rate limits, health/readiness endpoints and backup/restore testing.

- [Milestone 5 implementation and validation](docs/MILESTONE_5.md)
- [Operations and recovery runbook](docs/OPERATIONS_RUNBOOK.md)

The production deployment requires configured Supabase Auth, Resend and Stripe test-mode integrations. CI validates PostgreSQL and application code but does not substitute for an actual Supabase/Stripe/Resend integration test or regulatory review.

## Milestone 6: Advanced accounting and Canadian GST/HST

Milestone 6 implements a protected year-end close with retained earnings, audited adjusting journals, one-time opening balance import, allocated payment refunds, customer deposits and applications, receivable write-offs, historical P&L and balance-sheet reporting, AR/AP aging, and user-selected province-based GST/HST rate lookup.

See [Milestone 6 accounting design and test requirements](docs/MILESTONE_6.md).

**Not a certified tax solution:** PST/QST, full place-of-supply rules, GST/HST filing, qualified ITC determinations, and formal financial statement certification require additional implementation and professional review.

## Milestone 7: Automation and integrations

Milestone 7 adds recurring invoice/bill draft generation, opt-in overdue reminders, downloadable invoice PDFs, email delivery, private receipt storage and explicit OCR review, reviewed contact CSV import, bank CSV field mapping, and suggested journal matches. See [Milestone 7 documentation](docs/MILESTONE_7.md) for required integration setup and compliance limitations.

**Provider setup is external:** Resend, Google Cloud Vision, private Supabase Storage and GitHub Actions worker secrets must be configured. No live bank-feed provider is connected, and no production data was processed.

## Milestone 8: Bank feeds, QuickBooks migration and release acceptance

- **Plaid bank feeds:** authorized Canadian bank connections, encrypted provider tokens, incremental transaction staging, explicit CAD account mapping and manual promotion to reconciliation.
- **QuickBooks Online extraction:** Intuit OAuth2 authorization and paginated source entity archival, mapped accounts/contacts, reviewed invoice/bill drafts and payment allocations.
- **Accountant cutover:** six documented reconciliations against PostgreSQL-derived target balances and preserved source report evidence.
- **Commercial readiness:** a separate manually invoked, protected-environment acceptance workflow requiring security, financial, provider, backup and privacy attestations.

Review [Milestone 8 implementation and launch blockers](docs/MILESTONE_8.md).

**Source archival is not complete semantic accounting conversion.** Unsupported credits, payroll, inventory, historical journal treatment, attachments and special taxes require further mapping and verification. No production bank connections or commercial launch are authorized by the CI suite alone.

## Milestone 9: Accounting feature completion

Milestone 9 adds accountant-controlled FIFO inventory and COGS, supplier advances, CAD-based foreign-currency settlement, standard provincial sales-tax reference previews, and safe QuickBooks inventory SKU mapping and optional opening FIFO lots verified against an existing asset balance (without double posting). See [Milestone 9 scope, deployment and limitations](docs/MILESTONE_9.md).

**Not complete statutory parity:** multi-currency revaluation, full provincial tax calculation/filing, inventory returns and adjustment workflows, full historical stock valuation and payroll migration remain incomplete.

## Milestone 10: Production integration and security

Milestone 10 establishes deployment packaging, fail-closed production configuration, atomic provider OAuth/Link-session consumption, staging smoke tests, a provider readiness matrix, and explicit acceptance and incident-response documentation. See [Milestone 10 deployment and security runbook](docs/MILESTONE_10.md).

**Engineering implementation is not evidence of production verification.** Protected GitHub Environment approvals and external tests remain mandatory. Never set readiness attestations to `true` merely because CI passes.

## Roadmap and launch gates (updated November 2026)

| Milestone | Scope | State |
| --- | --- | --- |
| 1–3 | Tenant ledger, financial documents, tax snapshots and manual bank reconciliation | Implemented, in development |
| 4–5 | SaaS billing, organization administration, exports, audit and recovery scaffolding | Implemented, real-provider testing outstanding |
| 6 | Year-end close, adjustments, deposits, refunds and GST/HST reports | Implemented, CPA validation outstanding |
| 7 | Recurring drafts, notifications, receipts/OCR, CSV imports | Implemented, live-provider tests outstanding |
| 8 | Plaid and Intuit adapters, QBO migration review, financial cutover controls | Implemented, integration certification outstanding |
| 9 | FIFO inventory, supplier advances, realized FX, provincial tax previews | Implemented, advanced accounting gaps remain |
| **10** | **Production packaging, security controls, staging verification and operational acceptance** | **Engineering implementation in Milestone 10 PR, deployment/acceptance pending** |
| 11 (proposed) | CPA parallel-book validation and 3–5 isolated business pilots | Not started |
| 12 (proposed) | Controlled commercial rollout, operations and support | Not started |

### Non-negotiable production go/no-go

1. Deploy the entire migration chain to a **dedicated staging Supabase project**, with private Storage, Auth and negative cross-tenant tests.
2. Complete Plaid Sandbox/Development and Intuit Sandbox **actual** authorization, transaction sync, disconnect, migration and reconciliation exercises.
3. Verify Stripe test payments, subscription webhook replay and cancellation, Resend send/bounce, and OCR provider consent and quotas.
4. Run a real encrypted backup, independent restore, blob recovery and security/credential-rotation drill. Record measured RPO/RTO.
5. Obtain a Canadian CPA's written acceptance of supported tax/accounting scenarios, a privacy assessment and an independent security review.
6. Complete pilot books in parallel with the source system, resolve **all material** source-to-target discrepancies, approve a rollback plan and record the protected release signoffs.

**Production availability is blocked until every criterion is evidenced.** CI, container readiness and the staged release gate are necessary, not sufficient.

## Developer note

PostgreSQL database functions form the write boundary for ledger operations. Review every schema migration before deployment. Posted journals are not directly writable by regular authenticated users; elevated DB administration remains a separate trust boundary.
