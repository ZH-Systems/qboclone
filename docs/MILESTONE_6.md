# Milestone 6: Advanced accounting and Canadian GST/HST

## Status and operating boundary
This milestone implements core general-ledger year-end close, retained earnings, adjustments, refunds and Canadian GST/HST base-rate lookup. **It is not a certified Canadian accounting or tax filing system.** All tax rates, ITCs, place-of-supply decisions, cash flow classifications and year-end policy require a CPA or qualified Canadian tax professional to review before use.

## New migrations
Apply following the merged Milestone 1–5 migrations, in lexical order:

1. `20261110140000_year_end_close.sql`: retained earnings account, protected fiscal closing and journal locking.
2. `20261110150000_payment_refunds.sql`: payment refunds, outstanding accounting and source-linked reversal controls.
3. `20261110160000_canadian_gst_hst.sql`: 2020-onward GST/HST rate reference, explicit province selection, dated tax codes, tax summary.
4. `20261110170000_advanced_reporting_adjustments.sql`: adjusting journals, year-end-aware income statement, historical aging, balance sheet, bank cash movement.
5. `20261110180000_opening_balances.sql`: one-time opening balances with a balancing equity offset.
6. `20261110190000_bad_debt_writeoffs.sql`: controlled receivable writeoffs and updated aging.
7. `20261110200000_customer_deposits.sql`: customer deposits, invoice allocation, unused deposit returns.
8. `20261110210000_scalable_year_end.sql`: dedicated protected year-end origin and support for up to 9,999 closing account lines.

Do not replay the migrations against an already-upgraded database. Restore to an isolated environment first and compare with expected schema.

## Accounting examples
**Year-end transfer:** Suppose Revenue has a $100 credit balance and Operating Expenses has a $40 debit balance for 2025. Closing journal posts Revenue DR $100, Expenses CR $40, Retained Earnings CR $60. The closing year is then locked. Annual P&L for 2025 still shows revenue of $100, expenses of $40 and net income of $60. The balance sheet includes the $60 retained earnings account. Posting into the closed fiscal period or reversing the close through the manual reversal RPC is prohibited.

**Customer refund:** An invoice for $100 is paid in full, leaving no AR. A $30 refund posts Accounts Receivable DR $30, Operating Bank CR $30, restoring $30 outstanding on the original invoice. If the refund is for goods/services returned, a source-linked $30 credit note reverses revenue and clears the restored AR. This implementation **does not** handle unapplied credits, customer deposits, processor fee refunds or cash refunds without an original allocated payment.

**Vendor payment refund:** A refunded supplier payment debits Operating Bank and credits Accounts Payable. It restores the amount owed on the vendor bill until an appropriate vendor credit is posted.

**Opening balances:** A company with no existing journal activity can import one-time debit/credit opening balances on the first date of an open fiscal period. The remaining difference is assigned to Owner Equity. If financial transactions have already posted, the import is rejected and corrections must be represented as reviewed adjustments.

**Bad debt:** A posted $100 customer invoice can be written off by $20, posting Bad Debt Expense DR $20 and Accounts Receivable CR $20, with the outstanding invoice now $80. This does not automatically claim a GST/HST bad-debt adjustment.

**Customer deposit:** A $70 prepayment is posted as Operating Bank DR $70, Customer Deposits liability CR $70. Allocating $50 to a matching posted invoice debits Customer Deposits $50 and credits Accounts Receivable $50. Any unused $20 can be returned, debiting Customer Deposits $20 and crediting Operating Bank $20. Matching contact and available balance are verified in PostgreSQL.

**Adjustments:** A qualified owner, administrator or accountant can post an explained and balanced adjustment for accruals, deferrals, reclassifications and corrections. Every posted journal remains immutable, with reversal required for corrections. An adjustment cannot be posted into a locked/closed period.

## Tax functionality
The jurisdiction tables contain core **GST/HST** rates for Canadian provinces and territories from 2020 onward, including the Nova Scotia change from **15% through March 31, 2025** to **14% effective April 1, 2025**. Ontario HST is 13%, other HST provinces are 15%, and nonparticipating provinces use federal GST at 5%.

These rates are derived from CRA:
- https://www.canada.ca/en/revenue-agency/services/tax/businesses/topics/gst-hst-businesses/charge-collect-which-rate.html
- https://www.canada.ca/en/revenue-agency/services/tax/businesses/topics/gst-hst-businesses/charge-collect-place-supply.html

**Critical restrictions:**
- Users must explicitly determine and select the correct place-of-supply province, supply type (taxable/zero-rated/exempt/out-of-scope), and effective date.
- The basic GST/HST table **excludes separate Quebec QST, British Columbia PST, Manitoba RST, Saskatchewan PST**, and industry-specific rates/rules.
- ITC recoverability is an explicitly configured percentage; it is never inferred from the province. ITC eligibility, allocation and filing methodology require independent review.
- Legacy/manual rate tax lines appear with an **UNSPECIFIED** province in the reconciliation report.
- Tax summary aggregates posted invoices/bills/credits on an accrual basis by document issue date, not GST/HST return filing method. It is **not a filed return**.
- Older rates before January 1, 2020 and transitional tax exceptions are not represented.

## Financial reports
- **Profit & loss** excludes closing-only journal lines to preserve historical profit reporting.
- **Balance sheet** uses normal account balances and separately discloses unclosed profits within equity.
- **AR/AP aging** uses original document, payment, refund and credit dates as of the selected date, rather than the current outstanding.
- **Bank movement** shows opening/closing balances and total debit/credit movements for designated bank accounts. It is *not* a formally classified cash flow statement.
- **Tax reconciliation** summarizes categorized GST/HST outputs and recorded input tax credits, including unclassified line counts.

## UI
A new **Advanced accounting** navigation section provides financial statements, formal year-end closing, payment refunds, accounting adjustments, one-time opening balances, customer deposit receipt/application/refund, bad-debt writeoffs and CRA rate lookups/tax-code creation.

## Acceptance tests
- `npm run verify` checks web/API TypeScript, unit tests and production builds.
- PostgreSQL 17 CI applies all migrations and executes all Milestone 2–6 SQL regressions in a single throwaway database.
- The Milestone 6 regression checks rate change boundaries, idempotent closing, retained earnings, historical profit, refund capacity, aging and tenant authorization.
- The extended regression verifies opening balance equity, deposit liability allocations, refunds, bad-debt settlements, cross-tenant protections, and a large year-end closure with 110 income accounts.
- Existing backup/restore CI exercise remains enabled.
- A real Supabase test environment and Canadian accountant sign-off remain required.

## Remaining work before Canadian compliance certification
- Full legal place-of-supply rules and federal/provincial indirect tax engine including PST/QST and transitional exceptions.
- CRA tax return generation, ITC/adjustment review, support for cash/quick accounting methods.
- Complete classified cash flow statement and account grouping for audited financial statements.
- Automated carry-forward reconciliation and restatement workflows.
- Payment processor refund reconciliation, unapplied overpayments, statutory bad-debt tax adjustment, and inventory/COGS.
- FX, payroll, asset depreciation, accountant sign-off, production restore testing and independent security review.

The implemented milestone is a **development-ready accounting extension**, not a claim of QuickBooks functional or statutory parity.
