# Milestone 2: Financial documents and reports

## Status
Implemented as a **development feature branch**. Code review and PostgreSQL integration testing are mandatory before merge or use with real financial data.

## Migration order
Apply these migrations, in lexical order, to a *non-production* Supabase instance:
1. `20261110000000_ledger_foundation.sql` (Phase 1, already merged)
2. `20261110010000_accounting_workflows.sql`
3. `20261110020000_fiscal_period_management.sql`

Do not reapply Phase 1 if already present. Migrations 2 and 3 are not designed to be replayed on an already-upgraded database.

## Implemented workflows
- Create customer/vendor contacts.
- Create invoice and bill drafts containing line items.
- Explicitly post invoices/bills to general ledger.
- Record allocated partial or full payments to the Operating Bank account.
- Issue source-linked credit notes and vendor credits, capped by the source's outstanding balance.
- Reverse standalone manual journals in open fiscal periods. Invoice, bill, and payment journals cannot be manually reversed.
- Manage fiscal periods (create non-overlapping periods, lock/unlock with elevated business roles).
- Trial balance and profit-and-loss report RPCs over full posted journal history.
- Basic balance-sheet summary with cumulative earnings. This is not a certified financial statement.
- Isolated posting idempotency namespaces for manual, document, payment and reversal events.

## Accounting mapping

| Financial event | Debit | Credit |
|---|---|---|
| Invoice | AR, gross | Revenue, net and HST payable, tax |
| Bill | Operating expense, net and tax recoverable, tax | AP, gross |
| Invoice payment | Operating Bank | AR |
| Bill payment | AP | Operating Bank |
| Credit note | Revenue, net and HST payable, tax | AR, gross |
| Vendor credit | AP, gross | Operating expense, net and tax recoverable, tax |
| Manual journal reversal | Opposite sides of every original line | Opposite sides of every original line |

**Tax treatment limitation:** tax basis points are manually supplied by a user. Automatically assuming ITC eligibility is not legally sufficient. There is no tax-code library, place-of-supply logic, filing, province-specific assessment, or validated GST/HST engine. Do not claim regulatory compliance.

## Automated test artifacts
- `apps/web/src/AccountingWorkspace.test.ts`: document amount and input validation tests (run with `npm run test`).
- `supabase/tests/milestone2_regression.sql`: rollback-safe database regression script for a disposable Supabase development environment. Run with a privileged SQL test connection after migrations 1-3. Covers idempotency, balanced journals, partial payments, credits, period locks and cross-tenant denial. **Not executed during authoring.**

## Required QA scenarios

### Tenant boundaries
- User from organization A cannot view organization B contacts, invoices, journal lines, payments, or reports.
- Read-only member cannot call any write RPC.
- A contact, account, credit source or document belonging to B cannot be attached to a document in A.
- No service-role credentials are exposed to the frontend.

### Posting
- Posting a zero-value document fails.
- Posting an invoice of $100.00 with a manually supplied 13% rate creates AR $113 debit, Revenue $100 credit, HST payable $13 credit.
- Posting a bill at that rate creates $100 expense debit, $13 tax recoverable debit, $113 AP credit.
- Duplicate posting attempts return the original journal, with no duplicate lines.
- A manual journal with a caller-controlled idempotency UUID does not collide with document or payment posting.
- Posting with an inactive or cross-tenant account fails.
- A document outside an open period does not post.
- Locking a period prevents further postings, while keeping already-posted entries readable.

### Payments and credits
- A $113 invoice permits payments of $30 and then $83, but rejects another $1.
- A posted $113 invoice with a $20 credit permits no more than $93 total payments.
- Over-crediting a partially paid invoice is rejected.
- Duplicate payment requests with identical idempotency keys do not duplicate postings or allocations.
- Vendor bill payments create AP debit and Bank credit.
- A credit note must reference a posted invoice for the same customer and tenant.

### Reversals
- A manual journal reverses with opposite debit/credit lines, and a second reversal call returns the same reversing journal.
- An invoice, bill, credit, payment, or previous reversing journal cannot be reversed with the manual reversal RPC.
- A reversal in a closed period is rejected.

### Reporting
- Trial balance total debit and credit agree as of the selected reporting date.
- Postings after the as-of date are excluded.
- Profit and loss includes only entries in the requested range.
- The derived balance-sheet equation equals zero for a valid closed set of accounts.
- Reports do not rely on the dashboard's 100-row recent-activity preview.
- Run high-volume data fixtures to validate precision, indexing and report performance.

## Known limitations blocking production
- No professional accounting sign-off.
- No PostgreSQL/Supabase end-to-end integration test run has been executed in the current authoring environment.
- No source-document voiding, cash refund handling, unapplied customer deposits or general payment reallocation.
- Tax treatment is a manually entered amount only, without eligible-tax-code validation or tax-return functionality.
- Invoice and bill postings currently map revenue/expenses to basic default accounts rather than per-line configurable accounts.
- No PDF generation, email delivery, invoice editing, multi-currency, tax jurisdictions or bank synchronization.
- The full balance sheet has not been validated for fiscal-year closing and retained earnings.
- No production incident response, automated database restores or penetration testing.
- No subscription billing or entitlements implemented.
- User-facing document lists are limited to the latest 500 records. Server RPCs remain authoritative about outstanding balances.
- Source-document payment reversal is deliberately excluded until a safe undo/refund model exists.

## Next milestone
Tax classification/rules, configurable posting accounts, invoice/bill edit/void state machines, bank transaction import and reconciliation, and comprehensive ledger integration tests.
