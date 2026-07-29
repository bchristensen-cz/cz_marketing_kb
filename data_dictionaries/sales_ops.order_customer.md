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
| `mapped_email` | STRING | Best-available email = pulse customer email → booking email → order email → **SessionM loyalty email** (last fallback added 2026-07-27). Now populated on every identified order. **⚠️ NOT lowercased — always wrap in `lower()` before matching or grouping.** See the email-casing gotcha. |
| `mapped_email_domain` | STRING | **New 2026-07-27.** Domain portion of `mapped_email`. Closes the old `mapped_domain` gap that only existed on the legacy table — internal-order exclusion can now be done on this mart. |
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
| `customer_type` | STRING | **New 2026-07-24.** Classifies the customer **on this order**. NULL when the order has no identified customer. Order-level, not customer-level — see the table below. |
| `is_guest_order` | BOOLEAN (nullable) | **Redefined 2026-07-29.** Guest checkout is a **digital/Pulse concept only**. TRUE = digital order placed without a loyalty account; FALSE = digital order by a loyalty member; **NULL = in-store POS order, where the distinction does not exist.** Before this fix the column was an exact alias for `pulse_order_id is null` and carried no loyalty information at all — see the gotcha. `is_guest_order = 1` has not worked since 2026-07-27 (BOOLEAN, not INTEGER). |
| `is_employee_discount` | INTEGER (0/1) | 1 when the order used an employee/team discount — matched via Brink discount names (`%Team%`, `%Employee%`) or SessionM offers (`%Meal%`, `%Emp%`, `%Team%`). ~1.5% of orders. |

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

- **⚠️ `mapped_email` and `email` are NOT lowercased — never match or group on them raw**
  (audited 2026-07-29). `mapped_email_domain` **is** lowercased (the build lowers before
  splitting), so only the full-address columns are affected.

  | Column (365d) | Non-null | NOT lowercase | Distinct raw | Distinct lowered | Casing dupes |
  |---|---|---|---|---|---|
  | `mapped_email` | 4,462,505 | 180,079 (4.04%) | 1,047,296 | 1,029,353 | **17,943** |
  | `email` | 3,392,624 | 183,466 (5.41%) | 884,293 | 883,175 | 1,118 |
  | `mapped_email_domain` | 4,462,505 | **0** | 22,342 | 22,342 | 0 ✅ |

  **`count(distinct mapped_email)` overstates by ~17,900** because the same address in different
  case counts twice. Always `lower(mapped_email)`.

  **Root cause is Pulse, and only Pulse.** `braze.users.email` and `sessionM.users.email` are
  **100% lowercase with zero casing duplicates**; `pulse.customers.email` is 8.7% non-lowercase
  with 3,983 casing duplicates. The build lowers the SessionM email (which was already clean)
  but not the Pulse chain (which isn't) — backwards. Fix is `lower()` on the `mapped_email`
  coalesce.

  Impact on customer identity: **5,604 emails have one person split across multiple
  `mapped_cust_id`s by letter case alone** — 7.6% of all 73,429 duplicate-email clusters. See
  `design/crm_identity_hygiene_plan.md` §3.

- **`customer_type` aggregator matching is case-SENSITIVE while kiosk and internal are not**
  (audited 2026-07-29). The `kiosk` and `internal` branches use `regexp_contains(..., r'(?i)...')`,
  but the three aggregator branches use bare `like '%ezcater%'`, `like '%doordash.com'`,
  `like '%itsacheckmate.com'`. **Currently harmless** — case-insensitive and case-sensitive
  counts match exactly (ezcater 15,823 = 15,823; doordash 924,760 = 924,760; checkmate
  367,693 = 367,693), so today's aggregator emails are all lowercase. But if a partner ever
  sends `EZCater@…`, those orders silently classify as **`person`** and pollute every customer
  metric with aggregator volume. Worth making `(?i)` defensively to match the other branches.

- **SessionM `user_id` casing is only normalised on one of three branches** (audited
  2026-07-29). `all_trans_users` applies `lower()` to `transaction_discounts` (necessary — 78%
  of that table is uppercase) but **not** to `user_point_transactions` or
  `transaction_payments`, while `external_user_mappings.user_id` is 100% lowercase. Costs ~155
  loyalty links/month. Minor, but the same silent-identity-loss class as the fixed defect.

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

  **New definition (steward):** guest checkout is a digital/Pulse concept. In-store POS orders
  have no guest/member distinction, so the flag is **NULL** there — `is_guest_order = false` no
  longer sweeps them in. Boolean filters must handle three states:

  ```sql
  -- digital guests
  where oc.is_guest_order = true
  -- digital members
  where oc.is_guest_order = false
  -- everything that isn't a digital order
  where oc.is_guest_order is null
  ```

  ⚠️ **The near-miss:** the first proposed fix added `ocs.order_id is not null` to the old
  predicate. That removes the only case that ever satisfied `is null`, so the column would have
  been `false` on **every order** — verified 0 matching rows across all 7,893,337
  `pulse.order_customers` rows. When a boolean column looks wrong, check the source column's
  null rate before patching the null test.

  Validation that `is_loyalty_user = false` is the right signal: it holds flat at 49–51% of
  pulse orders Jan–Jun 2026, then steps to **56.2% in July** — matching guest checkout going
  live 2026-07-01.

- **⚠️ `mapped_cust_id` is NOT a valid join key to `claude.loyalty_user`** (steward 2026-07-29).
  `mapped_cust_id = coalesce(pulse_customer_id, sm_external_user_id)` mixes two id spaces, so
  joining it to `loyalty_user.sm_external_user_id` matches **Pulse** ids against **SessionM**
  ids. June 2026: of 287,563 pulse-identified orders, 170,160 matched a loyalty row and
  **7,270 of those matched an account whose email disagrees with the order's email** — wrong
  people. A further 142,440 orders hold *both* ids, and the coalesce discards the known-good
  SessionM one.

  **Always join on `oc.sm_external_user_id`** — the dictionary-verified 100%-match key. This
  yields no loyalty attributes on pulse-only digital orders; that gap is real and is what the
  email bridge in `design/crm_identity_hygiene_plan.md` exists to close. A NULL is recoverable,
  a wrong attribution is not.

- **Order-level `is_catering` ≠ catering *account*.** A catering account can place an ordinary
  individual order and it will correctly show `is_catering = false`. Worked example: Brink order
  `56569385453631` (2026-04-23, store 171, **To Stay**, $55.16) on account
  `cater_kim.harston@merit.com` / `sm_external_user_id` 3810208 — a Silver catering member since
  2024-09-12 with `is_individual_member = false`, buying lunch in the dining room. June 2026:
  **343 orders / $5,284 net across 234 catering accounts** are non-catering orders. For the
  account-level question use `claude.loyalty_user.is_catering_member` (or `account_type` on
  `claude.order_customer`), never `is_catering`.

- **Always filter `business_date`** — table is partitioned on it; unfiltered queries scan 50M rows. The column was `businessdate` before 2026-07-24.
- **`order_lines` still uses `BusinessDate`** (capitalized, no underscore) as of 2026-07-24 — a rename is planned. Cross-table joins must partition-prune with both spellings: `oc.business_date` and `ol.BusinessDate`.
- **Customer metrics require `customer_type = 'person'`.** 38% of identified orders belong to kiosk terminals, internal accounts, or the orphan third-party aggregator id. Sales metrics should keep them.
- **✅ Grain defect RESOLVED 2026-07-29 by the full-history rebuild.** `brink_order_id` 2279778269187 (2024-09-17, store 154) previously had **two** rows: two pulse orders (4545135, 4608051) pointing at the same Brink order, double-counting $263.99 across two customers. The `pulse_orders` CTE dedupes on `brink_order_id`; the earlier `partition by po.id` was a no-op because `po.id` was already unique. **Verified 2026-07-29 across the whole table: 50,315,908 rows, 50,315,908 distinct `brink_order_id`, 0 duplicates.** The grain is now exactly one row per Brink order and `count(*)` is safe.
  - **Tiebreak direction is HIGHEST pulse id** — `qualify row_number() over(partition by po.brink_order_id order by po.id desc) = 1`. **Steward-confirmed 2026-07-29:** an earlier statement that "lowest pulse id wins" was incorrect and is retracted; highest is the rule. A brink↔pulse order map table to replace the arbitrary tiebreak is still open (Asana 1216938720407007).
- Orders with zero item sales are excluded (build keeps orders with item gross or net > 0).
- Tips: `total_tip_amount` (payment tips) and delivery/other tip items are **separate mechanisms** — don't add them blindly.
- `is_guest_order` is loyalty-based; a guest can still have `mapped_cust_id` NULL and an email present.
- `is_catering` is now a **superset** of `revenue_category = 'Catering'` — all catering-destination orders are TRUE, plus 48 June orders that pulse flagged as catering on In-Store/Digital destinations. Use `revenue_category` for channel reporting, `is_catering` to include or exclude catering as a business line.
- `revenue_category = 'Other'` is a catch-all (~5 orders/yr) — safe to ignore.
- Deduped on `brink_order_id` at build (latest insertion job wins) — but see the pulse fan-out defect above.
