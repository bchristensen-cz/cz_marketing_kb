# Data Dictionary: `marketing-data-442316.claude.store_info`

**One row per store.** Authorized view over `sales_ops.store_info`, exposing the store
dimension to standard users. Build script: [`sql/claude.store_info.sql`](../sql/claude.store_info.sql).
Deployed 2026-07-30.

## Why it exists

`sales_ops.store_info` is the only source of store geography, and it was **not** exposed
in the `claude` interface layer. That made every "by market", "by state", or "by city"
question unanswerable for a standard user — the dimension simply wasn't reachable. Found
2026-07-30 while testing a real user question ("sales data by market for the following
items…"), which is worth noting: the gap was invisible until someone asked a perfectly
ordinary question.

The `claude` dataset is authorized on `sales_ops` at the **dataset** level
(`targetTypes: ["VIEWS"]`), so the view inherited access with no additional grant.

## Columns

Same as the [`sales_ops.store_info` dictionary](sales_ops.store_info.md), with two changes:

| Column | Type | Notes |
|---|---|---|
| `market` | STRING | **Added.** An explicit alias of `store_state`. "Market" is the word users say, so it's in the schema — the canonical mapping can't be got wrong |
| `store_tz` | — | **Dropped.** Ambiguous abbreviations (`MDT` vs `CT` mixes DST and standard forms). Use `timezone_name` (IANA) |

Everything else passes through unchanged: `store_id`, `store_name`, `store_short_name`,
`store_address`, `store_city`, `store_state`, `store_zip`, `store_open_date`,
`is_comp_store`, `latitude`, `longitude`, `weather_cluster_id`, `timezone_name`.

## Divergences from the `sales_ops` parent

**Three non-store rows are dropped** — `store_id` 0 (`Company`, every field blank, the
source of the nameless group in any geography breakdown), 901 (`Zupas Lab2`), and 9001
(`Zupas automation test`). All three carried zero orders. So this view is **96 rows**
against the parent's 99.

**Store 101 (Corporate) and 113 / 114 (mall kiosks) are kept** — real locations with real
addresses. They also carry zero orders, so `count(*)` here is still **not** the trading
store count.

## Gotchas

- **`count(*)` is not "how many stores do we have."** 96 rows includes corporate and two
  kiosks, plus stores that haven't opened yet (`store_open_date` is NULL on several live
  and pre-opening rows). For trading stores, count distinct `store_id` on
  `order_customer` over the window in question.
- **Store 1111 is absent** — it isn't in the parent table either. Convenient, but keep
  the explicit `store_id <> 1111` filter on the fact table: a `left join` still lets it
  through with a NULL market. See the note on `claude.order_customer` below.
- **`is_comp_store` is INTEGER**, not BOOL. Write `si.is_comp_store = 1`.
- **`store_city` splits `West Valley` and `West Valley City`** — the same metro, two values.

## You usually don't need to join this view

The market dimension is carried directly on both order views, but **under two different
names** — `claude.order_customer.state` and `claude.order_lines.store_state`. Check which
view you're on before writing the column. Either way, most market questions need no join:

```sql
select
  coalesce(ol.store_state, '(unmapped)') as market
, round(sum(ol.item_gross_sales), 0) as item_gross_sales
from `marketing-data-442316`.claude.order_lines ol
where 1=1
and ol.business_date between @start and @end
and ol.store_id <> 1111
and ol.line_item_type = 'item'
group by
  market
order by
  item_gross_sales desc
```

> **⚠️ The market column is NULL for stores 1111 and 999 on both order views** — this
> table has no row for either. Without `store_id <> 1111` a market breakdown grows a
> phantom tenth market: 1,154 orders and **$117,196** over 2026-05-03 → 2026-06-27,
> sitting in a NULL group that reads like a data problem rather than the test store.
> Always keep the filter, and `coalesce` the label so no group ships unnamed.
>
> Note `claude.order_customer` briefly carried a `store_state` column from a join to this
> table; it was removed 2026-07-30 after being verified to duplicate the pre-existing
> `state` column exactly (1,326,905 orders, zero disagreements). **`oc.store_state` does
> not exist — use `oc.state`.**

Reach for `claude.store_info` when you need the attributes that aren't denormalised onto
the order views — city, zip, address, open date, comp status, lat/long, timezone.
