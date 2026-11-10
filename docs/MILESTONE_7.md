# Milestone 7: Automation and integrations

## Delivered functionality
1. **Recurring customer invoices and supplier bills.** A tenant-scoped schedule references a draft or posted invoice/bill, uses weekly/monthly issue dates, and generates an **unposted draft** using its financial line snapshots. Each occurrence is deduplicated by rule/date. The scheduler pauses invalid sources and expired tax-code configurations. Humans must review/post.
2. **Scheduled worker.** `.github/workflows/recurring.yml` runs hourly on the default branch, calling a separately deployed Fastify API with a worker secret. It can optionally run overdue reminder delivery. Both operations are idempotent in the database subject to provider delivery caveats.
3. **Opt-in overdue invoice reminders.** Owners/admins configure number of overdue days and cooldown interval. A service worker claims and sends reminders only when an invoice is posted, has a valid customer email and still has a positive ledger-derived outstanding amount at claim time. Deliveries and failures are audited. Policies are **off by default**.
4. **Invoice PDFs and email delivery.** Server renders posted invoice snapshots into downloadable PDFs and can send invoices or user-initiated payment reminders to the **saved customer's email** through Resend. The PDF contains invoice items, dates, subtotal and tax total, and does not expose service credentials.
5. **Private receipt intake.** Upload PDF/PNG/JPEG receipts (up to 8 MiB) through an authenticated API into a fixed, private Supabase Storage bucket named `receipts`. Content signatures and SHA-256 hashes are checked. The API returns 60-second signed preview links after organization authorization. Users can link receipts to same-tenant documents.
6. **Explicit OCR review.** On demand, and only after the user explicitly acknowledges third-party processing, the API uses Google Cloud Vision to extract document text. For PDFs it submits up to five pages. It stores raw OCR text and unverified vendor/total suggestions, and **never automatically posts invoices, expenses or taxes**. The paid-plan OCR allowance is reserved transactionally and released on failed requests.
7. **Bank CSV import mapping.** Users map date, description, amount or debit/credit columns, reference and explicit date convention to the existing canonical bank CSV import. Bank matching suggestions are calculated from existing signed bank journal movements and dates. **All matches require the user's confirmation.**
8. **QuickBooks/generic contact CSV import.** User maps customer/vendor CSV columns, previews and validates data, then confirms an import up to 5,000 rows. Exact name/email duplicates are skipped; there is no automatic merge based only on name.
9. **Tenant exports.** Account export now includes recurring schedules and occurrences, receipt metadata and OCR text, receipt-document links, import reviews and delivery logs. Binary attachments need a separate storage archive process.

## Database installation
Apply after all merged Milestones 1–6 migrations, ordered by filename:

- `20261110220000_recurring_bank_suggestions.sql`
- `20261110230000_receipts_delivery_imports.sql`
- `20261110240000_receipt_ocr_results.sql`
- `20261110250000_receipt_ocr_quota.sql`
- `20261110260000_opt_in_reminders.sql`

Never apply new migrations directly to production before staging validation and backup verification. Do not apply `supabase/tests/ci_auth_bootstrap.sql` to real Supabase.

## Required API configuration
Existing API environment:
```env
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_SERVICE_ROLE_KEY=server-only-key
STRIPE_SECRET_KEY=sk_test_...
STRIPE_WEBHOOK_SECRET=whsec_...
WEB_APP_ORIGIN=https://your-frontend.example
RESEND_API_KEY=re_...
INVITATION_EMAIL_FROM=Ledger North <invoices@your-domain.example>
GOOGLE_VISION_API_KEY=google-cloud-vision-key
AUTOMATION_WORKER_SECRET=long-random-secret
```

**All keys are server-side only.** `VITE_BILLING_API_URL` in the Vercel frontend points to the dedicated HTTPS Fastify API. Never expose service role, Google OCR, Resend or worker keys as Vite variables.

### Supabase Storage
In the same **development Supabase** project, create a bucket named `receipts` with public access **disabled**, max object size 8 MiB and allowed MIME types `application/pdf`, `image/png`, `image/jpeg`. The API creates paths of form `organizations/<organization-uuid>/<receipt-uuid>` and does not grant direct public storage access. Verify no permissive bucket policies allow cross-tenant reads. A full document retention/purge workflow remains outstanding.

### GitHub Actions scheduler
In the GitHub repository configuration set the Actions **secrets** `QBOCLONE_API_URL` (the HTTPS API origin, without trailing slash) and `QBOCLONE_AUTOMATION_WORKER_SECRET` (same as API env `AUTOMATION_WORKER_SECRET`). The `recurring.yml` schedule executes hourly while the default branch is active and GitHub Actions is enabled. For automatic payment reminders, also set repository **variable** `QBOCLONE_REMINDERS_ENABLED=true`, configure Resend and enable each organization's reminder policy in the UI.

Scheduled GitHub Actions have no hard realtime execution guarantees. Monitor workflow run history and alert on failures. The database serializes recurring occurrences, but a retry after an email provider accepted delivery and before state recording can create a duplicate message, so production delivery requires further outbox/provider-idempotency hardening.

## CI acceptance
- All migrations apply to PostgreSQL 17.
- Milestones 2–7 financial/tenant regressions pass.
- Recurring generation produces unposted, correctly valued documents exactly once for the same occurrence, and authenticated users cannot invoke service-only jobs.
- OCR quota tests cover subscription entitlement, concurrent reservation rejection, releasing failed attempts, and caching completed results.
- Invoice reminder tests verify admin opt-in, service-only claiming, single pending claim, cooldown and tenant isolation.
- TypeScript, unit tests, production web/API builds and PostgreSQL backup/restore pass.

## Explicit exclusions
- **Live banking feeds:** Direct Flinks, Plaid, bank-specific APIs and Canada's emerging consumer-driven banking APIs are not connected; they require approved provider accounts, legal agreements, institution permissions and a credential vault.
- **Full QuickBooks migration:** The CSV workflow imports contacts only, not transactions, attachments, payroll, inventory or complete QBO general ledgers.
- **Automatic expense categorization:** OCR provides candidates, never validated journal or tax classifications. No accounting-grade AI auto-posting is enabled.
- **Merchant email/PDF polish:** Email addresses are taken from the customer record. Branded invoice templates, delivery confirmations and bounced-mail webhooks are not implemented.
- **PDF OCR:** Google Vision online PDF extraction processes the requested first five pages. Complex receipts may need human correction.
- **Subscription usage:** OCR monthly quota is enforced; external bank feeds and other unimplemented premium features are not billable or metered.
- **Production validation:** No real Supabase project migration, Stripe/Resend/Vision billing setup, external email send, live bank connector, security penetration test or accountant attestation was performed.

The milestone is **code-complete for the implemented automation and import workflows** but is not a production-certified commercial accounting platform.
