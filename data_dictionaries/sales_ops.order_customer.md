# Data Dictionary: `marketing-data-442316.sales_ops.order_customer`

**One row per order.** Order-level financials, channel attribution, and customer identity. This is the canonical table for sales, order counts, channel mix, and customer/loyalty questions.

> **Rebuilt 2026-07-24** (full history). Breaking changes — update any saved query:
> - `businessdate` → **`business_date`** (partition column)
> - `net_sales` is now the **calculated** net (`gross_sales - total_discount_amount - total_promotions_amount`); the Brink-given value moved to **`brink_net_sales`** (validation only)
> - **dropped**: `item_net_sales`, `item_netsales_with_mods`, `mods_net_sales`
> - **`is_catering` redefined** — destination-based catering is now flagged (was silently false)
> - **new `customer_type`** — required filter for customer metrics
> - `order_count` / `days_since_prev_order` **moved out** to `sales_ops.order_sequence` (and `order_count` renamed `customer_order_count`)
>
> **Further changes 2026-07-27:**
> - `is_guest_order` is now **BOOLEAN**, not INTEGER — `is_guest_order = 1` fails, use `= true`
> - **new `mapped_email_domain`**; `mapped_email` gained a SessionM loyalty-email fallback
> - `customer_type` aggregator matching widened to ezcater / doordash / itsacheckmate, and is explicitly **order-level** — see the note below the values table
>
> **Further changes synced 2026-08-13** (found deployed in the console script; full history rebuilt — `has_order_items` is populated back to 2018):
> - **new `destination_id`** (INT64) — raw Brink destination id, alongside `destination`
> - **new `has_order_items`** (BOOL, added 2026-08-04) — audit flag; FALSE = order kept by the build but carrying no qualifying item rows (~2.4% of recent rows)
> - `phone` is now **STRING** (cast at build)
> - `email` and `mapped_email` are **lowercased at build**, and the SessionM fallback email is trimmed and stripped of its leading `cater_` prefix — the email-casing gotchas below are ✅ resolved
>
> **Further changes 2026-08-17** (deployed + full history rebuilt; verified by steward query the same day):
> - **`is_employee_discount` DROPPED** — the column no longer exists on the table. Its replacement is `order_line_discount_detail.is_employee_meal_discount`, which is line-level, never NULL, and covers all four eras of the benefit. Any query naming `oc.is_employee_discount` now errors
> - **`is_catering` widened**: store 50 (Middleton Mobile) is now unconditionally catering, per finance's definition
> - **`revenue_category` aligned to `is_catering`**: pulse-flagged catering and store 50 both resolve to `'Catering'` in the base table. The two are now **equivalent sets** in `sales_ops` — they were not before
> - **`destination` / `destination_id` overridden for store 50 only**: `'Middleton Mobile Catering'` / `999999999`. Every other store keeps its raw Brink id and name

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
| `mapped_email` | STRING | Best-available email = pulse customer email → booking email → order email → **SessionM loyalty email** (last fallback added 2026-07-27). Now populated on every identified order. **Lowercased at build** since the 2026-07-29 fix (verified 2026-08-13: 0 non-lowercase values in 365 days). The SessionM fallback also strips the leading `cater_` prefix, so a catering login resolves to the same address as the individual account — compare against `loyalty_user.email_normalized`, not `email`. |
| `mapped_email_domain` | STRING | **New 2026-07-27.** Domain portion of `mapped_email`. Closes the old `mapped_domain` gap that only existed on the legacy table — internal-order exclusion can now be done on this mart. |
| `email`, `phone` | STRING | Raw contact info captured on the order (pulse order_customers). `email` is lowercased at build (since 2026-07-29); `phone` is cast to STRING (2026-08-13 sync). |

### Dates & times
| Column | Type | Description |
|---|---|---|
| `business_date` | DATE | Operating day (partition column). Canonical date for all reporting. **Renamed from `businessdate` 2026-07-24.** |
| `order_datetime` | DATETIME | Local time. Normally `ClosedTime`; if the order closed on a later day than its `business_date` (catering / advance orders), falls back to `promise_time` then `OpenedTime`. |
| `order_timestamp_utc` | TIMESTAMP | `order_datetime` converted to UTC using the store's timezone: `timestamp(order_datetime, s.timezone_name)`. **NULL whenever `store_info.timezone_name` is NULL** — see the gotcha below. The canonical column for any comparison against a UTC source (Braze); never rebuild it with a `timestamp()` cast of your own. |
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
| `customer_type` | STRING | **New 2026-07-24.** Classifies the customer **on this order**. NULL when the order has no identified customer. Order-level, not customer-level — see the table below. |
| `is_guest_order` | BOOLEAN | **Redefined 2026-07-29.** TRUE only when the order is **first-party digital** (`po.source in ('mobile_web_source','web_source','iOS','Android','mobile_source')`) **and** `pulse.order_customers.is_loyalty_user = false`. FALSE for everything else — POS, third-party (`checkmate`, `ezcater`), `Outdoor Kiosk`, `operator`, and digital orders by loyalty members. Before this fix the column was an exact alias for `pulse_order_id is null` and carried no loyalty information at all — see the gotcha. `is_guest_order = 1` has not worked since 2026-07-27 (BOOLEAN, not INTEGER). |
| `has_order_items` | BOOLEAN | **New 2026-08-04 (synced 2026-08-13), for auditing.** FALSE = the order row exists but no `brinkOrderItem` rows survived the item filters (not cleared/voided/deleted, sales > 0) — `item_gross_sales`, `mods_gross_sales`, tip-item and fee columns are NULL on these rows. ~2.4% of rows in the trailing 8 days. **⚠️ Corrected 2026-08-15 — an earlier revision of this line said "order-level financials (gross, net, payments) are still real on these orders." That is wrong for discounts.** `total_discount_amount` and `total_promotions_amount` are **silently zeroed** whenever this is FALSE, because both CTEs join on `boi.orderid` rather than `bo.id` (see the gotcha below), and `net_sales` is derived as `gross − discount − promotion` so it inherits the error. Payments and `gross_sales` are still real. |
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

The classification describes **the customer on that order**, so the same `mapped_cust_id` can carry different values across its orders. June 2026: **30 ids / 108,313 orders** have mixed types — `19192` is 107,807 `aggregator` + 196 `person` (third-party orders that happened to capture a real guest email), and 29 real people are split `person` / `internal` from occasionally ordering with a work address.

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

Moved out of this table 2026-07-24 → **`sales_ops.order_sequence`** (join on `brink_order_id` + `business_date`). See `data_dictionaries/sales_ops.order_sequence.md`. The sequence is now computed over full history every run, so the old "reload-window-scoped, treat as approximate" caveat no longer applies — but as of 2026-07-27 the table is **not** filtered to `customer_type = 'person'`, so filter it yourself.

## Gotchas

- **⚠️ OPEN 2026-08-19 — `order_timestamp_utc` is NULL for stores missing a `timezone_name`,
  which silently drops newly-opened stores from every UTC-based analysis**
  (Asana 1217684772713570). Built as `timestamp(order_datetime, s.timezone_name)`; BigQuery's
  `timestamp()` returns NULL on a NULL timezone instead of erroring. Six stores have no
  timezone today (191, 192, 196, 197, 198, 199) and two of them are trading — **8,230 orders
  over 2026-08-01 → 08-16** carry a NULL `order_timestamp_utc`. Details and the store list are
  in [`sales_ops.store_info.md`](sales_ops.store_info.md).
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

- **🔑 SessionM loads ONCE PER DAY (~03:00 MT), so today's orders have no loyalty identity**
  (steward-confirmed 2026-07-29). This is normal and permanent, not a defect.

  | `business_date` | Brink orders | SessionM-linked | `pct_sm_linked` |
  |---|---|---|---|
  | Yesterday (2026-07-28) | 26,258 | 7,868 | **30.0%** ✅ |
  | **Today (2026-07-29, 13:20 MT)** | 9,758 | **195** | **2.0%** — expected |

  A day's transactions all land in the next morning's ~03:00 load, so **yesterday and older are
  fully covered; today is not assessable for loyalty identity at all.** Consequences:

  - **The detector above will false-positive on today's date every single day.** Always exclude
    the current `business_date`. (This nearly produced a P1 raised against the ETL team over
    entirely normal behaviour — the mistake was inferring ingestion cadence from
    `last_updated_at` / `etl_time`, neither of which reflects the SessionM extract.)
  - **Never answer a customer-grain question about today.** `mapped_cust_id`, person counts,
    first-time vs repeat and anything from `order_sequence` / `customer_attribute` are all
    ~98% under-identified for today. Sales, order counts and channel mix are fine — those come
    from Brink, which loads intraday.
  - This is why the load chain is ordered **SessionM ~03:00 → `order_customer` 04:00 reload →
    `customer_attribute` 05:00**, and why `customer_attribute.attribute_asof_date` is
    `run_date - 1`. Anchoring the trailing windows on *today* would have read a day with ~2%
    loyalty identity and silently understated every customer metric. Don't "improve" that
    anchor to today.

- **`mapped_cust_id` can migrate between customers without a new order** (audited 2026-07-29).
  `sm_external_user_map` keeps one `external_user_id` per SessionM `user_id`, chosen by
  `max(updated_at)`. **6,095 user_ids (0.34%) carry more than one** `cafezupas` external id, so
  which CZ customer their orders land on is a recency tiebreak that **flips if a mapping's
  `updated_at` moves**. Exposure over 365 days: **17,269 orders · 2,913 customers · $472,797
  net**, of which **7,236 have no `pulse_customer_id`** — no fallback identity, so a flip moves
  the whole order to a different customer. This is a real and separate reason lifetime
  per-customer figures shift between builds. Fix proposed (deterministic tiebreak) in
  `design/sessionm_identity_pipeline_audit.md`.

- **✅ RESOLVED — `mapped_email` and `email` are now lowercased at build** (fix deployed
  2026-07-29 with the full-history rebuild; verified 2026-08-13: **0 non-lowercase values in
  365 days** on both columns). `lower(mapped_email)` in queries is now a harmless no-op — fine
  to keep writing defensively, no longer load-bearing.

  <details><summary>What it looked like before the fix (audited 2026-07-29)</summary>

  | Column (365d) | Non-null | NOT lowercase | Distinct raw | Distinct lowered | Casing dupes |
  |---|---|---|---|---|---|
  | `mapped_email` | 4,462,505 | 180,079 (4.04%) | 1,047,296 | 1,029,353 | **17,943** |
  | `email` | 3,392,624 | 183,466 (5.41%) | 884,293 | 883,175 | 1,118 |
  | `mapped_email_domain` | 4,462,505 | **0** | 22,342 | 22,342 | 0 ✅ |

  `count(distinct mapped_email)` overstated by ~17,900; 5,604 emails had one person split
  across multiple `mapped_cust_id`s by letter case alone. Root cause was Pulse (8.7%
  non-lowercase) — Braze and SessionM emails were already 100% clean. See
  `design/crm_identity_hygiene_plan.md` §3.

  </details>

  Related normalization: the SessionM fallback email also strips the leading **`cater_`**
  prefix (and trims), so catering logins resolve to the individual account's address in
  `mapped_email`. `claude.loyalty_user.email` keeps the prefix — compare against its
  `email_normalized`.

- **✅ RESOLVED 2026-07-29 — `customer_type` matching is now case-insensitive on all five
  branches** (all compare against `lower(...)`; verified no reclassification — case-sensitive
  and case-insensitive counts matched exactly, so the fix was purely defensive). The risk was
  a partner sending `EZCater@…` silently classifying as `person`.

- **✅ RESOLVED 2026-07-29 — SessionM `user_id` is now lowercased on all three
  `all_trans_users` branches** (`user_point_transactions`, `transaction_discounts`,
  `transaction_payments`) and in `sm_external_user_map`. Before the fix only the discounts
  branch was normalised, costing ~155 loyalty links/month.

- **✅ `is_guest_order` FIXED 2026-07-29 — it previously meant "POS order", not "guest".**

  The build read `case when ocs.is_loyalty_user is null then true else false end`. But
  `pulse.order_customers.is_loyalty_user` is a **non-nullable boolean** — 4,224,215 true /
  3,669,122 false / **0 null** — so `is null` could only fire when the pulse row was *absent*.
  The column was an exact alias for `pulse_order_id is null`.

  | June 2026 (store 1111 excluded) | Orders |
  |---|---|
  | All orders | 713,139 |
  | POS-only (`pulse_order_id is null`) | 425,630 |
  | Flagged `is_guest_order = true` | **425,630** — identical set |
  | Digital orders flagged guest | **0** |
  | Loyalty-scanned POS orders flagged guest | 94,754 ($2.21M net) |

  Every real digital guest was labelled a member; 94,754 loyalty scanners were labelled guests.
  **Any pre-2026-07-29 analysis that split on `is_guest_order` split on channel, not loyalty.**

  **New definition (steward):** a guest order is **first-party digital** *and* non-loyalty.
  Both halves matter — third-party and kiosk orders are non-loyalty by construction, not by
  guest choice.

  ```sql
  ocs.is_loyalty_user = false
  and lower(po.source) in ('mobile_web_source','web_source','ios','android','mobile_source')
  ```

  **The match is case-insensitive on purpose.** Full history holds exactly 10 distinct
  `po.source` values and one of them is `IOS` — a single order on 2023-06-14 that a
  case-sensitive in-list drops. That is the same failure class as the case-**sensitive**
  aggregator branches in `customer_type` (documented below): one oddly-cased value from
  upstream silently changes an order's classification.

  | Guest-eligible | Orders | Excluded | Orders |
  |---|---|---|---|
  | `iOS` | 2,094,394 | `checkmate` | 2,519,649 |
  | `mobile_web_source` | 950,282 | `Outdoor Kiosk` | 900,124 |
  | `web_source` | 898,673 | `operator` | 73,832 |
  | `Android` | 467,369 | `ezcater` | 19,149 |
  | `mobile_source` | 1,518 | | |
  | `IOS` | 1 | | |

  July 2026 (07-01 → 07-28), non-loyalty share by raw `po.source`:

  | `po.source` | Orders | Non-loyalty | % | Guest-eligible |
  |---|---|---|---|---|
  | `checkmate` | 90,834 | 90,834 | 100% | no — third party |
  | `ezcater` | 1,118 | 1,118 | 100% | no — third party |
  | `Outdoor Kiosk` | 34,024 | 30,165 | 88.7% | no — in-store terminal |
  | `operator` | 1,869 | 0 | 0% | no — call center |
  | `mobile_web_source` | 28,878 | **14,040** | **48.6%** | **yes** |
  | `web_source` | 15,983 | **3,186** | **19.9%** | **yes** |
  | `iOS` | 62,692 | 62 | 0.1% | yes |
  | `Android` | 12,668 | 32 | 0.3% | yes |

  **Guest checkout is a web / mobile-web feature.** The native apps sit at 0.1–0.3%
  non-loyalty — they still require login. July guest orders: **17,320**. Including
  `Outdoor Kiosk` would have added 30,165 in-store terminal orders and made the metric
  meaningless; that exclusion is the judgment call most likely to be questioned, and this is
  the reason.

  `iOS` and `Android` are genuine **raw** `po.source` values, not only the cleaned
  `order_source` labels. `mobile_source` is the legacy iOS value (1,518 orders, 2023 only) and
  is included so a full-history rebuild doesn't drop it.

  **FALSE is a catch-all, not "was a member."** It covers POS orders, third-party, kiosk,
  operator, *and* digital loyalty orders. Never read `is_guest_order = false` as "loyalty
  member" — for that, test loyalty directly (`sm_external_user_id is not null`,
  `mapped_cust_id`, or `claude.loyalty_user`). A guest *rate* must be computed against a
  first-party-digital denominator, not all orders.

  ⚠️ **The near-miss:** an interim fix added `ocs.order_id is not null` to the old predicate.
  That removes the only case that ever satisfied `is null`, so the column would have been
  `false` on **every order** — verified 0 matching rows across all 7,893,337
  `pulse.order_customers` rows. When a boolean column looks wrong, check the source column's
  null rate before patching the null test.

  Independent validation of the launch date: overall non-loyalty share of pulse orders holds
  flat at 49–51% Jan–Jun 2026, then steps to **56.2% in July** — driven entirely by
  `mobile_web_source` going to 48.6%. Guest checkout went live 2026-07-01.

- **✅ `mapped_cust_id` IS the right join key to `claude.loyalty_user`** (verified 2026-07-29
  against the live deduped view). `pulse_customer_id` and `sm_external_user_id` are the **same
  id space**, not two — of 142,386 June orders carrying both, **142,127 (99.8%) hold an
  identical value**. Only 259 differ, and just 26 of those resolve to a loyalty account.

  `mapped_cust_id` also covers materially more than `sm_external_user_id`: **27,953** June
  orders are pulse-identified with no SessionM id, and the order email agrees with the matched
  loyalty account on **26,632 (95.3%)** of them. Joining on `sm_external_user_id` silently
  drops all of those.

  ⚠️ **Do not "correct" this on the basis of an email-mismatch count.** Of the 7,568 June
  orders where `lower(mapped_email) <> loyalty_user.email`, **7,088 (93.7%) are the `cater_`
  prefix and nothing else**: the build's `sm_external_user_map` strips it
  (`regexp_replace(..., r'^cater_', '')`) while `loyalty_user.email` retains it, so
  `mapped_email` equals `email_normalized` exactly. **Compare against `email_normalized`, not
  `email`.** Only 480 are genuinely different addresses — and the `sm_external_user_id` join
  carries 6,275 mismatches of its own, so the key is not the cause.

  *(An earlier revision of this file asserted the opposite. It reached that conclusion by
  attributing the whole email-mismatch count to the join key without testing whether the two
  ids were actually distinct, or whether the documented `cater_` normalization explained the
  gap. Both checks reverse the finding.)*

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
- **✅ Grain defect RESOLVED 2026-07-29 by the full-history rebuild.** `brink_order_id` 2279778269187 (2024-09-17, store 154) previously had **two** rows: two pulse orders (4545135, 4608051) pointing at the same Brink order, double-counting $263.99 across two customers. The `pulse_orders` CTE dedupes on `brink_order_id`; the earlier `partition by po.id` was a no-op because `po.id` was already unique. **Verified 2026-07-29 across the whole table: 50,315,908 rows, 50,315,908 distinct `brink_order_id`, 0 duplicates.** The grain is now exactly one row per Brink order and `count(*)` is safe.
  - **Tiebreak direction is HIGHEST pulse id** — `qualify row_number() over(partition by po.brink_order_id order by po.id desc) = 1`. **Steward-confirmed 2026-07-29:** an earlier statement that "lowest pulse id wins" was incorrect and is retracted; highest is the rule. A brink↔pulse order map table to replace the arbitrary tiebreak is still open (Asana 1216938720407007).
- **Orders with no qualifying item rows are NOT excluded** — the item aggregation is a LEFT
  join, so an order whose items were all voided/cleared/zero still gets a row with NULL
  `item_gross_sales` / `mods_gross_sales` / tip-item / fee columns. `has_order_items = false`
  finds them (~2.4% of recent rows; that's what the column was added for on 2026-08-04). An
  earlier revision of this line claimed such orders were excluded — wrong.
- **⚠️ `total_discount_amount` and `total_promotions_amount` are ZERO on every
  `has_order_items = false` order, and that is a join-key bug — not a data absence.** Found
  2026-08-15. Both CTEs are joined on **`boi.orderid`**, the output of the `brink_order_item`
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
  Measured: **80 orders / $767.17 over 90 days** to 2026-08-15. `net_sales` inherits the error
  because it is computed as `gross − discount − promotion`.

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

Migrated here 2026-08-17 when `sql/sales_ops.order_customer.sql` was cut down to the **deployable
console text, verbatim** (the convention set for `order_line_discount_detail` the same day). The
repo script now carries no prose, so a diff against the console shows real drift and nothing else.
That convention immediately earned itself: the repo copy of `sql/claude.order_customer.sql` had
silently drifted from the deployed view in two places (missing `store_id not in (1111, 999)`,
missing the `business_date` predicate on the `order_sequence` join), both in the safe direction,
both invisible until a redeploy was attempted from the repo copy.

- **`brink_order` dedupes the raw table.** `brink.brinkOrder` holds more than one row per order id;
  the build keeps one per `id` ordered by `insertionjob`. Never read `brinkOrder` without it.
- **`cust_trans` resolves identity before deduping** (rewritten 2026-07-29). The earlier two-stage
  shape picked one user per `transaction_id` by recency and only *then* checked whether that user
  resolved to a mapping, so resolvability was incidental to the ordering. Now the inner joins run
  first and the dedupe happens once, at `pos_transaction_key` — the grain the final SELECT joins on.
  Only resolvable users can win, structurally. Verified output-equivalent over 30 days (203,855 rows
  both ways, 0 links changed): a robustness change, not a recovery. Safe because
  `pos_transaction_key` ↔ `transaction_id` is 1:1 after `header_trans` (731,353 rows, 731,353
  distinct of each, 0 reuse).
- **`sm_external_user_map` partitions on the RAW `u.user_id` while selecting `lower(u.user_id)`.**
  Harmless today — the source is 100% lowercase — and `cust_trans`'s dedupe caps any fan-out.
  Partitioning on `lower(u.user_id)` would close it properly (Asana 1216995170178886). Its inner
  join to `sessionM.users` drops nothing: 0 of 1,782,178 `cafezupas` mapping rows lack a users row
  (verified 2026-07-27, re-verified 2026-07-29 with 0 null emails).
- **`pulse_orders` scoping is safe.** `po.business_date >= start_date` cannot orphan an in-window
  Brink order: verified across June 2026, of the 55 orders where pulse and Brink business dates
  disagree, pulse is always the **later** date (lag −1 to −42 days), never earlier.
- **Dead branches in the store-50 destination CASE (2026-08-17, cosmetic).** Both the
  `destination_id` and `destination` CASE expressions open with `when bo.FKStoreId = 50`, then
  repeat the same predicate in two further branches (`642414069` / `'Catering Online Delivery'`,
  `642414070` / `'Catering Online Takeout'`). The first branch always wins, so the other two are
  unreachable — confirmed in the data: all 808 store-50 orders in the trailing 30 days carry
  `999999999` / `'Middleton Mobile Catering'` and none carry the catering-online ids. **Store 50 has
  no delivery/takeout split.** Left in the repo because the repo mirrors the console; flagged to the
  steward 2026-08-17.
- **The fee proxy would not have worked anyway.** An earlier revision of this build split catering
  destinations into Delivery vs Takeout on `total_fees_amount > 0`. `total_fees_amount` counts any
  item whose name matches `\bfee\b`, and the live set is `CZ Fee`, `Service Fee`, `Delivery Fee`,
  `Catering Delivery Fee`. Measured 2026-08-17 over the trailing 30 days: **zero** catering orders
  carried a `Delivery Fee` or `Catering Delivery Fee` item — every "Delivery" classification came
  from a `Service Fee` or `CZ Fee`. It agreed with the real Brink destination ~99% of the time by
  correlation, not by construction, and would have flipped silently the first time fee configuration
  changed. Don't rebuild it on this proxy.
