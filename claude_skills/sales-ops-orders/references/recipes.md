# Recipes — validated query templates

> Part of the `sales-ops-orders` skill. Read `../SKILL.md` first; this file is loaded on demand. **Read it when:** you are about to write SQL for sales, menu mix, combos, modifiers, VTO/limited-time items, store or channel breakdowns.
> Content moved verbatim from `SKILL.md` on 2026-10-07 (progressive-disclosure restructure); the rules and dates inside are unchanged.

## Recipes

**Intraday pacing — "how is today running versus comparable days at this hour?" (steward pattern, mined 2026-09-07):**

Compare cumulative order counts at fixed wall-clock cutoffs, not day totals — a partial day against full days is the classic false alarm. Use `order_datetime_local` (DATETIME, store-local), never `order_timestamp_utc`. Pick the comparison set explicitly and label it: the same weekday for the prior four weeks, plus the holiday-aligned LY day if today is a holiday (Labor Day 2026-09-07 ↔ 2025-09-01) and a plain LY weekday as the non-holiday baseline. Always carry `max(order_datetime_local)` so the reader sees where today's data stops — intraday reloads land hourly at :02, so "today" is stale by up to an hour. Restrict `revenue_category` / `is_catering` to the population being paced; catering orders carry their *service*-date timestamp and distort a same-hour read. Hour-of-day against **2024** is not comparable (12-hour clock defect, see top of file).
```sql
select
oc.business_date
, format_date('%a', oc.business_date) as dow
, count(*) as orders_day
, countif(time(oc.order_datetime_local) < time '11:00:00') as thru_11
, countif(time(oc.order_datetime_local) < time '12:00:00') as thru_12
, countif(time(oc.order_datetime_local) < time '13:00:00') as thru_13
, countif(time(oc.order_datetime_local) < time '14:00:00') as thru_14
, max(oc.order_datetime_local) as last_order
from `marketing-data-442316`.claude.order_customer oc
where 1=1
and oc.business_date in ('2025-09-01', '2025-08-25', '2026-08-10', '2026-08-17', '2026-08-24', '2026-08-31', '2026-09-07')
and oc.is_catering = false
and oc.revenue_category = 'Digital'
group by 1, 2
order by 1
```

**Daily net sales by channel (last 30 days):**
```sql
select
oc.business_date
, oc.revenue_category
, round(sum(oc.net_sales), 2) as net_sales
, count(*) as orders
from `marketing-data-442316`.sales_ops.order_customer oc
where 1=1
and oc.business_date >= date_sub(current_date('America/Denver'), interval 30 day)
and oc.store_id <> 1111
group by 1, 2
order by 1, 2
```

**Sub-channel split — in-store / digital pickup / CZ Delivery / third party (added 2026-09-18):** `revenue_category` is the rollup and does not split Digital into pickup vs delivery, which is why analysts keep rebuilding a channel CASE from `destination` (five different shapes observed 09-16/17). Compose it from the two canonical pieces instead — the rollup for everything, `destination = 'CZ Delivery'` (§6) for the one split the rollup lacks. Never test `destination in ('DoorDash', …)` or `order_source = 'Checkmate'` for third party: `revenue_category = 'Third_Party'` already is that list, and the two-value pickup lists seen in the wild (`'Online Takeout', 'Good Life Lane'`) drop every other digital destination into "In store".
```sql
select
case
	when oc.revenue_category = 'Third_Party' then 'Third party'
	when oc.destination = 'CZ Delivery' then 'CZ Delivery'
	when oc.revenue_category = 'Digital' then 'Digital pickup'
	when oc.revenue_category = 'In-Store' then 'In store'
	else oc.revenue_category
	end as channel
, count(*) as orders
, round(sum(oc.net_sales), 2) as net_sales
, round(avg(oc.net_sales), 2) as avg_check
from `marketing-data-442316`.claude.order_customer oc
where 1=1
and oc.business_date >= date_sub(current_date('America/Denver'), interval 30 day)
and oc.store_id not in (1111, 999)
and oc.is_catering = false
group by 1
order by 2 desc
```
Catering and Fundraiser fall through the `else` with their own names; state whether they are in scope (protocol item 3).

**Annual spend tiers — "who are our $1,000+/year customers?" (added 2026-09-18):** do not re-aggregate `order_customer` for this. `customer_attribute.net_sales_l365` / `orders_l365` are the trailing-365-day spend and order count per person customer, rebuilt daily, store 1111 excluded, and since 2026-09-18 they come with a catering subset (`catering_orders_l365`, `catering_net_sales_l365`) so the standard catering exclusion is a subtraction, not a rescan. All four are exposed on `claude.order_customer`, so a standard user gets them by taking one row per `mapped_cust_id` (the columns repeat on every order of the customer — dedupe, never sum them across orders). Two things to state: the window is **365 days to `attribute_asof_date`** (yesterday, not `max(business_date)`, whose last day is the partial intraday partition), and **catering is 23.3% of chain-wide `net_sales_l365`** ($20.10M of $86.38M on the 2026-09-18 build) even though only 277 customers mix catering and individual orders — include it and every top band fills with catering accounts, so the exclusion is a real fork, not a footnote.
```sql
with cust as (
select
ca.mapped_cust_id
, ca.net_sales_l365 - ca.catering_net_sales_l365 as spend
, ca.orders_l365 - ca.catering_orders_l365 as orders
from `marketing-data-442316`.sales_ops.customer_attribute ca
where 1=1
and ca.orders_l365 - ca.catering_orders_l365 > 0
)
select
case
	when c.spend >= 5000 then 'e. $5,000+'
	when c.spend >= 3000 then 'd. $3,000-4,999'
	when c.spend >= 2000 then 'c. $2,000-2,999'
	when c.spend >= 1000 then 'b. $1,000-1,999'
	else 'a. under $1,000'
	end as tier
, count(*) as customers
, round(sum(c.spend)) as net_sales_l365_ex_catering
, round(avg(c.spend), 2) as avg_spend
, round(avg(c.orders), 1) as avg_orders
from cust c
group by 1
order by 1
```
Standard-user form: replace the `cust` CTE with `select distinct oc.mapped_cust_id, oc.net_sales_l365 - oc.catering_net_sales_l365 as spend, oc.orders_l365 - oc.catering_orders_l365 as orders from claude.order_customer oc where oc.business_date >= date_sub(current_date('America/Denver'), interval 365 day) and oc.customer_type = 'person' and oc.orders_l365 - oc.catering_orders_l365 > 0`.

To describe *how* a tier orders (channel mix, check size, share of orders over $60), take the tier's `mapped_cust_id`s from the dimension and join them to the last 365 days of `claude.order_customer` — the fact scan is then filtered to the tier, and the channel split is the recipe above.

**Identified customer counts (person only):** *(rewritten 2026-09-08 — `mapped_cust_id` and `customer_type` now live on `order_sequence`; on `claude.order_customer` they are still exposed directly and the join is unnecessary)*
```sql
select
date_trunc(oc.business_date, month) as month
, count(distinct os.mapped_cust_id) as customers
, count(*) as orders
, round(sum(oc.net_sales), 2) as net_sales
from `marketing-data-442316`.sales_ops.order_customer oc
	join `marketing-data-442316`.sales_ops.order_sequence os
	on os.brink_order_id = oc.brink_order_id
	and os.business_date = oc.business_date
where 1=1
and oc.business_date >= date_sub(current_date('America/Denver'), interval 365 day)
and os.business_date >= date_sub(current_date('America/Denver'), interval 365 day)
and oc.store_id not in (1111, 999)
and os.customer_type = 'person'
group by 1
order by 1
```

**First-time vs repeat orders (last 30 days):**

`order_sequence` is not pre-filtered, so the `customer_type` test belongs in the CASE — without it every aggregator and kiosk order lands in "Repeat" and swamps the split.
```sql
select
oc.business_date
, case
    when os.brink_order_id is null then 'Unidentified'
    when os.customer_type <> 'person' then 'Non-person'
    when os.customer_order_count = 1 then 'First-time'
    else 'Repeat'
  end as guest_type
, count(*) as orders
, round(sum(oc.net_sales), 2) as net_sales
from `marketing-data-442316`.sales_ops.order_customer oc
	left join `marketing-data-442316`.sales_ops.order_sequence os
	on os.brink_order_id = oc.brink_order_id
	and os.business_date = oc.business_date
where 1=1
and oc.business_date >= date_sub(current_date('America/Denver'), interval 30 day)
and os.business_date >= date_sub(current_date('America/Denver'), interval 30 day)
and oc.store_id <> 1111
group by 1, 2
order by 1, 2
```

**Top items by quantity (entrées, last 90 days):**
```sql
select
ol.item_name
, ol.item_size
, sum(ol.qty) as qty
, round(sum(ol.item_gross_sales), 0) as gross_sales
from `marketing-data-442316`.sales_ops.order_lines ol
where 1=1
and ol.business_date >= date_sub(current_date('America/Denver'), interval 90 day)
and ol.store_id <> 1111
and ol.line_item_type = 'item'
and ol.item_type = 'Entree'
group by 1, 2
order by 3 desc
limit 25
```

**Entrée units split standalone vs inside a Try 2 Combo (verified 2026-07-28):**

An entrée appears in `order_lines` in **three** distinct shapes. Getting these wrong is the single easiest way to produce a confidently wrong item number — see the taxonomy note below.

```sql
select
date_trunc(ol.business_date, week(monday)) as week
, case
    when ol.line_item_type = 'item' and ol.composite_item_id is null then 'Standalone'
    when ol.line_item_type = 'item' and ol.composite_item_id is not null then 'Combo component (priced)'
    when ol.line_item_type = 'modifier' then 'Combo slot (zero-priced)'
  end as sale_shape
, sum(ol.qty) as units
, round(sum(ol.item_gross_sales), 2) as gross_sales
from `marketing-data-442316`.sales_ops.order_lines ol
where 1=1
and ol.business_date between @start and @end
and ol.store_id <> 1111
and ol.item_name = 'Ultimate Grilled Cheese'
and ol.is_catering = false
group by 1, 2
order by 1, 2
```

### Combo line taxonomy — the three shapes (steward finding 2026-07-28)

| Shape | Filter | Carries revenue? |
|---|---|---|
| **Standalone** | `line_item_type = 'item'` and `composite_item_id is null` | Yes — full menu price |
| **Combo component (priced)** | `line_item_type = 'item'` and `composite_item_id is not null`, `parent_rev_center_name = 'Try 2 Combo'` | **Yes** — real allocated price (~$6.64/line for UGC) |
| **Combo slot (zero-priced)** | `line_item_type = 'modifier'` **and `parent_rev_center_name = 'Try 2 Combo'`** | No — ~$0.01/line; the entrée recorded as a modifier selection |

#### Item questions default to UNITS — dollars are opt-in and warned (steward rule 2026-07-30)

The three sale shapes carry **three different prices for the same sandwich**, so a per-item
dollar total is not the figure it looks like. Ultimate Grilled Cheese, 2026-05-03 →
2026-06-27, non-catering, store 1111 excluded:

| Sale shape | Units | Gross | **Per unit** |
|---|---|---|---|
| Sold alone | 24,125 | $215,890 | **$8.95** ← menu price |
| In a combo, paid | 47,461 | $315,280 | **$6.64** ← allocated, 26% under menu |
| In a combo, free | 37,623 | $386 | **$0.01** |
| **Blended** | **109,209** | **$531,556** | **$4.87** |

**A blended average price lands 46% below the menu price** — and it moves with combo mix,
not with any pricing decision. Two items on the same menu price will show different average
prices purely because one gets bundled more often. This is the most quotable wrong number
the mart can produce.

- **Report units unless dollars were explicitly asked for.**
- **When you do report dollars**, say in the same sentence that combo components are booked
  at an allocated price and that this is *gross* — it will not tie to net sales.
- **A revenue number someone needs to reconcile is not an item question.** Use order-level
  `net_sales` from `order_customer` and say why you switched.

`artifacts/item-sales-builder.html` enforces this same default, so chat answers and the
report builder agree.

#### 🚨 "Did this order contain a salad?" is NOT `line_item_type = 'item'` (observed 2026-08-27)

The taxonomy above is usually read as a *revenue* rule. It is also a **presence** rule, and
that is where campaign-lift analysis quietly breaks. Observed in a live Braze experiment
query on 2026-08-27:

```sql
-- WRONG for a "bought a salad" test
select distinct brink_order_id
from `marketing-data-442316`.sales_ops.order_lines
where business_date between '2026-08-24' and '2026-08-26'
  and line_item_type = 'item'
  and rev_center_name = 'Salads'
```

`line_item_type = 'item'` keeps standalone sales **and** priced combo components, but drops
the **zero-priced combo slot** — the entrée recorded as a `modifier` selection. That third
shape is not a rounding error: for the entrée classes it applies to, the split between priced
components and $0 modifier lines runs roughly **56/44 across all 88 stores and both combo
types** (documented in the taxonomy above). The *why* is settled: it is the POS-vs-digital channel split described in the taxonomy note corrected 2026-07-30, and since 2026-09-24 it is also visible on the dimension side as separate `item_id`s per channel (Try 2: POS 642388932 / 642388929 / 642388930 `$0` composites vs Pulse 642361973 `$12.99`; Kids Combo: POS 643647054 vs Pulse 642361971, see the `order_lines` dictionary Kids Meals gotcha). So a Try 2 Combo
containing a salad can register as "did not buy a salad", and it does so **only for combo
buyers** — a behavioural segment, not a random sample. In a lift test that is a biased
denominator, not noise.

**For "did the order contain X", ask about presence and ignore `line_item_type`:**

```sql
select distinct ol.brink_order_id
from `marketing-data-442316`.claude.order_lines ol
where 1=1
and ol.business_date between @start and @end
and ol.store_id not in (1111, 999)
and ifnull(ol.item_type, '') not in ('Discount', 'Promotion')
and ifnull(ol.rev_center_name, '') not in ('Discount', 'Promotion')
and ifnull(ol.line_item_type, '') not in ('discount', 'promotion')
and 'Salads' in (ifnull(ol.rev_center_name, ''), ifnull(ol.parent_rev_center_name, ''))
```

Testing `rev_center_name` **or** `parent_rev_center_name` catches all three shapes, because
the combo slot carries its category on the parent. Keep the discount/promotion exclusion —
promotion lines pass the standalone-sale test and named promotions collide with item names.

**Generalisable rule: a revenue filter and a presence filter are different questions.** Same
family as the filter-vs-breakout rule in `ask-a-data-question` — reusing one for the other is
how a control group ends up measured differently from a treated one.

#### Equivalent formulation without `line_item_type` (verified 2026-07-30)

`line_item_type` is a POS-internal concept — **"item" vs "modifier" means nothing to a
business user**, and exposing it in a user-facing tool invites the wrong question. The same
four shapes are fully separable from `composite_item_id` and `parent_rev_center_name`
alone, which name things people recognise:

| Shape | Filter | Plain English |
|---|---|---|
| Sold alone | `composite_item_id is null and parent_rev_center_name = rev_center_name` | Bought on its own |
| In a combo, paid | `composite_item_id is not null` | The priced half of a Try 2 Combo |
| In a combo, free | `composite_item_id is null and parent_rev_center_name = 'Try 2 Combo'` | The zero-priced slot |
| In a catering box | `composite_item_id is null and ifnull(parent_rev_center_name, '') not in ('Try 2 Combo','Discount','Promotion') and ifnull(parent_rev_center_name, '') <> ifnull(rev_center_name, '')` | Box Lunches / Party Trays |

The tell for a standalone line is that its **`parent_rev_center_name` equals its own
`rev_center_name`** — an unbundled item is its own parent. Verified to produce identical
numbers to the `line_item_type` version on the four-item test set over 2026-05-03 →
2026-06-27: 211,033 sold alone / 90,226 in-combo paid / 71,330 in-combo free / 19,638
catering box, and $1,260,795 Utah gross either way. Use whichever is clearer for the
audience; **prefer this one in anything a non-analyst will read.**

- **`line_item_type = 'item'` is NOT the same as "standalone."** For Ultimate Grilled Cheese over 2026-05-03 → 2026-06-27: 71,586 `item` lines, but only **24,125** were standalone — the other **47,461** were priced combo components. Treating all `item` lines as standalone overstates standalone units ~3x and understates combo units.
- **The two combo shapes are mutually exclusive per `combo_order_line_item_id`** (verified: 47,461 groups have exactly one priced component line and zero modifier lines; 37,623 have exactly one modifier line and zero component lines). So **combo units = component lines + modifier lines, with no double-counting.** **Corrected 2026-07-30: the two shapes are a CHANNEL split, not a per-slot quirk.** Sandwich lines, 2026-06-30 → 2026-07-29, store 1111 excluded: in-store POS produced 209,982 priced components and only **29** zero-priced slots; digital produced 143,097 zero-priced slots and only **172** priced components. It is ~99.9% clean in both directions. So `composite_item_id is not null` is very nearly a proxy for `pulse_order_id is null`, and any analysis that filters to one combo shape has silently filtered to one channel. The earlier "appears across all 88 stores, so it isn't a split" reasoning was wrong — both channels operate in all 88 stores, which is exactly why the store test couldn't see it. **Test the candidate dimension, not a dimension that happens to be uniform.**
- **Revenue lives in the first two shapes, not just the first.** The priced combo components carried $315,280 of gross for UGC in that window vs $215,890 standalone — so "essentially all revenue is in standalone lines" is false. For revenue-per-unit, divide by standalone + component lines; exclude the zero-priced modifier lines.
- Box Lunches (catering) also surface entrées as zero-priced `modifier` lines with `parent_rev_center_name = 'Box Lunches'` — another reason to settle the catering question up front.
- 🚨 **The same channel split applies to paid ADD-ONS, and there it costs you a whole `item_id`** (observed 2026-09-16). A protein or topping add-on is recorded as `line_item_type = 'modifier'` with `item_modifier = 'Add'` on digital orders, and as `line_item_type = 'item'` on in-store POS — **under two different `item_id`s**. Cottage cheese is 643644590 (digital modifier) and 643644591 (POS item); ham is 643538356 / 642369565. So an attach rate written as `item_id = 643644590 and item_modifier = 'Add'` silently measures digital only, and the POS half never appears as a zero — it appears as a smaller, entirely plausible number. Resolve add-ons the way §5 resolves sizes: **discover by name across `item_id`, `line_item_type`, `item_modifier` and `rev_center_name` first**, then filter on the resolved id set — `(item_id = 643644590 and item_modifier = 'Add') or (item_id = 643644591 and line_item_type = 'item')`. `'Extra'` and `'No'` are separate `item_modifier` values on the digital id and are **not** add-on purchases (`'No'` is a removal); count only `'Add'`. Related: `rev_center_name = 'Modifiers'` with `line_item_type = 'item'` is the POS add-on population as a whole.
- ⚠️ **The "in a catering box" test catches orphaned modifiers** (found 2026-07-31). Modifiers attached to *priced combo components* (mostly POS Kids Combo selections — `Kids Tomato Basil Soup`, `Sprite`, …) get `parent_rev_center_name` = their **own description** because the mart's parent join misses combo components — 50,734 lines / 171 stray values over 2026-05-01 → 2026-07-30. Those lines satisfy `composite_item_id is null and parent <> rev_center and parent not in (...)` and would be misfiled as catering-box. Before running a shape breakdown, restrict to lines whose `parent_rev_center_name` is in the known rev-center list (see the `order_lines` dictionary gotcha), or add `and ifnull(ol.rev_center_name, '') <> 'Modifiers'` when the item can appear as a kids-combo/drink selection.

### Modifier / customization analysis — digital orders ONLY (verified 2026-07-30)

**`order_lines` carries essentially no modifier detail for in-store POS orders.** Standalone sandwiches
2026-06-30 → 2026-07-29, store 1111 excluded: **25** explicit ingredient changes across **65,276** POS lines
(0.0%) against **23,453** across **63,027** digital lines (37.2%). Priced combo components — which are the POS
combo shape — have **zero** attached modifiers across all 210,154 lines. This is a capture gap, not behavior:
a guest at the counter can obviously say "no tomato."

**Consequences, all mandatory:**

1. **Never report a company-wide modification rate.** Any rate is a *digital* rate. Filter
   `ol.pulse_order_id is not null` explicitly and say so — leaving POS in the denominator halves the number
   with no warning. Whether Brink records in-store modifiers at all is an open upstream question
   (Asana `KB finding: no in-store modifier capture`).
2. **`item_modifier = 'With'` is a build selection, not a modification.** The seven values are `With`, `No`,
   `Add`, `Substitute`, `Extra`, `None`, `For`. **A customization is `No` / `Add` / `Substitute` / `Extra`.**
   `With` covers the bread choice (`Ciabatta` 53,052, `Ancient Grain` 10,121) and the combo entrée slot, and it
   fires on **99.9%** of digital sandwiches because it's a required step. Counting any modifier line as
   "modified" returns ~99.9% — a technically-correct, completely useless number.
3. **Also require `rev_center_name = 'Modifiers'` on the change.** A `No` line can point at a dessert or a
   side (`No Chocolate Dipped Strawberry`, 2,896 lines) — that's a combo-slot decline, not an ingredient edit.

**Join key:** modifier lines attach to the parent item line on **(`brink_order_id`, `order_item_id`)** — the
modifier's `order_item_id` holds the *parent's* order-item id, and its own identity is `item_id_seq_num`.
Do **not** join on `combo_order_line_item_id`; it groups the whole combo.

> **⚠️ Inside a Try 2 Combo, modifiers cannot be attributed to a specific entrée.** All modifiers for every
> slot hang flat off the *combo parent's* `order_item_id`, siblings of the entrée slot lines themselves. Over
> 2026-06-30 → 2026-07-29, non-catering, **143,123 of 143,124** sandwich-bearing combos also held a
> soup/salad/bowl — so "No Roma Tomato" belongs to either entrée with no way to tell. The tell is in the data:
> the top changes on sandwich-bearing combos include `Add Salad Tortilla Strips` (8,157), `Add Radiatore Noodle`
> (7,802) and `Add Wild Rice Blend` (4,174), which are soup and salad ingredients.
>
> **So report the standalone rate as the answer and the combo rate as an upper bound**, never a blended number
> without both stated. Sandwiches, last 30 days, digital, non-catering: **37.2% standalone (exact, 1.61 changes
> each) vs 49.3% in-combo (ceiling, 2.04 each)**; blended 45.6% of 206,122.

**Try 2 Combo count and composition:**
```sql
select
ol.parent_item_grp_name
, count(distinct ol.combo_order_line_item_id) as combos
from `marketing-data-442316`.sales_ops.order_lines ol
where 1=1
and ol.business_date >= date_sub(current_date('America/Denver'), interval 30 day)
and ol.store_id <> 1111
and ol.parent_rev_center_name = 'Try 2 Combo'
group by 1
order by 2 desc
```

### Identify VTO / limited-time items by first appearance (steward pattern, mined 2026-08-22)

There is no `is_limited_time` / `is_vto` flag on any item table, so a "which items are seasonal
rotations vs core menu?" question has to be answered from **when an item first appears in
`order_lines`**. The steward iterated this shape ~10 times on 2026-08-22 while building a
`sales_ops.vto_items` dimension.

> **✅ `sales_ops.vto_items` is now deployed — this section's earlier "not deployed, use the pattern
> inline" warning is retracted (verified against `INFORMATION_SCHEMA.TABLES`, 2026-08-25).** Prefer
> the table; keep the pattern below for understanding how membership is decided and for re-deriving
> it on a different cutoff.
>
> **The deployed schema is not the pattern's output shape.** It is a plain (unpartitioned,
> unclustered) 5-column dimension:
>
> | Column | Type |
> |---|---|
> | `launch_date` | DATE |
> | `item_id` | INT64 |
> | `item_name` | STRING |
> | `item_grp_name` | STRING |
> | `rev_center_name` | STRING |
>
> `launch_date` is the first-appearance date the pattern computes as `min_date`. The pattern's
> `max_date` and `is_current_vto` **are not in the table** — a "is this VTO currently running?" test
> has to be derived at query time (`launch_date > current_date('America/Denver') - 91`, or a
> `max(business_date)` back on `order_lines`), not selected. Join on `item_id`; it is the grain.
> **The missing end date is now a measured cost (2026-09-09):** two analysts re-derived launch
> *and* end windows from `order_lines` on the same day (≥60%-of-active-stores "chainwide" test,
> 2 × 20 GiB over 2019→today; 180-day `min(business_date)` list) because the scorecard needs both
> edges of the campaign window and neither knew this table existed. Adding `end_date` here retires
> that scan (Asana 1218319740414409).
>
> Observed in use 2026-08-24 (analyst weekly scorecard): `join sales_ops.vto_items v on v.item_id =
> ol.item_id` to sum `item_gross_sales` for trailing-52-week and past-week VTO revenue. That is the
> intended use. See the join-pruning caution in the tenth-business-day notes below — the same query
> joined `order_lines` to `order_customer` on `brink_order_id` alone, with no `business_date`
> equality, and billed 10.71 GiB.

```sql
with items as (
	select
	ol.business_date
	, ol.item_id
	, ol.item_name
	, count(distinct ol.brink_order_id) as order_cnt
	from `marketing-data-442316`.claude.order_lines ol
	where 1=1
	and ol.business_date >= '2024-11-01'
	and ol.is_catering = false
	and ol.item_type = 'Entree'
	group by 1,2,3
	having count(distinct ol.brink_order_id) > 25
)
, vto_items as (
	select
	i.item_id
	, i.item_name
	, min(i.business_date) as min_date
	, max(i.business_date) as max_date
	, case when min(i.business_date) > current_date('America/Denver') - 91 then 1 else 0 end as is_current_vto
	from items i
	group by 1,2
	having min(i.business_date) > '2025-01-15'
)
select * from vto_items order by min_date desc
```

Four things in it are deliberate and worth reusing:

1. **First appearance is the discriminator.** `having min(business_date) > <cutoff>` where the
   cutoff sits comfortably after the history floor: an item whose first-ever line is *after* the
   window opened is a new or rotating item, whereas a core-menu item appears on day one. The
   cutoff must be later than the scan start (`2024-11-01` scan, `2025-01-15` cutoff) or every item
   qualifies.
2. **Group by `business_date` first, then roll up.** The inner CTE keeps the partition column in the
   `group by` so pruning still applies, and the outer CTE collapses to `min`/`max`. It looks
   redundant and isn't — flattening it into one `group by item_id` costs the same read but loses
   the per-day counts that make step 3 work.
3. **`having count(distinct brink_order_id) > 25` is a per-day noise floor**, not a popularity
   filter. It removes test SKUs, one-off POS mistakes and single-store experiments that would
   otherwise each present as a "new item" with a first-appearance date.
4. **Key on `item_id`, carry `item_name`.** Names get re-used and re-cased across rotations; the id
   is what makes "first seen" meaningful.

Scope notes: `item_type = 'Entree'` reflects that VTOs are entrees — widen it deliberately, and
remember `item_type` is the closed 7-value domain (menu categories live in `rev_center_name`).
`is_catering = false` keeps catering-only SKUs out. And `select *` on `order_lines` for this is
expensive — the steward's own `select *` variant billed **27.12 GiB** against **3.43 GiB** for the
column-projected equivalent over the same window.
