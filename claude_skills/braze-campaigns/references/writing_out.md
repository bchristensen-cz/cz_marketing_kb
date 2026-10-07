# Writing attributes OUT — Braze CDI and Google Ads offline conversions

> Part of the `braze-campaigns` skill. Read `../SKILL.md` first; this file is loaded on demand. **Read it when:** the task pushes data to Braze (CDI) or Google Ads offline conversions rather than reading it.
> Content moved verbatim from `SKILL.md` on 2026-10-07 (progressive-disclosure restructure); the rules and dates inside are unchanged.

## Writing attributes OUT — Braze CDI and Google Ads offline conversions

Everything above is about reading Braze. Four builds push *out* of the warehouse: `braze.bz_cid_bgnbd_palive_churn`, `braze.bz_cid_weather_flag`, `braze.cdi_order_attributes` (Braze custom attributes) and `shared_datasets.google_offline_conversions` (Google Ads). All four were migrated off the dropped `sales_ops.OrderCustomer` on 2026-08-21 and reviewed then. **Outbound builds fail differently from queries: nobody reads the output, so a wrong value lands in a targeting segment or an ad platform and stays there.** The four defects found in that review are all of the same shape — the SQL compiles, runs, and produces something plausible.

### 1. 🚨 `%Ez` on a DATETIME emits the literal string `%Ez`

`format_timestamp('%Y-%m-%dT%H:%M:%S%Ez', oc.order_datetime_local)` — the argument is a **DATETIME**, and the `%Ez` (UTC-offset) specifier is not honoured. Measured 2026-08-18, one order per state:

| written | produced |
|---|---|
| `format_timestamp('…%Ez', order_datetime_local)` | `2026-08-18T11:07:46%Ez` |
| `format_timestamp('…%Ez', order_timestamp_utc, 'UTC')` | `2026-08-18T15:07:46+00:00` |

Every row carries an unparseable timestamp — a DATETIME has no offset to print, so the specifier passes through as text. It does not error. **And even with the format fixed, `order_datetime_local` is store-local**, so the value would be 4–7 hours early across the nine states (Ohio 4, IL/MN/TX/WI 5, ID/UT 6, AZ/NV 7). This is the `timestamp(order_datetime)` anti-pattern documented above, reappearing inside a different function — which is why the rule is written as *"never build a UTC order timestamp yourself,"* not *"never call `timestamp()`."*

**Rule: on anything leaving the warehouse, format `order_timestamp_utc` with an explicit `'UTC'` argument.** Verify by eye that the output string ends in an offset (`+00:00`), because a malformed one looks fine in a spot check.

### 2. Hashed phone identifiers must be E.164 *before* hashing

`to_hex(sha256('+' || cast(i.Phone as string)))` produces `+8015551234`. Google requires E.164, which for US numbers is `+1` + 10 digits. Measured on `sales_ops.cust_info`: **977,569 of 977,606 non-null phones are exactly 10 digits** (11 are 11-digit, and the minimum length is 1, so junk exists). So essentially every phone identifier hashes to something that can never match, silently, forever — a hash mismatch is indistinguishable from "no such user."

Normalize and reject the junk before hashing, e.g. `'+1' || phone` for the 10-digit case and NULL below 10 digits. (`cust_info` itself is clean 1:1 on `mapped_cust_id` — 1,208,682 rows, 1,208,682 distinct — so joining it fans nothing out.)

### 3. 🚨 A null-unsafe change-detection filter can only *update* an attribute, never *initialise* it

The pattern that makes these builds cheap is "only send rows whose value differs from what Braze already holds." Written naively:

```sql
-- ANTI-PATTERN
where json_value(u.custom_attributes.risk_band) <> p.risk_band
```

`NULL <> 'healthy'` is NULL, which is not TRUE, so **every user who does not already have the attribute is dropped.** Measured on `braze.users` 2026-08-21: **3,767,646 of 4,286,702 profiles have no `risk_band` at all** (519,056 have one). A newly-scored guest is therefore locked out permanently — the attribute can only ever be revised, never first written, and on a fresh attribute the build sends **zero rows** while succeeding.

```sql
-- CORRECT
where coalesce(json_value(u.custom_attributes.risk_band), '') <> p.risk_band
```

`cdi_order_attributes` already does this correctly with `coalesce(lax_int64(...), 0)` / `coalesce(timestamp(lax_string(...)), current_timestamp)` on all eight of its comparisons — copy that build's shape. Same family as the `col <> 'X'` null-unsafe filter rule; the twist here is that the dropped rows are exactly the population you most want to reach.

### 4. A priority table that is joined but never ordered by

`bz_cid_weather_flag` defines an explicit precedence — `snow` 1, `rain` 2, `hot` 3, `cold` 4 — joins it, and then picks the winner with:

```sql
qualify row_number() over (partition by oc.mapped_cust_id order by c.weather_flag) = 1   -- ANTI-PATTERN
```

That orders the flag **alphabetically**: `cold` → `hot` → `rain` → `snow`. So `cold` always wins and `snow` always loses — precisely inverted from the declared intent, and the `sort_order` column is never referenced. The join makes the CTE look load-bearing, so the table reads as if the priority were applied. Fix: `order by o.sort_order`.

**Generalisable:** when a lookup table exists to express an *ordering*, check that its rank column appears in an `ORDER BY` and not only in a join predicate. A join gives you the filter; only the `ORDER BY` gives you the precedence. Related: a filter and a breakout are different controls, and this is the same confusion between "restrict the set" and "rank the set."

### 5. Order-event upload recipe (steward query, 2026-09-03)

The steward's ad-hoc "customers who bought X" custom-event feed is the reference shape for anything that turns orders into Braze events — it satisfies rule 1 above without an explicit `'UTC'` argument because the source column is already the true-UTC TIMESTAMP:

```sql
-- One row per (customer, order): distinct collapses multiple qualifying lines on the same order
select distinct
  cast(oc.mapped_cust_id as string) as external_id
, format_timestamp('%Y-%m-%dT%H:%M:%E3SZ', oc.order_timestamp_utc) as event_time
from `marketing-data-442316`.claude.order_lines ol
	join `marketing-data-442316`.claude.order_customer oc
	on oc.brink_order_id = ol.brink_order_id
where 1=1
and ol.business_date >= current_date('America/Denver') - 45
and ol.is_catering = false
and ol.rev_center_name = 'Desserts'
and lower(ol.item_name) like '%cup%'
and oc.mapped_cust_id is not null
and oc.order_timestamp_utc is not null
```

- `external_id` is `mapped_cust_id` cast to STRING — the same id space as `braze.users.external_id` / event `external_user_id`. Never key an upload on email.
- `distinct` is load-bearing: an order with two cup lines must produce one event, not two.
- `order_timestamp_utc is not null` drops the still-open orders (rule (2) under Time columns) rather than emitting a NULL `event_time` that Braze rejects row-by-row.
- The `Z` suffix is a literal. It is truthful here **only** because `order_timestamp_utc` is UTC — the same string built from `order_datetime_local` is the item-1 defect with a different mask.
- Use `item_id` rather than a `like` on `item_name` when the target is a single product; the name matches every size (see `sales-ops-orders`, *item_name is not the product key*).

### Two lower-priority notes from the same review

- **`current_date` is UTC.** Three of these builds anchor on bare `current_date` / `current_date()` (the churn model's `ref_date`, the weather build's `weather_date = current_date`, the L90/L180/L365 windows). After 18:00 MT it is already tomorrow in UTC. Use `current_date('America/Denver')`, which `google_offline_conversions` already does.
- **The internal-traffic exclusion was lost in the migration.** `cdi_order_attributes` carries `--and oc.mapped_domain NOT IN ('cafezupas.com', 'tkxel.com')`, commented out because `mapped_domain` was the legacy name (it is `mapped_email_domain` now). The churn build *does* exclude `cafezupas.com`. So two Braze attribute builds disagree about whether employees are guests — pending the open steward decision on ratifying that exclusion.
