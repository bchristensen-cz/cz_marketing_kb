# Data Dictionary: `marketing-data-442316.sales_ops.order_customer`

> **Companion files (split 2026-10-14 so this one loads in a single read).** The dated change-log banners (2026-07-24 → 2026-09-23) and the resolved / retracted gotchas are in [`sales_ops.order_customer.history.md`](sales_ops.order_customer.history.md). The SessionM ingestion schedule and the build-script notes are in [`sales_ops.order_customer.build.md`](sales_ops.order_customer.build.md). Text moved word for word; nothing here was rewritten.

**One row per order.** Order-level financials, channel attribution, and customer identity. This is the canonical table for sales, order counts, channel mix, and customer/loyalty questions.

> # 🚨 Rebuilt 2026-09-08 16:16 MT — identity columns MOVED OFF this table (breaking)
>
> The steward dropped and re-created the table (full history, drop + CTAS) with the **identity rework**, then chained the build into one scheduled query (`sql/sales_ops.order_marts.sql`, first scheduled run 17:02 MT). Update any saved query:
> - **DROPPED:** `mapped_cust_id`, `mapped_email`, `mapped_email_domain`, `customer_type`. They now live on **`sales_ops.order_sequence`** (join on `brink_order_id` + `business_date`), and `claude.order_customer` re-exposes all four from there, so **the `claude` view's column list is unchanged**. `sales_ops` readers must join `order_sequence`.
> - **NEW:** `acct_email`, `acct_phone` (the Pulse *account's* email/phone, vs the per-order `email`/`phone`), `sm_email` (SessionM loyalty email, `cater_` prefix stripped), `is_sys_order_email`, `is_sys_acct_email`, `has_acct_email` (INT64 0/1 flags feeding the new `mapped_cust_id` chain). `sm_external_user_id` moved to the identity block but is otherwise unchanged.
> - **Clustering changed** to `brink_order_id, pulse_customer_id, email, sm_email` (was `..., mapped_cust_id, store_id, store_name`).
> - **`is_guest_order` tightened:** now also requires `sm_email is null` — a loyalty member who scanned in-store on a digital order is no longer a guest.
> - **`in_store_scan` keys on `sm_email is not null`** (was `sm_external_user_id is not null`) — same population in practice, both come from `cust_trans`.
> - **Refresh:** hourly at :02, **5am = full history from 2018-08-07**, 8am–11pm today only, hours 0–4 / 6–7 skip. The intraday window is **today only** again (was yesterday + today from 2026-08-2x). `order_lines` and `order_line_discount_detail` now reload on exactly the same window in the same job — the timing collision of 2026-08-16→25 cannot recur.
> - **Six downstream scheduled builds still read the dropped columns** off this table (customer_attribute, bz_cid_bgnbd_palive_churn, cs_comp_points, bz_cid_weather_flag, google_offline_conversions, Braze CDI) — patch list in the steward's CLAUDE.md backlog. The `claude.order_customer` view itself was broken 16:16 → ~16:55 MT and is fixed.

## Table facts

| Property | Value |
|---|---|
| Grain | 1 row per `brink_order_id` — **one known exception**, see Gotchas |
| Row count | ~50M orders, 2018-08-07 to present |
| Partitioned by | `business_date` (DAY) — **always filter on it** |
| Clustered by | `brink_order_id`, `pulse_customer_id`, `email`, `sm_email` (since 2026-09-08 16:16; was `brink_order_id, mapped_cust_id, store_id, store_name`) |
| Refresh | **Since 2026-09-08 17:02 MT: section 1 of the chained scheduled query `sql/sales_ops.order_marts.sql`** (order_customer → order_sequence → order_lines → order_line_discount_detail, sequential, each mart's `delete`+`insert` inside its own `begin transaction` / `commit transaction`). Hourly at :02 `America/Denver`. **5am: full history from 2018-08-07** (the 8-day / 5-week / 13-month branches are commented out). 8am–11pm: **today only**. Hours 0–4 and 6–7 skip. Delete + insert by `business_date >= start_date`. Intraday run measured 2026-09-08 17:02: 68 s, 40 GiB for the whole chain (the sources were never window-bounded, so intraday ≈ full). Upstream `sales_ops.cust_map` rebuilds at 04:00 and `claude.loyalty_user` at 04:30, so the 5am full refresh always sees the day's identity map. |
| Source build script | `sql/sales_ops.order_marts.sql` section 1 (also builds `sales_ops.order_sequence`). `sql/sales_ops.order_customer.sql` is a retired pointer since 2026-09-08 |
| Upstream | `brink.*` (POS), `pulse.*` (digital ordering), `sessionM.*` (loyalty), `sales_ops.store_info`. (`sales_ops.cust_map` is read by the `order_sequence` statement, not by this table.) |

## Columns

### Identifiers
| Column | Type | Description |
|---|---|---|
| `brink_order_id` | INTEGER | POS order id. Primary key. Join key to `order_lines` and `order_sequence`. |
| `pulse_order_id` | INTEGER | Digital order id. NULL for in-store-only orders (~60% of orders). |
| `pulse_customer_id` | INTEGER | Customer id from the digital ordering platform (Pulse). May be an **orphan** — present on the order but absent from `pulse.customers` (see `customer_type = 'aggregator'`). |
| `email` | STRING | **The ORDER email — the address the guest gave for updates on *that order*, not the customer's email** (steward, 2026-08-24). Source is `pulse.order_customers.email`; we accept whatever they type and nothing forces it to match the account. `lower(trim())` at build (trim added 2026-09-08). **Never use it as an identity, join, dedup or cohort key** — that is `order_sequence.mapped_cust_id`. It *is* the right column for order-level contact questions ("which address got this receipt") and for reading the aggregator brand on third-party orders. Since 2026-09-08 it is also the join key into `sales_ops.cust_map`. |
| `phone` | STRING | Contact phone captured on the order (`pulse.order_customers.phone`), cast to STRING (2026-08-13 sync). Same caveat as `email` — per-order and user-supplied, not a customer attribute. |
| `acct_email` | STRING | **New 2026-09-08.** The Pulse **account's** email — `lower(trim(pulse.customers.email))` for `pulse_customer_id`. NULL when the order has no pulse customer or the customer row has no email (~14% of person orders in July 2026 per the 2026-08-24 measurement). This is the address that used to head the old `mapped_email` chain. |
| `acct_phone` | STRING | **New 2026-09-08.** `pulse.customers.phone` cast to STRING. Account-level counterpart of `phone`. |
| `sm_email` | STRING | **New 2026-09-08.** SessionM loyalty email resolved through `cust_trans` (transaction → user → `external_user_mappings` → `sessionM.users.email`), lowercased, leading `cater_` stripped. Populated on in-store scans and on digital orders by loyalty members. **Lags a day on the current business date**: SessionM loads once daily, so today's (and until the 5am run, yesterday's) partition carries only the handful of rows SessionM has already delivered — 2026-09-07 showed 10 of 24,147 at 16:45 MT vs ~7,600–10,300 on settled days. Don't read loyalty identification off today. |
| `sm_external_user_id` | INTEGER | Loyalty (SessionM) user mapped to a cafezupas external id, from the same `cust_trans` resolution as `sm_email`. Captures in-store loyalty scans. Same one-day lag as `sm_email`. |
| `is_sys_order_email` | INTEGER (0/1) | **New 2026-09-08.** 1 when `email` is a system address rather than a person's: `%@guest.doordash.com`, `%@itsacheckmate.com`, `support@doordash.com`, `%outdoor%@cafezupas.com` (kiosk terminals). First gate of the `mapped_cust_id` chain — see `order_sequence`. |
| `is_sys_acct_email` | INTEGER (0/1) | **New 2026-09-08.** 1 when `acct_email` is `checkmate_user@cafezupas.com` or `%outdoor%@cafezupas.com`. ~19% of orders on a settled day (kiosk + aggregator accounts). |
| `has_acct_email` | INTEGER (0/1) | **New 2026-09-08.** 1 when `acct_email is not null`. |
| ~~`mapped_cust_id`~~ | — | **MOVED to `sales_ops.order_sequence` 2026-09-08**, and redefined there (a 7-branch coalesce through `sales_ops.cust_map`, no longer `coalesce(pulse_customer_id, sm_external_user_id)`). `claude.order_customer` still exposes it. |
| ~~`mapped_email`~~, ~~`mapped_email_domain`~~ | — | **MOVED to `sales_ops.order_sequence` 2026-09-08**: now `lower(coalesce(pulse.customers.email for mapped_cust_id, order email))`. The 2026-08-24 "canonical only when a canonical exists" caveat still applies. `claude.order_customer` still exposes both. |
| ~~`customer_type`~~ | — | **MOVED to `sales_ops.order_sequence` 2026-09-08** and re-keyed on the same `coalesce(pulse.customers.email, order email)`: `kiosk` (`%outdoor%@cafezupas.com`), `aggregator` (`%ezcater%@zupas.com`, `checkmate_user@cafezupas.com`), `internal` (`@cafezupas.com`, `@tkxel.com/.io`), else `person`. **`doordash.com` / `itsacheckmate.com` order emails no longer map to `aggregator`** — those orders are gated out of `mapped_cust_id` by `is_sys_order_email` instead and mostly have no `order_sequence` row. Rows without an `order_sequence` row read NULL through the `claude` view, as before. |

### Dates & times
| Column | Type | Description |
|---|---|---|
| `business_date` | DATE | Operating day (partition column). Canonical date for all reporting. **Renamed from `businessdate` 2026-07-24.** |
| `order_datetime_local` | DATETIME | Store-local time. Normally `ClosedTime`; if the order closed on a later day than its `business_date` (catering / advance orders), falls back to `promise_time` then `OpenedTime`. **Renamed from `order_datetime` 2026-08-20/21 — the rename went base-table-wide, so `oc.order_datetime` now errors here too, not just on the `claude` view.** Verified against deployed `INFORMATION_SCHEMA.COLUMNS` 2026-08-21. **🚨 2024 rows carry a 12-hour clock with no AM/PM** (steward working note 2026-09-02, extent not yet measured in the KB): afternoon/evening orders read as hours 1–9. Workaround until the build normalises it: `case when extract(year from business_date) = 2024 and extract(hour from order_datetime_local) between 1 and 9 then extract(hour from order_datetime_local) + 12 else extract(hour from order_datetime_local) end`. Asana 1218146293827269. **2026-10-13 analyst evidence (unmeasured by the steward yet): affected store-days also appear in 2023 and 2025 (store 169 drilled), so the `year = 2024` CASE can under-correct.** Until the build is fixed, for hour-of-day work outside 2025-2026 YTD check each store-day for orders at hours 1-9 before trusting the hour, and state which correction was applied. |
| `order_timestamp_utc` | TIMESTAMP | `order_datetime_local` converted to UTC using the store's timezone: `timestamp(order_datetime_local, s.timezone_name)`. **NULL whenever `store_info.timezone_name` is NULL** — see the gotcha below. The canonical column for any comparison against a UTC source (Braze); never rebuild it with a `timestamp()` cast of your own. Inherits the 2024 12-hour-clock defect of `order_datetime_local` for the same rows. |
| `opened_time` | DATETIME | Raw POS opened time. |
| `loyalty_signup_date` | DATE | Customer's loyalty enrollment date (NULL for guests). |

### Store & channel
| Column | Type | Description |
|---|---|---|
| `store_id` | INTEGER | FK to `sales_ops.store_info`. **Store 1111 is a test/training store — ALWAYS exclude it** (`store_id <> 1111`) in all sales/order metrics. No exceptions (steward rule 2026-07-23). |
| `store_name` | STRING | Store name (denormalized). |
| `store_state` | STRING | Store state — **this is "market"**; there is no market/region/DMA/metro column anywhere. Full state name (`Utah`, not `UT`). Stores with orders in the window: Utah (30), Arizona (14), Minnesota (12), Nevada (9), Wisconsin (8), Idaho (7), Illinois (6), Ohio (3), Texas (1). **⚠️ Renamed from `state` on 2026-07-30** for consistency with `order_lines` and `store_info` — `oc.state` now fails with `Name state not found inside oc`. **NULL for stores absent from `store_info`** (1111, 999), so `store_id <> 1111` is load-bearing for geography. |
| `destination_id` | INTEGER | Raw Brink destination id (`brinkOrder.DestinationId`) for every store **except store 50**, which is stamped with the synthetic id **`999999999`** (2026-08-17, finance). `999999999` does **not** exist in `brink.brinkDestinations`, so a join back to Brink on this id drops store 50 entirely. Every other row still round-trips: verified 2026-08-17 across four sample days (2024-06-15, 2025-06-15, 2026-06-15, 2026-08-14), **0 of 77,632 non-store-50 orders differ from the raw Brink id**. `destination` is its name via `brinkDestinations` (id + store). Prefer `destination` / `revenue_category` for reporting. |
| `destination` | STRING | Raw Brink destination, **except store 50**, which is stamped `'Middleton Mobile Catering'` (2026-08-17, finance). Common values: To Stay, Takeout, DoorDash, Online Takeout, Drive Thru, Good Life Lane, UberEats, CZ Delivery, GrubHub, Catering Online Delivery/Takeout, Postmates, Fundraiser, EZ Cater Delivery/Takeout. |
| `source` | STRING | Raw pulse order source. NULL for in-store orders. |
| `revenue_category` | STRING | **Canonical channel rollup**: `In-Store`, `Digital`, `Third_Party`, `Catering`, `Fundraiser`, `Other`. Derived from `destination`, **plus two catering overrides added 2026-08-17**: a pulse-flagged catering order and any store-50 order resolve to `'Catering'` whatever their destination says. **Consequence: `revenue_category = 'Catering'` and `is_catering = true` now select exactly the same orders in `sales_ops`.** They did not before — `is_catering` used to be a strict superset, and `claude.order_customer` existed partly to paper over the difference. That view still applies its own `case when is_catering then 'Catering'` override; it is now a **no-op**, kept as a belt-and-braces guard. |
| `order_source` | STRING | Cleaned digital source: `Checkmate` (3rd-party integration), `iOS`, `Android`, `Mobile Web`, `Web`, `Outdoor Kiosk`, `Operator`, `ezcater`. NULL = in-store POS order. |
| `in_store_scan` | INTEGER (0/1) | 1 = loyalty member scanned in-store with no digital order attached. |

### Flags
| Column | Type | Description |
|---|---|---|
| `is_catering` | BOOLEAN | TRUE when the Brink destination name contains `cater`, **or** the order is at **store 50** (Middleton Mobile), **or** the pulse order is flagged catering. **Widened 2026-08-17** to add store 50, per finance's definition — 807 orders / $10.3K net in the 30 days to 2026-08-16, none of which any earlier rule caught (store 50's Brink destinations are Takeout / To Stay / Drive Thru / Fundraiser and its pulse `is_catering` is always false). **Redefined 2026-07-24** — the destination test previously never evaluated (dead code behind a NULL/false branch), which flagged POS-only catering orders as FALSE. June 2026 impact: 641 orders / $70.7K net moved from FALSE to TRUE. **⚠️ `order_lines.is_catering` does not yet carry the store-50 rule — see Gotchas.** |
| `is_guest_order` | BOOLEAN | **Tightened 2026-09-08:** also requires **`sm_email is null`** (no SessionM identity resolved on the order). **Redefined 2026-07-29.** TRUE only when the order is **first-party digital** (`po.source in ('mobile_web_source','web_source','iOS','Android','mobile_source')`) **and** `pulse.order_customers.is_loyalty_user = 0` (the predicate read `= false` until 2026-09-23, when the raw column became INT64 — same meaning). FALSE for everything else — POS, third-party (`checkmate`, `ezcater`), `Outdoor Kiosk`, `operator`, and digital orders by loyalty members. Before this fix the column was an exact alias for `pulse_order_id is null` and carried no loyalty information at all — see the gotcha. `is_guest_order = 1` has not worked since 2026-07-27 (BOOLEAN, not INTEGER). |
| `has_order_items` | BOOLEAN | **New 2026-08-04 (synced 2026-08-13), for auditing.** FALSE = the order row exists but no `brinkOrderItem` rows survived the item filters (not cleared/voided/deleted, sales > 0) — `item_gross_sales`, `mods_gross_sales`, tip-item and fee columns are NULL on these rows. ~2.4% of rows in the trailing 8 days. **Corrected 2026-08-24 (steward ruling) — the zeros on these rows are RIGHT.** These are voided/comped shells: Brink zeroes the header and voids the items. `total_discount_amount`, `total_promotions_amount` and `net_sales` all read $0.00, and **an order with no sellable lines cannot carry a discount or a promotion** — so that is the correct answer, not missing data. Verified 2026-08-24 over 2026-07-20 → 08-22: `gross_sales` is 0 on **12,327 of 12,327** such orders, and `claude.order_line_discount_detail` carries **zero** lines against them, so both marts agree at $0.00. Treat this as an audit flag, never as a correction factor — do not add these orders back into a giveaway figure. (A 2026-08-15 revision called this a join-key bug and said `net_sales` "inherits the error"; retracted 2026-08-24.) |
| ~~`is_employee_discount`~~ | — | **REMOVED 2026-08-17. The column does not exist; naming it errors.** It was an order-level 0/1 matched on Brink discount names (`%Team%`, `%Employee%`) plus SessionM offers (`%Meal%`, `%Emp%`, `%Team%`). Use **`order_line_discount_detail.is_employee_meal_discount`** instead — line-level, never NULL, covers all four eras of the benefit. Aggregate to order grain with `max()` / `logical_or()` if you need an order-level flag. |

#### `customer_type` values

Matched at build against the order's best-available email (`pulse.customers.email` → `booking_customer_email` → order email), in this branch order: kiosk → aggregator → internal → person.

| Value | Meaning | June 2026 (store 1111 excluded) |
|---|---|---|
| `person` | Real guest, including SessionM-only in-store scanners. **The only value valid for customer metrics.** | 152,593 ids · 236,783 orders · $7.44M net |
| `aggregator` | Third-party ordering funnel — `ezcater`, `doordash.com`, `guest.doordash.com`, `itsacheckmate.com`. Dominated by pulse customer id **19192**, a single id carrying 108K orders/month across 89 stores. Not a person. | 5 ids · 109,198 orders · $3.48M net |
| `kiosk` | Shared outdoor-kiosk terminal accounts (`NNN-outdoor-N@cafezupas.com`). One account per kiosk per store, thousands of orders each. | 43 ids · 35,545 orders · $737K net |
| `internal` | Employee / developer accounts (`@cafezupas.com`, `@tkxel.com`, `@tkxel.io`). | 119 ids · 736 orders · $6.5K net |
| NULL | No identified customer (`mapped_cust_id is null`). | 330,877 orders · $7.23M net |

**Why it matters:** 38% of *identified* June orders sat on non-person ids. Without the filter, customer counts, order frequency, retention, and lifetime value are all materially wrong — `19192` alone looks like a single guest ordering 108,000 times a month.

Orders from non-person ids are **still real sales** — keep them in sales, order-count, and channel metrics. Only exclude them when the unit of analysis is a *customer*.

#### `customer_type` is order-level, not customer-level (steward decision 2026-07-27)

The classification describes **the customer on that order**, so the same `mapped_cust_id` can carry different values across its orders. June 2026: **30 ids / 108,313 orders** have mixed types — `19192` is 107,807 `aggregator` + 196 `person` (third-party orders that happened to capture a real guest email), plus 29 staff ids split `person` / `internal`.

> **⚠️ Corrected 2026-08-24 — the staff split is NOT "occasionally ordering with a work address."**
> An earlier revision of this line said exactly that, and the build makes it impossible: the
> classifier reads `coalesce(c.email, ocs.booking_customer_email, ocs.email, '')`, and `c.email`
> is a *customer-level* attribute, so a canonical `@cafezupas.com` address wins on every order
> that has one. Typing a personal address at checkout cannot flip an employee to `person`.
>
> Measured July 2026 (stores 1111/999 excluded): **24 mixed ids / 286 orders, all `internal` +
> `person`, and all 24 have a canonical email.** The split is 100% clean along the order route —
> **215 `internal` orders all arrived through Pulse** (`pulse_customer_id` present, so `c` joins
> and the `@cafezupas.com` canonical wins) and **71 `person` orders were all in-store SessionM
> scans** with `pulse_customer_id` NULL, so `c` never joins, the canonical is unavailable *for
> that row*, and the chain falls through to the loyalty/order address. **The mechanism is a
> missing join, not a typed address.** (`19192` no longer appears mixed in July.)

This is deliberate. Pulse customer id `19192` **does not exist in `pulse.customers`** — it should, and there is an open ticket with the dev team. Until that record exists there is no trustworthy customer-level attribute to classify on, so collapsing to one type per id would be confidently wrong rather than visibly incomplete.

**This resolves itself upstream.** Once `pulse.customers` / `pulse.order_customers` carry a proper record for `19192`, `c.email` resolves on all of its orders, every one classifies as `aggregator`, and the mixed-type problem disappears for the id that accounts for essentially all of it. Expect the June "30 mixed ids" figure to fall to ~29 staff accounts after the fix.

Practical consequences:

- `count(distinct mapped_cust_id) where customer_type = 'person'` slightly **over**counts — an id can qualify on a handful of its orders.
- Filtering orders by `customer_type = 'person'` is still correct and is the documented rule.
- `order_sequence` carries `customer_type` per order and does **no** pre-filtering (changed 2026-07-27) — its sequence and lifetime counts span all of a customer's orders regardless of type. See its dictionary before using them.

### Financials (all FLOAT, dollars)

> **Net sales rule (steward, revised 2026-07-24):** `net_sales` is now the canonical calculated net, computed at build as `gross_sales - total_discount_amount - total_promotions_amount`. Read the column directly. All financials come from Brink only — Pulse is never a financial source (helper/metadata only).

| Column | Description |
|---|---|
| `gross_sales` | Order gross sales from Brink (`brinkOrder.GrossSales`). |
| `net_sales` | **Canonical net sales.** Calculated at build: `gross_sales - total_discount_amount - total_promotions_amount`. |
| `brink_net_sales` | Brink-given net (`brinkOrder.NetSales`). **The steward's own cross-check — NOT an accuracy reference** (ruling 2026-08-21). Do not report it, and do not measure `net_sales` against it: a "reconciliation" to this column is not evidence about our data. Two such comparisons have been published in this KB and both are retracted — a June 2026 0.0025% variance, and a 2026-08-21 per-year tie-out that produced a fictitious ~$1.15M pre-2022 discrepancy. Not exposed on `claude.order_customer`. |
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

Moved out of this table 2026-07-24 → **`sales_ops.order_sequence`** (join on `brink_order_id` + `business_date`). See `data_dictionaries/sales_ops.order_sequence.md`. The sequence is now computed over full history every run, so the old "reload-window-scoped, treat as approximate" caveat no longer applies — but as of 2026-07-27 the table is **not** filtered to `customer_type = 'person'`, so filter it yourself. **Since 2026-09-08 `order_sequence` is also where `mapped_cust_id`, `mapped_email`, `mapped_email_domain` and `customer_type` live** — this table no longer carries any of them.

## Gotchas

> Resolved and retracted gotchas (the `order_timestamp_utc` NULL fix, the lowercasing and case-insensitivity fixes, the 2026-07-29 `is_guest_order` fix, the `mapped_cust_id` ↔ `loyalty_user` join-key verification, and the pulse fan-out grain defect) moved to [`sales_ops.order_customer.history.md`](sales_ops.order_customer.history.md).

### Open and refund orders are undocumented (open gap, 2026-09-28, Asana 1218944726616107)

The mart carries no `is_closed` / `is_refund` column, and this dictionary does not yet state whether unclosed or refund orders are included or how a refund signs `net_sales`. An analyst building a FY27 budget base on 2026-09-25 joined `brink.brinkOrder` on `(Id, BusinessDate)` just to read `IsClosed` and `IsRefund`. Until the steward measures and documents this, a refund or open-order question is a data-mart gap: say so, do not join raw Brink.

### Order email vs canonical email — `email` is not who the customer is (steward 2026-08-24)

**Rule.** `sales_ops.order_customer.email` is the address the guest supplied *on that order* so we
can send order-related updates. We accept whatever they type. The **canonical** customer email
lives in **`pulse.customers.email`**. Two fields, two jobs — and the mart carries the order one
under the plainer name, which is why it keeps getting mistaken for identity.

The build chain (`sql/sales_ops.order_customer.sql`, quoted as-is — this is documentation, not a
change request):

```
, lower(ocs.email) as email                                                -- pulse.order_customers = ORDER email
, lower(coalesce(c.email, ocs.booking_customer_email, ocs.email, t.email)) -- c = pulse.customers = CANONICAL, first
    as mapped_email
```

So `email` is **always** user-typed, and `mapped_email` is canonical-when-available and user-typed
otherwise.

**Measured — July 2026, stores 1111/999 excluded, orders carrying a `pulse_customer_id`:**

| `customer_type` | orders | both emails present | order ≠ canonical | no canonical at all → `mapped_email` is user-typed |
|---|---|---|---|---|
| `person` | 136,653 | 117,485 | **1,952** (1.66%) · 1,660 ids | **19,168 (14.0%)** |
| `aggregator` | 104,684 | 104,684 | **103,337 (98.7%)** | 0 |
| `kiosk` | 34,388 | 34,388 | 0 | 0 |
| `internal` | 707 | 704 | 9 | 3 |

Those 19,168 are 18,450 orders where the `pulse.customers` row exists with `email` NULL plus 718
where it is the literal string `'nan'` — **17,842 distinct customers in a single month**. Zero
person orders had a `pulse_customer_id` missing from `pulse.customers` entirely, so this is an
empty-column problem, not an orphan-id problem.

**Why the aggregator row is 98.7%.** The order email is the *courier's* and the canonical is the
*integration account's*: 75,010 July orders carry `support@doordash.com` as the order email
against a canonical of `checkmate_user@cafezupas.com`. Both are right for their own job. The
practical consequence is worth knowing: `oc.email like '%doordash%'` finds 75,010 orders and
`oc.mapped_email like '%doordash%'` finds **none**. To read the aggregator *brand*, use `email`;
to classify the customer, use `customer_type`.

**What the 1,952 `person` divergences actually are** (top pairs, order email → canonical):

- **Apple private relay, inverted** — `jared.liebesny@gmail.com` → `srqmv8tshh@privaterelay.appleid.com`.
  The *canonical* is the relay and the *order* email is the real deliverable address.
- **Work vs personal** — `rchavez@urgencyroom.com` → `khall@urgencyroom.com`,
  `sarah.shafer40@gmail.com` → `sarah.shafer@fraser.org`.
- **Household sharing** — `marasandrabibro@gmail.com` → `kbibro1@gmail.com`.
- **Near-miss typos** — `sns1987@gmail.com` → `sna1987@gmail.com`.

Four different situations; only the last is an error. A divergence count on its own tells you
nothing about which address is "right".

**Consequences to hold onto:**

1. **Never key a cohort, dedup, retention or LTV calculation on `email`.** `mapped_cust_id` is the
   canonical key — that was already the rule, and this is the reason for it.
2. **`mapped_email` is safe as contact, unsafe as identity.** On 14% of person orders it is a typed
   address. Of the 17,842 customers with no canonical email, **7,315 have an order email equal to
   *some* `pulse.customers.email`**, and **143** of those addresses are owned by more than one
   customer id — an email-keyed merge would fuse those clusters on an address the account never
   claimed. See `design/crm_identity_hygiene_plan.md` §3.
3. **`primary_email` is NOT canonical** (steward ruling 2026-08-24). `pulse.customers` carries both:
   `primary_email` is populated on 1,962,081 rows vs `email`'s 1,817,870, differs from `email` on
   91,108 rows, and fills 173,717 rows where `email` is NULL. Tempting, and still not the field of
   record. Do not substitute it; `email` is canonical.
4. `pulse.customers` also carries **4,919 soft-deleted rows** (`deleted_at is not null`) that the
   build's `pulse_customer` CTE does not filter. Not yet measured for order impact — noted, not
   claimed.

- **⚠️ Never rebuild a UTC timestamp from `order_datetime` yourself.** `order_datetime` is
  **store-local**, so `timestamp(oc.order_datetime)` — the bare cast, which assumes UTC — is
  wrong by the store's offset, and the chain spans **four** live offsets (Ohio 4 h;
  Illinois/Minnesota/Texas/Wisconsin 5 h; Idaho/Utah 6 h; Arizona/Nevada 7 h — measured
  2026-08-01 → 08-16 over 355,700 orders). No single timezone literal is correct for Cafe
  Zupas, so the error cannot be corrected downstream by a fixed shift, and it always makes an
  order look *earlier* than it happened. Observed in 73 of one analyst's 160 queries on
  2026-08-19. Use `order_timestamp_utc`.
- **⚠️ OPEN 2026-08-17 — `order_lines.is_catering` does not have the store-50 rule, so the two
  marts disagree.** The finance catering definition was applied to `order_customer` only;
  `sales_ops.order_lines` still computes `is_catering` from raw Brink with the pre-2026-08-17
  rule. Measured 2026-08-17 over the trailing 30 closed days: **793 orders disagree, every one
  of them store 50**, `order_customer` true / `order_lines` false. Any catering figure pulled
  from `order_lines` (item counts, item mix, the report-builder artifact) **understates store 50
  to zero**; anything from `order_customer` is correct.

  `order_line_discount_detail` inherits the split — it takes `is_catering` from `order_lines`
  and `revenue_category` from `order_customer`, so a store-50 row would carry
  `revenue_category = 'Catering'` **and** `is_catering = false` at the same time. Not yet
  observable: store 50 has **0** discount lines in the trailing 90 days. It will surface the
  first time the truck rings a discount.

  **This is the third instance of one defect class.** 2026-07-24 (destination test was dead
  code), 2026-07-31 (`+644` June orders / `+$71,586`), 2026-08-17 (store 50). Every time the
  cause is the same: `is_catering` is computed **twice, independently, from raw Brink**, so a
  steward decision applied to one script silently does not apply to the other. The fix in flight
  is to merge the four order-mart scripts into one chained scheduled query and have `order_lines`
  read its header attributes from `order_customer` (steward taking it 2026-08-17) — see CLAUDE.md.
  Until that lands, **catering questions go to `order_customer`, not `order_lines`.**

- **✅ RESOLVED 2026-07-29 — SessionM identity loss (`create_date > start_date`).** Kept here
  because the failure mode is worth recognising and the detector is still worth running.

  **Fix:** `header_trans` now uses `and h.create_date >= start_date`. Deployed and verified —
  the repaired counts match the pre-fix reproduction exactly (7/21: 7,927; 7/27: 7,657;
  7/28: 7,868), which confirms the diagnosis rather than just improving the numbers.
  `pct_sm_linked` is back to 28–31% on every business day.

  The same one-character change also resolved what looked like a second, independent defect
  (intraday runs writing today with no identity). An intraday run sets
  `start_date = run_date`, so `create_date > start_date` matched nothing. One predicate, two
  symptoms.

  **Full audit of the pipeline: `design/sessionm_identity_pipeline_audit.md`** (2026-07-29) —
  all six source tables verified fresh, end-to-end link rate stable, plus three remaining
  low-severity findings.

  <details><summary>What the failure looked like (for pattern recognition)</summary>

  `sm_external_user_id` was NULL for whole business dates. Because
  `mapped_cust_id = coalesce(pulse_customer_id, sm_external_user_id)`, in-store loyalty
  scanners lost their identity entirely on those days:

  | `business_date` | All orders | SessionM-linked | Identified | Person orders |
  |---|---|---|---|---|
  | Normal day (2026-07-22) | 26,986 | 8,341 | 14,614 (54.2%) | 9,088 (33.7%) |
  | 2026-07-21 | 25,955 | **0** | 10,686 (41.2%) | **5,337 (20.6%)** |
  | 2026-07-27 | 25,100 | **74** | 10,555 (42.1%) | **5,143 (20.5%)** |
  | 2026-07-28 | 26,258 | **0** | 10,812 (41.2%) | **5,369 (20.4%)** |

  ~7,900 orders/day lost loyalty identity; person orders fell ~38%. **Order counts and all
  sales figures were unaffected and looked completely normal** — visible only by checking
  `sm_external_user_id` or person-order counts. That invisibility is the lesson: a defect can
  destroy customer-grain data while every financial number ties.

  </details>

  Detector — still worth running before any customer-grain answer covering recent dates:

  ```sql
  select
    oc.business_date
  , count(*) as all_orders
  , countif(oc.sm_external_user_id is not null) as sm_linked
  , countif(oc.customer_type = 'person') as person_orders
  , round(100 * countif(oc.sm_external_user_id is not null) / count(*), 1) as pct_sm_linked
  from `marketing-data-442316`.sales_ops.order_customer oc
  where 1=1
  and oc.business_date >= date_sub(current_date('America/Denver'), interval 14 day)
  and oc.store_id <> 1111
  group by 1
  order by 1
  ```

  Healthy is **~28–33% `pct_sm_linked`**, **excluding the current business date** — see below.
  Anything under 15% on a *completed* day means that day is corrupted.

- **The Pulse orders feed can stop on its own** (2026-09-15 → 09-22 outage: `pulse_order_id` = 0 while `sm_external_user_id` keeps loading). Signature, root cause and recovery moved to [`sales_ops.order_customer.build.md`](sales_ops.order_customer.build.md).

- **🔑 SessionM loads ONCE PER DAY — merged into `sessionM.*` at 04:07 MT — so today's orders have
  no loyalty identity; yesterday is complete from the 05:02 full rebuild** (chain re-sequenced
  2026-09-08/09; supersedes the 2026-09-04 "06:15 / 07:02" note and the 2026-07-29 "~03:00" note).
  Normal and permanent, not a defect.

  | `business_date` | Brink orders | `pct_sm_linked` | `sessionM.transaction_headers` rows |
  |---|---|---|---|
  | 2026-09-07 (Labor Day) | 24,105 | **32.8%** ✅ | 19,387 |
  | 2026-09-08 (yesterday, read 10:15 MT 09-09) | 26,618 | **31.1%** ✅ | 29,062 |
  | **2026-09-09 (today, 10:15 MT)** | 404 | **0.0%** — expected | 6,275 (yesterday's dump tail) |

  The three-step SessionM ingestion schedule, the downstream chain timings, the 2026-09-05 → 09-08 regression signature and the DTS scheduling trap moved to [`sales_ops.order_customer.build.md`](sales_ops.order_customer.build.md).

  Consequences:

  - **The detector above false-positives on today's date every single day.** Exclude it.
    (The 2026-07-29 mistake was inferring ingestion cadence from `last_updated_at` / `etl_time`;
    the correct source is the loader's own jobs on `JOBS_BY_PROJECT`.)
  - **Never answer a customer-grain question about today.** `mapped_cust_id`, person counts,
    first-time vs repeat, `in_store_scan` and anything from `order_sequence` /
    `customer_attribute` are ~98% under-identified. Sales, order counts and channel mix are
    fine — those come from Brink, which loads intraday.
  - `customer_attribute` and `loyalty_user` now both run **after** the merge, so the 2026-09-04
    open item ("customer_attribute reads an under-identified day") is closed.

- **`mapped_cust_id` can migrate between customers without a new order** (audited 2026-07-29).
  `sm_external_user_map` keeps one `external_user_id` per SessionM `user_id`, chosen by
  `max(updated_at)`. **6,095 user_ids (0.34%) carry more than one** `cafezupas` external id, so
  which CZ customer their orders land on is a recency tiebreak that **flips if a mapping's
  `updated_at` moves**. Exposure over 365 days: **17,269 orders · 2,913 customers · $472,797
  net**, of which **7,236 have no `pulse_customer_id`** — no fallback identity, so a flip moves
  the whole order to a different customer. This is a real and separate reason lifetime
  per-customer figures shift between builds. Fix proposed (deterministic tiebreak) in
  `design/sessionm_identity_pipeline_audit.md`.

- **Order-level `is_catering` ≠ catering *account*.** A catering account can place an ordinary
  individual order and it will correctly show `is_catering = false`. Worked example: Brink order
  `56569385453631` (2026-04-23, store 171, **To Stay**, $55.16) on account
  `cater_kim.harston@merit.com` / `sm_external_user_id` 3810208 — a Silver catering member since
  2024-09-12 with `is_individual_member = false`, buying lunch in the dining room. June 2026:
  **343 orders / $5,284 net across 234 catering accounts** are non-catering orders. For the
  account-level question use `claude.loyalty_user.is_catering_member` (or `account_type` on
  `claude.order_customer`), never `is_catering`.

- **Always filter `business_date`** — table is partitioned on it; unfiltered queries scan 50M rows. The column was `businessdate` before 2026-07-24.
- **`order_lines` uses `business_date` too** since the 2026-07-30 full-history rebuild — the old `BusinessDate` spelling is gone. Cross-table joins still must partition-prune **both** tables (`oc.business_date` and `ol.business_date`), but the names now match.
- **Customer metrics require `customer_type = 'person'`.** 38% of identified orders belong to kiosk terminals, internal accounts, or the orphan third-party aggregator id. Sales metrics should keep them.
- **Orders with no qualifying item rows are NOT excluded** — the item aggregation is a LEFT
  join, so an order whose items were all voided/cleared/zero still gets a row with NULL
  `item_gross_sales` / `mods_gross_sales` / tip-item / fee columns. `has_order_items = false`
  finds them (~2.4% of recent rows; that's what the column was added for on 2026-08-04). An
  earlier revision of this line claimed such orders were excluded — wrong.
- **`total_discount_amount` and `total_promotions_amount` are ZERO on every
  `has_order_items = false` order, and that is the CORRECT answer** (steward ruling
  2026-08-24) — not a defect. An order with no sellable lines cannot carry a discount or a
  promotion. The mechanics, documented 2026-08-15: both CTEs are joined on
  **`boi.orderid`**, the output of the `brink_order_item`
  CTE, instead of on `bo.id`:

  ```sql
  left join instore_emp_discounts d
  on d.order_id = boi.orderid      -- <- boi, not bo
  ...
  left join brink_promotions bp
  on bp.orderid = boi.orderid      -- <- boi, not bo
  ```

  `brink_order_item` filters `IsCleared/IsVoided/IsDeleted = false` and then applies
  `having sum(ItemGrossSales) > 0 or sum(ItemNetSales) > 0`. Any order it drops has
  `boi.orderid = NULL`, so the discount and promotion joins collapse with it and the order
  reports $0 even though the `brinkOrderDiscount` rows exist with `isDeleted = false`.
  Measured: **80 orders / $767.17 over 90 days** to 2026-08-15. `net_sales` reads $0.00 on
  these rows and is likewise correct — `gross_sales` is 0 too, so `0 - 0 - 0 = 0`.

  **Do not "fix" this by switching to `bo.id`.** The affected orders are voided/comped shells —
  Brink zeroes the header (`GrossSales` / `NetSales` / `Subtotal` / `Total` all 0) and voids the
  items but leaves the discount row standing. Nothing was sold, so nothing was given away, and
  joining on `bo.id` would book $767 of giveaway against $0 of sales and drive `net_sales`
  negative. The **zeros here are the correct answer**; the fix went into `sales_ops.order_lines`
  instead, which now suppresses the matching discount lines. See
  [`claude.order_line_discount_detail.md`](claude.order_line_discount_detail.md).

  The `has_order_items` column can be reproduced exactly from `order_lines` — verified across
  2,050,577 orders / 90 days with zero disagreements:

  ```sql
  select
    ol.brink_order_id
  , ol.business_date
  , case when sum(ol.amount) > 0 or sum(ol.item_net_sales) > 0 then true else false end as has_order_items
  from `marketing-data-442316`.sales_ops.order_lines ol
  where 1=1
  and ol.business_date between @start_date and @end_date
  and ol.line_item_type in ('item','fee','tip')
  group by
    ol.brink_order_id
  , ol.business_date
  ```

  An order absent from that result entirely (no `item` / `fee` / `tip` lines at all) is also
  `has_order_items = false`.
- Tips: `total_tip_amount` (payment tips) and delivery/other tip items are **separate mechanisms** — don't add them blindly.
- `is_guest_order` is loyalty-based; a guest can still have `mapped_cust_id` NULL and an email present.
- ~~`is_catering` is a **superset** of `revenue_category = 'Catering'`~~ — **no longer true as of
  2026-08-17.** The build now stamps `'Catering'` on pulse-flagged and store-50 orders too, so the
  two select identical sets. Use `revenue_category` for channel reporting, `is_catering` to include
  or exclude catering as a business line; they will agree.
- `revenue_category = 'Other'` is a catch-all (~5 orders/yr) — safe to ignore.
- Deduped on `brink_order_id` at build (latest insertion job wins) — but see the pulse fan-out defect above.

## Build-script notes

Moved to [`sales_ops.order_customer.build.md`](sales_ops.order_customer.build.md).
