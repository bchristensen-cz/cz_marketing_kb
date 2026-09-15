# Data Dictionary: `marketing-data-442316.sales_ops.store_info`

**One row per store id.** The store dimension: location, geography, timezone, comp status
and weather cluster. Join it to any order/line table on `store_id` to break results out by
geography.

- **Grain:** one row per `store_id`. **101 rows, 101 distinct ids** (verified 2026-09-15).
  Enforced by guard 7a, not by a primary key.
- **Size:** ~15 KB. No partition column; full scans are fine and the "always filter the
  partition" rule does not apply here. Filter the partition column on the table you join it to.
- **Source feed:** **`brink.gblStore`** (changed 2026-09-15, was `staging.store_info`).
- **Build script:** [`sql/sales_ops.store_info.sql`](../sql/sales_ops.store_info.sql),
  scheduled daily. Maintenance statements first, guards last.
- **Documented:** 2026-07-30. Rewritten 2026-09-15 for the `gblStore` source swap and the
  two newly derived columns.

## Columns

| Column | Type | Notes |
|---|---|---|
| `store_id` | INT64 | Join key. Matches `order_customer.store_id` and `order_lines.store_id` |
| `store_name` | STRING | e.g. `Zupas Oconomowoc`. **Insert-once.** Includes non-store rows, and two rows with no `Zupas ` prefix (`Company`, `Middleton Mobile`) |
| `store_address` | STRING | **Insert-once.** Feed values are dirty; see the address section |
| `store_city` | STRING | **Insert-once.** ~70 distinct. `West Valley` and `West Valley City` are **separate values for the same metro** |
| `store_state` | STRING | **Insert-once.** Full state name (`Utah`, not `UT`). **This is "market"**, see below |
| `store_zip` | STRING | **Insert-once**, and that is load-bearing: 5 feed zips are wrong today and the mart holds the corrected value. Keep it STRING, an INT64 zip eats leading zeros |
| `store_phone` | INT64 | Stored as INT64, so a leading zero would be lost. Cast to STRING to display. Fed but transformed, see below |
| `store_short_name` | STRING | `store_name` with a leading `Zupas ` stripped. **Derived since 2026-09-15** (step 6), is-null only |
| `store_tz` | STRING | Abbreviation (`MDT`, `CT`, ...), 6 distinct. **Prefer `timezone_name`**, abbreviations mix DST and standard forms |
| `store_open_date` | DATE | 2004-10-01 to 2026-08-14. **First business date with more than 150 orders**, not a lease or announcement date. NULL on 9 rows. Do not build store-age cohorts on it without checking coverage |
| `is_comp_store` | INT64 | 1 = comp (77), 0 = not (24). **INT64, not BOOL**: write `si.is_comp_store = 1`, never `= true`. **Derived from `store_open_date` since 2026-09-15**, no longer read from the feed |
| `store_comp_date` | DATE | **The date the store enters the comp base.** Always a January 1st. **Derived since 2026-09-15** (step 2), previously hand-maintained. See the comp section, this is the most-forked definition in the KB |
| `latitude` | FLOAT64 | **Human geocode. BigQuery cannot derive it.** NULL on 4 rows |
| `longitude` | FLOAT64 | Same. Guard 7d requires **both**, not just latitude |
| `weather_cluster_id` | INT64 | 12 distinct. Nearest centroid from `marketing_ops.zip_weather_cluster`, is-null only |
| `timezone_name` | STRING | IANA name (`America/Denver`, `America/Chicago`), 5 distinct. **Use this one.** Derived from `store_state` in step 4 |

## What the feed supplies, and what is derived (rewritten 2026-09-15)

**The source moved from `staging.store_info` to `brink.gblStore` on 2026-09-15.** The new feed
supplies **7 columns only**: `StoreId`, `Name`, `Address`, `City`, `State`, `Zipcode`,
`StorePhone`. `staging.store_info` still exists and is not dropped, but nothing reads it any
more; `staging.gblstore_test` was the migration scratch table.

**The feed lost a column in the swap.** `staging.store_info` supplied `is_comp_store`;
`brink.gblStore` has an `IsCompStore` column and the build **deliberately ignores it**. Comp
status is now computed here. This reverses a note recorded on 2026-09-10 that said the comp flag
"has a single upstream source and it is Brink's", so do not go looking for the flag upstream.

| Column | How it is filled | Self-healing? |
|---|---|---|
| `store_id`, `store_name`, `store_address`, `store_city`, `store_state`, `store_zip` | fed, **insert-once** | n/a, never restated |
| `store_phone` | fed, but non-digits stripped before the INT64 cast | n/a |
| `store_open_date` | first business date with >150 orders (step 3) | yes, is-null only |
| `store_comp_date`, `is_comp_store` | derived from `store_open_date` (step 2) | yes, restated whenever it changes |
| `timezone_name`, `store_tz` | `store_state` to IANA map (step 4) | yes, is-null only |
| `weather_cluster_id` | nearest cluster centroid (step 5) | yes, is-null only |
| `store_short_name` | `Zupas ` prefix stripped from `store_name` (step 6) | yes, is-null only |
| `latitude`, `longitude` | **human geocode, no warehouse source** | no, guard 7d prompts a human |

`store_phone` is fed but **transformed**: the feed holds it formatted (`801-613-3380`) and the
column is INT64, so the insert strips non-digits before casting. A bare
`safe_cast(store_phone as int64)` returns NULL on that format. Measured 2026-08-20, it would
have blanked the phone on **82 of 100** feed rows while leaving every older row intact. Same
failure signature as the timezone hole: correct on history, NULL on everything new, no error.

**The general rule this table teaches: a derived column absent from the build script is a column
that is NULL forever on every new store.** That is how `timezone_name` went missing on six
stores and silently NULLed `order_timestamp_utc`, and how `store_short_name` went missing on
seven.

## ⚠️ Comp store: the rule is now known, derived, and reproducible (2026-09-15)

**The rule.** A store enters the comp base on the **first day of the year following 18 months of
trading**, counted from `store_open_date`:

```sql
date_add(last_day(date_add(store_open_date, interval 18 month), year), interval 1 day)
```

`is_comp_store` is then simply whether that date has arrived. Verified 2026-09-15 across all
**101 rows: zero mismatches** on `store_comp_date` and zero on `is_comp_store`. The formula
reproduces the stored values exactly, including all 77 comp stores.

Worked examples:

| store | name | opened | +18 months | `store_comp_date` |
|---|---|---|---|---|
| 50 | Middleton Mobile | 2024-08-16 | 2026-02-16 | 2027-01-01 |
| 191 | Zupas San Tan Village | 2026-08-14 | 2028-02-14 | 2029-01-01 |

**This corrects what this dictionary said on 2026-09-14.** The earlier note concluded that comp
entry was "a finance-calendar decision, not a tenure rule" and that no offset could reproduce
it. Half of that was right and half was wrong: it **is** a tenure rule (18 months), but it is
snapped forward to the start of the next fiscal year, which is why every value is a January 1st
and why a store that opened 2024-08-08 does not comp until **2027-01-01**, nearly two and a half
years later. A *plain* offset still cannot reproduce it, so the practical guidance below is
unchanged. What is new is that the rule is written down and enforced by the build.

This also closes a loose end from 2026-09-10, when the steward was seen probing
`date_add(last_day(date_add(current_date(), interval 18 month), year), interval 1 day)` in the
console with no stated intent, and the KB correctly declined to infer a rule from its
arithmetic. That arithmetic is this rule.

**Rules for answering:**

- "Comp" as of today is **`is_comp_store = 1`**. Still the canonical answer and the one to quote.
  State it in the answer: "comp stores only (`is_comp_store = 1`), 77 stores".
- A **historical or point-in-time** comp base ("what was comp in FY25?") is
  **`store_comp_date <= <window start>`**. This is now safe to use: the column is derived and
  restated by the build rather than hand-maintained. `is_comp_store` is a property of *today* and
  will silently apply today's 77 stores to a 2025 window, so say which of the two you used.
- Never `store_open_date <= <cutoff>`. Never "traded in both windows". Both are different
  questions; if that is what someone wants, name it that way and never call it comp.

**The open-date proxy, and what it costs.** Six variants have been observed in the query log
(2026-08-25, 09-03, 09-05, 09-08, 09-09, 09-14): the canonical flag, a hand-typed 77-id
`in (...)` list, "traded in both windows", `having count(distinct business_date) = 6`,
`store_open_date <= date_sub(launch, interval 365 day)`, and `store_open_date <= '2025-06-14'`.
Only the first is comp. The sixth returned **81 stores against the canonical 77**:

| store | name | state | opened | `store_comp_date` | TY net (06-03 to 09-08) | LY net |
|---|---|---|---|---|---|---|
| 185 | Zupas Brookfield | Wisconsin | 2024-12-19 | 2027-01-01 | $859,421 | $806,334 |
| 183 | Zupas Burnsville | Minnesota | 2024-08-16 | 2027-01-01 | $825,315 | $830,954 |
| 182 | Zupas Prasada | Arizona | 2024-08-08 | 2027-01-01 | $512,058 | $546,093 |
| 184 | Zupas Surprise | Arizona | 2024-12-26 | 2027-01-01 | $413,842 | $455,947 |

**$2,610,636 TY / $2,639,328 LY of non-comp sales inside a "comp" number**, and because the four
are collectively down ~1.1% they drag the result rather than washing out. The same session used a
second cutoff (`<= '2025-06-03'`) in other queries, so two comp bases were live inside one
analysis. Asana 1217879256348882.

**`store_comp_date` is still not exposed on `claude.store_info`**, so a standard user cannot see
it. The comp-ish columns they get are `is_comp_store` and `store_open_date`, which is a large
part of why analysts reach for the open-date proxy. Exposing it is now a much smaller ask than it
was, because the column is derived rather than hand-kept.

### ⚠️ Two things to know about the derivation before you rely on it

**1. Comp status inherits everything wrong with `store_open_date`.** The chain is
order volume, then open date, then comp date, then comp flag. `store_open_date` is the first day
a store cleared **150 orders**, which is a traffic threshold, not an opening. If a store has a
slow soft-open week, its open date lands later, and its comp date moves with it. A store with a
NULL open date gets a NULL comp date and `is_comp_store = 0`, which is why Corporate 101, the two
kiosks and pre-opening Tooele all read as non-comp.

**2. Step 2 uses `current_date()` with no timezone, everywhere else uses `America/Denver`.**
`current_date()` is UTC, so on December 31 the comp flag flips about **7 hours early**, at
17:00 MT. The comp base a query returns on the evening of December 31 is next year's. Cosmetic on
any other day of the year, and worth a one-word fix (`current_date('America/Denver')`) the next
time the script is touched.

**3. A brand-new store picks up its comp date on the second run.** Step 2 reads
`store_open_date`, which step 3 sets *after* it. Harmless in practice since comp dates land about
2.5 years out, but it means a store inserted tonight has a NULL comp date until tomorrow.

## The guards (rewritten 2026-09-15: three became four)

All four `assert`s run **last, deliberately**, so a failing guard marks the scheduled run failed
without preventing the maintenance statements above it from completing. **A script stops at the
first failing assert**, so fix 7a before trusting 7b to 7d.

The guards share one `trading_stores` temp table: stores that took an order in the **last 7
days**, excluding non-store ids 0, 901 and 9001. That is the single definition of "a store we
care about", it scans `order_customer` once for the whole section instead of three times, and the
exclusion list lives in one place.

| Guard | Checks | Auto-repairable? |
|---|---|---|
| **7a** | **no duplicate `store_id`** (new) | no, needs a human de-dup |
| 7b | a trading store has a `timezone_name` | yes, add its state to the step-4 map |
| 7c | a trading store has a `weather_cluster_id` | yes, usually a zip that does not resolve |
| 7d | a trading store has **both** `latitude` and `longitude` | **no**, human geocode |

**Why 7a is new and why it matters.** BigQuery has no primary keys, and **step 1 has no `distinct`
or `group by`**: it anti-joins the feed against the mart on `store_id`, so two feed rows for the
same new `StoreId` become **two mart rows**. One duplicated store silently doubles every metric
joined to it, and a broken grain makes the other three guards untrustworthy, which is why it is
checked first. The feed is clean today: **100 distinct ids, zero duplicates** (verified
2026-09-15).

**7d now requires both coordinates.** The old version checked `latitude` only, which let a
half-geocoded store through and quietly sent step 5 to the ZIP centroid for it.

**Status as of 2026-09-15: all four guards pass.** Only 4 of 101 rows carry any NULL in a guarded
column, and **none of them is trading**: `0` Company (blank state, so no timezone), `199` Zupas
Tooele (no geocode, pre-opening), `901` Zupas Lab2 and `9001` Zupas automation test.

> **⏭️ The one guard failure to expect: store 199 Zupas Tooele.** It has a timezone and a cluster
> but no `latitude`/`longitude`, and it is pre-opening with zero orders. **The day Tooele starts
> trading, guard 7d fails the run every night until someone geocodes it.** It is not geocodable
> today: its address has no street number (`West 1000th North`) and no location resolves on Google
> Maps. Get a real address from ops before opening, not after.

## ⚠️ The feed's zips are wrong on 5 stores, and insert-once is what protects you

`store_zip` is insert-once, and today that is the only reason the mart is right. Comparing
`brink.gblStore.Zipcode` against the mart and against `bigquery-public-data` (2026-09-15):

| store | name | feed zip | feed zip really is | mart zip today |
|---|---|---|---|---|
| 157 | Zupas Ogden | 84407 | does not resolve | 84404 |
| 158 | Zupas Centennial | 80161 | does not resolve (Colorado range) | 89149 |
| 159 | Zupas Vernon Hills | *(NULL)* | | 60061 |
| 160 | Zupas Deerfield | 84070 | **Sandy, Utah** | 60015 |
| 163 | Zupas Millcreek | 44109 | **Cleveland, Ohio** | 84109 |

**Why this is more than untidiness.** Step 5 derives the weather cluster from the ZIP centroid
whenever a store has no geocode. A wrong-but-valid zip resolves to a real centroid in the wrong
state, so an Illinois store would be assigned a Utah weather cluster, and **guard 7c would pass**,
because it only checks for NULL. Existing stores are safe (their zips were corrected and are never
restated), but **a new store inherits the dirty zip from the feed** and there is no guard that can
catch a plausible wrong answer.

Practical consequence: when a new store appears, **geocode it before trusting its weather
cluster**, and sanity-check that `store_zip` resolves to the same state as `store_state`.

## Build behaviours that are not obvious from reading the SQL

- **`store_name`, `store_address`, `store_city`, `store_state`, `store_zip` are insert-once.**
  Nothing re-syncs them, which is what makes the 2026-08-20 cleanup stick: 8 normalised addresses
  and the store 191 rename. **The feed is still dirty**, so adding an address sync would overwrite
  the corrections. `is_comp_store` used to be the one column kept in sync with the feed; it is now
  derived instead, so **no column is synced from the feed after insert**.
- **The `store_open_date` statement is bounded to 400 days** (1.14 GiB to 0.21 GiB per run,
  dry-run measured 2026-08-20). Safe because a store missing an open date is by definition new: of
  the NULLs on that date, only store 192 had any orders in 400 days (12 orders, max 11/day), and
  Corporate 101 plus kiosks 113/114 had zero, so the >150 threshold can never fire for them.
  **If a long-open store ever appears with a NULL open date, this bound would stamp it with the
  window edge instead of its real first day.** Re-check before widening.
- **`row_number()` is evaluated after `having`**, so `rn = 1` is the first date that *cleared* the
  150-order threshold, not the first date the store appears in `order_customer`. Verified
  2026-09-10.
- **Split-timezone states are deliberately absent from the step-4 map.** Northern Idaho is
  Pacific, El Paso is Mountain, and Oregon, the Dakotas, Kansas, Nebraska, Florida, Michigan,
  Indiana, Kentucky and Tennessee are all split. A store in one of those stays NULL and trips
  guard 7b rather than being guessed an hour wrong: a wrong-but-populated timezone is worse than a
  NULL, because `order_timestamp_utc` then looks fine. Verified 2026-09-10 that the current estate
  is safe at state level (all 7 Idaho stores are southern; the single Texas store is McKinney/DFW).
- **The feed's `State` is a full state name** (`Utah`, `Arizona`), which is what the step-4 map
  joins on, so the source swap did not break the timezone derivation. Confirmed 2026-09-15. One
  feed row has a NULL state: store 0 `Company`.
- **Step 5 builds its point from ONE source.** The store's own geocode when it has *both*
  coordinates, otherwise the ZIP centroid. The previous version coalesced latitude and longitude
  independently, which could pair a real latitude with a ZIP longitude. Re-verified 2026-09-10:
  the single-source form reproduces 96 of 98 assignments, the only 2 misses being the cluster-12
  holders below.
- **Cluster 12 (`Unassigned (53005)`) is excluded as a candidate in step 5.** It is a hand-made
  cluster of one at Brookfield WI whose centroid sits inside the Milwaukee suburbs, so
  nearest-centroid pulls its neighbours in: Menomonee Falls is 10.3 mi from it vs 55.7 mi from its
  real cluster, Greenfield 7.4 vs 39.9. Remove the exclusion once 53005 is folded into cluster 4
  (Asana 1217699704979785).
- **Known weakness of the cluster derivation:** cluster 4 spans Illinois *and* Wisconsin, so its
  centroid sits near Chicago and nothing in Milwaukee's outskirts is close to it. Stores 185 and
  194 keep their hand-assigned cluster 12 only because step 5 is is-null only; 194 Oconomowoc
  would derive to cluster 8 `Madison` at 47.9 mi. A future Milwaukee-area store **will** auto-land
  in Madison until that corridor cluster is split.
- **`store_short_name` is derived, not fed.** `gblStore`'s own short columns do not match the
  convention: `ShortStoreName` carries state suffixes and abbreviations (`Lake Mead, NV`,
  `Corporate Offc`), `ShortName` is camelCase-prefixed (`zupRidgedale`). The strip-`Zupas `-prefix
  rule reproduces all 94 existing values exactly, 0 misses (verified 2026-09-10). The `nullif`
  guards a store named exactly `Zupas`, which would otherwise be written as an empty string.

> **📋 Deploy status, 2026-09-15.** The `gblStore` version of this script had **not yet run** as of
> this writing: no job in the last 7 days reads `brink.gblStore` in an `INSERT`/`UPDATE`/`SCRIPT`
> statement. The previous `staging.store_info` build **last ran 2026-09-11** (89 jobs over 30 days,
> zero failures) and has not run since, so **the store dimension has had no scheduled maintenance
> for several days**. Nothing is currently broken by that: the feed has **0 stores to insert**
> tonight and every derived column is populated on every trading store. Verify the first run lands,
> and remember that repo and deployed text drift in both directions, so read the job text rather
> than the table.

> **✅ RESOLVED 2026-08-20: the `timezone_name` hole, and what it cost.** Six stores (191, 192,
> 196, 197, 198, 199) had no `timezone_name`, and both order marts build
> `order_timestamp_utc = timestamp(order_datetime, s.timezone_name)`. BigQuery's `timestamp()`
> returns **NULL** on a NULL timezone rather than erroring, so a store with no timezone had no UTC
> order timestamp, failed every inequality against a Braze (UTC) event, and **disappeared from
> results instead of raising**. Over 2026-08-01 to 08-16 that was **8,230 orders** (197 Rexburg
> 6,330 from 08-03; 191 San Tan Village 1,895 from 08-11). Fixed by the step-4 state map plus what
> is now guard 7b. Asana 1217684772713570.
>
> **⚠️ The fix is not retroactive.** `order_timestamp_utc` is materialized in the order marts, so
> historical rows stay NULL until a reload passes over their `business_date`. The daily run
> restates only the last **8 days**, so after populating a timezone, either force a reload of the
> affected dates or expect the gap to persist for up to a week. Re-check
> `countif(order_timestamp_utc is null)` rather than assuming the dimension fix propagated.

> **⚠️ `latitude` / `longitude` are hand-maintained and there is no source for them in the
> warehouse** (2026-08-20). The feed has no coordinate column, and the `zip_weather_cluster`
> centroid is up to **1.043 degrees (~70 miles)** from the real store, so it is not a substitute.
> Ten stores were geocoded on 2026-08-20 from Google Maps exact address matches, each verified to
> land **0.3 to 2.7 miles** from its own ZIP centroid in the correct state.
>
> **Method, and the confidence signal that matters:** search the bare street address (dropping the
> brand name, since "Cafe Zupas" *prevented* a match on store 191) and read the coordinates from
> the resolved URL. A `/maps/place/` URL is an exact address pin; a `/maps/search/` URL is a
> viewport fallback and its coordinates are **not** the store. That distinction caught both
> failures: store 191's mangled address, and store 199 Tooele, where no location exists on Maps at
> all. **Never write coordinates from a `/maps/search/` result.**

> **⚠️ Address quality is poor and it originates upstream in the feed.** Eight addresses were
> normalised on 2026-08-20 (191, 192, 193, 194, 196, 197, 198, 199): they embedded city/state/ZIP
> in the street field, or were POS-abbreviated (`SN TN VLLY 2910 S SAN TAN VILLAGE PK`). The feed
> still carries these shapes today, for example
> `1686 Old Schoolhouse Rd, Oconomowoc WI 53006` with the wrong ZIP inside the street string while
> `store_zip` correctly says 53066. **The fixes were applied to `sales_ops` only**, and the script
> never updates `store_address` after insert, so the fixes stick but the source does not improve.
>
> Two city mismatches are **known and unresolved**: store **193** Zupas McKinney has
> `store_city = 'Dallas'` while its address and geocode are in McKinney (~30 mi north), and store
> **109** Zupas Orem carries `store_zip = 84088`, which is West Jordan, not Orem.

> **Store 191 was renamed 2026-08-20**, `Zupas San Tan Valley` to **`Zupas San Tan Village`**
> (steward confirmed: it is the San Tan Village mall in Gilbert, not the town of San Tan Valley
> ~20 miles southeast). `store_name` is denormalised onto `order_customer` and `order_lines`, so
> order rows carry the old name until a reload restates their `business_date`.

## "Market" means `store_state` (steward decision 2026-07-30)

There is **no `market`, `region`, `dma`, or `metro` column anywhere in `sales_ops`**, verified
against `INFORMATION_SCHEMA.COLUMNS`. When a user asks for anything "by market," group by
`si.store_state` and **say in the answer that market = state**.

Footprint as of **2026-09-15** (all 101 rows; "trading" = took an order in the last 7 days):

| `store_state` | Stores | Cities | Comp | Trading (7d) |
|---|---|---|---|---|
| Utah | 36 | 29 | 30 | 30 |
| Arizona | 18 | 9 | 11 | 16 |
| Minnesota | 12 | 11 | 10 | 12 |
| Nevada | 9 | 2 | 8 | 9 |
| Wisconsin | 8 | 7 | 5 | 7 |
| Idaho | 7 | 5 | 5 | 7 |
| Illinois | 6 | 6 | 6 | 6 |
| Ohio | 3 | 1 | 2 | 3 |
| Texas | 1 | 1 | 0 | 1 |
| *(blank)* | 1 | 1 | 0 | 0 |
| **Total** | **101** | | **77** | **91** |

Caveats to state when they matter: **Utah is over a third of the footprint** across 29 cities
from Logan to St George, so a single "Utah" row hides most of the geographic variation.
`store_city` is finer but splits `West Valley` / `West Valley City`. A true metro/DMA rollup is an
open KB gap; do not invent one per-session.

## Gotchas

- **Column names are not the obvious ones.** It is `store_state`, not `state`; `store_city`,
  `store_zip`, `store_address`, `store_short_name`. Guessing `state` failed an analyst session
  2026-07-24.
- **`count(*)` is not "how many stores do we have."** 101 rows includes non-store rows, corporate,
  two kiosks and pre-opening stores. **91 stores traded in the last 7 days**; for a store count,
  count distinct `store_id` on `order_customer` over the window in question.
- **6 rows are not stores**: `0` (`Company`, every field blank), `101` (`Zupas Corporate`),
  `113` / `114` (mall kiosks), `901` (`Zupas Lab2`), `9001` (`Zupas automation test`). All six
  carry zero orders, so they do not pollute a joined result, but any store *count* or *list* read
  straight off this table includes them.
- **`store_id = 0` has a blank `store_state`.** It is the source of the nameless row in any
  `store_info`-driven geography breakdown. Exclude or label it; never ship an unnamed group.
- **Store 50 is `Middleton Mobile`, a mobile unit, not a restaurant.** It is the one row besides
  `Company` whose `store_name` has no `Zupas ` prefix, so its `store_short_name` is the full
  `Middleton Mobile`. It opened 2024-08-16, is **not comp** (`store_comp_date` 2027-01-01) and took
  **zero orders in the last 7 days**. It also drives the catering definition on `order_lines`, so
  it turns up in analyst SQL as a bare `store_id <> 50` exclusion. That exclusion is not a comp
  filter and does not make a comp base: store 50 is already outside `is_comp_store = 1`.
- **Store 1111 is absent from this table**, so an **inner** join silently drops the test store.
  Convenient, but keep the explicit `store_id <> 1111` filter, because a `left join` (or no join)
  lets it back in. Store `999` is likewise absent.
- **`is_comp_store` is INT64.** `= true` fails with a type error, the same trap as the legacy
  `iscatering` column.
- **`store_open_date` is NULL on 9 rows**, and it is a *first busy day*, not an opening. Check
  coverage before using it for new-store / mature-store splits, and never use it as a comp proxy.
- **`store_comp_date` is NULL wherever `store_open_date` is NULL.** A point-in-time comp filter
  therefore excludes those rows silently, which is correct (they are not comp) but worth stating.
- **9001 is in the mart but no longer in the feed.** The feed has 100 distinct ids, the mart 101.
  Rows are never deleted, so a retired store stays here forever.

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
and oc.store_id not in (1111, 999)
and si.store_state <> ''
group by
  si.store_state
order by
  net_sales desc
```

Comp-store YoY, the canonical form:

```sql
select
  oc.business_date
, count(*) as orders
, round(sum(oc.net_sales), 2) as net_sales
from `marketing-data-442316`.sales_ops.order_customer oc
	join `marketing-data-442316`.sales_ops.store_info si
	on si.store_id = oc.store_id
	and si.is_comp_store = 1
where 1=1
and oc.business_date between @start and @end
and oc.store_id not in (1111, 999)
group by
  oc.business_date
order by
  oc.business_date
```

Point-in-time comp base, when the question is historical:

```sql
	and si.store_comp_date <= @window_start   -- instead of is_comp_store = 1
```
