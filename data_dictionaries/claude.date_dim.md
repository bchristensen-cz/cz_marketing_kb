# Data Dictionary: `marketing-data-442316.claude.date_dim`

**One row per calendar date.** Pass-through authorized view (`select *`) over
`sales_ops.date_dim`, a static clustered table built by the steward (created 2025-07-02).
Build script: [`sql/claude.date_dim.sql`](../sql/claude.date_dim.sql). Deployed 2026-08-05.
Parent altered **2026-08-24** to add `week_beginning_ly` / `week_ending_ly`; the view is a
`select *`, so it picked them up with no redeploy (verified through `claude.date_dim`).

Coverage: **2001-01-01 → 2057-10-31**, 20,758 rows, verified no gaps and no duplicate
dates (2026-08-05). The end date is mid-fiscal-period (FY2057 P11 W2), not a calendar
boundary — nothing after 2057-10-31 exists.

## Why it exists

Weekly, fiscal-period, and holiday groupings were previously hand-rolled expressions
(`date_trunc(…, week(sunday)) + 6` and friends) that every session had to reconstruct.
This view makes the **company fiscal calendar** (4-4-5 periods), continuous week/period
counters, and holiday flags reachable for standard users as ordinary join-and-group-by
columns. The `claude` dataset is authorized on `sales_ops` at the dataset level, so the
view inherited access with no extra grant.

It is a **dimension, not a fact table**: 4.4 MB, unpartitioned, and exempt from the
always-filter-the-partition rule — the partition filter belongs on the fact table you
join it to (`business_date`).

## Columns

Everything verified against the live view 2026-08-05.

### Calendar

| Column | Type | Meaning |
|---|---|---|
| `cal_date` | DATE | The date. Grain and join key — join `dd.cal_date = oc.business_date` |
| `day_of_week` | INTEGER | **Monday = 1 … Sunday = 7** |
| `day_of_week_shrt` | STRING | `Mon`, `Tue`, … |
| `day_of_week_full` | STRING | `Monday`, `Tuesday`, … |
| `week_num` | INTEGER | Week of the **calendar year**. Resets to 1 on Jan 1 (mid-week!), increments each Monday. See gotchas |
| `week_beginning` | DATE | Monday of the Mon–Sun week containing this date |
| `week_ending` | DATE | **Sunday** of that week — one day *after* the CZ "week ending" Saturday. See gotchas |
| `week_beginning_ly` | DATE | `week_beginning` minus **364 days** — the Monday of the prior-year comparison week. Day-of-week preserved. Added 2026-08-24 |
| `week_ending_ly` | DATE | `week_ending` minus **364 days** — the **Sunday** of that same prior-year week. Added 2026-08-24 |
| `week_of_month` | INTEGER | Resets to 1 on the 1st of the month, increments each Monday |
| `month` | INTEGER | 1–12 |
| `day_of_month` | INTEGER | 1–31 |
| `month_short` | STRING | `Jan`, `Feb`, … |
| `month_full` | STRING | `January`, … |
| `quarter` | INTEGER | **Calendar** quarter 1–4 (not fiscal — that's `fsc_qtr`) |
| `year` | INTEGER | Calendar year |
| `year_month` | STRING | `2026-08` — sorts correctly as text |
| `year_quarter` | STRING | `2026-3` (no `Q`) |
| `holiday` | STRING | Sparse label, NULL on ordinary days. **Populated 2001–2050 only.** See holiday section |

### Fiscal calendar (4-4-5)

| Column | Type | Meaning |
|---|---|---|
| `fsc_year` | INTEGER | Fiscal year. Ends on the **last Sunday of December**; begins the Monday after. FY2026 = 2025-12-29 → 2026-12-27 |
| `fsc_qtr` | INTEGER | Fiscal quarter 1–4 = 3 periods each (13 weeks) |
| `fsc_period` | INTEGER | Fiscal period 1–12 in a **4-4-5 week pattern** (P3, P6, P9, P12 are the 5-week periods) |
| `fsc_week` | INTEGER | Week within the period: 1–4 or 1–5 (1–6 in P12 of a 53-week year) |
| `fsc_week_of_year` | INTEGER | Week within the fiscal year, 1–52 (53 in 53-week years). Resets at fiscal year start — always a Monday, unlike `week_num` |
| `fsc_day_of_period` | INTEGER | Day within the period, 1–28/35/42 |
| `fsc_day_of_year` | INTEGER | Day within the fiscal year, 1–364/371 |
| `run_period` | INTEGER | **Continuous period counter**, never resets. `1000` = FY2001 P1; `run_period = 1000 + 12*(fsc_year-2001) + fsc_period - 1`. Verified monotone, no gaps, over the full range |
| `run_week` | INTEGER | **Continuous week counter**, never resets. `10000` = FY2001 W1. Verified monotone, no gaps |

Fiscal weeks run **Monday–Sunday** (identical buckets to `week_beginning`/`week_ending`).
Most fiscal years are 364 days / 52 weeks; when the calendar drifts far enough a
**53-week year** occurs (FY2023 and FY2028 in the 2022–2028 window checked) and the
extra week lands in **period 12** (6 weeks / 42 days).

### Mountain-time DST helpers

| Column | Type | Meaning |
|---|---|---|
| `mtn_dst` | INTEGER | 1 while Mountain time is on daylight saving, else 0. Flag turns **on** on the spring-forward Sunday and **off** on the fall-back Sunday (the fall Sunday itself reads 0) |
| `mtn_to_utc` | INTEGER | Hours to **add** to Mountain local time to get UTC: 6 during DST (MDT), 7 otherwise (MST) |

## Holidays

25 labels, at most one per date, populated **2001–2050 only** (1,486 flagged days).
Verified 2026-08-05:

| Group | Labels | Shape |
|---|---|---|
| Fixed dates | New Year's Day, Valentine's Day, Juneteenth, Independence Day, Veterans Day, Christmas Eve, Christmas Day, New Year's Eve | 1 day/year |
| Floating Mondays | Martin Luther King, Jr. Day, Presidents Day, Memorial Day, Labor Day, Columbus Day | the Monday |
| Weekend companions | Presidents / Memorial / Labor / Columbus `… Day Weekend` | the Sat + Sun **before** the Monday holiday |
| Easter | `Easter` (the Sunday), `Easter Weekend` (the Fri + Sat before) | 3 days |
| Thanksgiving retail span ("C5") | Thanksgiving Eve (Wed), then `C5 - Thanksgiving Day`, `C5 - Black Friday`, `C5 - Saturday`, `C5 - Sunday`, `C5 - Cyber Monday` | 6 days |

Quirks:

- **One label per date, and collisions are resolved silently.** When Valentine's Day
  falls on the Sat/Sun of Presidents Day weekend, `Valentine's Day` wins — which is why
  `Presidents Day Weekend` has 86 rows over 50 years instead of 100. Don't count weekend
  rows and expect 2 × years.
- **`holiday is null` means "no label" only through 2050.** From 2051 the column is NULL
  on every row including Christmas. Any query touching dates past 2050 must not read
  NULL as "ordinary day".
- Some labels fall on Sundays (Easter, C5 - Sunday) when **all stores are closed** — a
  holiday join against sales produces legitimately empty groups for those.

## Gotchas

- **⚠️ `week_ending` is the Sunday, not the CZ "week ending" Saturday.** The business
  week is Mon–Sat (stores closed Sunday) and the steward's weekly label rule is
  `date_trunc(business_date, week(sunday)) + 6` — the Saturday. `dd.week_ending` is one
  day later, and it disagrees on *bucketing* for Sunday rows: the ~4 stray Sunday lines
  that exist chain-wide join to the **preceding** Mon–Sun week here, while the steward
  expression pushes them into the **following** week. For user-facing weekly sales
  output, keep the steward expression. Use `week_beginning`/`week_ending` when you want
  the fiscal (Mon–Sun) calendar. Full guidance in the `date-dimensions` skill.
- **`week_num` splits a physical week across years.** It resets on Jan 1 regardless of
  weekday, so the week spanning 2025-12-29 → 2026-01-04 is week 53 for its 2025 days and
  week 1 for its 2026 days. Grouping by `(year, week_num)` produces two short buckets at
  every year boundary. For continuous weekly series group by `week_beginning` or
  `run_week` instead.
- **`quarter`/`year` are calendar; `fsc_qtr`/`fsc_year` are fiscal — and they disagree
  near year-end.** 2025-12-29 → 2025-12-31 is calendar 2025 but FY2026 P1. "Q4" is
  ambiguous in a question; ask which calendar (see the skill's clarification protocol).
- **DST columns apply the post-2007 US rule to all years.** For 2001–2006 the flags are
  historically wrong (actual DST then ran first-Sunday-April → last-Sunday-October; the
  table claims March → November). No practical impact — order data starts 2018-08-28 —
  but don't use these columns for pre-2007 timestamp conversion.
- **53-week fiscal years break naive fiscal YoY.** `fsc_week_of_year = 53` (FY2023,
  FY2028) has no prior-year counterpart, and `run_week - 52` misaligns across a 53-week
  boundary. The 364-day day-level offset rule in `sales-ops-orders` is unaffected.
- **⚠️ The `_ly` columns are a flat 364-day offset, not a fiscal-week lookup.** They
  preserve day-of-week and match `fsc_week_of_year` in ordinary years, but a **53-week year
  breaks the alignment for the two years around it**. Joining `ly.cal_date =
  dd.week_beginning_ly` shifts the fiscal week by +1 for **all 364 days of FY2024 and
  FY2029** (the years after 53-week FY2023 / FY2028), and for the 7 days of week 53 itself
  it lands 52 weeks off. Example: 2024-06-03 is FY2024 W23, but its `week_beginning_ly`
  (2023-06-05) is FY2023 **W24**. For fiscal week-over-week comparison keep the
  `fsc_week_of_year` + `fsc_year - 1` rule; use `_ly` for calendar/day-of-week-aligned
  comparison. Both are correct — they answer different questions, so say which you used.
- **`week_beginning_ly` runs off the front of the table.** It reaches back to 2000-01-03,
  but the table starts 2001-01-01 — so **364 rows (2001-01-01 → 2001-12-30) have no
  self-join match**. `join dd2 on dd2.cal_date = dd.week_beginning_ly` silently drops them.
  No impact on order data (starts 2018-08-28), but don't use an inner self-join as a row-count
  check. The tail is safe: max `week_ending_ly` is 2056-11-05, inside the range.
- **Don't `select *` into a report.** 30 columns; pick the grouping columns you need.
