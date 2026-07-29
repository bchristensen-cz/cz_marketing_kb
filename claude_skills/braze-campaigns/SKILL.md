---
name: braze-campaigns
description: How to query Braze marketing campaign data in BigQuery (dataset braze) — campaign/canvas activity by day and cross-channel customer engagement (email, push, SMS, content cards, in-app). Use for ANY question about marketing campaigns, campaign sends, opens, clicks, engagement rates, journeys/canvases, or channel performance. Contains the canonical union templates and identity/machine-open rules so every session returns the same answer.
---

# Querying Braze Campaign Data

> **Freshness check:** this file must come from a clone of `https://github.com/bchristensen-cz/cz_marketing_kb` `main` pulled **this session**. If you're reading it from an installed skill package, a fork, or any saved copy, stop and re-clone first — it may be stale.

**Project:** `marketing-data-442316`  **Dataset:** `braze`

A reference for writing SQL against the Braze tables so that Claude and analysts produce **consistent, correct** cross-channel campaign queries without re-deriving the logic each time. It answers two recurring questions:

1. **What campaigns were running on which days?** (historical campaign activity, across all channels)
2. **How did customers engage with a campaign, and what's its engagement rate?** (cross-channel engagement)

The companion templates in this repo are the source of truth for the SQL:

- `sql/braze_campaign_daily_activity.sql` — normalized cross-channel **activity** (sends/exposures).
- `sql/braze_campaign_engagements.sql` — normalized cross-channel **engagement** (opens/clicks/replies) + engagement-rate example.

Both have been validated against BigQuery (dry run, zero errors). Use them as the starting point rather than rewriting the unions by hand — that's where errors creep in. Full column docs: `data_dictionaries/braze_data_dictionary.md` (note: generated pre-streaming, 2026-06-11 — covers the original 69 tables but not yet the streaming-era additions below).

## Workspaces (added with the 2026-07 streaming switch)

Every event table now carries a **`workspace`** column with two values:

- `cafe_zupas` — main workspace (~99% of volume)
- `cafe_zupas_catering` — separate catering workspace

**Canonical default: filter `workspace = 'cafe_zupas'`** on every base table. Include the catering workspace only when explicitly asked — and when you do, keep `workspace` in the grain, because campaign ids never cross workspaces. Always state which workspace(s) an answer covers when catering is in scope.

## The core idea: one campaign spans many channels and many tables

A single campaign can reach a customer through **email, push notification, SMS, an in-app message, and an on-site/in-app banner (Content Card)**. Braze writes each channel's events to **separate tables**, and each event type (send, delivery, open, click, bounce, …) is also its own table. To reason about a campaign as a whole you must **union the relevant per-channel tables together** into one normalized shape, then aggregate.

Channel → table mapping used by the templates:

| Channel | Activity / exposure (campaign "running") | Engagement (opens/clicks/replies) |
|---|---|---|
| Email | `email_send` | `email_open`, `email_click` |
| Push | `pushnotification_send` | `pushnotification_open` |
| SMS | `sms_send` | `sms_shortlinkclick` (click), `sms_inboundreceive` (reply) |
| RCS † | `rcs_send` | `rcs_read` (≈open), `rcs_click`, `rcs_inboundreceive` (reply) |
| Content Card | `contentcard_send` | `contentcard_click` |
| Banner † | `banner_impression` * | `banner_click` |
| In-app message | `inappmessage_impression` * | `inappmessage_click` |

\* In-app messages and Banners have **no send event** in Braze Currents. The closest "the campaign was shown" signal is the **impression**, so the activity template tags these `activity_type = 'impression'` while everything else is `'send'`.

† Added with the 2026-07 streaming switch. **RCS now carries most text-message volume** (~4x SMS) — any "SMS/text campaign" question must include the `rcs_*` tables or it will badly undercount. `rcs_read` is a genuine device read receipt (treated as an open, never a machine open).

Other tables exist per channel (delivery, bounce, abort, unsubscribe, mark-as-spam, soft bounce, etc.) — see `data_dictionaries/braze_data_dictionary.md`. They aren't part of these two templates but follow the same column conventions, so you can add them the same way (e.g., swap `email_send` for `email_delivery` to switch the denominator to delivered).

### Streaming-era tables (added 2026-07)

The switch to streaming ingestion (Currents → `braze_stream` → merged into `braze`) added ~50 tables. Status as of 2026-07-22:

- **Active, in the templates**: `banner_impression`, `banner_click`, `rcs_send`, `rcs_read`, `rcs_click`, `rcs_delivery`, `rcs_inboundreceive`, `email_deferral`, `email_retry`.
- **Present but no data yet** (channels not in use): `line_*` (LINE), `whatsapp_*` (WhatsApp), `sms_carriersend`, `pushnotification_iosforeground`, `liveactivity_*`, `featureflag_impression`, `agentconsole_*`, `banner_abort`/`banner_dismiss`. If these light up, extend the templates the same way.
- **Plumbing — never query for analysis**: `currents_raw`, `load_watermark`, the whole `braze_stream` dataset, `stg_*`, `table_rec_cnt`.
- **Custom attribute feeds** (`bz_cid_*`, `cdi_*`, `users`, `global_holdout`, points/user-id sync tables): Cafe Zupas profile/attribute syncs, not campaign events — out of scope for this skill.

## Identity keys you must understand

Every event row carries both a Campaign identity and a Canvas identity, plus message/variation and dispatch keys. Pick the right grain for the question.

- **`campaign_id` / `campaign_name`** — a Braze *Campaign*. Populated when the message came from a campaign.
- **`canvas_id` / `canvas_name`** — a Braze *Canvas* (a multi-step, often multi-channel journey). Populated when the message came from a Canvas. When a Canvas sends, `campaign_*` is typically empty and `canvas_*` is set.
- **`is_canvas`** — `1` if the message originated from a Canvas, else `0`. Use it to label the source. **Streaming-era tables (`banner_*`, `rcs_*`) don't have this column** — derive it: `case when coalesce(canvas_id, '') <> '' then 1 else 0 end` (the templates already do).
- **`program_id` / `program_name`** (derived, not a real column) — the templates coalesce the two into a single identity so a "campaign" delivered as a Campaign *or* a Canvas lines up:

  ```sql
  case when is_canvas = 1 then 'canvas' else 'campaign' end as program_type
  , coalesce(nullif(campaign_id, ''), canvas_id)   as program_id
  , coalesce(nullif(campaign_name, ''), canvas_name) as program_name
  ```

  Group by `program_id` for the broad "campaign or journey" view. If you only want true Campaigns, filter `is_canvas = 0` and group by `campaign_id`.

- **`canvas_step_id` / `canvas_step_name`** — which step of a Canvas produced the event (a Canvas's email step vs SMS step).
- **`message_variation_id` / `message_variation_name`** — the A/B variant.
- **`send_id`** — groups all messages from one send; useful for send-level analytics. Note `sms_shortlinkclick`, `sms_inboundreceive`, `rcs_read`, and the `banner_*` tables have **no `send_id`** (the templates null it); `banner_*` tables also lack `dispatch_id`.
- **`dispatch_id`** — one dispatch batch to a user; usable to tie an engagement back to a specific send.
- **`external_user_id`** — the **Cafe Zupas customer ID**. This is the join key to customers and to other datasets (e.g., `sales_ops`). `user_id` is Braze's internal `braze_id`.

> **`campaign_*` vs `cmpgn_*`:** the export includes both naming styles for the same attributes; `cmpgn_*` is a legacy duplicate. Use `campaign_*`.

## Time columns

- **`event_date`** (DATE, UTC) — the **partition column**. Always filter it (`where event_date between @start_date and @end_date`) in every base table for cost control. This is the date to group by for "by day".
- **`event_timestamp`** (DATETIME, UTC) — precise event time.
- **`local_event_datetime`** — event time in the user's local zone (use when daypart/local-day matters; not present on every table).
- **`time`** — raw Unix epoch seconds.

## Conventions these templates follow (team SQL style)

- All lower case; fully-qualified table names (`` `marketing-data-442316`.braze.table ``).
- **Steward SQL layout (mandatory 2026-07-23, applies to ALL generated SQL):** select list one column per line with leading commas; column aliases use `as`; CTEs chained `with a as (...)`, `, b as (...)`; `where 1=1` then one `and ...` per line; each join on its own line with `on ...` indented on the next line; short lowercase table aliases. See the "SQL style" section of `claude_skills/sales-ops-orders/SKILL.md` and the build scripts in `sql/` for reference.
- **All datasets are read-only.** Materialize intermediate results ONLY in `marketing-data-442316.scratch` (the single writable dataset; 7-day auto-expiry). Use `create table`, not views over heavy unions.
- **Early partition filtering** on `event_date` in every base CTE.
- Select only the columns needed.
- No `sales_ops` filters here. `storeid = 1111` exclusion and `iscatering = 0` apply to **order** tables, not Braze.

---

## Pattern 1 — Which campaigns ran on which days

Full template: **`sql/braze_campaign_daily_activity.sql`**.

It unions the seven activity tables (email, push, SMS, RCS, content card, banner, in-app) into a CTE `activity`, then exposes a normalized row per event with `workspace` / `program_id` / `program_name` / `channel` / `activity_type`. Build the "by day" answer on top:

```sql
-- after the normalized select (call it activity_norm):
select
  event_date
, program_type
, program_id
, program_name
, array_agg(distinct channel order by channel) as channels_active
, count(distinct channel)                       as channel_count
, count(*)                                       as activity_events
, count(distinct external_user_id)              as users_reached
from activity_norm
where program_id is not null
group by event_date, program_type, program_id, program_name
order by event_date, program_name;
```

This gives one row per campaign per day, with the channels it ran on and how many customers it reached — the historical "what was live when" view that later analysis builds on. Drop `event_date` from the grain for a per-campaign lifetime summary, or add `channel` to the grain for a day × campaign × channel matrix.

## Pattern 2 — Customer engagement and engagement rate

Full template: **`sql/braze_campaign_engagements.sql`**.

It unions the engagement tables into a CTE `engagements`, normalized to one row per open/click/reply with `program_id`, `channel`, `engagement_type`, and `is_machine_open`.

**Did a customer engage with a campaign?** Group the normalized set by `external_user_id` + `program_id` (filter `not is_machine_open` for true human engagement). See *Example A* in the template.

**Engagement rate (default denominator = SENT):** the template's *Example B* builds a `sent` base from the send/impression tables and an `engaged` base from the engagement union, then divides distinct engaged users by distinct sent users per `program_id`:

```text
engagement_rate = distinct engaged users / distinct sent users   (per program_id)
```

It reports two variants side by side:

- **`engagement_rate_human`** — excludes machine opens (`not is_machine_open`). Use this as the headline rate.
- **`engagement_rate_all`** — every open/click including machine opens.

Add `channel` to both the `sent` and `engaged` grains for a per-channel engagement-rate breakdown of the same campaign.

### Machine opens (Apple Mail Privacy Protection)

Email `email_open` rows include proxy/"machine" opens (notably Apple MPP) that fire automatically and are **not** human actions. Only `email_open` can be a machine open; the template computes:

```sql
coalesce(lower(machine_open) = 'true', false) as is_machine_open
```

and sets `is_machine_open = false` on all non-email engagements. Default to the human-only metric; keep the all-opens metric available for reconciliation against Braze's dashboard, which counts all opens.

### Why "sent" as the denominator (and how to switch to delivered)

We default to **sent** because it's consistent across every channel (in-app/banner have no "delivered" event — impressions are the exposure base). It slightly overstates the denominator vs delivered. To switch to a **delivered**-based rate, swap the send tables in the `sent_base` for the delivery tables — `email_delivery`, `sms_delivery`, `rcs_delivery`, and push sends minus `pushnotification_bounce` — and keep impressions for in-app/banner. The rest of the query is unchanged.

## Attribution note (precise vs campaign-level)

These templates attribute an engagement to a campaign by matching `program_id` on both sides — correct at campaign / campaign-day grain. For **stricter** attribution (e.g., this open belongs to this exact send), additionally join engagements to sends on `dispatch_id` (and `external_user_id`), available on most tables. For most reporting, `program_id`-level is the right and simpler choice.

## Caveats

- **Dedup:** events can repeat (a user opens an email twice). Use `count(distinct external_user_id)` for unique-user metrics, as the templates do. For **total event** counts use `count(distinct id)`, **not** `count(*)` — the Currents merge can emit duplicate `id` rows. See "Currents ingestion integrity" below.
- **Nulls:** filter `program_id is not null` to drop transactional/API messages with no campaign or Canvas attached.
- **Replies:** `sms_inboundreceive` and `rcs_inboundreceive` include `STOP`/`HELP` and other inbound texts. They're tagged `engagement_type = 'reply'` — include or exclude per analysis; don't treat all replies as positive engagement.
- **In-app/banner have no send or delivery** — impressions are the exposure base; keep that asymmetry in mind when comparing rates across channels.
- **Cost:** always keep the `event_date` partition filter. The tables are large.
- **Workspaces (added 2026-07-22):** event tables carry a `workspace` column — `'cafe_zupas'` (retail) or `'cafe_zupas_catering'` — backfilled for full history. Catering campaign events live in the *same* tables; filter `workspace = 'cafe_zupas'` for retail-only analyses and state which workspace(s) an answer includes.
- **Freshness / event maturation (steward rule 2026-07-23):** event tables (`email_send`, `email_open`, clicks, `app_sessionstart`, etc.) keep backfilling for **~2 days** — same-day reads have run **20–25% low**. Treat the most recent 1–2 event days as partial: label them as immature in any answer, and never compare a just-loaded day against matured days (day-over-day on fresh data will always look like a drop). Check `braze.load_watermark` (`watermark`, `updated_at`) before treating recent events as complete.
- **`event_timestamp` is DATETIME, not TIMESTAMP** — comparing it directly to a TIMESTAMP column (e.g., order timestamps when joining Braze events to `sales_ops` orders) fails with `No matching signature for operator > for argument types: TIMESTAMP, DATETIME`. Cast the Braze side: `cast(event_timestamp as timestamp)` (it's UTC, so the cast is safe). Observed tripping analyst MCP sessions 2026-07-23.
- **`braze.users` is not partitioned** — every query against it is a full scan. Touch it once per analysis (or wait for the planned user-dim mart), not inside repeated CTE runs.
- **`external_user_id` is STRING; `order_customer.mapped_cust_id` is INT64** — joining them raw fails with `No matching signature for operator = for argument types: INT64, STRING` (hit again by an analyst MCP session 2026-07-27). Cast the Braze side.
- **Use `safe_cast`, not `cast` — this is now mandatory, not conditional (upgraded 2026-07-28).** The workspace *does* contain non-numeric `external_user_id` values: `cast(external_user_id as int64)` failed on 2026-07-27 with `Bad int64 value: 05d0a59b-ab22-46d8-b1fa-1577681b…` — a UUID-shaped id. A plain `cast` aborts the whole query the moment one such row is in scope, and which rows are in scope changes with the date window, so a query that worked yesterday can fail today. Always:

  ```sql
  and safe_cast(ce.external_user_id as int64) = oc.mapped_cust_id
  ```

  `safe_cast` yields NULL for the non-numeric ids, which then simply don't join. If you need to know how many you dropped, count them: `countif(safe_cast(external_user_id as int64) is null)`.
- **`braze.load_watermark.watermark` is already a TIMESTAMP** — it is not epoch seconds. `timestamp_seconds(cast(watermark as int64))` fails with `Invalid cast from TIMESTAMP to INT64` (observed 2026-07-27). Select `watermark` and `updated_at` as-is.
- **`customevent` payloads** — `properties` is a JSON *string*; read fields with `json_value(properties, '$.field')`. Filter `name = '<event>'` **and** the `event_date` partition. Known Cafe Zupas events: `guest_email_from_order` (`$.order_id` — guest-checkout email linkage) and `protein_amount_tracked` (`$.protein_amount`, `$.order_id` — per-order protein grams, pipeline under steward validation as of 2026-07-26, not yet trustworthy for reporting). `local_event_datetime` gives the user-local time if you need daypart.
- **The DATETIME/TIMESTAMP trap above is still catching people** — an analyst MCP session hit it again on 2026-07-24 (`order_timestamp_utc` vs a Braze event datetime) despite being documented since 2026-07-23. If a session is failing on this, it is probably not reading a fresh clone of `main`.

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
job_name
, watermark
, updated_at
, watermark > current_timestamp() as lock_currently_held
from `marketing-data-442316`.braze.load_watermark
order by job_name
```

Check this alongside the ~2-day event maturation rule below. `watermark` is already a TIMESTAMP — see the caveat about not casting it.

### 3. There is a `__NULL__` event_date partition

Rows with `event_date is null` exist. The mandatory `where event_date between @start and @end` filter **silently drops them**. That's normally the right trade (they can't be placed on a timeline), but say so if a total needs to reconcile to a Braze dashboard figure.

### 4. Never bound `event_date` with a possibly-NULL value

`where event_date >= @some_null_var or event_date is null` defeats partition pruning entirely and scans the whole table — the exact failure mode observed on `contentcard_send`. If a bound can be NULL, `coalesce` it to a real date first. The "always filter `event_date`" rule only saves money when the bound is a genuine date literal or parameter.

## Files

| File | What it is |
|---|---|
| `claude_skills/braze-campaigns/SKILL.md` | This guide. |
| `sql/braze_campaign_daily_activity.sql` | Normalized cross-channel activity union + campaigns-by-day rollup. |
| `sql/braze_campaign_engagements.sql` | Normalized cross-channel engagement union + engagement-by-customer and engagement-rate examples. |
| `data_dictionaries/braze_data_dictionary.md` | Full table & column dictionary for the `braze` dataset (69 pre-streaming tables; streaming-era additions summarized in this skill, dictionary refresh pending). |

## When done

If you learned something new about the Braze tables during the session (new gotcha, new canonical definition, data quality issue), do **not** edit this skill or any local copy — only the data steward commits to the repo, and session copies are discarded. Instead, create an Asana task on the **Claude Data** board (workspace cafezupas.com, project `1216769551099591`) titled `KB finding: <short title>`, describing what you observed (include the query that surfaced it) and the proposed change. The steward reviews and merges vetted findings; the next session's fresh clone benefits automatically.
