# Discount, promotion and loyalty-giveaway questions

> Part of the `sales-ops-orders` skill. Read `../SKILL.md` first; this file is loaded on demand. **Read it when:** the question involves discounts, promotions, offers, employee meals, "what did we give away", or tying discounts back to orders.
> Content moved verbatim from `SKILL.md` on 2026-10-07 (progressive-disclosure restructure); the rules and dates inside are unchanged.

## Discount and loyalty-giveaway questions — `claude.order_line_discount_detail` (new 2026-08-15)

"What did we give away, and through what?" now has a home. One row per **discount
component**, with loyalty and offer attribution joined on. Full docs:
[`data_dictionaries/claude.order_line_discount_detail.md`](../../../data_dictionaries/claude.order_line_discount_detail.md).
It is the sanctioned wrapper around `pulse.order_discounts`, `sessionM.transaction_discounts`
and `sessionM.user_offers` — **never query those directly.**

### The grain is components, not lines — get this right first

Brink emits **exactly one** `item_id = 643536109` ("Online Discount") line per order. Where
Pulse holds several discount components under it, the table **splits that one Brink amount
across them** proportionally, so a single Brink line can produce several rows each with its
own `discount_type`. Row count runs **~1.5% above the source line count** (3,440,131 vs
3,388,269 full history, 2026-08-14). That surplus is the design.

- **`discount_amount` is the only summable money column.** It reconciles to `order_lines`
  exactly — **−$25,977,208.08 on both sides**, full history, identical filters (deployed table, 2026-08-15).
- **`count(*)` counts components**, not discounts and not orders. For discounts use
  `count(distinct concat(brink_order_id, '-', item_id))`; for orders,
  `count(distinct brink_order_id)`.
- **Joining to `order_customer` requires aggregating this table first**, or the component
  split multiplies the sales side. See the discount-rate recipe in the dictionary.

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

### Employee / team-member meal questions — use `is_employee_meal_discount` (new 2026-08-17)

**Do not filter on `discount_type` or on a name pattern.** The employee benefit has run under
four different Brink programs and two sessionM offer paths since 2018, and no single name or id
covers them. `is_employee_meal_discount` is the canonical flag and is never NULL.

```sql
select
dd.business_date
, count(distinct dd.brink_order_id) as employee_meal_orders
, round(sum(dd.discount_amount), 2) as employee_meal_discount
from `marketing-data-442316`.claude.order_line_discount_detail dd
where 1=1
and dd.business_date between @start_date and @end_date
and dd.is_employee_meal_discount = true
group by
dd.business_date
order by
dd.business_date
```

It replaces **`order_customer.is_employee_discount`**, which was **dropped from the table on
2026-08-17** — the column no longer exists and naming it errors. That one was built from name
patterns and its `%Meal%` arm flagged `Free Birthday Meal - Catering Offer` as an employee order
(55 orders in 90 days). Any saved query still using it is now broken, not merely stale; move it
here. For an order-level flag, aggregate this table with `max()` / `logical_or()` first.

⚠️ **Two live caveats.** (1) The flag was widened on 2026-08-17 to cover `Employee 25%`
(2018→2020) and the pre-cutover family-meal id; that widening reaches history **only after a
full-history rebuild**, because the widest scheduled reload is 730 days. Until that runs,
pre-2023 employee-meal spend reads ~$757K low. (2) `discount_type` still keeps `Employee 25%`
and `Employee Meal Discount` as **separate** programs on purpose — 25%-off and 100%-off are
different benefits. Use the flag to union them, not a merged `discount_type`.

### `discount_origin` is not a channel

Values: `In-Store`, `Online`, `Third Party`, `Outdoor Kiosk`. **The column deliberately mixes
two axes** — `Outdoor Kiosk` and `Third Party` key on the *order*, `Online` and `In-Store` key
on the *discount mechanism*. That's why Kiosk carries 9 distinct discount types off 799 lines
(30 days to 2026-08-14) while Online carries 4. `Online` includes phone-entered catering that
flowed through the integrated bucket. **For channel questions the axis is `revenue_category`,
always.**

### `discount_type` is an open domain

Curated labels for the programs that matter, then `else item_name`. **There is no `'Other'`
bucket** — an unmapped Brink program surfaces under its own name on day one. 28 distinct
values across full history, **zero NULLs** in 3.44M rows. Most of the long tail is the
pre-2023 Punchh/OLO era; two label seams there (`NewTeamMemb Family Meal` vs
`New Team Member Family Meal`, and `Punchh Loyalty` vs `Punch Loyalty`) need collapsing by
hand before presenting a full-history breakdown.

### "Earned" discounts = the two loyalty redemption types (steward definition 2026-08-18)

**Earned = `discount_type in ('Reward Redemption', 'In-cart Points Redemption')`.** Full stop.
Confirmed by the steward 2026-08-18. Everything else was **given**: marketing offers outside the
loyalty wallet, in-store promotions, third-party discounts, service recovery, manager
discretion, employee benefit.

```sql
select
dd.business_date
, case
    when dd.discount_type in ('Reward Redemption', 'In-cart Points Redemption')
      then 'earned'
    else 'given'
  end as discount_basis
, count(*) as discount_lines
, count(distinct dd.brink_order_id) as orders
, round(sum(dd.discount_amount), 2) as discount_amount
from `marketing-data-442316`.claude.order_line_discount_detail dd
where 1=1
and dd.business_date between @start_date and @end_date
group by
dd.business_date
, discount_basis
order by
dd.business_date
, discount_basis
```

2026-05-01 → 2026-07-31: earned **103,540 lines / −$752,606.55**, out of 181,505 lines /
−$1,485,468.22 of all discounts — **50.7% of discount dollars**.

#### Why both Brink ids belong, including `643571116`

**`643571116` is a purpose-built loyalty-redemption id** — the in-store Cafe Zupas Rewards
button. It fires only when a member redeems something from their loyalty wallet. That is the
definition of the id, not an inference from its contents.

The data agrees. Every reward line resolves to a sessionM member wallet offer
(`root_offer_id`), on both ids and every origin:

| `discount_type` | `discount_origin` | `item_id` | Lines | With wallet offer | Coverage |
|---|---|---|---|---|---|
| Reward Redemption | In-Store | 643571116 | 42,173 | 41,767 | **99.0%** |
| Reward Redemption | Online | 643536109 | 26,675 | 26,452 | **99.2%** |
| Reward Redemption | Outdoor Kiosk | 643571116 | 605 | 597 | 98.7% |
| Reward Redemption | Outdoor Kiosk | 643536109 | 385 | 383 | 99.5% |
| In-cart Points Redemption | Online / Kiosk | 643536109 | 33,702 | n/a — `points > 0` on 100% | — |

`In-cart Points Redemption` carries the point spend directly: `points > 0` on **all 33,702
lines**, 43.0M points in the window, zero exceptions.

> **Do not "correct" this by excluding `offer_kind = 'promotional'` rows.** A wallet offer that
> was issued rather than points-priced is still a loyalty redemption by a member — the program
> earned it, and the steward's definition covers it. An earlier pass at this question excluded
> them and understated earned by −$36,798.41. That was wrong.

#### Optional breakdown *within* earned — points-priced vs issued-to-wallet

If someone asks specifically about **points cost, points liability, or what points bought**,
they want the points-priced subset, not all of earned. `claude.loyalty_offer_usage.offer_kind`
splits it: `points_purchase` = the guest paid points at a published price, `promotional` = the
offer was issued into the wallet and redeemed at no point cost. Verified clean over offers
redeemed in the window — `points_required > 0` on **59,190 of 59,190** `points_purchase` rows
(avg 1,110 points) and **0 of 22,074** `promotional` rows.

| Subset of earned (in-store `643571116`, 2026-05-01 → 07-31) | Lines | Amount |
|---|---|---|
| `points_purchase` — points paid at a published price | 32,299 | −$243,048.45 |
| `promotional` — offer issued to the wallet, redeemed free | 10,064 | −$36,798.41 |

The points menu with its prices: `Try 2 Combo` 1,950 pts, `Protein Bowl` 1,900,
`Large Salad` 1,750, `Sandwich` 1,350, `Half Salad` 1,350, `Half Soup` 1,100,
`Cheesecake` 1,000, `50% Off Try 2 Combo` 975, `Large Drink` 550, `Regular Drink` 450,
`Chips` 300, `French Baguette Bread` 200. The issued-to-wallet side:
`$1 Happy Hour Mocktail`, `Birthday Free Dessert`, `Free Reg Drink w/ Purch`,
`Sip Pass - Free Daily Drink`, `$5 off Your First Order`, `$5 off Oconomowoc`, `Free Delivery`.

**This is a breakdown, not a filter.** Both rows are earned. Present it only when the question
is about points economics, and label the two rows in the words above — not as
"earned vs not earned."

#### 🚨 `root_offer_id` case is inconsistent — `upper()` both sides or the join returns nothing

Independent of the definition, and still live. The column is
`coalesce(odr.root_offer_id, pd.sessionM_root_offer_id)`: the sessionM arm is **UPPERCASE**,
the Pulse arm is **lowercase**. `claude.loyalty_offer_usage.root_offer_id` is UPPERCASE.

Joining without `upper()` matches **0 of 12,040** `Offer` lines and drops online reward lines
too, and it fails **silently** — in the direction that makes wallet offers look unresolvable.
Same offer under two cases: `06ce255f-b15b-405e-8b0b-720059a51715` (Pulse,
`Sip Pass - Free Daily Drink`) vs `06CE255F-B15B-405E-8B0B-720059A51715` (sessionM).

Always `upper()` both sides. Build fix pending: `upper()` on `pd.sessionM_root_offer_id`, one
line below where `sessionM_user_offer_id` already is.

#### ⚠️ Employee meals sit inside earned — don't double-count them

**292 lines / −$4,255.83** in the window are `discount_type = 'Reward Redemption'` **and**
`is_employee_meal_discount = true` — the `Team Member Meal` offer, issued to team members'
loyalty wallets. Both flags are correct and both are canonical, so an earned-vs-employee
rollup that treats the two as exclusive double-counts them. State which one the question is
asking about; if it needs both, subtract the overlap explicitly.

#### Window rules

- **Reliable 2024-01-01 forward.** Unattributable `Error` as a share of loyalty-bucket dollars:
  **2023: 18.0%** (−$407,323.83) · 2024: 2.9% · 2025: 0.1% · 2026: 1.3%.
- **2023 spans the Punchh → sessionM cutover**, and the legacy earned programs carry different
  `discount_type` values the rule above does not name: `Punch Loyalty` 4,028 lines (→2023-05-30),
  `Catering Redemption` 3,627 (2023-05-31→12-01), `Punchh Loyalty` 534 (→2023-02-15),
  `Loyalty Reward-Free Drink` / `-Birthday Meal` / `-Free Dessert` 37 combined (→2023-02-10).
  These *were* earned in the old program's terms. Add them by name for any pre-2024 figure and
  label the result as two incompatible loyalty programs stitched together.
- **`Offline Cafe Zupas Rewards`** (`item_id 643571119`, 2,225 lines full history) is always
  **$0.00** — a marker line. Harmless in dollar totals, inflates line and order counts. It is
  not one of the two earned types, so the rule above already excludes it.
- **Never intraday** — see the `Error` health signal below.

#### ⚠️ Offer resolution shifts when a wide reload runs

Measured 2026-08-18: online reward `root_offer_id` coverage read **314 of 26,675 lines** early
in the session and **26,452 of 26,675** after `sales_ops.order_line_discount_detail` was
modified at 17:15 MT the same afternoon. Same table, same window, same query.

The likely mechanism is the build's `offer_detail` CTE filtering
`uo.create_date >= start_date - 60`: a narrow daily reload cannot see older offers, so
`root_offer_id` goes NULL on rows a wide reload would resolve. **That explanation is untested** —
do not repeat it as fact. What is certain: **wallet-offer attribution on this table is not
stable across reload widths**, so a coverage percentage is only true as of a stated timestamp,
and a low one means "check what last touched the partition" before it means "the data is
missing." Same family as the `is_employee_meal_discount` widening note.

### 🚨 `Error` is a health signal — and today always fails it

`Error` = an integrated line with neither a Pulse component type nor a `Third_Party` category.
**On any closed business day it runs at 0–1 lines.** Two ways it fires:

1. **Today, always.** Pulse hasn't loaded the current business date, so **~76% of today's
   integrated lines read `Error`** (531 of 694, measured 2026-08-14, against 0 on every closed
   day in the prior six weeks). It self-heals at the next 4am pass. **Never report today's
   discount mix intraday** — answer through yesterday and say why, same as the customer-grain
   rule for today.
2. **A closed day above ~1 line means the build's 60-day source lookback got too short.** That
   is a real defect — raise it, don't explain it away.

## Discounts must tie to `order_customer` — and how to run that check (2026-08-15)

`sum(discount_amount)` on `claude.order_line_discount_detail` equals
`sum(total_discount_amount + total_promotions_amount)` on `claude.order_customer`, to the cent.
If a user reports these disagreeing, **check the comparison before you check the data** — three
things break it and all three look like a data defect:

1. **Compare at ORDER grain, not date grain.** At date grain a compensating pair on the same day
   cancels out and reads as a match. Join on `brink_order_id` **and** `business_date`.
2. **Exclude store 999 on the `order_customer` side.** `order_line_discount_detail` drops
   `store_id not in (1111, 999)` upstream; `claude.order_customer` drops only 1111. One order /
   **$13.49** over 90 days lives in that gap.
3. **Closed days only.** `order_customer` is a snapshot from its last load while raw Brink moves
   all day, so the current business date drifts ~47 orders / ~$438. Same rule as the discount-mix
   one above: answer through yesterday and say why.

```sql
with dd as (
select
dd.business_date
, dd.brink_order_id
, abs(round(sum(dd.discount_amount), 2)) as amount
from `marketing-data-442316`.claude.order_line_discount_detail dd
where 1=1
and dd.business_date between @start_date and @end_date
group by
dd.business_date
, dd.brink_order_id
)

, oc as (
select
oc.business_date
, oc.brink_order_id
, round(oc.total_discount_amount + oc.total_promotions_amount, 2) as order_discount
from `marketing-data-442316`.claude.order_customer oc
where 1=1
and oc.business_date between @start_date and @end_date
and oc.store_id not in (1111, 999)
)

select
dd.business_date
, dd.brink_order_id
, dd.amount
, oc.order_discount
from dd
	full outer join oc
	on oc.business_date = dd.business_date
	and oc.brink_order_id = dd.brink_order_id
where 1=1
and ifnull(dd.amount, 0) <> ifnull(oc.order_discount, 0)
```

### Why they used to disagree — and why `order_customer`'s zeros were RIGHT

Worth carrying as a pattern, because the instinct it corrects is a common one.

`sales_ops.order_customer` joins its discount and promotion CTEs on **`boi.orderid`** — the output
of its own `brink_order_item` CTE — not on `bo.id`. That CTE filters
`IsCleared/IsVoided/IsDeleted = false` and then applies
`having sum(ItemGrossSales) > 0 or sum(ItemNetSales) > 0`. Any order it drops has
`boi.orderid = NULL`, so the discount joins collapse and the order reports **zero** discount even
though `brinkOrderDiscount` holds live rows with `isDeleted = false`. `order_lines` keyed on
`bo.id`, kept the money, and ran **$753.68 high over 90 days across 80 orders**. Every affected
order carries `has_order_items = false`.

It reads like a bug in `order_customer`, and the obvious fix — repoint the join at `bo.id` — is
**wrong**. Those orders are voided/comped shells: Brink zeroes the header (`GrossSales` /
`NetSales` / `Subtotal` / `Total` all 0) and voids the items but leaves the discount row standing.
78 of the 80 had every item row cleared/voided/deleted; the other 2 carried a single
`Online Details Memo` line at $0.00. Nothing was sold, so nothing was given away — joining on
`bo.id` would book $767 of giveaway against $0 of sales and drive `net_sales` negative.

**The rule: when two marts disagree, work out which one is describing reality before you make the
other one match it.** Here the fix went into `order_lines` (a `sellable_orders` guard suppressing
discount and promotion lines on those orders), not into the mart that looked broken.

`has_order_items = false` orders read `net_sales` = **$0.00, and that is correct**.
`gross_sales` is 0 on every one of them — 12,327 of 12,327 over 2026-07-20 → 08-22 — so
`0 - 0 - 0 = 0`. Nothing was sold and nothing was given away. Payments on those rows are real.
**Retracted 2026-08-24 (steward ruling):** an earlier revision called this net figure "wrong"
and the zeroed discounts a join-key bug. Orders without valid lines cannot carry discounts or
promotions, so they are excluded by design.
