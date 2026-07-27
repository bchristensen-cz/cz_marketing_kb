# Data Dictionary: `marketing-data-442316.sales_ops.order_customer`

**One row per order.** Order-level financials, channel attribution, and customer identity. This is the canonical table for sales, order counts, channel mix, and customer/loyalty questions.

> **Rebuilt 2026-07-24** (full history). Breaking changes — update any saved query:
> - `businessdate` → **`business_date`** (partition column)
> - `net_sales` is now the **calculated** net (`gross_sales - total_discount_amount - total_promotions_amount`); the Brink-given value moved to **`brink_net_sales`** (validation only)
> - **dropped**: `item_net_sales`, `item_netsales_with_mods`, `mods_net_sales`
> - **`is_catering` redefined** — destination-based catering is now flagged (was silently false)
> - **new `customer_type`** — required filter for customer metrics
> - `order_count` / `days_since_prev_order` **moved out** to `sales_ops.order_sequence` (and `order_count` renamed `customer_order_count`)

## Table facts

| Property | Value |
|---|---|
| Grain | 1 row per `brink_order_id` — **one known exception**, see Gotchas |
| Row count | ~50M orders, 2018-08-07 to present |
| Partitioned by | `business_date` (DAY) — **always filter on it** |
| Clustered by | `brink_order_id`, `mapped_cust_id`, `store_id`, `store_name` |
| Refresh | Hourly at minute :02. Intraday runs (8am–11pm MT) reload **today only**. 4am daily reloads 8 days; Monday 4am reloads 5 weeks; 1st of month 4am reloads ~13 months (delete + insert by `business_date >= start_date`). Hours 0–3 and 5–7 skip. |
| Source build script | `sql/sales_ops.order_customer.sql` in this repo (also builds `sales_ops.order_sequence`) |
| Upstream | `brink.*` (POS), `pulse.*` (digital ordering), `sessionM.*` (loyalty), `sales_ops.store_info` |

## Columns

### Identifiers
| Column | Type | Description |
|---|---|---|
| `brink_order_id` | INTEGER | POS order id. Primary key. Join key to `order_lines` and `order_sequence`. |
| `pulse_order_id` | INTEGER | Digital order id. NULL for in-store-only orders (~60% of orders). |
| `pulse_customer_id` | INTEGER | Customer id from the digital ordering platform (Pulse). May be an **orphan** — present on the order but absent from `pulse.customers` (see `customer_type = 'aggregator'`). |
| `sm_external_user_id` | INTEGER | Loyalty (SessionM) user mapped to a cafezupas external id. Captures in-store loyalty scans. |
| `mapped_cust_id` | INTEGER | **Canonical customer key** = `coalesce(pulse_customer_id, sm_external_user_id)`. ~53% of orders in the last year have one. Use this for customer counts, frequency, retention — **always together with `customer_type = 'person'`**. |
| `mapped_email` | STRING | Best-available email = loyalty email → booking email → order email. |
| `email`, `phone` | STRING | Raw contact info captured on the order (pulse order_customers). |

### Dates & times
| Column | Type | Description |
|---|---|---|
| `business_date` | DATE | Operating day (partition column). Canonical date for all reporting. **Renamed from `businessdate` 2026-07-24.** |
| `order_datetime` | DATETIME | Local time. Normally `ClosedTime`; if the order closed on a later day than its `business_date` (catering / advance orders), falls back to `promise_time` then `OpenedTime`. |
| `order_timestamp_utc` | TIMESTAMP | `order_datetime` converted to UTC using the store's timezone. |
| `opened_time` | DATETIME | Raw POS opened time. |
| `loyalty_signup_date` | DATE | Customer's loyalty enrollment date (NULL for guests). |

### Store & channel
| Column | Type | Description |
|---|---|---|
| `store_id` | INTEGER | FK to `sales_ops.store_info`. **Store 1111 is a test/training store — ALWAYS exclude it** (`store_id <> 1111`) in all sales/order metrics. No exceptions (steward rule 2026-07-23). |
| `store_name` | STRING | Store name (denormalized). |
| `state` | STRING | Store state. Current footprint: Utah (30 stores), Arizona (14), Minnesota (12), Nevada (9), Wisconsin (8), Idaho (7), Illinois (6), Ohio (3), Texas (1). |
| `destination` | STRING | Raw Brink destination. Common values: To Stay, Takeout, DoorDash, Online Takeout, Drive Thru, Good Life Lane, UberEats, CZ Delivery, GrubHub, Catering Online Delivery/Takeout, Postmates, Fundraiser, EZ Cater Delivery/Takeout. |
| `source` | STRING | Raw pulse order source. NULL for in-store orders. |
| `revenue_category` | STRING | **Canonical channel rollup**: `In-Store`, `Digital`, `Third_Party`, `Catering`, `Fundraiser`, `Other`. Derived from `destination`. |
| `order_source` | STRING | Cleaned digital source: `Checkmate` (3rd-party integration), `iOS`, `Android`, `Mobile Web`, `Web`, `Outdoor Kiosk`, `Operator`, `ezcater`. NULL = in-store POS order. |
| `in_store_scan` | INTEGER (0/1) | 1 = loyalty member scanned in-store with no digital order attached. |

### Flags
| Column | Type | Description |
|---|---|---|
| `is_catering` | BOOLEAN | TRUE when the Brink destination name contains `cater` **or** the pulse order is flagged catering. **Redefined 2026-07-24** — the destination test previously never evaluated (dead code behind a NULL/false branch), which flagged POS-only catering orders as FALSE. June 2026 impact: 641 orders / $70.7K net moved from FALSE to TRUE. |
| `customer_type` | STRING | **New 2026-07-24.** Classifies `mapped_cust_id`. NULL when the order has no identified customer. See the table below. |
| `is_guest_order` | INTEGER (0/1) | 1 = no loyalty user linked (via `pulse.customers.loyalty_user_id`). |
| `is_employee_discount` | INTEGER (0/1) | 1 when the order used an employee/team discount — matched via Brink discount names (`%Team%`, `%Employee%`) or SessionM offers (`%Meal%`, `%Emp%`, `%Team%`). ~1.5% of orders. |

#### `customer_type` values

Derived at build from `pulse.customers.email` and from whether the pulse customer id resolves at all.

| Value | Meaning | June 2026 (store 1111 excluded) |
|---|---|---|
| `person` | Real guest, including SessionM-only in-store scanners. **The only value valid for customer metrics.** | 152,585 ids · 237,796 orders · $7.86M net |
| `aggregator` | **Orphan pulse customer id** — referenced on orders, absent from `pulse.customers`. The third-party ordering funnel, dominated by id **19192** (30,039 distinct `@itsacheckmate.com` order emails, 89 stores, 2.48M lifetime orders). Not a person. | 22 ids · 108,023 orders · $3.02M net |
| `kiosk` | Shared outdoor-kiosk terminal accounts (`NNN-outdoor-N@cafezupas.com`). One account per kiosk per store, thousands of orders each. | 43 ids · 35,545 orders · $737K net |
| `internal` | Employee / developer accounts (`@cafezupas.com`, `@tkxel.com`, `@tkxel.io`). | 108 ids · 894 orders · $52.6K net |
| NULL | No identified customer (`mapped_cust_id is null`). | 330,881 orders · $7.23M net |

**Why it matters:** 38% of *identified* June orders (144,462 of 382,258) sat on non-person ids. Without the filter, customer counts, order frequency, retention, and lifetime value are all materially wrong — `19192` alone looks like a single guest with 2.48 million orders.

Orders from non-person ids are **still real sales** — keep them in sales, order-count, and channel metrics. Only exclude them when the unit of analysis is a *customer*.

### Financials (all FLOAT, dollars)

> **Net sales rule (steward, revised 2026-07-24):** `net_sales` is now the canonical calculated net, computed at build as `gross_sales - total_discount_amount - total_promotions_amount`. Read the column directly. All financials come from Brink only — Pulse is never a financial source (helper/metadata only).

| Column | Description |
|---|---|
| `gross_sales` | Order gross sales from Brink (`brinkOrder.GrossSales`). |
| `net_sales` | **Canonical net sales.** Calculated at build: `gross_sales - total_discount_amount - total_promotions_amount`. |
| `brink_net_sales` | Brink-given net (`brinkOrder.NetSales`). **Validation only — do NOT use for reporting.** Reconciliation June 2026: calculated net runs $479 below Brink net on $18.9M (0.0025%), concentrated in Catering (−$346) and In-Store (−$124). |
| `subtotal` | Brink subtotal. |
| `tax` | Sales tax. |
| `rounding` | Cash rounding adjustment. |
| `item_gross_sales` | Sum of item-level gross, **excluding tip items**. |
| `mods_gross_sales` | Modifier-level gross sum. |
| `total_gift_card_amount` | Gift card purchases on the order (not redemptions). |
| `total_discount_amount` | Sum of applied discounts (positive number). |
| `total_promotions_amount` | Sum of applied promotions. |
| `total_tip_amount` | Tips from payments (`brinkOrderPayment.TipAmount`). |
| `total_delivery_tip_amount` | Tips rung as the delivery-tip item (item id 640943560). |
| `total_other_tip_amount` | Tips rung as any other tip item. |
| `total_fees_amount` | Fee items (item name matches `\bfee\b` — delivery/service fees). |
| `total_payment_amount` | Sum of payments. |
| `total_change` | Change given. |

**Removed 2026-07-24:** `item_net_sales`, `item_netsales_with_mods`, `mods_net_sales`. Net is a single order-level calculation now; there is no per-item or per-modifier net in the mart (discounts and promotions are order-level and not allocated to items).

### Customer behavior

Moved out of this table 2026-07-24 → **`sales_ops.order_sequence`** (join on `brink_order_id`). See `data_dictionaries/sales_ops.order_sequence.md`. The sequence is now computed over full history every run, so the old "reload-window-scoped, treat as approximate" caveat no longer applies.

## Gotchas

- **Always filter `business_date`** — table is partitioned on it; unfiltered queries scan 50M rows. The column was `businessdate` before 2026-07-24.
- **`order_lines` still uses `BusinessDate`** (capitalized, no underscore) as of 2026-07-24 — a rename is planned. Cross-table joins must partition-prune with both spellings: `oc.business_date` and `ol.BusinessDate`.
- **Customer metrics require `customer_type = 'person'`.** 38% of identified orders belong to kiosk terminals, internal accounts, or the orphan third-party aggregator id. Sales metrics should keep them.
- **Grain defect (1 order in ~50M):** `brink_order_id` 2279778269187 (2024-09-17, store 154) has **two** rows — two pulse orders (4545135, 4608051) point at the same Brink order, double-counting $263.99 and attributing it to two different customers. The `pulse.orders` join is not guaranteed 1:1. Immaterial to totals; matters if you rely on uniqueness. Fix pending a decision on which pulse order wins.
- Orders with zero item sales are excluded (build keeps orders with item gross or net > 0).
- Tips: `total_tip_amount` (payment tips) and delivery/other tip items are **separate mechanisms** — don't add them blindly.
- `is_guest_order` is loyalty-based; a guest can still have `mapped_cust_id` NULL and an email present.
- `is_catering` is now a **superset** of `revenue_category = 'Catering'` — all catering-destination orders are TRUE, plus 48 June orders that pulse flagged as catering on In-Store/Digital destinations. Use `revenue_category` for channel reporting, `is_catering` to include or exclude catering as a business line.
- `revenue_category = 'Other'` is a catch-all (~5 orders/yr) — safe to ignore.
- Deduped on `brink_order_id` at build (latest insertion job wins) — but see the pulse fan-out defect above.
