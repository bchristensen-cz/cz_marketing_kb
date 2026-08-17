# Data Dictionary: `marketing-data-442316.claude.order_line_discount_detail`

**One row per discount COMPONENT** — *not* one row per discount line, and not one row per
order. Read the grain section before writing anything against this table; it is the single
easiest thing to get wrong here.

View over `sales_ops.order_line_discount_detail` (rolling 3-year window, matching `claude.order_lines`
and `claude.order_customer`). Base table build script:
[`sql/sales_ops.order_line_discount_detail.sql`](../sql/sales_ops.order_line_discount_detail.sql). View:
[`sql/claude.order_line_discount_detail.sql`](../sql/claude.order_line_discount_detail.sql).

This is the sanctioned answer to **"what did we give away, and through what?"** It is the
wrapper around `pulse.order_discounts`, `sessionM.transaction_discounts` and
`sessionM.user_offers` — **never query those directly.**

> **✅ Deployment status 2026-08-15 — base table and view are both live.**
> `sales_ops.order_line_discount_detail` is deployed and fully loaded (3,441,279 rows,
> 2018-08-13 → 2026-08-14). `claude.order_line_discount_detail` was deployed later the same day
> and smoke-tested: 57,739 rows / 12 discount types / **zero NULL `discount_type`** over the
> trailing 30 days. The rename had dropped the view — for a window that day the `claude` dataset
> carried **no discount object at all** and standard users could not reach discounts. Redeploy
> the view after any rename; `create or replace view` on a renamed base does not carry over.
>
> The table was created as `sales_ops.discount_detail` and renamed the same day, before any
> user query — the old name never reached anyone. **There is no alias for the old name**, so
> anything still saying `discount_detail` fails loudly rather than returning stale numbers.
>
> **✅ RESOLVED 2026-08-17.** The `order_lines` `valid_order_lines` guard was deployed with both
> arms and `order_lines` rebuilt full history at 11:45 MT, then this table behind it at 11:49.
> That order matters — this table is downstream, and rebuilding it against a stale `order_lines`
> just re-freezes the old numbers. All three marts now read −$25,720,068.34 at order grain, full
> history, closed days, zero orders disagreeing.
>
> ⚠️ **AND THE RENAME BIT THE BUILD SCRIPT ITSELF.** "Anything still saying `discount_detail`
> fails loudly" turned out to include this table's own scheduled query: the `insert` target was
> renamed but the `delete` target was not. Every run from **2026-08-15 04:02 MT to 2026-08-17
> 09:02 MT — 37 consecutive runs — died** on `Not found: ... sales_ops.discount_detail at
> [29:1]`, and the failures are near-invisible because the job reports `state = DONE` with a
> populated `error_result`. Two days of incremental loads were lost; only the manual full
> rebuilds on 08-17 healed it. **After a rename, grep the whole scheduled config for the old
> name — the insert is not the only place it appears.**
>
> ⚠️ **PENDING 2026-08-17:** the widened `is_employee_meal_discount` (item_id 1 + 640945199 +
> the `discount_name` arm + the anchored regex) is committed to the repo, and the deployed
> config as of the 13:02 MT run carries only the **narrow** first version — flag present, but
> without `item_id 1`, without `640945199`, and without the anchored regex. It also runs
> **without the `begin transaction` / `commit transaction` wrapper**. Until the full script is
> saved to the config AND a full-history rebuild is run, pre-2023 employee-meal spend reads
> ~$757K low.

## Grain — read this first

Brink emits **exactly one** `item_id = 643536109` ("Online Discount") line per order —
verified across Jul 2026, no order had more. Where Pulse holds several discount *components*
under that one Brink line (points + reward + offer on the same order), this table **splits
the single Brink amount across them** in proportion to each component's Pulse amount.

So one Brink discount line can produce several rows, each with its own `discount_type`. In
July 2026, 204 orders genuinely carried two different component types on one Brink line.
Consequence: **row count runs ~1.5% above the source line count** (3,440,131 vs 3,388,269
over full history, measured 2026-08-14). That surplus is the feature, not a defect.

> **⚠️ `discount_amount` is the ONLY summable money column.** It is the prorated value and
> it reconciles to `order_lines` **exactly**: full history on identical filters,
> **−$25,977,208.08 on both sides** (verified 2026-08-15 against the deployed table; the same check on the 2026-08-14 pre-deploy build read −$25,967,881.35 — the delta is today's partition still filling, not drift). **Once the `order_lines` sellable-order guard is deployed this becomes −$25,693,161.50**; the −$284,046.58 difference is the fix described below, not drift.
>
> The un-prorated Brink line amount is deliberately **not exposed**. An earlier draft carried
> it beside `discount_amount` under the more natural name `amount`; summing it returned
> **−$504,903.90 against a true −$471,017.34 in July 2026 (+7.2%)**, because it repeats in
> full on every split row. If you ever need the Brink line total, aggregate
> `discount_amount` up to `brink_order_id` + `item_id` — don't reintroduce the raw column.

`count(*)` is a count of **components**, not discounts and not orders. For discount counts
use `count(distinct concat(brink_order_id, '-', item_id))`; for orders,
`count(distinct brink_order_id)`.

## Tying this table to `order_customer`

`sum(discount_amount)` here should equal `sum(total_discount_amount + total_promotions_amount)`
on `claude.order_customer`, **to the cent, at order grain, on closed days** — once the
`order_lines` sellable-order guard is deployed. Three things are load-bearing in that comparison
and all three were learned the hard way on 2026-08-15:

```sql
and oc.store_id not in (1111, 999)   -- this table drops 999 upstream; claude.order_customer drops only 1111
and dd.business_date <= date_sub(current_date('America/Denver'), interval 1 day)
-- ...and join on brink_order_id, not just business_date
```

- **Store 999.** The build excludes `store_id not in (1111, 999)`; `claude.order_customer`
  excludes only 1111. Leaving 999 in produced one order / **$13.49** over 90 days — small, but a
  permanent floor on any comparison that omits it.
- **Today.** `order_customer` is a snapshot from its last load while raw Brink moves all day, so
  the current business date drifts ~47 orders / ~$438. Not a defect. Compare closed days only.
- **Order grain, not date grain.** At date grain a compensating pair on the same day cancels out
  and reads as a match.

### Why they disagreed before 2026-08-15 — a join-key bug worth remembering

The two tables differed by **$753.68 over 90 days across 80 orders**, always in the same
direction (this table high). `sales_ops.order_customer` joins its discount and promotion CTEs on
**`boi.orderid`** — the output of its own `brink_order_item` CTE — rather than on `bo.id`:

```sql
left join instore_emp_discounts d
on d.order_id = boi.orderid      -- <- boi, not bo
```

`brink_order_item` filters `IsCleared/IsVoided/IsDeleted = false` and then applies
`having sum(ItemGrossSales) > 0 or sum(ItemNetSales) > 0`. Any order it drops has
`boi.orderid = NULL`, so the discount joins collapse and the order reports **zero** discount even
though the `brinkOrderDiscount` rows are live with `isDeleted = false`. `order_lines` keyed on
`bo.id` and kept the money, so this table ran high. Every affected order carries
`has_order_items = false`.

**The zeros in `order_customer` are the correct answer.** These are voided/comped shells: Brink
zeroes the header (`GrossSales` / `NetSales` / `Subtotal` / `Total` all 0) and voids the items but
leaves the discount row standing. 78 of the 80 had every item row cleared/voided/deleted; the
other 2 carried a single `Online Details Memo` line at $0.00. Nothing was sold, so nothing was
given away — patching `order_customer` to join on `bo.id` would have booked $767 of giveaway
against $0 of sales and driven `net_sales` negative.

So the fix went into **`order_lines`**, which now carries a `sellable_orders` guard suppressing
discount and promotion lines on those orders. The guard reproduces
`order_customer.has_order_items` **exactly** — 2,050,577 orders over 90 days, zero disagreements
in either direction. That equivalence is the invariant to re-check if either build changes.

Scope of the guard, full history: **42,092 lines / −$238,698.36** on orders with no surviving item
rows, plus **2,701 lines / −$45,348.22** on orders whose surviving items all sum to $0. The second
bucket is concentrated in 2019–2022 — it is only −$58.17 in 2026 and −$396.97 in 2025.

**Gift-card orders are the one legitimate item-less shape** and they need no carve-out: 2,027 of
them over 90 days carry $82,441.99 of gift cards and **$0.00 of discount**. The pre-2023 tail is
−$3,327.16, and `order_customer` reports $0 on it too, so suppressing it improves agreement.

## Columns

| Column | Type | Notes |
|---|---|---|
| `brink_order_id` | INTEGER | Join key to `claude.order_customer`. Not unique here |
| `pulse_order_id` | INTEGER | NULL for POS-only orders |
| `business_date` | DATE | Partition column. **Always filter it** |
| `is_catering` | BOOLEAN | From `order_lines`, matches `order_customer` since 2026-07-31 |
| `store_id` | INTEGER | 1111 and 999 already excluded upstream |
| `store_name` / `store_state` | STRING | Native, no `store_info` join needed |
| `revenue_category` | STRING | **Catering-overridden in this view**, same as `claude.order_customer` — so `revenue_category = 'Catering'` ⟺ `is_catering = true` here. The base `sales_ops` table is *not* overridden |
| `line_item_type` | STRING | `'discount'` or `'promotion'` only |
| **`discount_amount`** | FLOAT | **The answer column.** Negative. Prorated. The only summable money column |
| `points` | INTEGER | Loyalty points spent on this component. NULL off the integrated path. Already at component grain — safe to sum |
| `item_id` | INTEGER | Brink discount/promotion id |
| `discount_origin` | STRING | Where the discount came from — **not a channel**, see below |
| `discount_type` | STRING | What kind of discount — **open domain**, see below |
| **`is_employee_meal_discount`** | BOOLEAN | **The canonical employee / team-member meal flag.** Added 2026-08-17. Never NULL. Covers all four eras of the benefit — see below. Supersedes `order_customer.is_employee_discount`, which is being retired |
| `item_name` | STRING | Brink `brinkDiscounts` program name (since the 2026-08-12 `order_lines` rebuild) |
| `discount_name` | STRING | Best available name: sessionM → Pulse item → `item_name` |
| `root_offer_id` | STRING | sessionM root offer id. NULL for non-offer discounts |
| `offer_name` | STRING | sessionM offer name. NULL for non-offer discounts |

**`description` is deliberately not exposed.** On team-member discount lines it can carry an
employee's personal name (see the `order_lines` dictionary). It stays in the build CTE only.

## `discount_type` — an open domain, by design

Curated labels for the programs that matter, then **`else item_name`** as a fallback:

| `discount_type` | Lines (30d to 2026-08-14) | Amount |
|---|---|---|
| Reward Redemption | 22,390 | −$158,189.53 |
| Employee Meal Discount | 11,994 | −$144,335.95 |
| In-cart Points Redemption | 10,841 | −$89,080.04 |
| Third Party Discount | 6,738 | −$38,528.50 |
| Offer | 2,420 | −$36,753.09 |
| Promotion | 2,111 | −$26,093.71 |
| Manager Discount | 609 | −$3,921.31 |
| **Error** | **536** | **−$4,822.09** |
| Guest Relations | 502 | −$4,070.92 |
| Face To Face | 338 | −$4,024.12 |
| New Team Member Family Meal | 192 | −$3,126.40 |
| Offline Cafe Zupas Rewards | 22 | $0.00 |

**There is no `'Other'` bucket.** A Brink discount program that isn't explicitly mapped
surfaces under its own `item_name` on day one rather than vanishing into an unnamed group.
28 distinct values exist across full history; **zero NULLs** in 3.44M rows (verified
2026-08-14) — most of the long tail is the pre-2023 Punchh/OLO era (`OlO Discounts`,
`Employee 25%`, `Punchh Loyalty`).

One seam in that tail is still live: the master carries both `Punchh Loyalty` and
`Punch Loyalty`, so collapse those by hand in a full-history breakdown. The family-meal seam
is **fixed as of 2026-08-17** — `item_id 640945199` (pre-cutover) now maps to the same
`New Team Member Family Meal` label as `643529958`, so the two no longer split. That takes the
distinct count from 28 to 27, but **only for rows a full-history rebuild has touched**;
untouched pre-2024 partitions still carry the old `NewTeamMemb Family Meal` spelling.

## `is_employee_meal_discount` — the canonical employee-meal flag

**Added 2026-08-17.** `true` = the discount is a team-member / employee meal benefit, in **any
era**. This is the sanctioned answer to "what do we give away to team members?" — use it
instead of filtering on `discount_type` or on any name pattern.

Never NULL (`ifnull(..., false)`). Full history: **897,198 lines / −$9,396,781.51 true.**

### Why it is three arms and not one

No single source covers the whole history, so the flag ORs three independent tests. Each one
exists because the arm above it provably misses a population:

| Arm | Catches | Window | Lines | Amount |
|---|---|---|---|---|
| `item_id in (1, 2, 643529958, 640945199)` | the four Brink programs | 2018-08-20 → live | 870,665 | −$9,003,373 |
| `discount_name = 'Team Member Meal'` | sessionM rows where the `user_offers` lookup missed, so `offer_name` is NULL | 2025-01-21 → 2026-05-30 | 7 | −$115.64 |
| `offer_name` regex `team member meal\|\bemp.*(meal\|lunch)` | the sessionM offer path + the Jan-2025 `Emp Meal` / `Emp Lunch` test offers | 2023-07-27 → live | 26,572 | −$391,448 |

The four Brink ids, and why each is there:

| `item_id` | Program | Window | Lines | Amount |
|---|---|---|---|---|
| 2 | `Team Member 100% Discount` | 2018-08-22 → live | 707,194 | −$8,138,233.89 |
| **1** | `Employee 25%` — the pre-COVID 25%-off benefit | 2018-08-20 → 2020-03-21 | 155,792 | −$687,404.85 |
| 643529958 | `New Team Member Family Meal` | 2023-01-18 → live | 4,834 | −$107,433.85 |
| **640945199** | the SAME family-meal program on its pre-cutover Brink id | 2019-03-12 → 2023-02-14 | 2,845 | −$70,301.44 |

> **⚠️ `discount_type` deliberately does NOT merge these.** `item_id 1` keeps its own
> `discount_type` of `'Employee 25%'` because a 25%-off program and a 100%-off program are
> different things and collapsing them is irreversible for anyone reading history. The flag is
> what unions them. By contrast 640945199 and 643529958 **do** share one `discount_type`
> (`'New Team Member Family Meal'`) because they are one program under two POS ids across the
> Brink cutover — identical `item_name`, four weeks of overlap.
>
> The rule: **merge on `item_name`, not on who received the discount.**

### The arm that is a defect guard, not a definition

The `discount_name` arm is small (7 lines) and load-bearing. `offer_detail` filters
`uo.redeem_date is not null`, which is semantically right but degrades **silently** if sessionM
lags on stamping redemptions — offer attribution just goes NULL with no alarm. Without this
arm, employee meals would quietly stop flagging during such a lag. Do not simplify it away
because it looks like it catches nothing.

Likewise `\bemp` in the regex is anchored on purpose: unanchored `emp` would match a future
offer named `Temp … Meal`. Verified 2026-08-17 — both forms return the identical 9 offer names
/ 26,572 lines across full history, so the anchor costs nothing today and closes the trap.

### ⚠️ The widening only reaches history after a FULL rebuild

Measured 2026-08-17: widening the flag turns **+158,799 lines / −$760,224.18** from `false` to
`true`, and flips **zero** lines the other way. But the widest scheduled reload is 730 days.
`Employee 25%` ended 2020-03-21 and the legacy family-meal id ended 2023-02-14 — both sit
behind that floor and stay `false` until the full-history `create or replace table` is re-run.
**Employee-meal spend before 2023 reads ~$757K low until then.** Assertion E in
[`sql/sales_ops.order_line_discount_detail.sql`](../sql/sales_ops.order_line_discount_detail.sql)
is the check; all four buckets must return zero unflagged lines.

### Relationship to `order_customer.is_employee_discount`

`sales_ops.order_customer.is_employee_discount` is an ORDER-level flag built from name
patterns (`%Team%`, `%Employee%` on Brink names; `%Meal%`, `%Emp%`, `%Team%` on sessionM
offers). **Brent is retiring it 2026-08-17 — this table is the source of truth for employee
discounts.** Measured disagreement over 90 days to 2026-08-15, at order grain: 34,612 orders
agree, 78 disagree —

- **55 orders**: `order_customer` flags `Free Birthday Meal - Catering Offer` as an employee
  order. Its `%Meal%` pattern is too loose. This is the reason it is being retired.
- **13 orders**: an `Offer` line with no resolved `offer_name`.
- **5 orders**: `order_customer` flags an order that carries **no discount line at all** —
  the voided/comped shells the `order_lines` `valid_order_lines` guard suppresses.
- **3 orders / 2 orders**: the `discount_name` arm above, in each direction.

⚠️ Dropping that column from `sales_ops.order_customer` will break `claude.order_customer`,
which is a frozen `select * except(...)` view. Redeploy the view in the same change.

### `Error` is a health signal, not a category

`Error` = an integrated (`item_id = 643536109`) line with neither a Pulse component type nor
a `Third_Party` category. **On any closed business day it runs at 0–1 lines.** It fires for
two distinct reasons, and both are worth catching:

1. **Today, always.** Pulse hasn't caught up on the current business date, so the integrated
   lines find no component to classify against. Measured 2026-08-14: **531 of 694 of today's
   integrated lines (76.5%) read `Error`**, against 0 on every closed day in the prior six
   weeks. It self-heals at the next 4am pass.
2. **A closed day above ~1 line means the build's source lookback got too short** — see the
   lookback bet in Gotchas.

```sql
select
  dd.business_date
, countif(dd.discount_type = 'Error') as error_lines
, round(safe_divide(countif(dd.discount_type = 'Error'), countif(dd.item_id = 643536109)) * 100, 2) as pct_of_online_bucket
from `marketing-data-442316`.claude.order_line_discount_detail dd
where 1=1
and dd.business_date >= date_sub(current_date('America/Denver'), interval 14 day)
group by
  dd.business_date
order by
  dd.business_date desc
```

## `discount_origin` — where it came from, NOT the channel

| Value | Lines (30d) | Amount | Distinct `discount_type` |
|---|---|---|---|
| In-Store | 29,123 | −$278,899.14 | 8 |
| Online | 22,032 | −$189,223.87 | 4 |
| Third Party | 6,739 | −$38,531.78 | 2 |
| Outdoor Kiosk | 799 | −$6,290.87 | **9** |

> **⚠️ This column mixes two axes and that is deliberate.** `Outdoor Kiosk` and `Third Party`
> key on the **order**; `Online` and `In-Store` key on the **discount mechanism**. That's why
> Kiosk carries more distinct discount types than any other origin off the smallest volume —
> it sweeps up manager discounts, guest relations and reward scans placed at a kiosk terminal
> alongside integrated ones.
>
> **For channel questions the axis is `revenue_category`, always.** `Online` here means the
> discount came through the POS's integrated bucket, which includes phone-entered catering
> (83 lines / −$9,957 in July 2026 with `order_source = 'Operator'`).

Every `Third_Party` discount line in July 2026 was `item_id = 643536109` (6,773 of 6,773), so
`Third Party` is a clean subset of what would otherwise read `Online` — no information is lost
by the arm ordering.

## Recipes

**What did each discount program cost us?**

```sql
select
  dd.discount_type
, count(distinct dd.brink_order_id) as orders
, round(sum(dd.discount_amount), 2) as discount_amount
from `marketing-data-442316`.claude.order_line_discount_detail dd
where 1=1
and dd.business_date between @start_date and @end_date
group by
  dd.discount_type
order by
  discount_amount
```

**Loyalty giveaway split, integrated vs in-store:**

```sql
select
  dd.discount_origin
, dd.discount_type
, round(sum(dd.discount_amount), 2) as discount_amount
, sum(dd.points) as points_spent
from `marketing-data-442316`.claude.order_line_discount_detail dd
where 1=1
and dd.business_date between @start_date and @end_date
and dd.discount_type in ('Reward Redemption', 'In-cart Points Redemption', 'Offer')
group by
  dd.discount_origin
, dd.discount_type
order by
  discount_amount
```

**Discount rate against sales** — join to `order_customer` at order grain, aggregate this
table first so the component split doesn't multiply the sales side:

```sql
with disc as (
select
  dd.brink_order_id
, dd.business_date
, round(sum(dd.discount_amount), 2) as discount_amount
from `marketing-data-442316`.claude.order_line_discount_detail dd
where 1=1
and dd.business_date between @start_date and @end_date
group by
  dd.brink_order_id
, dd.business_date
)
select
  oc.revenue_category
, round(sum(oc.net_sales), 2) as net_sales
, round(sum(ifnull(disc.discount_amount, 0)), 2) as discount_amount
from `marketing-data-442316`.claude.order_customer oc
	left join disc
	on disc.brink_order_id = oc.brink_order_id
	and disc.business_date = oc.business_date
where 1=1
and oc.business_date between @start_date and @end_date
and oc.store_id <> 1111
group by
  oc.revenue_category
order by
  net_sales desc
```

## Gotchas

- **Never sum `count(*)` as a discount count.** It counts components. See the grain section.
- **Today is loaded intraday and is not reportable.** The table follows `order_customer`'s
  schedule (4am daily reload, hourly 8am–11pm for today only). On the current business date
  ~76% of integrated discounts classify as `Error` until the next 4am pass. Exclude or
  annotate today in any discount-mix report.
- **The build bets on a 60-day source lookback.** The source CTEs read `start_date - 60`,
  where `start_date` is the reload window (120d daily / 380d Monday / 730d on the 1st). This
  covers everything measured — over a 5-week window, **2 of 27,772 redemptions** referenced an
  offer issued before the floor, and those two only lose `offer_name` / `root_offer_id`,
  never money. But it is a bet on lead times: `pulse.order_discounts.created_at` is when an
  order was **placed**, `business_date` is when it was **fulfilled**, and catering is booked
  in advance (33 days observed max). A campaign booking further out than the window would show
  up as `Error` on closed days — which is exactly what the check above catches.
- **The offer tail is long, not fat.** The oldest offer behind a redemption was issued
  **2024-10-28 and redeemed in July 2026** — a ~20-month gap. Widening the lookback from 60 to
  90 or 120 days catches essentially nothing extra; only the 730-day monthly reload reaches
  that far back.
- **`offer_detail` requires `redeem_date is not null`.** Good for cost and semantically right,
  but it creates a silent dependency: if sessionM ever lags on stamping `redeem_date`, offer
  attribution degrades with no alarm. Currently 4 of 27,772 (measured 2026-08-14), evenly
  spread rather than clustered on recent days.
- **🧊 65% of the table is never refreshed by any scheduled run.** The widest reload is 730
  days; **2,239,212 of 3,440,131 rows (65.1%, −$15.6M) sit before that floor** and are frozen
  at whatever the last full-history build produced. `sales_ops.order_lines` was restated across
  full history **three times in the month to 2026-08-14** (07-30, 07-31, 08-12) — each one
  silently changes the parent beneath that frozen block. **Re-running the full-history build
  of this table is a required step in the `order_lines` rebuild checklist**, not a
  nice-to-have.
- **13 sessionM discount rows are dropped by design.** 2,535 `pos_transaction_key`s carry more
  than one `transaction_headers` row; the build keeps the latest, which drops 13 `USEROFFERID`
  discounts across full history. Immaterial, but documented so it isn't rediscovered.
- **`sm_discount_rel` is pinned to 1 row per order but nothing upstream enforces it.**
  539,153 / 539,153 with zero surplus across full history. The build adds a `qualify` guard
  because that join carries **no proration** — a second `USEROFFERID` discount on one order
  would silently double `discount_amount` without it.
- **Access:** the view reads `sales_ops`, which already carries
  `{dataset: claude, targetTypes: [VIEWS]}` in its access list, so **no new authorized-dataset
  grant is needed** (unlike `claude.order_payment_tender`, which reads `pulse`/`brink`).
- **`select *` freezes at view-creation time.** If a column is added to or renamed on
  `sales_ops.order_line_discount_detail`, redeploy this view with an identical `create or replace` — the
  `INFORMATION_SCHEMA` metadata and the actual behaviour will disagree until you do.

## Refresh & cost

Same schedule as `order_customer`, widened windows (steward 2026-08-15):

| Run | Reload window | Scan |
|---|---|---|
| Intraday, hourly 8am–11pm MT | today only | ~0.9 GB |
| Daily 4am | 120 days | 3.12 GB |
| Monday 4am | 380 days | ~8 GB |
| 1st of month 4am | 730 days | 14.36 GB |
| Hours 0–3, 5–7 | skipped | — |

~525 GB/month total, ≈$2.60. The 16 intraday runs are ~80% of that and are unaffected by the
reload-window width. The `delete`/`insert` is wrapped in an explicit transaction — without it,
a failed insert after a committed delete would leave a 120-day (730-day on the 1st) hole
returning zeros rather than an error, and the intraday runs only cover today so nothing would
heal it until the next 4am pass.

## Build script & post-load assertions

[`sql/sales_ops.order_line_discount_detail.sql`](../sql/sales_ops.order_line_discount_detail.sql)
is **the deployable script, verbatim** — paste it straight into the scheduled-query config.
Convention set 2026-08-17: the build file carries only the comments Brent wants living in the
console; everything explanatory lives here. Keep it that way, or the two copies drift and the
structural diff that catches deploy gaps stops being clean.

Run these after any logic change and after every `order_lines` full-history rebuild.

> ⚠️ **Every date function below is pinned to `America/Denver`.** Bare `current_date` is UTC,
> and the intraday runs fire 8pm–11pm Denver = 2am–5am the *next* UTC day, so a bare
> `current_date` silently means "tomorrow" for a third of the schedule. This bit during the
> 2026-08-14 review: three test builds either side of the UTC rollover picked different windows
> and the comparison read as a logic regression when it was a clock difference.

### 0. Does the DEPLOYED config match the repo file?

**Run this first. The built table cannot tell you what is deployed.** Filter to
`job_id like 'scheduled_query%'` — a manual console CTAS (`bquxjob_*`) fixes the *data* while
leaving the saved config untouched, and the next scheduled rebuild silently undoes it. Also
check `error_result`, not `state`: a failed run still reports `state = DONE`.

```sql
select
  datetime(j.creation_time, 'America/Denver') as run_mt
, j.job_id
, ifnull(j.error_result.message, 'ok') as result
, regexp_contains(j.query, r'(?i)is_employee_meal_discount') as has_emp_flag
, regexp_contains(j.query, r'(?i)640945199') as has_legacy_family_meal_id
, regexp_contains(j.query, r'(?i)begin transaction') as has_txn
from `region-us`.INFORMATION_SCHEMA.JOBS_BY_PROJECT j
where 1=1
and j.creation_time >= timestamp_sub(current_timestamp(), interval 2 day)
and j.query like '%sales_ops.order_line_discount_detail%'
and j.query like '%sessionM.transaction_discounts%'
and j.job_id like 'scheduled_query%'
order by
  j.creation_time desc
```

### A. `discount_amount` must reconcile to `order_lines` exactly

Full history 2026-08-15: **−$25,693,161.50 on both sides** (−$25,977,208.08 before the
`order_lines` `valid_order_lines` guard).

```sql
select
  round(sum(dd.discount_amount), 2) as mart_total
, (
    select round(sum(ol.amount), 2)
    from `marketing-data-442316`.sales_ops.order_lines ol
    where 1=1
    and ol.line_item_type in ('discount', 'promotion')
    and ol.store_id not in (1111, 999)
  ) as source_truth
from `marketing-data-442316`.sales_ops.order_line_discount_detail dd
```

### B. `Error` on a closed day must be 0–1 lines

Today is expected to spike (~76%). A sustained non-zero on a **closed** day means the 60-day
source lookback got too short. Query is in the `Error` section above.

### C. Offer attribution must not move when the reload window changes

Run on a Monday (380d pass) and again on a Tuesday (120d pass) — the numbers must match. They
did not before the windowing fix (275 rows differed over an 8-day window).

```sql
select
  dd.business_date
, countif(dd.offer_name is null) as null_offer_name
, countif(dd.root_offer_id is null) as null_root_offer_id
, count(*) as lines
from `marketing-data-442316`.sales_ops.order_line_discount_detail dd
where 1=1
and dd.business_date between date_sub(current_date('America/Denver'), interval 380 day)
                         and date_sub(current_date('America/Denver'), interval 121 day)
group by
  dd.business_date
order by
  dd.business_date desc
```

### D. Must tie to `order_customer` at ORDER grain — expect zero rows

⚠️ **Closed days only** (the current business date drifts ~47 orders / ~$438 against live Brink
because `order_customer` is a snapshot from its last load — not a defect). ⚠️ **Exclude store
999 on the `order_customer` side** — this table drops it upstream, `claude.order_customer` drops
only 1111; leaving it in costs $13.49 / 90 days. ⚠️ **Order grain, not date grain** — date grain
lets a compensating pair cancel out and read as a match. Query is in the
"Tying this table to `order_customer`" section above.

### E. `is_employee_meal_discount` must cover all four eras — expect zero rows

Added 2026-08-17. A non-zero legacy bucket means the **full-history rebuild has not been run**
since the flag was widened; the scheduled reload only reaches 730 days.

```sql
select
  case
    when dd.item_id = 1 then 'A. Employee 25% (2018-08 -> 2020-03)'
    when dd.item_id = 640945199 then 'B. NewTeamMemb Family Meal, legacy id'
    when regexp_contains(lower(ifnull(dd.offer_name, '')), r'\bemp.*(meal|lunch)') then 'C. Emp * Meal/Lunch offers'
    else 'D. discount_name Team Member Meal, offer lookup missed'
  end as bucket
, count(*) as unflagged_lines
, round(sum(dd.discount_amount), 2) as unflagged_amount
from `marketing-data-442316`.sales_ops.order_line_discount_detail dd
where 1=1
and dd.business_date >= '2018-08-07'
and dd.is_employee_meal_discount = false
and (
     dd.item_id in (1, 640945199)
  or regexp_contains(lower(ifnull(dd.offer_name, '')), r'\bemp.*(meal|lunch)')
  or dd.discount_name = 'Team Member Meal'
)
group by
  bucket
order by
  bucket
```

## Version note

**2026-08-17 — `is_employee_meal_discount` added and widened; build file slimmed to the
deployable script.** The flag covers the team-member meal benefit in all four eras (see its
section above); widening it moved +158,799 lines / −$760,224.18 from `false` to `true` with zero
flips the other way. `discount_type` gained `640945199` alongside `643529958` (one program, two
POS ids) and deliberately did **not** merge `item_id 1` into `item_id 2` (different programs).
`order_customer.is_employee_discount` is being retired in favour of this column.

Same day: the `order_lines` `valid_order_lines` guard was deployed with both arms and both tables
rebuilt from full history (11:45 then 11:49 — order matters). And the 08-15 rename was found to
have broken this build's own `delete` target, failing 37 consecutive scheduled runs invisibly;
the `begin`/`commit transaction` wrapper was lost during that fix and has been restored.

Convention change: [`sql/sales_ops.order_line_discount_detail.sql`](../sql/sales_ops.order_line_discount_detail.sql)
is now the deployable script verbatim. Documentation lives here, not in the scheduled query.

**2026-08-15 (later same day) — renamed, view deployed, reconciled to `order_customer`.**
`sales_ops.discount_detail` → `sales_ops.order_line_discount_detail`, and the `claude` view with
it. The rename dropped the view; it was redeployed under the new name the same day. **No alias
exists for the old name** — stale references fail loudly, which is the behaviour we want.

Shipped alongside it (repo-committed, deploy pending): the `sellable_orders` guard in
`sales_ops.order_lines`, which suppresses discount and promotion lines on orders with no sellable
`brinkOrderItem` row. This closes the $753.68 / 80-order gap against `order_customer` and moves
the full-history discount total from **−$25,977,208.08** to **−$25,693,161.50**.

⚠️ **This table must be rebuilt from full history after that `order_lines` change lands**, per the
frozen-block rule in Gotchas. Until it is, the pre-2023 block still carries the removed lines.

**2026-08-15 — initial deploy.** Reviewed before ship; the review found and fixed a
double-count on the un-prorated amount column (+7.2% in July 2026), an unbounded
`order_customer` join, a missing store 999 exclusion, an unmapped live `item_id`, and a
fact-vs-dimension windowing bug in the incremental that made `offer_name` **non-deterministic
by day of week** (Monday's wider reload resolved offers that Tuesday's narrower one wiped —
275 rows over an 8-day window). See
[the windowing gotcha](../claude_skills/sales-ops-orders/SKILL.md) for the general rule.
