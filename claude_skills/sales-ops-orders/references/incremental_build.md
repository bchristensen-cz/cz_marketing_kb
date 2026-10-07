# Steward: incremental-build windowing rule

> Part of the `sales-ops-orders` skill. Read `../SKILL.md` first; this file is loaded on demand. **Read it when:** you are the steward building or reloading a mart (not needed to answer questions).
> Content moved verbatim from `SKILL.md` on 2026-10-07 (progressive-disclosure restructure); the rules and dates inside are unchanged.

## ⚠️ In an incremental build, never window a DIMENSION by the fact window (general rule, 2026-08-15)

This one generalises to **every** scheduled script in `sql/`, and it produced the nastiest bug
found in the `order_line_discount_detail` review — worth stating as a rule rather than a war story.

An incremental script reloads a window of the **fact** (here `business_date >= start_date`,
matching the `delete`). The temptation is to put the same `start_date` on every source CTE for
pruning. **Don't** — the lookup tables are keyed on *different clocks*:

| Source | Its date column means | Not the same as |
|---|---|---|
| `sessionM.user_offers.create_date` | when the offer was **issued** | when it was redeemed |
| `pulse.order_discounts.created_at` | when the order was **placed** | when it was fulfilled (`business_date`) |
| `sessionM.transaction_headers.create_date` | the sessionM record date | either of the above |

Two measured consequences from applying `start_date` directly:

- **Offer attribution went non-deterministic by day of week.** Monday's 5-week reload resolved
  offers issued 8–35 days back; Tuesday's 8-day reload wiped them again. **275 rows differed
  over an 8-day window** — same row, different `offer_name` depending on which run last touched
  the partition. That breaks the same-question-same-answer guarantee this KB exists for.
- **Catering was silently dropped.** 31 orders lost their Pulse match, **27 of them catering**,
  with up to **33 days** between order placement and fulfillment — and those rows reclassified
  to `Error` rather than erroring out.

Two valid fixes, both verified set-identical to a full-history build:

1. **Filter the lookups by the order KEYS in the window**, not by their own timestamps
   (`od.order_id in (select pulse_order_id from window_orders)`). Exact, no lead-time
   assumption, ~5× the scan.
2. **Widen the reload windows so the lookback covers the tail** — what `order_line_discount_detail`
   ships with (120d daily / 380d Monday / 730d monthly, each with a further `- 60` on the
   sources). Cheaper, but it is a *bet* on lead times and needs an alarm. Here that alarm is
   the `Error` bucket.

Related traps in the same family:

- **Wrap the `delete` + `insert` in `begin transaction; … commit transaction;`.** BigQuery
  scripts are **not** atomic. A failed insert after a committed delete leaves a hole the width
  of the reload window — returning **zeros, not an error** — and intraday runs that only cover
  today won't heal it until the next 4am pass.
- **A wide reload window is not a full rebuild.** Whatever sits before the widest window is
  frozen forever. On `order_line_discount_detail` that is **65.1% of rows (2,239,212 / −$15.6M)**. Since
  `order_lines` was restated across full history **three times in the month to 2026-08-14**,
  re-running the full-history build of any derived table is a **required step in the
  `order_lines` rebuild checklist**, not a nice-to-have.
- **`current_date` is UTC.** Intraday runs firing 8pm–11pm Denver are 2am–5am the *next* UTC
  day, so a bare `current_date` silently means "tomorrow" for a third of the schedule. Pin
  `current_date('America/Denver')` in every scheduled script and every assertion. This cost
  real time during the `order_line_discount_detail` review: three test builds either side of the rollover
  picked different windows and the diff read as a logic regression when it was a clock
  difference.
