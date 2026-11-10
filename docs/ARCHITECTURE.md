# Architecture decisions

## Product status
Phase 1 foundation, not commercial accounting software. No invoicing, AR/AP workflows, tax filing, automatic bank feeds or payment processor integrations exist yet.

## Trust boundaries
- Users authenticate using Supabase Auth.
- Tenancy is enforced with RLS plus server-side membership checks in explicit write RPCs.
- Journal entry and line tables are read-only to authenticated clients; only the posting RPC can write.
- The RPC checks tenant membership, fiscal period, active accounts, line signs, cent precision and aggregate balance before committing.
- No service-role secrets should be exposed in browser code.
- Financial statement APIs must query the *entire* ledger, not the limited recent-entry preview currently shown in the dashboard.

## Known limitations that block production
- Ledger integrity currently relies on tightly controlled DB function grants, not hard immutability against privileged DB operators.
- No historical opening balances, corrections/reversals, fiscal-year close, tax engine, subscription enforcement, bank reconciliation or invoice posting.
- No accountant-reviewed posting specifications.
- No integration tests against a real Supabase/PostgreSQL database yet.
- Fiscal period setup is calendar-year only for the current year. Additional periods must be added via future admin workflows.
- Currently no invitation or membership-management workflow.
- The UI's summary tiles use only the most recent 100 journals and are deliberately labelled as previews, not financial statements.
- Test isolation, audit logs, key rotation, RPO/RTO and jurisdiction-specific compliance before any real customer data.

## Next iterations
1. Automated PostgreSQL ledger tests and hardened append-only audit history.
2. Fiscal periods, period management and reversing journals.
3. Organization roles, invitations and accounting authorization tests.
4. Dedicated reporting RPCs over complete journal data.
5. Invoices, bills and receipts with transactional source-document posting.
6. GST/HST tax metadata and independently reviewed rules.
7. Stripe Billing and entitlements.
8. Bank imports, reconciliation and asynchronous OCR.
