# Milestone 9: Accounting feature completion

## Implemented accounting workflows

**1. FIFO perpetual inventory.** Stock products and unique SKUs are tenant-scoped. Posted supplier bill lines can be received into a tracked FIFO cost lot. Receipt reclassifies the bill line's net-of-recoverable-tax expense as Inventory Asset. A posted customer invoice line can issue inventory against the oldest available lots, debiting Cost of Goods Sold and crediting Inventory Asset. Both operations require an explicit action, create a balanced journal, and write source-linked audit records. The system prevents duplicate receipt/issue per document line, rejects insufficient stock and protects these source journals from manual reversal.

Inventory limitations: opening lot registration is only available against a previously imported one-time opening balance journal; single CAD valuation currency, positive cost lots only, no negative inventory, no bundles/kits, serials, cycle counts, inventory shrinkage, inventory returns, landed costs, valuation method changes, or automated QBO stock valuation. Inventory receipt on a bill must not be interpreted as a goods-receipt workflow independent of billing.

**2. Vendor advances.** Supplier prepayments are recorded as a Supplier Advances asset until applied against the payable on a posted vendor bill. Unused advances can be refunded. The database enforces the vendor relationship, remaining balance and source journal integrity.

**3. CAD-functional foreign-currency settlement.** Selected draft invoices/bills can be denominated in another currency while retaining a posted CAD value and a specified recognition exchange rate. The payment flow records foreign amounts, CAD bank movement and realized exchange differences in dedicated gain/loss accounts, without floating-point money handling.

FX limitations: this is not an IAS 21-compliant multi-currency subledger. No period-end unrealized FX revaluation, historical foreign-currency line pricing, foreign-currency bank account and transfer support, foreign-denominated credit-note allocations or FX hedge reporting. CAD remains the functional currency. A qualified accountant must validate recognition and settlement methods before live use.

**4. Canadian provincial sales-tax reference previews.** Provides selectable, separately displayed BC PST, Manitoba RST, Saskatchewan PST and Quebec QST reference calculations alongside existing federal GST/HST rates. These are date-aware informational estimates, not a verified combined tax engine or statutory reporting module. Users must determine tax applicability, registration, nexus, place of supply, exemptions, combined tax bases, recoverability and applicable rates. This feature does not automatically post provincial liabilities or generate filing returns.

**5. QuickBooks inventory catalog mapping.** The QuickBooks source normalizer retains item SKU, name, source type, original quantity on hand, purchase cost and asset account reference. An accountant-approved batch imports only validated inventory SKUs, preserving a source-to-target crosswalk. It **does not automatically post stock balances** or invent FIFO source lots from a QBO snapshot. Historical inventory valuation must be reconciled to source inventory reports. The `register_inventory_opening_lots` workflow accepts costed opening lots **only after** the one-time opening-balance journal has already debited Inventory Asset for the identical total cost. This registers quantities without double-posting that asset.

## Deployment

Apply following all merged Milestone 1–8 migrations, ordered by filename:

- `20261110340000_fifo_inventory.sql`
- `20261110350000_vendor_advances.sql`
- `20261110360000_fx_settlements.sql`
- `20261110370000_provincial_tax_preview.sql`
- `20261110380000_inventory_migration_opening.sql`

The Advanced Accounting workspace includes Inventory, Vendor Advances, Foreign Currency and Provincial Tax Estimate views, in addition to previous accounting workflows. The QuickBooks migration workspace includes safe inventory SKU import. These features require the existing Supabase account/tenant setup and valid open fiscal periods.

## Regression and acceptance

The CI database pipeline applies every ordered migration to PostgreSQL 17 and runs historical Milestone 2–9 accounting tests. New tests cover:

- FIFO receipt/issue lots, stock value, COGS, replay protection, tenant isolation.
- Vendor advance receipt, application, refund and outstanding payable.
- CAD recognition, foreign settlement, realized FX differences, idempotency.
- Provincial tax reference calculations, date filtering and access controls.
- QBO product mapping with **no automatic source stock quantity/value posting**, plus reconciliation of approved opening lots against the posted inventory asset opening journal.
- PostgreSQL backup/archive and isolated restore rehearsal.

Front-end/API TypeScript, Vitest, and production builds run through the existing web validation workflow.

## Outstanding before accounting or commercial certification

This milestone does not finish:
- Full source-to-target semantic migration of historical payroll, inventory costing/returns, asset depreciation, all attachments, unsupported QBO tax scenarios or unapplied credits.
- Canadian province-specific tax exemptions and real filing workflows, Quebec QST tax-on-tax nuances where applicable, place-of-supply and recoverability.
- Full foreign currency accounting including unrealized remeasurement, exchange-rate sourcing, foreign-currency cash accounts and full audit-ready presentation.
- Inventory valuation adjustments, physical counts, returns and correction workflows.
- External CPA signoff, production Plaid/Intuit/Stripe/Resend/OCR provider validation, real tenant-isolation penetration testing, production backup and restore, regulatory/privacy approvals.

**Milestone 9 is an engineering enhancement, not a claim of QuickBooks accounting or tax compliance parity.** Do not deploy live financial operations without professional review, a documented opening balance/stock import, and end-to-end acceptance testing.
