# Milestone 8: Direct bank feeds, full-source migration and launch acceptance

**Status:** Code implemented on a development PR. No live Plaid/Intuit credentials, customer data, production migrations, provider acceptance, external tax certification or commercial deployment has been performed.

## Direct Canadian bank feeds

The first provider integration is Plaid, rather than having the application store customers' online banking credentials. Plaid Link authorizes bank access in a hosted bank-consent flow. The server exchanges a temporary token for a long-lived access token, encrypts that token with AES-256-GCM, and stores it in `bank_feed_connections` without exposing it to organization users or RLS queries. The encrypted-token key is required on the API server only.

Bank feed flow: **Link authorization -> institution account selection -> explicit bank ledger mapping -> /transactions/sync cursor pages -> tenant-scoped staging -> optional promotion into an open statement -> user-reviewed reconciliation.**

- Connection status: active, requires reauthorization, disconnected.
- Accounts map to a single ledger bank account only when currency is **CAD**.
- Provider transaction IDs are unique per connection, avoiding duplicate records.
- Pending and removed provider transactions are identified; they cannot be promoted into a statement.
- Cursor advancement and transaction update happen in a single database transaction per page.
- Plaid expenses use positive transaction amounts, but ledger bank movements are negative, so sign inversion is applied explicitly during staging.
- No imported feed transaction automatically changes general ledger balances or marks a journal as matched.
- Removed provider transactions are tombstoned rather than deleting imported financial evidence.
- Disconnection requests revoke provider access and clear the active stored token.
- The existing manual bank CSV and reconciliation workflows remain a fallback.

**Commercial limitation:** Canadian bank coverage varies by institution and Plaid's commercial agreement. Flinks remains a possible additional adapter. Reconnect/update-mode UX, institution-specific long-tail cases, provider-verified webhooks, advanced foreign exchange and settlement timing require live provider testing. The current worker uses scheduled polling.

References:
- Plaid Link token and exchange: https://plaid.com/docs/link/
- Plaid Transactions Sync: https://plaid.com/docs/transactions/
- Flinks documentation/availability should be commercially verified before implementation.

### Required environment variables (API only)
```env
PLAID_ENV=sandbox
PLAID_CLIENT_ID=<Plaid developer client ID>
PLAID_SECRET=<Plaid sandbox or production secret>
BANK_TOKEN_ENCRYPTION_KEY=<64 hexadecimal characters, 32 random bytes>
```
Do not rotate `BANK_TOKEN_ENCRYPTION_KEY` without decrypt/re-encrypt tooling or reconnecting all institutions.

**Bank synchronization scheduler:** Add a secured invocation of `POST /bank-feeds/sync-due` on a reliable schedule using the existing `AUTOMATION_WORKER_SECRET`. For development, invoke `POST /bank-feeds/sync` explicitly in the UI after Link. The default Milestone 7 GitHub Actions job currently triggers only recurring drafts and reminders. The bank feed poll must be configured separately, not assumed to be active.

## QuickBooks Online migration

The Intuit OAuth connector uses user consent, an expiry-bound anti-CSRF state, server-only encrypted OAuth credentials, refresh-token rotation, and pagination through the QBO Accounting API. The application requests accounting scope but uses **read-only query/report endpoints**. Never log authorization codes, bearer tokens, source financial records or tenant PII.

Supported **source extraction and archival** includes Account, Customer, Vendor, TaxCode, Invoice, Bill, CreditMemo, VendorCredit, Payment, BillPayment, JournalEntry, Attachable, Purchase, Deposit, SalesReceipt, RefundReceipt, Transfer, Estimate, PurchaseOrder and Item.

The complete, original QBO JSON of each extracted entity is archived, keyed by the source ID. This supports traceability but **archiving does not mean source entities have been fully converted**.

Current **semantic conversion**:
- Chart of accounts, with QBO account-code mapping and fallback stable QBO-prefixed codes.
- Customers and vendors with email, preserving raw source details.
- Invoices and bills to target drafts, with line accounts mapped through source-to-target account references.
- Explicit, accountant-approved posting of invoices and bills only after source totals exactly match the generated target documents.
- Payment allocations to the corresponding posted invoice or bill using the original source transaction links and deterministic idempotency keys.
- **Linked credit notes and vendor credits** can be explicitly mapped to a posted source invoice/bill, reviewed, matched by source total and posted. Unapplied credits remain archived and block complete financial cutover approval.\n- **Standalone historical journals** can be approved individually by an accountant, mapped through source account IDs, and posted idempotently. Journals already represented by imported invoices/bills must never be approved as standalone.\n- Refunds, payroll, unapplied credits, tax codes, attachments, inventory transactions, opening balances and unmatched bank transactions **remain archived for further mapping or manually controlled import**. Automatic combined historical GL and document replay is prohibited because of double-counting risk.
- QBO financial source reports (Trial Balance, Balance Sheet, P&L, Aged AR, Aged AP) can be captured and SHA-256 referenced as reconciliation evidence.

The cutover workflow:
1. Connect the source company using Intuit OAuth.
2. Create a migration batch with a source as-of date.
3. Stage the chosen QBO entities in paginated, repeatable batches, or upload a canonical JSON bundle.
4. Review missing contact references, incomplete invoices, source journals requiring specialized mapping and unallocated credits.
5. Owner/accountant approves the source batch.
6. Import mapped accounts, contacts and documents as drafts.
7. Reconcile source tax and document amounts with target documents; explicitly post reviewed documents and allocations, up to 50 items per transaction.
8. Map eligible source credit notes to posted documents, and explicitly approve truly standalone journals before posting.\n9. Compare source financial reports with target PostgreSQL ledger calculations, record evidence for six categories and obtain accountant signoff.
10. Independently validate all archived records that have no target mapping. Financial cutover signoff does **not** certify that inventory, payroll, foreign currency, every attachment and all special tax scenarios have been converted.
11. Freeze the source ledger and document the delta migration/cutover window. A live production cutover plan requires a restore rehearsal and source/target rollback policies.

### Required Intuit environment variables
```env
QBO_CLIENT_ID=<Intuit developer client ID>
QBO_CLIENT_SECRET=<Intuit developer secret>
QBO_REDIRECT_URI=https://api.example.ca/qbo/connect/callback
QBO_SANDBOX=true
```
Register the exact callback in the Intuit Developer Portal. The same encrypted-token key protects QuickBooks refresh/access tokens.

References:
- Intuit OAuth2: https://developer.intuit.com/app/developer/qbo/docs/develop/authentication-and-authorization/oauth-2.0
- Intuit Accounting API: https://developer.intuit.com/app/developer/qbo/docs/api/accounting/all-entities

## Milestone 8 acceptance gate

The CI workflows cover TypeScript, Vitest, production builds, all ordered migrations, tenant isolation and rollback-safe Milestone 2–8 regressions, plus PostgreSQL archive restore. The separate `release-readiness.yml` workflow runs on manual dispatch in a **protected production GitHub Environment**.

It fails unless a HTTPS production API is configured and the required manual GitHub Environment acceptance variables all equal `true`:

- `QBOCLONE_CPA_SIGNOFF`
- `QBOCLONE_PRIVACY_REVIEW_APPROVED`
- `QBOCLONE_SECURITY_REVIEW_APPROVED`
- `QBOCLONE_RESTORE_DRILL_VERIFIED`
- `QBOCLONE_TENANT_ISOLATION_VERIFIED`
- `QBOCLONE_STRIPE_TEST_ACCEPTED`
- `QBOCLONE_PLAID_BANK_TEST_ACCEPTED`
- `QBOCLONE_QBO_MIGRATION_ACCEPTED`
- `QBOCLONE_EMAIL_DELIVERY_ACCEPTED`

The production environment secret `QBOCLONE_PROD_API_URL` must be set to the deployed HTTPS backend. This is an **attestation-gated smoke check**, not a substitute for penetration testing or a real accounting audit. The workflow never deploys automatically.

## Required live launch test cases

**Accounting:** Balanced posting, year-end locks, refunds/deposits/bad-debt write-offs, GST/HST source classification, AR/AP aging and historical statements with accountant-approved QBO cutover.

**Billing:** Stripe test-mode customer onboarding, plan downgrade, cancellation, failed payment, webhook replay/out-of-order events, member/usage enforcement and read-only/export after billing restriction.

**Bank feeds:** Plaid sandbox Link, exchange, sync, changed/removed transactions, token invalidation and reconnect, duplicate cursor replay, CAD account mapping, explicit statement promotion, multi-tenant isolation and bank transaction deletion disputes.

**Security/privacy:** Supabase real Auth, MFA, RLS, private document storage, key/secret rotation, support access, PIPEDA/Quebec applicability assessment, CRA retention policy, person-level deletion/export policy, payment token boundaries and provider data residency.

**Recovery:** Scheduled encrypted production backups, independent off-host retention, actual Supabase Restore/PITR exercise, RTO/RPO measurement, rollback from failed schema migration, blob/storage backup and incident notification runbook.

**Operations:** Email acceptance/bounces, worker failure alerts, provider disconnect errors, rate limiting behind production proxy, monitoring and on-call escalation.

## Go/no-go

**No-go** until production provider credentials, real migrations, positive external penetration results, accountant signoff, cross-tenant acceptance, off-host backup and recovery, and verified QBO import completeness exist.

Milestone 8 implements an engineering foundation and safety gates. It does **not** authorize use for production financial records, direct bank connectivity to customer institutions, or commercial launch by itself.
