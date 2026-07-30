# Data Dictionary: `marketing-data-442316.sales_ops.store_info`

**One row per store id.** The store dimension — location, geography, timezone, and comp
status. Join it to any order/line table on `store_id` to break results out by geography.

- **Grain:** one row per `store_id`. 99 rows, 99 distinct ids (verified 2026-07-30).
- **Size:** ~15 KB. No partition column; full scans are fine and the "always filter the
  partition" rule does not apply here. Filter the partition column on the table you join it to.
- **Documented:** 2026-07-30 (was an open backlog item).

## Columns

| Column | Type | Notes |
|---|---|---|
| `store_id` | INTEGER | Join key. Matches `order_customer.store_id` and `order_lines.store_id` |
| `store_name` | STRING | e.g. `Zupas Oconomowoc`. Includes non-store rows — see below |
| `store_address` | STRING | |
| `store_city` | STRING | ~70 distinct. `West Valley` and `West Valley City` are **separate values for the same metro** |
| `store_state` | STRING | Full state name (`Utah`, not `UT`). **This is "market"** — see below |
| `store_zip` | STRING | |
| `store_phone` | INTEGER | Stored as INTEGER, so a leading zero would be lost. Cast to STRING to display |
| `store_short_name` | STRING | |
| `store_tz` | STRING | Abbreviation (`MDT`, `CT`, …), 6 distinct. **Prefer `timezone_name`** — abbreviations mix DST and standard forms |
| `store_open_date` | DATE | 2004-10-01 → 2026-05-01. **NULL on 9 rows**, including several live stores (191, 192, 196, 197) — do not use it to build store-age cohorts without checking coverage |
| `is_comp_store` | INTEGER | 1 = comp store (77), 0 = not (22). **INTEGER, not BOOL** — write `si.is_comp_store = 1`, not `= true` |
| `latitude` | FLOAT | NULL on the non-store rows |
| `longitude` | FLOAT | |
| `weather_cluster_id` | INTEGER | 12 distinct. From `marketing_ops.zip_weather_cluster`, refreshed daily |
| `timezone_name` | STRING | IANA name (`America/Denver`, `America/Chicago`), 5 distinct. Use this one |

## "Market" means `store_state` (steward decision 2026-07-30)

There is **no `market`, `region`, `dma`, or `metro` column anywhere in `sales_ops`** —
verified against `INFORMATION_SCHEMA.COLUMNS`. When a user asks for anything "by market,"
group by `si.store_state` and **say in the answer that market = state**.

Footprint as of 2026-07-30, store 1111 excluded:

| `store_state` | Stores | Cities |
|---|---|---|
| Utah | 35 | 28 |
| Arizona | 17 | 9 |
| Minnesota | 12 | 11 |
| Nevada | 9 | 2 |
| Wisconsin | 8 | 7 |
| Idaho | 7 | 5 |
| Illinois | 6 | 6 |
| Ohio | 3 | 1 |
| Texas | 1 | 1 |
| *(blank)* | 1 | — |

Caveats to state when they matter: **Utah is over a third of the footprint** across 28
cities from Logan to St George, so a single "Utah" row hides most of the geographic
variation. `store_city` is finer but splits `West Valley` / `West Valley City`. A true
metro/DMA rollup is an open KB gap — don't invent one per-session.

## Gotchas

- **Column names are not the obvious ones.** It's `store_state`, not `state`; `store_city`,
  `store_zip`, `store_address`, `store_short_name`. Guessing `state` failed an analyst
  session 2026-07-24.
- **6 of the 99 rows are not stores** — `0` (`Company`, every field blank), `101`
  (`Zupas Corporate`), `113` / `114` (mall kiosks), `901` (`Zupas Lab2`), `9001`
  (`Zupas automation test`). **All six carried zero orders** over 2026-05-03 → 2026-06-27,
  so they don't pollute a joined result — but any store *count* or store *list* read
  straight off this table includes them. "How many stores do we have" is **not**
  `count(*)` = 99.
- **`store_id = 0` has a blank `store_state`.** It is the source of the nameless row in
  any `store_info`-driven geography breakdown. Exclude or label it; never ship an
  unnamed group.
- **Store 1111 is absent from this table.** So an **inner** `join` to `store_info`
  silently drops the test store. Convenient, but don't rely on it — keep the explicit
  `store_id <> 1111` filter, because a `left join` (or no join at all) will let it back in.
- **Only `1111` and `999` are missing** from `store_info` among stores with orders in
  2026-05-03 → 2026-06-27 (`999`: 1 order, $0). Every real trading store is present, so
  an inner join does not silently drop revenue.
- **`is_comp_store` is INTEGER.** `= true` fails with a type error, the same trap as the
  legacy `iscatering` column.
- **`store_open_date` is NULL on 9 rows**, four of them live stores. Check coverage before
  using it for new-store / mature-store splits.

## Join pattern

```sql
select
  si.store_state
, count(*) as orders
, round(sum(oc.net_sales), 2) as net_sales
from `marketing-data-442316`.sales_ops.order_customer oc
	join `marketing-data-442316`.sales_ops.store_info si
	on si.store_id = oc.store_id
where 1=1
and oc.business_date between @start and @end
and oc.store_id <> 1111
and si.store_state <> ''
group by
  si.store_state
order by
  net_sales desc
```
