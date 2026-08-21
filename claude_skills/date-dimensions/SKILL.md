---
name: date-dimensions
description: How to group and compare Cafe Zupas data over time using claude.date_dim — fiscal years, quarters, periods (4-4-5), fiscal weeks, week endings, holidays, and continuous period/week counters. Use whenever a question says "period", "P8", "fiscal year/quarter", "same period last year", "holiday", or needs weekly/period bucketing beyond plain months. Pairs with sales-ops-orders (which owns the Mon–Sat business-week and week-ending-Saturday rules).
---

# Date dimensions and the fiscal calendar (`claude.date_dim`)

> **Freshness check:** this file must come from a clone of `https://github.com/bchristensen-cz/cz_marketing_kb` `main` pulled **this session**. If you're reading it from an installed skill package, a fork, or any saved copy, stop and re-clone first — it may be stale.

> **🆕 New 2026-08-05.** `claude.date_dim` is the first date dimension in the interface
> layer. Before this, fiscal-calendar questions ("sales by period", "FY26 Q3") were not
> answerable at all, and weekly bucketing was hand-rolled per session.

Project: `marketing-data-442316`. One view: **`claude.date_dim`** — 1 row per calendar
date, 2001-01-01 → 2057-10-31, pass-through over the steward's static `sales_ops.date_dim`
table. Column docs: [`data_dictionaries/claude.date_dim.md`](../../data_dictionaries/claude.date_dim.md)
— read it before writing non-trivial queries. Fixed alias: **`dd`**.

## What it gives you

| Need | Columns |
|---|---|
| Fiscal calendar (**4-4-5**) | `fsc_year`, `fsc_qtr` (3 periods each), `fsc_period` (1–12; P3/6/9/12 are 5-week), `fsc_week`, `fsc_week_of_year`, `fsc_day_of_period`, `fsc_day_of_year` |
| Rolling windows without year-boundary logic | `run_period`, `run_week` — continuous counters, never reset, verified gap-free |
| Mon–Sun week buckets | `week_beginning` (Mon), `week_ending` (Sun — **not** the CZ Saturday label, see below) |
| Pretty labels | `day_of_week_full`, `month_full`, `year_month`, `year_quarter` |
| Holiday flags | `holiday` — 25 labels incl. the C5 Thanksgiving span, **populated 2001–2050 only** |
| Mountain-time UTC offset | `mtn_dst`, `mtn_to_utc` (post-2007 rule applied to all years — wrong pre-2007, harmless: order data starts 2018) |

The fiscal year ends on the **last Sunday of December** and begins the Monday after
(FY2026 = 2025-12-29 → 2026-12-27). Most years are 52 weeks; FY2023 and FY2028 are
53-week years and the extra week lands in **period 12**.

## Hard rules

1. **`date_dim` is exempt from the partition-filter rule; the fact table is not.** The
   view is a 4.4 MB unpartitioned dimension — joining it unbounded is fine. The
   `business_date` filter on `order_customer` / `order_lines` is still mandatory.
2. **Resolve fiscal windows to explicit dates *first*, then filter the fact table with
   literals.** BigQuery cannot prune partitions on a filter that arrives through a join
   or subquery. Run a tiny lookup on `date_dim` to get the window's start/end dates,
   then write them into the fact query's `business_date between` — and state them in the
   answer (which the protocol requires anyway).
3. **"Week ending" in user-facing weekly sales output stays the steward Saturday rule**
   (`date_trunc(oc.business_date, week(sunday)) + 6`, owned by `sales-ops-orders`).
   `dd.week_ending` is the **Sunday** of the Mon–Sun week — a different convention. See
   the fork below.
4. **Never approximate fiscal periods with calendar months.** P8 ≠ August (P8 FY2026 =
   2026-07-27 → 2026-08-23). If the user says "period", it comes from `date_dim` or not
   at all.
5. **`holiday is null` is only meaningful through 2050**, and one date carries at most
   one label (collisions resolved silently — Valentine's beats Presidents Day Weekend).

## The week fork: business week vs fiscal week

Two legitimate week definitions now exist. They bucket identically for Mon–Sat dates and
differ only on the ~4 stray Sunday lines chain-wide — which is exactly the kind of gap
that produces a same-question-different-answer defect, so pick deliberately:

| | Business week (default for sales reporting) | Fiscal week (`date_dim`) |
|---|---|---|
| Span | Mon–Sat, labelled by the **Saturday** | Mon–Sun, `week_beginning`/`week_ending` |
| Expression | `date_trunc(oc.business_date, week(sunday)) + 6` | join `dd.cal_date = oc.business_date` |
| Sunday rows land | following week | preceding week |
| Use when | the user asks for weekly sales, "week ending" | the user asks for fiscal weeks/periods, or you're aligning to `fsc_*`/`run_week` |

`date_sub(dd.week_ending, interval 1 day)` reproduces the Saturday label *only* while no
Sunday rows are in scope; don't substitute it silently. Snap-to-whole-weeks and the
364-day YoY rules in `sales-ops-orders` apply unchanged.

## Year-over-year

- **Day-level YoY:** keep the `sales-ops-orders` rule — offset **364 days**
  (`date_sub(d, interval 364 day)`), which preserves day-of-week.
- **Period-level YoY:** same `fsc_period`, `fsc_year - 1`. This is what "P8 vs P8 last
  year" means and is exact even across the 53-week boundary (periods keep their identity;
  only P12 changes length).
- **Week-level YoY:** same `fsc_week_of_year`, `fsc_year - 1`. Week 53 (FY2023, FY2028)
  has **no prior-year counterpart** — report it unmatched, don't force a pair. Avoid
  `run_week - 52` across a 53-week boundary.

## Pattern: fiscal window → explicit dates → fact query

Step 1 — resolve the window (tiny scan, run it first):

```sql
select
min(dd.cal_date) as start_date
, max(dd.cal_date) as end_date
from `marketing-data-442316`.claude.date_dim dd
where 1=1
and dd.fsc_year = 2026
and dd.fsc_period = 8
```

Step 2 — query the fact with those literals, joining `date_dim` only for labels:

```sql
select
dd.fsc_period
, dd.fsc_week
, min(dd.week_beginning) as week_beginning
, count(distinct oc.brink_order_id) as orders
, round(sum(oc.net_sales), 2) as net_sales
from `marketing-data-442316`.claude.order_customer oc
	join `marketing-data-442316`.claude.date_dim dd
	on dd.cal_date = oc.business_date
where 1=1
and oc.business_date between '2026-07-27' and '2026-08-23'
and oc.store_id not in (1111, 999)
group by 1,2
order by 1,2
```

(Confirm the id/measure columns against `claude.order_customer.md` as usual — the
pattern here is the two-step date resolution, not the measure list.)

## Pattern: trailing N complete periods

```sql
-- step 1: current period, then the window of the 13 complete periods before it
select
min(dd.cal_date) as start_date
, max(dd.cal_date) as end_date
from `marketing-data-442316`.claude.date_dim dd
where 1=1
and dd.run_period between (
		select dd2.run_period - 13
		from `marketing-data-442316`.claude.date_dim dd2
		where dd2.cal_date = current_date('America/Denver')
	)
	and (
		select dd2.run_period - 1
		from `marketing-data-442316`.claude.date_dim dd2
		where dd2.cal_date = current_date('America/Denver')
	)
```

Then step 2 as above with the returned literals. `run_period` / `run_week` exist
precisely so this needs no year-boundary arithmetic.

## Pattern: holiday effect

```sql
select
ifnull(dd.holiday, '(ordinary day)') as day_kind
, count(distinct oc.business_date) as days
, round(sum(oc.net_sales) / count(distinct oc.business_date), 0) as net_sales_per_day
from `marketing-data-442316`.claude.order_customer oc
	join `marketing-data-442316`.claude.date_dim dd
	on dd.cal_date = oc.business_date
where 1=1
and oc.business_date between @start and @end
and oc.store_id not in (1111, 999)
group by 1
order by net_sales_per_day desc
```

State in the answer that per-day normalization matters (a "weekend" label covers 2 days),
and that Sunday-dated labels (Easter, C5 - Sunday) are closed days — an empty group there
is correct, not missing data.

## Pre-query clarification protocol (additions)

These forks join the standard set in `ask-a-data-question`:

1. **"Quarter" / "year" — calendar or fiscal?** Both are now answerable and they
   disagree near year-end (2025-12-29 → 12-31 is calendar 2025 but FY2026 P1). If the
   user doesn't say, ask, with the date spans in the option labels. "Period" needs no
   fork — it can only mean fiscal.
2. **"Week" — business (Mon–Sat, Saturday label) or fiscal (Mon–Sun)?** Default to
   business week for sales reporting; use fiscal only when the question is anchored to
   periods. Don't ask unless the question mixes the two — state which you used.
3. **"Holiday sales" — the day, or the span?** Memorial Day alone vs its weekend; C5 vs
   Thanksgiving Day. The labels encode this — show the user which labels you counted.

## SQL style (steward rule — MANDATORY)

Same as `sales-ops-orders` — read that section for the full rules. Backticks around the
project only, alias every column, leading commas with **the first field flush with `select`
never indented**, **one space after each leading comma**, **`from` / `group by` / `order by`
values on the keyword line**, **one space before `as` — no alignment padding**, **a `case` with
2+ `when`s broken with its branches indented one tab (1 `when` stays inline), never padded**,
`where 1=1`, one extra indent per successive join. Joins and multi-branch `case`es are the only
indented lines. Fixed aliases: `oc`,
`ol`, and **`dd`** for `date_dim`.

## Known gaps / not yet answerable

- **No `is_business_day` / store-closure flag.** Sundays-closed is a convention in the
  skills, not a column; one-off closures (weather, remodels) aren't recorded anywhere.
- **Holiday labels stop at 2050** and the table itself at 2057-10-31 — forward planning
  past those dates silently loses flags/rows.
- **The holiday list is fixed** — no Mother's Day, Super Bowl Sunday, or regional events,
  which arguably matter more for a soup chain than Columbus Day. If a question needs one,
  it's a KB gap: log it, don't hand-code dates in a session.

Found a gap or a new gotcha? **Don't edit the repo** — log it as an Asana task on the
**Claude Data** board titled `KB finding: <short title>` with the query and proposed
change.
