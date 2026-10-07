# Currents ingestion integrity

> Part of the `braze-campaigns` skill. Read `../SKILL.md` first; this file is loaded on demand. **Read it when:** counts look low or a day looks missing, or you are checking whether the stream is healthy.
> Content moved verbatim from `SKILL.md` on 2026-10-07 (progressive-disclosure restructure); the rules and dates inside are unchanged.

## Currents ingestion integrity (steward findings 2026-07-28)

The `braze` dataset is built by a `currents_merge` job that MERGEs `braze_stream` into the event tables. Four things about that pipeline change how you should write queries.

### 1. `id` is the event dedupe key — use it for event counts

Every Currents table carries an `id`. It is the row's unique event identifier, and the merge can emit duplicates. For any **event-level** count, count distinct ids:

```sql
count(distinct ce.id) as events   -- not count(*)
```

`count(distinct external_user_id)` (the existing unique-user guidance) was never affected by this — the exposure is specifically `count(*)` metrics: sends, opens, impressions, clicks.

Health check the steward runs across all 89 tables — use it on any table you're about to report from:

```sql
select
count(*) - count(distinct id) as extra_rows
from `marketing-data-442316`.braze.email_send
where 1=1
and event_date >= date_sub(current_date('America/Denver'), interval 3 day)
and id is not null
```

**Duplicates are real and recent.** `canvas_entry` had duplicate ids under investigation on 2026-07-28 (a new merge image went live ~19:56 UTC that day). Treat late-July event counts as provisional until the merge fix is confirmed. `canvas_entry.create_datetime` is `current_datetime()` at insert (UTC civil time), so it dates when a row *landed* rather than when the event happened — useful for isolating rows from one bad load.

### 2. `load_watermark` is a lock, not just a freshness marker

A **future-dated** watermark means the merge job is holding the lock and is mid-write. Don't trust reads taken in that state:

```sql
select
lw.job_name
, lw.watermark
, lw.updated_at
, lw.watermark > current_timestamp() as lock_currently_held
from `marketing-data-442316`.braze.load_watermark lw
where 1=1
order by
lw.job_name
```

Check this alongside the ~2-day event maturation rule below. `watermark` is already a TIMESTAMP — see the caveat about not casting it.

### 3. There is a `__NULL__` event_date partition

Rows with `event_date is null` exist. The mandatory `where event_date between @start and @end` filter **silently drops them**. That's normally the right trade (they can't be placed on a timeline), but say so if a total needs to reconcile to a Braze dashboard figure.

### 4. Never bound `event_date` with a possibly-NULL value

`where event_date >= @some_null_var or event_date is null` defeats partition pruning entirely and scans the whole table — the exact failure mode observed on `contentcard_send`. If a bound can be NULL, `coalesce` it to a real date first. The "always filter `event_date`" rule only saves money when the bound is a genuine date literal or parameter.
