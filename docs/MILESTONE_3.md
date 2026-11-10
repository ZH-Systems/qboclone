# Milestone 3: Tax configurations, posting controls and bank reconciliation

## Status
Implemented on the `feat/milestone-3-tax-banking-controls` branch. GitHub Actions successfully runs `npm run verify` and applies all accounting migrations plus Milestone 2 and 3 rollback-safe SQL regressions on PostgreSQL 17. These checks use a synthetic Auth compatibility schema, **not** a live Supabase environment. **Not approved for production accounting or tax filing.**

## Migration order
Apply all earlier migrations, then the following in filename order, in a disposable Supabase development database:
- `20261110030000_tax_and_document_controls.sql`
- `20261110040000_bank_reconciliation.sql`
- `20261110050000_reconciled_ledger_lock.sql`
- `20261110060000_bank_account_types.sql`
- `20261110070000_effective_tax_rules.sql`
- `20261110080000_bank_import_reset.sql`
- `20261110090000_strict_idempotency.sql`

Migrations are deliberately nonreplayable and should be applied once. Backup and inspect schema before any deployment. Do **not** run them on a production database without verification.

## Features
- Tenant-scoped tax codes categorized as taxable, zero-rated, exempt or out-of-scope, per sale/purchase direction.
- Per-code manual rates in basis points (1300 = 13%), effective period, and purchase-tax recoverability setting (5000 = 50%).
- Document-line snapshots of rate, tax classification, recoverable tax amount, account and computed tax.
- Invoice and bill line mappings to same-tenant active revenue or expense accounts.
- Draft editor that can replace lines, memo and due date, with server-side validation.
- Voiding **unposted** drafts while preserving document numbers. Posted documents must use formal credits, not destructive edits.
- Explicit bank-account eligibility flag on asset accounts.
- CSV statement staging for date, description, signed amount and optional reference, supporting CSV quotes.
- Idempotent repeat imports by statement and row number, with conflicting replacement rows rejected.
- Resetting all imported rows in an **open** statement, including matches, without deleting ledger journals. Reconciled imports cannot be reset.
- Manual bank transaction-to-existing-journal matching by signed bank account delta.
- Reconciliation requiring matched rows, statement opening/closing arithmetic and agreement with the ledger balance.
- Protection against backdated posting to previously reconciled bank accounts.
- Rejection of conflicting retries where a caller reuses the same journal or payment idempotency key with changed fields.
- UI sections for tax codes, bank statements, draft edits, draft voiding and per-line posting accounts.

## Accounting caution
Tax codes are **user-defined**, not a certified Canadian tax library. Place-of-supply, provincial/QST/PST, partially recoverable input tax credits, prescribed adjustments, filing returns, interest and penalties are not fully implemented.

Manual purchase-tax rate entry defaults to **zero recoverable input tax**, rather than presuming a credit. Only explicit purchase tax-code recoverability yields a recoverable component. This is conservative but not a substitute for CPA assessment.

Existing Phase 2 documents retain their prior posting/snapshot data. The migration backfills the new recoverability column to match historical Phase 2 treatment.

Credit notes reference posted invoices, vendor credits reference posted bills, and posted credits cannot exceed remaining outstanding receivable/payable. **Refunds of already paid invoices, unapplied customer credits and cash refunds are not implemented.**

## CSV specification
Header: `date,description,amount,reference`

Example:
```csv
date,description,amount,reference
2026-11-01,"Invoice 1001, payment",113.00,INV-1001
2026-11-02,Monthly bank charge,-12.50,FEE-11
```

Bank statement entries are **staging data** and do not create ledger journals. A journal must exist with a matching account movement before reconciliation. You may create authorized standalone manual journals for bank charges and adjustments, with an accounting review.

The UI loads the 500 most recent journals as match candidates and displays up to 500 imported transactions per statement. The database enforces reconciliation against **all** imported transactions, including records beyond the UI's display limit.

A statement is one account and one date range. Overlapping statement date ranges for the same account are rejected. Reimports must preserve original row indices.

## Acceptance gates
- Compile and pass web unit tests; confirm the Vite build.
- Run `supabase/tests/milestone2_regression.sql` against a disposable DB.
- Run `supabase/tests/milestone3_regression.sql` against the same disposable DB. Both scripts roll back.
- Test user A cannot read/write user B's tax codes, bank statements, or transactions.
- Verify sale tax and partially recoverable purchase tax posting mappings.
- Test zero-rated/exempt/out-of-scope configuration and effective dates.
- Confirm draft modifications change totals but posted documents cannot be edited or voided.
- Import a CSV twice without duplicating transactions; a changed prior row must be rejected.
- Reset an open statement import and re-import it, then verify the posted ledger remains unchanged.
- Verify bank transaction match uses the correct sign and account, and does not create journal postings.
- Reconcile a statement, then verify it rejects unmatching and backdated journal postings.
- Verify RLS and `SECURITY DEFINER` functions with test JWTs.
- Confirm multi-tenant import performance and errors under 500+ lines.
- Verify a reused payment or manual journal idempotency key with modified details raises an error.
- Obtain accounting and application-security review.

## Known limitations and next work
- No real bank API integrations or Plaid/Flinks/other provider contracts.
- No CSV mapping UI for arbitrary Canadian bank formats, OFX/QFX, or duplicate matching across *different* statement imports.
- No automated suggested journal creation, bank rules, multi-line split matching or refund matching.
- No automated tax filing or provincial validation.
- No source-document credit beyond outstanding balance, cash refunds or invoice void-after-post.
- No production accounting attestation, restore test or complete audit event pipeline.
- Statement matching UI is limited to 500 recent journal candidates; pagination and search are required at scale.
- No payment-processor/Stripe subscription integration yet.

## Next milestone
Stripe Billing entitlements and pricing tiers, organization administration/invitations, audit log operations, statement pagination and production hardening.
