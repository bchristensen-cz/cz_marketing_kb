# Data Dictionary: `marketing-data-442316.claude.order_customer`

**One row per order.** The standard user's order table — a view over `sales_ops.order_customer` that adds order sequencing, lifetime customer metrics, and loyalty account type, restricts history to a rolling 3 years, and **excludes test store 1111 entirely**.

| | |
|---|---|
| Type | **View** (not materialized) |
| Grain | 1 row per order (`brink_order_id`) |
| Partition column | **`business_date`** — always filter it |
| Upstream | `sales_ops.order_customer` (base) + `sales_ops.order_sequence` + `sales_ops.customer_attribute` + `claude.loyalty_user` |
| Build script | `sql/claude.order_customer.sql` |
| History | **2023-01-01 forward** (rolling 3 years — see below) |
| Created | 2026-07-29 |

> **This is the table most people should be querying.** Standard access is `dataViewer` on the `claude` dataset only; `sales_ops.order_customer` returns `Access Denied` for everyone except the steward. If you have `sales_ops` access, read `sales_ops.order_customer.md` instead — the two are **not** interchangeable, for the three reasons below.

---

## The four ways this view differs from its parent

Anyone comparing a number from here against a number from `sales_ops` needs all four. **State which dataset you queried whenever a figure will be compared to someone else's.**

### 1. History is a rolling 3 years, and truncation is silent

```sql
where oc.business_date >= date_trunc(date_sub(current_date, interval 3 year), year)
```

As of 2026-07-29 the floor is **2023-01-01**. It steps forward every January 1.

A question about 2022 returns **zero rows, not an error** — which presents to the user as "no sales in that period." Confirm the requested range sits inside the window before reporting an empty or surprisingly small result, and state the floor whenever a question reaches near it. The steward querying `sales_ops` sees full history, so this is a common source of two people getting irreconcilable numbers.

### 2. `revenue_category` is overridden

```sql
case when oc.is_catering = true then 'Catering' else oc.revenue_category end as revenue_category
```

**In `claude`, `revenue_category = 'Catering'` and `is_catering = true` are equivalent.** In `sales_ops` they are not — `is_catering` is a superset, catching orders that Pulse flagged as catering on In-Store/Digital destinations (48 such orders in June 2026).

Practical effect: a channel breakdown from `claude` assigns those orders to Catering; the same breakdown from `sales_ops` leaves them in In-Store/Digital. **Neither is wrong — they are different definitions.** Don't "correct" one to match the other; say which you used.

This is a deliberate simplification: it removes the superset/subset trap for users who only ever see this view.

### 3. Sequencing and lifetime columns are folded in

There is **no `claude.order_sequence` and no `claude.customer_attribute`.** They are not missing — this view left-joins both onto the order grain, so a standard user gets first-time-vs-repeat, recency, and LTV from one table. See the added-columns section below.

### 4. Test store 1111 is excluded at the view level (documented 2026-08-13)

```sql
and oc.store_id <> 1111
```

The deployed view filters the test store out entirely — a standard user **cannot see store 1111 at all**, while the steward's `sales_ops` tables still contain it. Keep writing `store_id <> 1111` in queries anyway (it's free here and load-bearing on every `sales_ops` table), but know that a `claude`-vs-`sales_ops` total that differs by a few hundred orders/month is probably this filter, not a defect. Two side effects: the measured zero-trap numbers below predate the filter (the "person, store 1111" rows no longer appear here), and `customer_order_count` is computed upstream *including* 1111 orders, so a customer who ever ordered at the test store can show a gap in their visible sequence numbers.

---

## Columns

### Passthrough columns (44)

Identical to `sales_ops.order_customer` — **see [`sales_ops.order_customer.md`](sales_ops.order_customer.md) for full descriptions**, deliberately not duplicated here so the two can't drift:

`brink_order_id`, `pulse_order_id`, `is_catering`, `is_guest_order`, `pulse_customer_id`, `sm_external_user_id`, `business_date`, `order_datetime`, `order_timestamp_utc`, `store_id`, `store_name`, `store_state`, `destination_id`, `destination`, `source`, `order_source`, `in_store_scan`, `opened_time`, `gross_sales`, `item_gross_sales`, `mods_gross_sales`, `subtotal`, `total_gift_card_amount`, `total_discount_amount`, `total_promotions_amount`, `is_employee_discount`, `total_tip_amount`, `total_delivery_tip_amount`, `total_other_tip_amount`, `brink_net_sales`, `net_sales`, `rounding`, `tax`, `total_fees_amount`, `total_payment_amount`, `total_change`, `has_order_items`, `email`, `phone`, `mapped_email`, `mapped_email_domain`, `mapped_cust_id`, `customer_type`, `loyalty_signup_date`

(Updated 2026-08-13: `state` renamed to `store_state` 2026-07-30; `destination_id` and `has_order_items` added to the base table and now advertised here after a metadata-refresh redeploy — new base columns flow through `oc.*` at query time but stay invisible in `INFORMATION_SCHEMA.COLUMNS` until the view is redeployed, same trap as the rename.)

Plus `revenue_category`, which is present but **redefined** — see difference #2 above.

All the usual rules still apply to these: `net_sales` is the canonical calculated net (`brink_net_sales` is validation only), `is_catering` and `is_guest_order` are BOOLEAN, and customer metrics require `customer_type = 'person'`. Emails are lowercased at build since 2026-07-29, so `lower()` is defensive rather than required; store 1111 is already excluded by the view itself (difference #4).

### Added columns (13)

| Column | Type | Source | Description |
|---|---|---|---|
| `customer_order_count` | INT64 | `order_sequence` | This order's sequence number for the customer. `1` = first order. **`coalesce(…, 0)`** — see the zero trap |
| `days_since_prev_order` | INT64 | `order_sequence` | Days since that customer's previous order. **`coalesce(…, 0)`** — `0` on a first order *and* on an unidentified order |
| `lifetime_order_count` | INT64 | `customer_attribute` | Customer's lifetime order count. **`coalesce(…, 0)`** |
| `lifetime_catering_order_count` | INT64 | `customer_attribute` | Lifetime catering orders. **`coalesce(…, 0)`** |
| `lifetime_guest_order_count` | INT64 | `customer_attribute` | Lifetime guest orders. **`coalesce(…, 0)`**. Note the upstream `is_guest_order` defect — see gotchas |
| `lifetime_net_sales` | FLOAT64 | `customer_attribute` | Lifetime net sales. **NULL, not 0**, when absent |
| `lifetime_gross_sales` | FLOAT64 | `customer_attribute` | Lifetime gross sales. **NULL** when absent |
| `lifetime_avg_check` | FLOAT64 | `customer_attribute` | Lifetime average check. **NULL** when absent |
| `first_order_date` | DATE | `customer_attribute` | Customer's first-ever order date. **NULL** when absent. Not bounded by this view's 3-year window |
| `last_order_date` | DATE | `customer_attribute` | Customer's most recent order date. **NULL** when absent |
| `days_since_last_order` | INT64 | `customer_attribute` | Recency as of the attribute build. **NULL** when absent |
| `customer_tenure_days` | DATE→INT64 | `customer_attribute` | Days between first order and the attribute build |
| `account_type` | STRING | `loyalty_user.member_program` | **Account-level** catering flag: `'individual'` / `'catering'` / `'both'` / NULL. Derived from the SessionM tier system — the canonical catering-vs-individual member split. **NULL for 62.9% of orders** (June 2026) because only loyalty members have it. Distinct from `is_catering`, which describes the *order*, not the account |

> **`customer_attribute` is as-of *yesterday*, not real-time.** All `lifetime_*`, `first/last_order_date`, `days_since_last_order` and `customer_tenure_days` values come from a daily build. They do **not** include today's orders, and on the current business date they lag. Don't expect `lifetime_order_count` to equal a `count(*)` you compute from this view over full history.

---

## 🛑 The zero trap — the most likely way to get a wrong number here

Five of the added INT columns are wrapped in `coalesce(…, 0)`. **`0` means "no matching upstream row," not "a customer with zero orders."** No such customer exists — every customer has at least one order.

Worse, the two zero-producing joins **don't agree with each other**, and the FLOAT/DATE columns describing the same absent customer read `NULL` while the INT columns read `0`.

Measured on June 2026 (713,575 orders):

| Population | Orders | `customer_order_count = 0` | `lifetime_order_count = 0` |
|---|---|---|---|
| Unidentified (`mapped_cust_id is null`) | 330,944 | **all** | **all** |
| `person`, real stores | 236,784 | 0 | 0 |
| `aggregator` | 109,198 | 0 | 231 |
| `kiosk` | 35,553 | 0 | **all 35,553** |
| `internal` | 756 | 0 | 237 |
| `person`, store 1111 | 340 | 0 | 240 |
| **Total zeros** | | **330,944** (46.4%) | **367,205** (51.5%) |

Two rules fall out of this:

1. **`customer_order_count = 0` ⟺ `mapped_cust_id is null`.** Exact, both directions. It is a reliable "unidentified order" test.
2. **`lifetime_order_count = 0` is broader** — it means "no `customer_attribute` row," which covers every unidentified order *plus* essentially all kiosk orders, most `internal`, most store-1111 person orders, and a small aggregator remainder. **36,261 June orders have a valid sequence number but zero lifetime values.**

### What to do

| Goal | Do this | Not this |
|---|---|---|
| First-time orders | `customer_order_count = 1` | — (`0` is the unidentified bucket, so this is already safe) |
| Repeat orders | `customer_order_count > 1` | `customer_order_count >= 1` |
| Identified orders | `mapped_cust_id is not null` or `customer_order_count > 0` | — |
| Average LTV / lifetime orders | filter `lifetime_order_count > 0` **and** `customer_type = 'person'` first | `avg(lifetime_order_count)` over all rows — the zeros crush the mean |
| Average check from lifetime | `avg(lifetime_avg_check)` is safe (NULLs are skipped) but still filter `customer_type = 'person'` | mixing it with the coalesced INT columns and assuming the same denominator |
| Customer counts | `count(distinct mapped_cust_id)` with `customer_type = 'person'` | `count(distinct …)` unfiltered |

**Never present `lifetime_order_count = 0` as a customer segment.** If a cut shows a large "zero lifetime orders" group, that's the unidentified-and-non-person population, not a behavioral cohort.

---

## Gotchas

- **Don't average a coalesced column.** See the zero trap above. This is the single most likely error on this view.
- **`customer_order_count` and `lifetime_order_count` disagree by design.** They come from different joins with different population rules. Don't reconcile them; pick the one that matches the question.
- **`account_type` ≠ `is_catering`.** `account_type` is the *account's* program membership (from the loyalty tier system); `is_catering` is whether *this order* was catering. A catering-program member ordering lunch for themselves is `account_type = 'catering'`, `is_catering = false`.
- **`account_type` is NULL for non-members** (62.9% of June orders). `account_type is null` means "not a loyalty member or not matched," not "individual." Don't use it as a two-way flag.
- **`revenue_category` here ≠ `revenue_category` in `sales_ops`.** See difference #2.
- **`lifetime_guest_order_count` inherits a known upstream defect.** `is_guest_order` was historically an alias for `pulse_order_id is null`, carrying no loyalty information, so guest counts computed before the fix are wrong. The mart fix is written; a full-history rebuild is pending. Treat guest lifetime counts as provisional.
- **First-time orders only go back to 2023-03-06** in the underlying `order_sequence`, so `customer_order_count = 1` means "first order since March 2023," not first-ever. `first_order_date` (from `customer_attribute`) is not bounded that way — prefer it for true first-ever questions.
- **Sequence numbers are computed across all of a customer's orders, then filtered.** Mixed-type ids (30 in June 2026) show million-scale `customer_order_count` on their person rows — `mapped_cust_id` 19192 sits around 2.48M. Treat those as unreliable.
- **Store 1111 is excluded by the view itself** (difference #4, documented 2026-08-13) — writing `store_id <> 1111` here is a harmless no-op; keep the habit for `sales_ops` tables where it's load-bearing. Sequence numbers upstream are still built *including* 1111 orders, so visible sequences can have gaps for customers who ever ordered there.
- **It's a view, not a table.** A heavy query re-runs the full join every time. For repeated multi-step work, materialize into `scratch` — though standard users have no write access, so in practice: keep the partition filter tight.
- **Grain:** verified 713,575 rows = 713,575 distinct `brink_order_id` for June 2026, 0 duplicates. The historical `pulse.orders` fan-out defect was resolved by the 2026-07-29 full-history rebuild. Use `count(distinct brink_order_id)` if exact uniqueness matters on older data.

---

## Open question

`customer_attribute` is documented as person-only, which would predict that **all** non-person orders lack lifetime values. Observed June 2026: `kiosk` is 100% zero as expected, but `aggregator` is only 0.2% zero (231 of 109,198) and `internal` 31%. So aggregator ids largely *do* have `customer_attribute` rows. Either the person-only rule isn't applied the way the docs describe, or those ids carry `person` rows elsewhere in history. Worth confirming before anyone builds a segmentation that leans on non-person lifetime values (logged as a `KB finding:` Asana task).
