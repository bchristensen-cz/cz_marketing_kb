# Validation: bound every number before it is delivered

> Part of the `ask-a-data-question` skill. Read `../SKILL.md` first; this file is loaded on demand.
> **Read it when:** a query has returned the number you are about to deliver, for any sales, item,
> customer, breakdown, rate or Braze question. It is Step 4 of the protocol:
> resolve, ask once, query, **validate**, answer. Bands ratified by the steward 2026-10-26.

A number is not an answer until it has been checked against something, and the thing it was
checked against is stated next to it. The protocol's other walls stop you querying the wrong
table or the wrong definition. This step catches the remaining class of failure: a query that is
legal, canonical and still wrong, because a name matched three ids, a join fanned out, or the
window was not the one the user meant. The worked case that motivated it: "what are the sales
for the new item for the last week" answered 9,000 units when the typical item in the same
category sells 250. That number must never reach the user unexamined.

Three checks, in this order. The first is a hard stop, the second and third decide whether a
qualification question is needed.

## 4a. Containment: can the number exist?

A containment failure means the SQL is wrong, not that the business did something unusual. Fix
the query and re-run; never ask the user about a number that cannot exist.

| Question type | Invariant |
|---|---|
| Item units | `units <= orders_containing_item * 10`; `units_per_order` normally 1.0 to 1.3 |
| Item dollars | item gross `<=` category gross `<=` chain gross for the same window and filters |
| Any net sales | `net_sales <= gross_sales`; a store or channel `<=` the chain |
| Customers | new customers `<=` identified customers in the window; every count under `customer_type = 'person'` |
| Rates and shares | between 0 and 1; the denominator is named in the answer |
| Breakdowns | parts sum to the whole within 0.5%; the number of groups equals the dimension (`claude.store_info` says how many states and stores exist); no NULL or blank group |
| Braze | clicks `<=` opens `<=` sends `<=` segment size; same-day and two-day-old figures labelled provisional (D-004) |

An extra group in a breakdown (a tenth market, a nameless store) is the signature of stores
1111 / 999 leaking in on a `sales_ops` query, or a join that dropped a dimension row. Hard stop.

## 4b. Benchmark: how does it compare?

Every delivered number gets a peer measured **from the same table, window and filters** as the
answer. Compute benchmark and answer in one query from one CTE wherever you can (template below),
so the two cannot drift apart. The benchmark is **p90 of the peer group**, not the mean or
median: a mean is dragged by the one item everybody buys, and a launch above the median is the
normal case, so either would make the check fire on ordinary days.

| Question type | Peer group | Flag when |
|---|---|---|
| Item units or dollars, named item | p90 of per-item units across every item in the same `rev_center_name` sold in the window (`claude.item_daily` + `claude.items`) | above **3x the category p90**, or above **5x the item's own trailing 28 days** scaled to the window, or below **0.2x** of either |
| New item (`launch_date` within 28 days of the window end) | category p90 only; the trailing-28 run rate is not yet meaningful | above 3x the category p90 |
| Sales totals (chain, store, channel, week) | the immediately preceding period of the same length, and the same period last year, same filters | beyond **plus or minus 40%** versus the prior period, or **plus or minus 60%** year over year, unless the scope explains it (new stores, a closed period, a holiday shift) |
| Customer counts and cohorts | prior period of the same length | plus or minus 40% |
| Rates and shares | prior period | a move of more than **20 points** |
| Store or market breakdown | each group against its own prior period | any single group beyond plus or minus 40% while the total is inside its band |
| Braze engagement | the campaign's own prior send, or the channel's trailing 28-day rate | plus or minus 40% on a rate; and never call last-touch revenue incremental (D-007) |

The bands are deliberately wide. The check exists to catch the 36x case, not to interrogate a
good week. Every band carries the date it was set; change them only through a `KB finding:`
task and a ledger row.

### Item benchmark template (verified 2026-10-26 on `claude.item_daily`)

`claude.item_daily` is item by day, partitioned on `business_date`, already excludes stores
1111 / 999 and discount / promotion / surcharge lines, and reads a week in a few MB. Use it for
the benchmark even when the answer came from `order_lines`; the two tie out exactly under the
same filters (dictionary, "Tie-out"). Carry the user's catering choice into the benchmark with
`include_catering`.

```sql
declare start_date date default date '2026-10-19';
declare end_date date default date '2026-10-25';
declare item_ids array<int64> default [643649922, 643649923];
declare include_catering bool default false;

with scope as (
select d.item_id
, i.item_name
, i.item_size
, upper(i.rev_center_name) as category
, sum(if(include_catering, d.units, d.units - d.units_catering)) as units
, sum(d.orders) as orders
, round(sum(if(include_catering, d.gross_sales, d.gross_sales - d.gross_sales_catering)), 2) as gross_sales
from `marketing-data-442316`.claude.item_daily d
join `marketing-data-442316`.claude.items i on i.item_id = d.item_id
where 1=1
and d.business_date between start_date and end_date
group by d.item_id, i.item_name, i.item_size, category
)
, bench as (
select s.category
, count(*) as items_in_category
, approx_quantiles(s.units, 100)[offset(50)] as median_units
, approx_quantiles(s.units, 100)[offset(90)] as p90_units
, max(s.units) as max_units
from scope s
group by s.category
)
, prior as (
select d.item_id
, sum(if(include_catering, d.units, d.units - d.units_catering)) / 28 * (date_diff(end_date, start_date, day) + 1) as prior_units_scaled
from `marketing-data-442316`.claude.item_daily d
where 1=1
and d.business_date between date_sub(start_date, interval 28 day) and date_sub(start_date, interval 1 day)
and d.item_id in unnest(item_ids)
group by d.item_id
)
select s.item_id
, s.item_name
, s.item_size
, s.category
, s.units
, s.orders
, s.gross_sales
, round(s.units / nullif(s.orders, 0), 2) as units_per_order
, b.items_in_category
, b.median_units
, b.p90_units
, b.max_units
, round(s.units / nullif(b.p90_units, 0), 1) as x_p90
, round(p.prior_units_scaled, 0) as prior_28d_scaled
, round(s.units / nullif(p.prior_units_scaled, 0), 1) as x_prior
from scope s
join bench b on b.category = s.category
left join prior p on p.item_id = s.item_id
where 1=1
and s.item_id in unnest(item_ids)
order by s.units desc
```

`upper(rev_center_name)` matters: `COMBOS` and `Combos` are both real values on `claude.items`.
`orders` on `item_daily` is distinct orders within the day, so `units_per_order` is exact for a
single day and a close upper bound over a week.

Worked result, week of 2026-10-19 to 10-25, catering excluded: Italian Sausage Gnocchi Soup
Half = 22,668 units, 1.08 units per order, 27 soups in the category, p90 16,188, `x_p90` 1.4,
`x_prior` 2.8. Inside every band, so it is delivered with the validation line and no question.
The Large size of the same product read 5,494 units, `x_p90` 0.3: also inside the band. Had the
two sizes been blended under one name the answer would have been 28,162 units at a price the
product is never sold at, which is exactly the Chocolate Strawberry Cup failure in
`sales-ops-orders/references/item_questions.md`.

### Totals and customers

For a total, run the same query twice more with the window shifted (prior period, same period
last year) or, cheaper, widen the window once and `group by` the period. For customer cohorts
the prior-period comparison must use the same `customer_type = 'person'` filter and the same
cohort definition from `sales-ops-orders/references/cohorts.md`. Do not scan history for the
benchmark: a 2x window is the ceiling.

## 4c. Scope echo: did the query run on the scope the user picked?

Before delivering, confirm three things from the result itself, not from the SQL you meant to
write: `min` and `max` of `business_date` in the result equal the window the user chose
(the `claude` views floor silently at the rolling 3-year start, and a `sales_ops` read does not);
the group count equals the dimension; and the measure delivered is the one the user picked
(units, not dollars, unless they opted in).

## "New item" and other vague nouns: resolve from the data, then ask

When the user says "the new item", "the new soup", "the LTO", "the launch", do not guess which
one. List every candidate from `claude.items` and present them as the options. `launch_date` is
derived (the first business date the item sold in at least 25% of the stores it ever reached),
so show `first_sold_date` beside it: a product that has been on a few menus since March and
crossed 25% of stores last week looks launched last week by `launch_date` alone.

```sql
declare window_end date default date '2026-10-25';

select i.item_id
, i.item_name
, i.item_size
, i.rev_center_name
, i.launch_date
, i.first_sold_date
, i.item_status
, i.sold_as
, i.is_catering_item
, i.stores_selling_28d
, round(i.avg_unit_price_90d, 2) as avg_unit_price_90d
, round(i.units_28d, 0) as units_28d
from `marketing-data-442316`.claude.items i
where 1=1
and i.has_ever_sold
and i.launch_date >= date_sub(window_end, interval 28 day)
order by i.units_28d desc
```

Run 2026-10-26 this returned 18 ids: one soup in three sizes (Half, Large, Kids), one sandwich,
one fountain beverage, five Box sandwiches that `first_sold_date` shows have sold since March,
three chips, and six modifiers (gnocchi, coconut crunch, cinnamon, pepperoni). The question to
the user lists them by product with sizes grouped, units and price in the label, the top-selling
genuinely new product `(Recommended)` first, and modifiers and rollouts clearly marked. A
product in several sizes is reported per `item_id` with an all-sizes roll-up, never blended
(D-013). If the list is empty, widen to 56 days once and say so; if still empty, say no item
launched in that window and ask what the user means.

## The diagnostic ladder: run it before you ask

When 4a or 4b trips, do not ask yet. These are the ways a plausible number has actually been
wrong in this warehouse, in the order they occur. Each is a one-query check.

1. **The name resolved to more than one `item_id`** (two sizes, a kids version, a catering box,
   a modifier with the same name). Check: `select item_id, item_size, sold_as from claude.items
   where item_name = ...`. Fix: report per id.
2. **Discount or promotion lines counted as items** (same `item_name`, `$0` gross, `qty` 1).
   Fix: the three-marker exclusion in `item_questions.md`.
3. **Modifier or combo-slot lines counted as the item** (soups and sandwiches inside Try 2
   Combo; bowls inside Box Lunches when catering is on). Check: `line_item_type` and
   `parent_rev_center_name`. Fix: state the shape, split or exclude.
4. **Join fan-out.** Check: `count(*)` versus `count(distinct brink_order_id)` after any join to
   `order_sequence`, `loyalty_user`, `store_info` or `items`. Fix: the grain.
5. **Wrong window.** A fuzzy "last week" resolved to the wrong Monday-to-Sunday, or a
   `sales_ops` read that reached back past the `claude` floor. Fix: echo explicit dates.
6. **Units and dollars mixed.** 9,000 may be gross dollars read as units. Fix: label the measure.
7. **Catering against the user's choice** (store 50, Box Lunches, catering-only SKUs). Fix:
   resolve on `order_customer`, not `order_lines`.

If a rung explains the gap, correct the query, re-run, and deliver with the correction in the
validation line. No question needed. Only a number that survives the ladder goes to the user.

## The qualification question

One `AskUserQuestion`, one fork, measured consequences in every label, the recommended option
first. For the 9,000-unit case after the ladder found nothing:

- Report 9,000 units, flagged as 6x the category p90 (36x the median) `(Recommended)` if the
  launch was chain-wide and promoted; the flag stays on the answer.
- Report the per-store-day run rate instead, which normalises a launch across 93 stores.
- Hold the number and open a `KB finding:` task, because nothing in the data explains the size.

Never ask more than once for the same number, and never ask about a containment failure.

## The validation line

Every answer, flagged or not, carries one line directly after the scope line from Step 3:

`Validation: <number> is <x>x the <category> p90 for <start> to <end> (p90 <n>, <k> items) and
<y>x its trailing 28 days; <verdict>.`

Verdicts are one of: `within band`; `explained by <ladder rung>, corrected from <old number>`;
`outside band, user chose <option>`. A number without this line was never bounded, and the
query-log review treats it that way.

## What not to do

- Don't deliver a number you haven't bounded. A clean query is not evidence the number is right.
- Don't benchmark against a different table, window or filter set than the answer. The
  benchmark then measures the difference between two scopes, not the plausibility of the number.
- Don't use the mean or the median as the peer. p90 is the rule (steward 2026-10-26).
- Don't scan history for a benchmark. Trailing 28 days or a 2x window is the ceiling.
- Don't treat `launch_date` as "first sold". Show both.
- Don't narrow or widen the bands per session. They change through a `KB finding:` task.

## Cost

The item benchmark reads one week of `claude.item_daily` plus `claude.items` (under 1 MB): a
few MB per check. The totals benchmark reads the same partitions as the answer once more.
Neither should ever appear in the query-log review as a top-ten cost; if one does, the window
was wrong.

## When done

If a band fired on a number that turned out to be right, or missed one that was wrong, that is
a finding: create an Asana task on the **Claude Data** board (workspace cafezupas.com, project
`1216769551099591`) titled `KB finding: <short title>` with the number, the benchmark, the band
and the proposed change. Do not edit this file or any local copy.
