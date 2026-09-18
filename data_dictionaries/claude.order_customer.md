# Data Dictionary: `marketing-data-442316.claude.order_customer`

**One row per order.** The standard user's order table — a view over `sales_ops.order_customer` that adds order sequencing, lifetime customer metrics, and loyalty account type, restricts history to a rolling 3 years, and **excludes test store 1111 entirely**.

| | |
|---|---|
| Type | **View** (not materialized) |
| Grain | 1 row per order (`brink_order_id`) |
| Partition column | **`business_date`** — always filter it |
| Upstream | `sales_ops.order_customer` (base) + `sales_ops.order_sequence` (**since 2026-09-08 also the source of `mapped_cust_id`, `mapped_email`, `mapped_email_domain`, `customer_type`, and the join key for the next two**) + `sales_ops.customer_attribute` + `claude.loyalty_user` (a table since 2026-09-01, refreshed daily 04:30 MT — so `account_type` lags SessionM by up to a day, like the `lifetime_*` columns) |
| Build script | `sql/claude.order_customer.sql` |
| History | **2023-01-01 forward** (rolling 3 years — see below) |
| Created | 2026-07-29 |

> **🚨 Outage 2026-09-08 16:16 → ~16:55 MT.** The base table was dropped and rebuilt without `mapped_cust_id`; this view joined on `oc.mapped_cust_id`, so every query failed with `Name mapped_cust_id not found inside oc` for ~40 minutes. Redeployed keying the `customer_attribute` and `loyalty_user` joins on `os.mapped_cust_id` and re-exposing the four identity columns from `order_sequence`. **Column list unchanged for you** — but `mapped_cust_id` changed *definition* that day (see `sales_ops.order_sequence.md`), so customer counts and cohorts computed before and after 2026-09-08 are not strictly comparable. `lifetime_*` and `account_type` re-key at the 05:00 `customer_attribute` run on 2026-09-09 — until then a few percent of person orders show `lifetime_order_count = 0` (21 of 4,836 on 2026-09-07 at 16:55).
>
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

**In `claude`, `revenue_category = 'Catering'` and `is_catering = true` are equivalent.**

**⚠️ Updated 2026-08-17 — this override is now a NO-OP, and the `claude`/`sales_ops` difference it
existed to hide is gone.** The base build now stamps `'Catering'` on pulse-flagged and store-50
orders itself, so the two columns select identical sets in `sales_ops` as well. A channel breakdown
run against either layer now returns the same answer. The line is kept in the view deliberately, as
a guard in case the base definitions diverge again — not because it currently changes anything.

Historic behaviour, kept because it explains numbers in older reports: `is_catering` used to be a
strict **superset** of `revenue_category = 'Catering'` in `sales_ops`, catching orders Pulse flagged
as catering on In-Store/Digital destinations (48 such orders in June 2026). A channel breakdown from
`claude` assigned those to Catering; the same breakdown from `sales_ops` left them in In-Store /
Digital. Neither was wrong — they were different definitions — but a `claude`-vs-`sales_ops`
channel-mix discrepancy dated before 2026-08-17 is very likely this.

### 3. Sequencing and lifetime columns are folded in

There is **no `claude.order_sequence` and no `claude.customer_attribute`.** They are not missing — this view left-joins both onto the order grain, so a standard user gets first-time-vs-repeat, recency, and LTV from one table. See the added-columns section below.

### 4. Test stores 1111 and 999 are excluded at the view level (documented 2026-08-13, corrected 2026-08-17)

```sql
and oc.store_id not in (1111, 999)
```

⚠️ The 2026-08-13 entry recorded this as `store_id <> 1111`, and so did the repo copy of
`sql/claude.order_customer.sql`. The **deployed** view has always excluded both. Corrected here and
in the repo script 2026-08-17, after a redeploy from the stale repo copy would have quietly
readmitted store 999 — the store with no `store_info` row, hence a NULL `store_name` / `store_state`
that forms a second unnamed group in any store or market breakout.

The deployed view filters both test stores out entirely — a standard user **cannot see store 1111 or 999 at all**, while the steward's `sales_ops` tables still contain them. **Don't add `store_id not in (1111, 999)` to queries against this view** (steward rule 2026-09-03; the earlier "keep writing it anyway" guidance is withdrawn) — it is load-bearing only on `sales_ops` tables. Know that a `claude`-vs-`sales_ops` total that differs by a few hundred orders/month is probably this filter, not a defect. Two side effects: the measured zero-trap numbers below predate the filter (the "person, store 1111" rows no longer appear here), and `customer_order_count` is computed upstream *including* 1111 orders, so a customer who ever ordered at the test store can show a gap in their visible sequence numbers.

---

## Columns

> **⚠️ Renamed 2026-08-20 — `order_datetime` is exposed here as `order_datetime_local`.** The view is
> `oc.* except(brink_net_sales, order_datetime), oc.order_datetime as order_datetime_local`. Value and
> type are unchanged (DATETIME, store-local). ⚠️ **Updated 2026-08-21 — the sentence that used to sit
> here ("`sales_ops.order_customer` still calls it `order_datetime`") is no longer true.** The rename
> went **base-table-wide** overnight 2026-08-20 → 08-21 with the order-mart chaining rebuild:
> `sales_ops.order_customer`, `sales_ops.order_lines` and both `claude` views now expose
> `order_datetime_local` and **nothing** exposes `order_datetime`. Verified against deployed
> `INFORMATION_SCHEMA.COLUMNS` 2026-08-21. The one object that still has `order_datetime` is the
> retired `sales_ops.OrderCustomer`, where it is a **TIMESTAMP holding local time** — see the
> `sales-ops-orders` skill. Selecting `oc.order_datetime` anywhere else now errors. The rename exists because
> the old name gave no hint that the value was local, and `timestamp(order_datetime)` — a bare cast
> that assumes UTC — appeared in 73 of one analyst's 160 queries on 2026-08-19. Use
> `order_timestamp_utc` for anything cross-source; see the `sales-ops-orders` and `braze-campaigns`
> skills. Same rename applied to `claude.order_lines`, which has **no** UTC column at all — join to
> `order_customer` if you need UTC at line grain.

### Passthrough columns (43)

Identical to `sales_ops.order_customer` — **see [`sales_ops.order_customer.md`](sales_ops.order_customer.md) for full descriptions**, deliberately not duplicated here so the two can't drift:

`brink_order_id`, `pulse_order_id`, `is_catering`, `is_guest_order`, `pulse_customer_id`, `sm_external_user_id`, `business_date`, `order_datetime_local`, `order_timestamp_utc`, `store_id`, `store_name`, `store_state`, `destination_id`, `destination`, `source`, `order_source`, `in_store_scan`, `opened_time`, `gross_sales`, `item_gross_sales`, `mods_gross_sales`, `subtotal`, `total_gift_card_amount`, `discount_amount`, `promotions_amount`, `total_discount_amount`, `total_tip_amount`, `total_delivery_tip_amount`, `total_other_tip_amount`, `net_sales`, `rounding`, `tax`, `total_fees_amount`, `total_payment_amount`, `total_change`, `has_order_items`, `email`, `phone`, `mapped_email`, `mapped_email_domain`, `mapped_cust_id`, `customer_type`, `loyalty_signup_date`

⚠️ **Corrected 2026-08-21 against the deployed 57-column view.** Three names in the list above were wrong, all in the direction that makes a query look valid until it runs:

- `order_datetime` → **`order_datetime_local`** (rename, see above).
- **`brink_net_sales` was never here** — the view `except()`s it by steward rule. It had been listed as a passthrough since the file was written.
- **`total_promotions_amount` does not exist**; the deployed view carries **`discount_amount`** and **`promotions_amount`** alongside `total_discount_amount`. Any formula still written as `gross_sales − total_discount_amount − total_promotions_amount` fails with `Unrecognized name` — and is doubly wrong, because promotions are already inside `total_discount_amount` and **both discount columns are stored negative**, so the settled expression is `gross_sales + discount_amount + promotions_amount` (see `sales_ops.order_customer.md`). In practice: **read the precomputed `net_sales` column and don't re-derive it** (Asana 1217614170649235 tracks the remaining stale copies of the old formula).

The durable lesson: this list is a hand-maintained copy of a deployed schema, and every drift found so far has been silent. Regenerate it from `claude.INFORMATION_SCHEMA.COLUMNS` rather than editing it by hand.

(Updated 2026-08-13: `state` renamed to `store_state` 2026-07-30; `destination_id` and `has_order_items` added to the base table and now advertised here after a metadata-refresh redeploy — new base columns flow through `oc.*` at query time but stay invisible in `INFORMATION_SCHEMA.COLUMNS` until the view is redeployed, same trap as the rename.)

**Updated 2026-08-17 — `is_employee_discount` is GONE.** It was dropped from the base table; use
`order_line_discount_detail.is_employee_meal_discount` instead. The view was redeployed the same day
to refresh its metadata, and the live view is now **57 columns** (43 passthrough + `revenue_category`
+ 13 added). Note what the drop looked like before the redeploy, because it is the mirror image of
the 2026-08-13 add: `select *` returned the correct 57 columns immediately (`*` re-expands at query
time), while `INFORMATION_SCHEMA.COLUMNS` still listed `is_employee_discount` and naming the column
explicitly errored. **Metadata and behaviour disagree in both directions until the view is
redeployed** — after any base-table add, rename *or* drop.

Plus `revenue_category`, which is present but **redefined** — see difference #2 above.

All the usual rules still apply to these: `net_sales` is the canonical calculated net (`brink_net_sales` is validation only), `is_catering` and `is_guest_order` are BOOLEAN, and customer metrics require `customer_type = 'person'`. Emails are lowercased at build since 2026-07-29, so `lower()` is defensive rather than required; store 1111 is already excluded by the view itself (difference #4). **`email` is the ORDER email**
— the address the guest gave for updates on that order, not the customer's — while the canonical
customer email is `pulse.customers.email`, reaching this view only as the first fallback of
`mapped_email` (steward 2026-08-24). Neither is an identity key; `mapped_cust_id` is. See
`sales_ops.order_customer.md` → "Order email vs canonical email".

### Added columns (18)

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
| `first_order_date` | DATE | `customer_attribute` | Customer's first order date **since 2023-03-06** — `min(first_order_date)` across all 1,331,693 customers is exactly 2023-03-06 (measured 2026-09-09), the same floor as `order_sequence`. There is no deeper "first ever" anywhere in the marts, so never scan `order_customer` history to get one. **NULL** when absent |
| `last_order_date` | DATE | `customer_attribute` | Customer's most recent order date. **NULL** when absent |
| `days_since_last_order` | INT64 | `customer_attribute` | Recency as of the attribute build. **NULL** when absent |
| `customer_tenure_days` | DATE→INT64 | `customer_attribute` | Days between first order and the attribute build |
| `is_app_user` | BOOL | `customer_attribute` | **New 2026-09-17.** The canonical App User flag for the customer on this order: app order or in-store scan in the trailing 12 months, **or** a native-app session in the trailing 90 days, as of the attribute build. **NULL, not false, on unidentified and non-person orders** (~60% of orders) — filter `is_app_user is true`, and never read `is not true` as "not an app user" without also requiring `customer_type = 'person'`. Definition and rules: `sales-ops-orders` skill, *"App user" is a canonical customer definition* |
| `app_user_type` | STRING | `customer_attribute` | **New 2026-09-17.** `purchase_and_session` / `purchase_only` / `session_only`; **NULL** when not an app user *and* when unidentified, so a NULL alone does not distinguish the two. Measured on the week ending 2026-09-16: of 47,284 identified person orders, **37,902 (80%)** were placed by `purchase_and_session` customers, 1,736 by `purchase_only`, 290 by `session_only`, 7,356 by non-app-users |
| `gender` | STRING | `customer_attribute` | **New 2026-09-17.** Lowercase two-value domain, `female` / `male`; **NULL** when the customer never gave one and on unidentified / non-person orders. Quote splits on the populated base. Week ending 2026-09-16: populated on 37,158 of 47,284 identified person orders (79%) |
| `birthday` | DATE | `customer_attribute` | **New 2026-09-17.** Customer's birthday as entered in the app. **Year `1950` is the placeholder for "year not provided": month and day are real, the year is not** (151,258 of 279,164 birthdays, 54%). Birthday-month and birthday-day work is fine on the whole column; anything that needs the year must exclude `extract(year from birthday) = 1950` or simply use `age`. Real birthdays still run 1877 → 2022 unvalidated at the edges. NULL on unidentified / non-person orders |
| `age` | INT64 | `customer_attribute` | **New 2026-09-17.** Years since `birthday` as of the attribute build, **NULL when the birthday year is the 1950 placeholder**, so it is populated on exactly the real-year birthdays (127,906 customers, 9.6%; 127,867 of them in a plausible 13 to 100). Never derive an age from `birthday` yourself. Week ending 2026-09-16: populated on 13,369 of 47,284 identified person orders (28%), so an age-band split is a 28% sample of identified orders and must say so |
| `account_type` | STRING | `loyalty_user.member_program` | **Account-level** catering flag: `'individual'` / `'catering'` / `'both'` / NULL. Derived from the SessionM tier system — the canonical catering-vs-individual member split. **NULL for 62.9% of orders** (June 2026) because only loyalty members have it. Distinct from `is_catering`, which describes the *order*, not the account |

> **`customer_attribute` is as-of *yesterday*, not real-time.** All `lifetime_*`, `first/last_order_date`, `days_since_last_order`, `customer_tenure_days`, `is_app_user`, `app_user_type`, `gender`, `birthday` and `age` values come from a daily build. They do **not** include today's orders, and on the current business date they lag. Don't expect `lifetime_order_count` to equal a `count(*)` you compute from this view over full history.

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
- **First-time orders only go back to 2023-03-06** in the underlying `order_sequence`, so `customer_order_count = 1` means "first order since March 2023." `first_order_date` (from `customer_attribute`) has the **same floor** (corrected 2026-09-09 — an earlier version of this line said otherwise). Both are the canonical "first order"; a hand-rolled `min(business_date)` over `order_customer` from 2023-03-06 returns the identical population and just re-bills the scan (~2 GiB per run). Pre-2023-03-06 first orders are not answerable — say so.
- **Sequence numbers are computed across all of a customer's orders, then filtered.** Mixed-type ids (30 in June 2026) show million-scale `customer_order_count` on their person rows — `mapped_cust_id` 19192 sits around 2.48M. Treat those as unreliable.
- **Store 1111 is excluded by the view itself** (difference #4, documented 2026-08-13) — writing `store_id <> 1111` here is a harmless no-op; keep the habit for `sales_ops` tables where it's load-bearing. Sequence numbers upstream are still built *including* 1111 orders, so visible sequences can have gaps for customers who ever ordered there.
- **It's a view, not a table** — but a cheap one since 2026-09-01. Before that date `claude.loyalty_user` was itself a view, and this view rebuilt the whole SessionM identity spine on every query: a 30-day aggregate cost 483k slot-ms / 623 MB / 6.8 s even when `account_type` wasn't selected. `loyalty_user` is now a table refreshed daily at 04:30 MT, and the same query costs 2.4k slot-ms / 62 MB / 0.65 s — about 4× the bare `sales_ops.order_customer` scan, which is the `order_sequence` + `customer_attribute` joins. If numbers you're reconciling were produced before 2026-09-01 nothing changed semantically; only the cost did. Standard users still have no write access, so for repeated multi-step work keep the partition filter tight.
- **Grain:** verified 713,575 rows = 713,575 distinct `brink_order_id` for June 2026, 0 duplicates. The historical `pulse.orders` fan-out defect was resolved by the 2026-07-29 full-history rebuild. Use `count(distinct brink_order_id)` if exact uniqueness matters on older data.

---

## Open question

`customer_attribute` is documented as person-only, which would predict that **all** non-person orders lack lifetime values. Observed June 2026: `kiosk` is 100% zero as expected, but `aggregator` is only 0.2% zero (231 of 109,198) and `internal` 31%. So aggregator ids largely *do* have `customer_attribute` rows. Either the person-only rule isn't applied the way the docs describe, or those ids carry `person` rows elsewhere in history. Worth confirming before anyone builds a segmentation that leans on non-person lifetime values (logged as a `KB finding:` Asana task).
