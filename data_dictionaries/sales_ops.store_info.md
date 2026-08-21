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
| `store_open_date` | DATE | 2004-10-01 → 2026-08-14. NULL on the non-store rows, on Corporate / the two kiosks, and on any store that has not yet had a >150-order day (step 3 of the build). Do not use it to build store-age cohorts without checking coverage — and note it is a *first busy day*, not a lease or announcement date |
| `is_comp_store` | INTEGER | 1 = comp store (77), 0 = not (22). **INTEGER, not BOOL** — write `si.is_comp_store = 1`, not `= true` |
| `latitude` | FLOAT | NULL on the non-store rows |
| `longitude` | FLOAT | |
| `weather_cluster_id` | INTEGER | 12 distinct. From `marketing_ops.zip_weather_cluster`, refreshed daily |
| `timezone_name` | STRING | IANA name (`America/Denver`, `America/Chicago`), 5 distinct. Use this one. Derived from `store_state` in step 4 of the build; **0 NULLs as of 2026-08-20** |

## Which columns are derived, and which the feed supplies (added 2026-08-20)

`staging.store_info` carries **only 8 columns** — `store_id`, `store_name`, `store_address`,
`store_city`, `store_state`, `store_zip`, `store_phone`, `is_comp_store`. Everything else on
this table is derived in [`sql/sales_ops.store_info.sql`](../sql/sales_ops.store_info.sql):

| Column | How it's filled | Self-healing? |
|---|---|---|
| `store_open_date` | first business date with >150 orders | ✅ yes, is-null only |
| `timezone_name`, `store_tz` | `store_state` → IANA map, step 4 | ✅ yes, is-null only |
| `weather_cluster_id` | nearest metro cluster centroid, step 5 | ✅ yes, is-null only |
| `latitude`, `longitude` | **human geocode — BigQuery cannot derive it** | ❌ no |

`store_phone` is fed, but **transformed**: staging holds it formatted (`801-613-3380`) and the
column is INT64, so the INSERT strips non-digits before casting. A bare
`safe_cast(store_phone as int64)` returns NULL on that format — measured 2026-08-20, it would
have blanked the phone on **82 of 100** staging rows while leaving every older row intact. Same
failure signature as the timezone hole: correct on history, NULL on everything new, no error.

**The general rule this table teaches: a derived column absent from the build script is a
column that is NULL forever on every new store.** That is exactly how `timezone_name` went
missing on six stores and silently NULLed `order_timestamp_utc`.

### Build behaviours that aren't obvious from reading the SQL

- **`store_name`, `store_address`, `store_city`, `store_state`, `store_zip` are insert-once.**
  Nothing re-syncs them from staging, which is what makes the 2026-08-20 cleanup stick — 8
  normalised addresses and the store 191 rename. **The staging feed is still dirty**, so adding
  an address sync would overwrite the corrections. Only `is_comp_store` is kept in sync.
- **Guards run last, deliberately.** A failing `assert` marks the scheduled run failed but must
  not prevent the maintenance statements from completing, so all three sit at the end.
- **The `store_open_date` statement is bounded to 400 days** (1.14 GiB → 0.21 GiB per run,
  dry-run measured 2026-08-20). Safe because a store missing an open date is by definition new:
  of the 10 NULLs on that date, only store 192 had any orders in 400 days (12 orders, max
  11/day), and Corporate 101 plus kiosks 113/114 had zero, so the >150-order threshold can never
  fire for them. **If a long-open store ever appears with a NULL open date, this bound would
  stamp it with the window edge instead of its real first day** — re-check before widening.
- **Split-timezone states are deliberately absent from the step-4 map.** North Idaho is Pacific,
  El Paso is Mountain, and Oregon, the Dakotas, Kansas, Nebraska, Florida, Michigan, Indiana,
  Kentucky and Tennessee are all split. A store in one of those stays NULL and trips the guard
  rather than being guessed an hour wrong — a wrong-but-populated timezone is worse than a NULL,
  because `order_timestamp_utc` then looks fine.
- **Cluster 12 (`Unassigned (53005)`) is excluded as a candidate in step 5.** It is a hand-made
  cluster of one at Brookfield WI whose centroid sits inside the Milwaukee suburbs, so
  nearest-centroid pulls its neighbours in: Menomonee Falls is 10.3 mi from it vs 55.7 mi from
  its real cluster, Greenfield 7.4 vs 39.9. With the exclusion, the derivation reproduces **87 of
  87** existing assignments. Remove the exclusion once 53005 is folded into cluster 4
  (Asana 1217699704979785).
- **Known weakness of the cluster derivation:** cluster 4 spans Illinois *and* Wisconsin, so its
  centroid sits near Chicago and nothing in Milwaukee's outskirts is close to it. Store 194
  Oconomowoc would derive to cluster 8 `Madison` at 47.9 mi; it keeps its hand-assigned cluster 4
  only because step 5 is is-null-only. A future Milwaukee-area store **will** auto-land in Madison
  until that corridor cluster is split.

> **✅ RESOLVED 2026-08-20 — the `timezone_name` hole, and what it cost.** Six stores (191, 192,
> 196, 197, 198, 199) had no `timezone_name`, and both order marts build
> `order_timestamp_utc = timestamp(order_datetime, s.timezone_name)` — BigQuery's `timestamp()`
> returns **NULL** on a NULL timezone rather than erroring. A store with no timezone therefore
> had no UTC order timestamp, failed every inequality against a Braze (UTC) event, and
> **disappeared from results instead of raising**. Over 2026-08-01 → 08-16 that was **8,230
> orders** (197 Rexburg 6,330 from 08-03; 191 San Tan Village 1,895 from 08-11).
>
> Fixed by the step-4 state map plus the step-6a assert. Asana 1217684772713570.
>
> **⚠️ The fix is not retroactive.** `order_timestamp_utc` is materialized in the order marts,
> so historical rows stay NULL until a reload passes over their `business_date`. The daily 4am
> run restates only the last **8 days**, so Rexburg's 08-05 → 08-11 orders keep a NULL UTC
> timestamp until the Monday 5-week reload (or the 1st-of-month 380-day reload). **After
> populating a timezone, either force a reload of the affected dates or expect the gap to
> persist for up to a week** — and re-check `countif(order_timestamp_utc is null)` rather than
> assuming the dimension fix propagated.

> **⚠️ `latitude` / `longitude` are hand-maintained and there is no source for them in the
> warehouse** (2026-08-20). `staging.store_info` has no coordinate column, and the
> `zip_weather_cluster` centroid is up to **1.043° (~70 miles)** from the real store — not a
> substitute. Ten stores were geocoded on 2026-08-20 from Google Maps exact address matches,
> each verified to land **0.3–2.7 miles** from its own ZIP centroid in the correct state.
>
> **Method, and the confidence signal that matters:** search the bare street address (dropping
> the brand name — "Cafe Zupas" *prevented* a match on store 191) and read the coordinates from
> the resolved URL. A `/maps/place/` URL is an exact address pin; a `/maps/search/` URL is a
> viewport fallback and its coordinates are **not** the store. That distinction caught both
> failures: store 191's mangled address, and store 199 Tooele, where no location exists on Maps
> at all. Never write coordinates from a `/maps/search/` result.
>
> **Outstanding: store 199 Tooele.** Its address has no street number (`West 1000th North`) and
> the store is pre-opening (no orders, no `store_open_date`), so it is not geocodable until ops
> supplies a real address. It is the only NULL of the 98 real stores.

> **⚠️ Address quality is poor and it originates upstream in `staging.store_info`.** Eight
> addresses were normalised on 2026-08-20 (191, 192, 193, 194, 196, 197, 198, 199) — they
> embedded city/state/ZIP in the street field, or were POS-abbreviated
> (`SN TN VLLY 2910 S SAN TAN VILLAGE PK`). Two carried wrong data: store 194's address said ZIP
> **53006** (Ashippun) while `store_zip` said 53066 (Oconomowoc, confirmed correct by the
> geocode). **These fixes were applied to `sales_ops` only — the staging feed is still dirty**,
> and the daily script never updates `store_name` or `store_address` after insert, so the fixes
> stick but the underlying source does not improve.
>
> Two city mismatches are **known and unresolved**: store **193** Zupas McKinney has
> `store_city = 'Dallas'` while its address and geocode are in McKinney (~30 mi north), and
> store **109** Zupas Orem carries `store_zip = 84088`, which is West Jordan, not Orem.

> **Store 191 was renamed 2026-08-20**, `Zupas San Tan Valley` → **`Zupas San Tan Village`**
> (steward confirmed: it is the San Tan Village mall in Gilbert, not the town of San Tan Valley
> ~20 miles southeast). `store_name` is denormalised onto `order_customer` and `order_lines`, so
> order rows carry the old name until a reload restates their `business_date` — the store opened
> 2026-08-14, inside the 8-day window, so the daily 4am run clears it.

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
