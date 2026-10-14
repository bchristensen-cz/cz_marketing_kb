# SQL style and join patterns

> Part of the `sales-ops-orders` skill. Read `../SKILL.md` first; this file is loaded on demand. **Read it when:** before you write or run the first SQL of the session. Mandatory for all SQL shown or executed.
> Content moved verbatim from `SKILL.md` on 2026-10-14 (router split); the rules and dates inside are unchanged.

## SQL style (steward rule 2026-07-23, extended 2026-07-29, 2026-08-20 and 2026-08-21 — MANDATORY)

All SQL — shown to users or executed — follows the steward's format so he can diagnose any query quickly. The rules below are the source of truth. **Do not copy layout from `sql/`** — those build scripts predate the 2026-08-20 first-field and alias-padding rules and are deliberately left unreformatted so the repo stays diffable against the deployed scheduled-query text; each one gets reformatted the next time it is actually deployed.

1. **Fully qualify everything — tables *and* every column reference.**
   - Tables: `` `marketing-data-442316`.dataset.table ``. Never rely on a default project or dataset.
   - **Backticks wrap the project only, not the whole path.** `` `marketing-data-442316`.sales_ops.order_customer oc `` — correct. `` `marketing-data-442316.sales_ops.order_customer` oc `` — wrong, even though BigQuery accepts both. The project id is the only part that *needs* quoting (the hyphens); ticking the whole path hides the dataset/table boundary. (Steward rule 2026-07-29. Note this governs **SQL**; in markdown prose a full table name inside a code span, like `sales_ops.order_customer`, is just formatting.)
   - Columns: every column in every clause (select, where, join, group by, order by, window, having) carries its table alias — `oc.net_sales`, never bare `net_sales` — **even in a single-table query**. Nobody should have to go searching for which table a field came from.
2. **Fixed aliases for the core tables**, in either dataset (`sales_ops` or `claude`) — don't invent new ones:
   - `order_customer` → **`oc`**
   - `order_lines` → **`ol`**
   - `order_sequence` → `os`, `customer_attribute` → `ca`, `store_info` → `si`
3. **Lowercase whenever possible**: keywords, functions, aliases, CTE names. Case only where the identifier or value requires it — schema column names as they actually exist (`business_date` on `order_lines`) and string literals being compared (`'Third Party'`).
4. **Layout**:
   - select list: one column per line, **leading commas with a single space after the comma** — `, oc.store_id as store_id`; column aliases use `as`
   - **the first field is flush with `select` — do not indent it** (steward rule 2026-08-20). A leading-comma list has no reason to be indented; indenting the first field alone just makes it fail to line up with everything under it
   - **`from`, `group by` and `order by` keep their values ON the keyword line** (steward rule 2026-08-21) — `from `marketing-data-442316`.sales_ops.order_customer oc`, `group by oc.business_date, oc.store_id, ol.item_name`, `order by oc.business_date`. Only the **select list** is stacked one-per-line; the tail clauses stay compact however many values they hold. ⚠️ This **reverses** the 2026-08-20 wording that said `group by` / `order by` follow the select-list layout with stacked leading-comma lines — that was an extrapolation from the select-list rule, never the steward's instruction
   - **exactly one space before `as` — never pad or column-align aliases** (steward rule 2026-08-20). `oc.net_sales as net_sales`, not `oc.net_sales                 as net_sales`. Alignment padding survives exactly one edit before it's wrong, and it turns a one-column change into a whole-block diff
   - **`case`: one `when` stays inline, two or more break and indent** (steward rule 2026-08-21). One branch: `, case when oc.is_catering then 'Catering' else 'Retail' end as channel`. Two or more: `case` alone on its own line flush left, each `when` and the `else` indented **one tab**, then `end as alias` flush left again — see the worked example below
   - **no alignment padding inside a `case` either** — single spaces throughout, never lined-up `then`s, `else`s or `end`s. Same reasoning as the alias rule: padding is wrong after the next edit and turns a one-branch change into a whole-block diff
   - CTEs: `with name as (` … `)`, chained as `, next_name as (`
   - **`where 1=1` is always the first condition**, then each real condition on its own `and ...` line — so conditions can be added, removed, or commented out without touching the rest
   - each join on its own line with `on ...` on the line directly beneath it, **lined up with the `join`**
   - **indent one additional level for each successive join**, so nesting depth is readable at a glance
   - **indentation appears in exactly two places** (steward rule 2026-08-21): successive joins with their `on` lines, and the `when` / `else` branches of a multi-branch `case`. Nothing else is ever indented — not the select list (inside a CTE or out), not the `and` lines under `where`, not the tail clauses. ⚠️ Replaces the earlier 2026-08-21 line claiming a join and its `on` are the *only* indented lines; that was wrong, and it was wrong because it was written from a corrected snippet rather than from a full query the steward had actually laid out

Wrong — indented first field, padded aliases, aligned `case`, stacked `group by`:

```sql
select
  oc.business_date                        as business_date
, case when oc.is_catering then 'Catering'
       else                     'Retail'
  end                                     as channel
, count(distinct oc.brink_order_id)       as orders
from `marketing-data-442316`.sales_ops.order_customer oc
group by
oc.business_date
, channel
```

Right:

```sql
select
oc.business_date as business_date
, case when oc.is_catering then 'Catering' else 'Retail' end as channel
, count(distinct oc.brink_order_id) as orders
from `marketing-data-442316`.sales_ops.order_customer oc
group by oc.business_date, channel
```

Full worked example — multi-branch `case`, nested joins, compact tail clauses:

```sql
select
oc.business_date as business_date
, oc.store_id as store_id
, case
	when oc.revenue_category = 'Catering' then 'catering'
	when oc.destination = 'Third Party' then 'third_party'
	when oc.pulse_order_id is not null then 'digital'
	else 'in_store'
end as channel_group
, count(distinct oc.brink_order_id) as orders
, round(sum(oc.net_sales), 2) as net_sales
from `marketing-data-442316`.sales_ops.order_customer oc
	join `marketing-data-442316`.sales_ops.order_lines ol
	on ol.brink_order_id = oc.brink_order_id
		left join `marketing-data-442316`.sales_ops.order_sequence os
		on os.brink_order_id = oc.brink_order_id
where 1=1
and oc.business_date between @start and @end
and ol.business_date between @start and @end
and oc.store_id not in (1111, 999)
group by oc.business_date, oc.store_id, channel_group
order by oc.business_date, oc.store_id
```

## Join patterns

**order_customer → order_lines** (partition-prune both sides — same column name on each since 2026-07-30):
```sql
select
...
from `marketing-data-442316`.sales_ops.order_lines ol
	join `marketing-data-442316`.sales_ops.order_customer oc
	on oc.brink_order_id = ol.brink_order_id
where 1=1
and ol.business_date between @start and @end
and oc.business_date between @start and @end   -- partition-prune BOTH tables
```

**order_customer → order_sequence** (always `left join` — a missing row means unidentified, not an error):
```sql
select
...
from `marketing-data-442316`.sales_ops.order_customer oc
	left join `marketing-data-442316`.sales_ops.order_sequence os
	on os.brink_order_id = oc.brink_order_id
	and os.business_date = oc.business_date
where 1=1
and oc.business_date between @start and @end
and os.business_date between @start and @end
```
