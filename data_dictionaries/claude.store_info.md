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
| `market` | STRING | **Added.** An explicit alias of `store_state`. "Market" is the word users say, so it's in the schema — the canonical mapping can't be got wrong. **Values are full state names (`Arizona`, `Utah`, `Texas`…), not postal codes** — `store_state = 'AZ'` returns zero rows and reads as "no Arizona stores" (observed 2026-09-01; the correct literal is `'Arizona'`). Resolve the value against the data or use `like 'Ariz%'` when unsure |
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

### ⚠️ "Comp store" has two competing definitions — pick `is_comp_store` and say so (2026-08-26)

Observed in one analyst's queries **on a single day** (2026-08-25), used interchangeably for
year-over-year work:

1. **`si.is_comp_store = 1`** — the maintained flag, synced from the store master. This is the
   canonical comp base. It is a **property of the store**, not of the comparison window.
2. **A hand-rolled "active last year" base** — `select distinct store_id from order_customer
   where business_date between <LY window>`, then `join ly_active using(store_id)`. This is a
   *different set*: it includes any store that transacted in that particular LY window
   (including stores the business does not treat as comp), and it silently **changes with the
   window** you happen to pick.

They will not return the same YoY number, and neither query says which one it used — the
same-question-different-answer failure this KB exists to prevent.

**Rule: for any comp / YoY / "same-store" question, use `is_comp_store = 1` and state
"comp stores only (`is_comp_store = 1`), N stores" in the answer.** If someone genuinely
wants "stores trading in both windows" — a valid but different question — name it that,
never "comp".

**Six variants have now been observed in the log** (2026-08-25, 09-03, 09-05, 09-08, 09-09,
09-14): the canonical flag, a hand-typed 77-id `in (...)` list, "traded in both windows",
`having count(distinct business_date) = 6`, `store_open_date <= date_sub(launch, interval 365
day)`, and `store_open_date <= '2025-06-14'`. Only the first is comp.

> **Why the open-date proxies keep coming back, answered 2026-09-15.** `sales_ops.store_info`
> carries a **`store_comp_date`** column that is exactly `is_comp_store` expressed as a date
> (77 comp stores all past-dated, 21 non-comp all future-dated, zero disagreements). Every value
> is a **January 1st** — comp entry is a finance-calendar decision, *not* store tenure. A store
> opened 2024-08-08 comps on **2027-01-01**. So no "open at least N months" cutoff can ever
> reproduce the comp base, and writing a longer offset does not help. The 2026-09-14 variant
> (`store_open_date <= '2025-06-14'`) returned **81 stores, not 77**, putting **$2.61M TY /
> $2.64M LY** of non-comp sales into a comp number — and since those four stores are down ~1.1%,
> the error drags the result rather than washing out. Full numbers and the per-store table are in
> [`sales_ops.store_info.md`](sales_ops.store_info.md).
>
> **`store_comp_date` is deliberately NOT on this view**, and it is hand-maintained upstream with
> no sync or guard, so do not ask for it to be added casually. If a question genuinely needs a
> *point-in-time* comp base ("what was comp in FY25?"), that is a steward request — say so rather
> than approximating it from `store_open_date` (Asana 1217879256348882).

> Routing note: this view already carries `is_comp_store`, `weather_cluster_id`, `market`,
> lat/long and `timezone_name`. There is **no reason to reach into `sales_ops.store_info`**
> for a comp-store or geography question. Joining the `sales_ops` copy was the single most
> common routing violation in the 2026-08-25 log.

## You usually don't need to join this view

The market dimension is carried directly on both order views as **`store_state`** — the
same name on every table since 2026-07-30. Most market questions need no join at all:

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

> **⚠️ The market column is NULL for stores 1111 and 999 on the `sales_ops` order tables** — this
> table has no row for either. Without `store_id not in (1111, 999)` a `sales_ops` market breakdown
> grows a phantom tenth market: 1,154 orders and **$117,196** over 2026-05-03 → 2026-06-27,
> sitting in a NULL group that reads like a data problem rather than the test store.
> On `sales_ops`, always keep the filter and `coalesce` the label so no group ships unnamed.
> On the `claude` order views the filter is built in — don't add it (steward rule 2026-09-03).
>
> Naming history, because it churned in a single day: `order_customer` originally carried
> the state as **`state`**; a join briefly added a duplicate `store_state`; the join was
> removed once the two were verified identical (1,326,905 orders, zero disagreements); then
> the base column itself was renamed to **`store_state`** for consistency with `order_lines`
> and this table. **The settled answer is `store_state` everywhere. `oc.state` no longer
> exists.**

Reach for `claude.store_info` when you need the attributes that aren't denormalised onto
the order views — city, zip, address, open date, comp status, lat/long, timezone.
