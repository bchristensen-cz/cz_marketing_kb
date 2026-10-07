# Live incidents, stale-mart checks and known mart gaps

> Part of the `sales-ops-orders` skill. Read `../SKILL.md` first; this file is loaded on demand. **Read it when:** any customer-, guest-, `order_source`- or app-level figure dated 2026-09-15 or later; any item question (check `order_lines` staleness first); a question needs an order-placement timestamp; a date filter seems to be "in the way".
> Content moved verbatim from `SKILL.md` on 2026-10-07 (progressive-disclosure restructure); the rules and dates inside are unchanged.

### 🚨 LIVE 2026-09-18: `pulse.orders` stopped loading 2026-09-15 05:51 MT — digital identity, `order_source` and `is_guest_order` are blank on every order since (found 2026-09-18 12:50 MT)

Found independently twice on 2026-09-18 (a steward session at ~09:59 MT, commit 42ff761, and the query-log session at 12:50 MT while verifying the new `_l365` columns). The full signature and root cause are in the Gotchas checklist ("If a settled day reads ~14% identified…") and in `sales_ops.order_customer.md`: the compute-SA nightly loader stopped submitting the `orders_stg` LOAD + `orders` MERGE on 09-16/17/18 with no BigQuery error, so `pulse.orders` has `max(created_at) = 2026-09-15 05:51:57` while `pulse.order_customers` keeps loading. What a session answering questions needs: `pulse_order_id` / `pulse_customer_id` / `order_source` are NULL on every order from 09-15 (167 / 0 / 0 Pulse-identified orders on 09-15 / 16 / 17 vs 11,927 on 09-14), `is_guest_order` is NULL everywhere (860 guest orders on 09-14), identified orders fell to **~4,050/day = the in-store scan count**, so `mapped_cust_id` coverage is ~14% instead of ~55%, and `customer_type`, `order_sequence`, `customer_attribute` (`orders_l30`, `days_since_last_order`, the Braze push), the guest dashboard, social CAPI and Google offline conversions all inherit it. **`revenue_category` and `net_sales` are intact** (Brink/destination-based: 09-16 shows Digital 6,088 / In-Store 17,742 / Third_Party 4,928 / Catering 445 / Fundraiser 86), which is exactly why nothing errored. **Rule until it clears: any customer-, guest-, `order_source`- or app-level figure for `business_date >= 2026-09-15` is wrong; say so, and anchor identity-keyed work on 09-14 or earlier.** Recovery is automatic once `pulse.orders` is backfilled (the 5am chained run reloads full history); verify with the daily identified-% query before re-quoting. One extra fact from the second finding, for the steward, not a directive: **`pulse_new.orders` is current through 2026-09-18 06:15 with the same 63,414 rows since 09-12 as `pulse.order_customers`**, so the new pipeline has the missing orders if the old extractor is not coming back. Asana 1218635100444593.

> **Status Mon 2026-09-21 09:30 MT (query-log review): STILL STALLED, day 7.** `JOBS_BY_PROJECT` shows the last job writing `pulse.orders` at **2026-09-15 01:35 MT**; nothing has touched it since (`pulse.order_customers` merged every night 01:33-01:36 as normal). `pulse_new.orders` merged nightly at ~02:14 the whole time and the compute SA ran **three extra `pulse_new.orders` MERGEs at 05:46 / 05:51 / 05:54 on 09-21**, so the dev team is actively working the new loader this morning, not the old one. Nothing in the KB or the marts reads `pulse_new` yet. The rule above now covers `business_date >= 2026-09-15` through today: seven business days of identity-blind orders, and `customer_attribute` has been rebuilt on them for six mornings (`days_since_last_order`, `orders_l30` and the Braze attribute push are all understated for digital-only customers). Checked from the job log only, no order-table scan.

> **Status Tue 2026-09-22 09:40 MT (query-log review): BACKFILL LANDED, marts heal on the next 5am run.** The compute SA merged `pulse.orders` at **2026-09-22 07:57:38 MT** (`orders_stg_ae3794` -> `orders`, **75,213 rows inserted / 25,342 updated**, 2.95 GiB), the first write to that table since 09-15 01:35; ~75k inserts is roughly seven days of Pulse orders, so this reads as the whole 09-15 -> 09-22 gap, not a partial. `pulse.order_customers` was merged five times between 07:12 and 07:57 the same morning (normally once, ~01:35), so the dev team ran the old loader by hand. **The marts are still identity-blind for `business_date` 09-15 -> 09-21 until the 5am chained run on Wed 2026-09-23** (today's 5am full-history reload ran before the merge; the 8am-11pm intraday runs reload today only, so 09-22 itself heals hourly from 08:02). `customer_attribute` (05:00) reads the pre-refresh snapshot, so its `orders_l30` / `days_since_last_order` / Braze push are right from **Thu 2026-09-24**. Do not re-quote any identity-keyed figure for 09-15 onward until you have re-run the daily identified-% check and it reads ~55% again. Job-log evidence only, no order-table scan.

> **Update Wed 2026-09-23 09:40 MT (query-log review): HEALED, and `customer_attribute` healed a day earlier than the note above says.** The 05:02 chained run was DONE by **05:07:35** (340 s, 92.4 GiB): `order_customer` insert 05:02:11-05:03:19, `order_sequence` 05:03:31-05:04:26, `order_lines` 05:04:33-05:06:39, `order_line_discount_detail` 05:06:58-05:07:35. **`customer_attribute` fires at 05:20, not 05:00** (its CTAS ran 05:20:04-05:20:21), so it read the post-refresh marts and is right **from today**; the "05:00 reads the pre-refresh snapshot" caveat does not describe the current schedule. `cust_map` (04:15) and `loyalty_user` (04:30) were also DONE. Job-log evidence only; the steward ran the identified-% check on `claude.order_customer` at 09:29 MT. Re-run it yourself before quoting an identity figure for 09-15 -> 09-21.


### 🕳️ MART GAP: there is no order-*placement* timestamp anywhere in the marts (measured 2026-08-24)

**Catering lead time — "was this ordered the same day it was served, or booked in advance?" — cannot be answered from the `claude` or `sales_ops` marts.** This is a real gap, not a routing problem, and it is worth stating precisely because the obvious column looks like it should work and doesn't.

`order_datetime_local` is a **fulfillment**-side timestamp, not a placement time. Measured on `claude.order_customer`, 2026-07-27 → 08-20, stores 1111/999 excluded:

| Population | Orders | `date(order_datetime_local) = business_date` | max lead days |
|---|---|---|---|
| Non-catering | 596,215 | 596,211 (99.999%) | 5 |
| **Catering** | 7,407 | **7,378 (99.6%)** | **0** |

A catering order booked three weeks out still carries an `order_datetime_local` on its *service* date. So `date_diff(business_date, date(order_datetime_local))` is structurally ~0 and any "advance vs same-day" split built on it returns "100% same-day" — a confident, plausible, entirely wrong answer.

The only source of placement time is **`pulse.orders.place_time`**, which is behind the wall. That makes this the third instance of the same shape (after the guest-supplied email, Asana 1217645882648277): **a wall breach whose cause is a missing mart column, where repeating the rule accomplishes nothing and exposing the column removes the motive.** Observed driving it, 2026-08-21/23, `mraza@` direct console, 12 queries: a weekly `catering_same_day_sales_pct` by store built on `pulse.orders` joined to `pulse.locations`, with `DATE(o.place_time) = o.business_date` as the same-day test — then, on 08-23, wrapped in a `FORMAT(...)` generator emitting `INSERT INTO web_systems.catering_same_day_sales_pct ...` statements for a downstream MySQL application.

Two things to say about it, in this order:

1. **The question is legitimate and the marts cannot answer it.** Log it as a gap; don't send the author back to a mart that will silently tell them everything is same-day.
2. **The financials in that pipeline are not canonical, and that part is fixable today.** It measures catering sales as `sum(o.sub_total)` from `pulse.orders` — **Pulse financials, which hard rule 5 forbids outright** ("Brink is the sole financial source of truth; Pulse is a helper for digital order/customer metadata only"). It also uses Pulse's own `o.is_catering` rather than the finance definition on `order_customer`, and carries no `store_id not in (1111, 999)`. A production MySQL table is being populated from it. **Even before the placement-time column exists, the denominator and the sales measure must come from `claude.order_customer` (`net_sales` / `gross_sales`, `is_catering`);** only the same-day *flag* genuinely requires Pulse. Splitting the query that way shrinks the breach to one column and makes the number quotable.

### ⚠️ Legacy schemas survive outside the walls — `stella_cafezupas.OrderCustomer_test` (found 2026-08-24)

Dropping `sales_ops.OrderCustomer` did **not** retire the legacy vocabulary. A full copy of its schema lives in an undocumented dataset that no skill, dictionary or wall mentions:

`marketing-data-442316.stella_cafezupas.OrderCustomer_test` — the only table in its dataset, created 2026-04-01, **not partitioned and not clustered**, carrying the entire retired column set: `BusinessDate`, `order_datetime`, `storeid`, `state`, `netsales`, `iscatering INT64`, `lifetime_order_cnt`, `order_count`.

Three things make it worth knowing about:

1. **It is frozen at a single business date.** 29,552 rows, `min(BusinessDate) = max(BusinessDate) = 2026-03-26`, `max(update_datetime)` 2026-04-01. Yet `stella-bigquery@` has read it **15 times since 2026-08-17**, most recently 2026-08-24 06:10 MT, with `WHERE brink_order_id > ?` — an incremental-sync loop that can never advance because the source never changes. Whatever "Stella" is, it believes it is syncing orders and has received nothing since March. Cost is trivial (~0.10 GiB/run); the silence is the problem.
2. **Both time columns are typed `TIMESTAMP`.** On the mart, local is `DATETIME` and UTC is `TIMESTAMP`, so a type error catches the confusion (that is what happened on 08-17). Here `order_datetime` and `order_timestamp_utc` are *both* `TIMESTAMP` — the store-local wall clock has been cast into a UTC-bearing type and persisted. Nothing errors, and the only signal left is the column name.
3. **It independently confirms the 4–7 hour claim.** `timestamp_diff(order_timestamp_utc, order_datetime, hour)` ranges **min 4, max 7** over its 29,530 dual-populated rows — a separate table, built by a separate process, reproducing the four live offsets the KB measured on the mart. A number that survives an independent build is worth more than one measured twice the same way.

**Rule: `select *`-shaped copies of a mart into a vendor-facing dataset are a second, unwalled interface.** They inherit the schema at copy time and then diverge silently. When you rename or drop a column, grep `INFORMATION_SCHEMA.COLUMNS` across **every** dataset in the project, not just `sales_ops` and `claude` (Asana task filed 2026-08-24).

### ⚠️ Commenting out the date filter is not "widening the search" — an id predicate prunes nothing (measured 2026-08-18)

The most expensive authoring mistake in the log to date, and it isn't about this project's marts — it will bite anyone doing single-order lookups on a raw Brink table. Observed from a new direct-console account: **20 full-table scans / 224.08 GiB in one day, 99.9% of that account's entire spend.** The shape, verbatim:

```sql
-- ANTI-PATTERN, do not copy
select *
from `marketing-data-442316`.brink.brinkOrder bo
where 1=1
--and bo.businessdate = '2026-8-17'
and bo.id = 105394802264065
LIMIT 200500
```

The `bo.id` predicate is live and so is the `LIMIT`. It still reads the entire table, because **`brink.brinkOrder` is partitioned on `BusinessDate` and not clustered on `Id`** — an id filter is evaluated after the scan, and `LIMIT` doesn't bound bytes either. Measured on that table the same day:

| Predicate | Billed |
|---|---|
| `where businessDate = '2026-8-17'` | **0.01 GiB** |
| `where bo.id = <literal>` (no date) | **11.20 GiB** |

~1,120x, for a query that looks *more* selective. The author commented the date out to search across days, which is a reasonable intent with an unreasonable price. **A single-order lookup must carry a date**; if the date genuinely isn't known, expect and budget a full scan, or ask for the table to be clustered on `Id` (Asana 1217554047292419).

**The detection signal is a cost that doesn't move when the filter moves.** All 20 of these billed 11.2 GiB whether the id predicate was live or commented, and across twelve different order ids. Identical `total_bytes_billed` across different literals proves the literal is pruning nothing.

> **🧰 Harness note for whoever runs the query-log review — do not analyse query text with whitespace collapsed.** This finding was first written up as "the `--` comment swallowed the `bo.id` predicate and the `LIMIT` too," which is **false and was retracted the next morning**. The cause was the review's own SQL: `substr(regexp_replace(query, r'\s+', ' '), 1, 700)` flattens the six-line query onto one line, after which a leading `--` genuinely *appears* to comment out everything following it. Line structure is load-bearing whenever a `--` is present. Inspect with `split(query, '\n')` before drawing any conclusion about what a comment covers — and note that the wrong version was self-consistent with the byte counts, so plausibility was no protection.
