---
name: braze-campaigns
description: How to query Braze marketing campaign data in BigQuery (dataset braze) — campaign/canvas activity by day and cross-channel customer engagement (email, push, SMS, RCS, banners, content cards, in-app). Use for ANY question about marketing campaigns, campaign sends, opens, clicks, engagement rates, journeys/canvases, or channel performance. Contains the canonical union templates and identity/machine-open rules so every session returns the same answer.
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

Both have been validated against BigQuery (dry run, zero errors). Use them as the starting point rather than rewriting the unions by hand — that's where errors creep in. Full column docs: `data_dictionaries/braze_data_dictionary.md` (index + per-channel files under `data_dictionaries/braze/`) (refreshed 2026-09-03 from live `INFORMATION_SCHEMA` — all 119 tables / 2,651 columns including the streaming-era additions, each tagged Active/Empty with row counts; `.xlsx` twin alongside it).

## Workspaces (added with the 2026-07 streaming switch)

Every event table now carries a **`workspace`** column with two values:

- `cafe_zupas` — main workspace (~99% of volume)
- `cafe_zupas_catering` — separate catering workspace

**Canonical default: filter `workspace = 'cafe_zupas'`** on every base table. Include the catering workspace only when explicitly asked — and when you do, keep `workspace` in the grain, because campaign ids never cross workspaces. Always state which workspace(s) an answer covers when catering is in scope.

## The core idea: one campaign spans many channels and many tables

A single campaign can reach a customer through **email, push notification, SMS, RCS, an in-app message, an on-site/in-app Banner, or a Content Card**. Braze writes each channel's events to **separate tables**, and each event type (send, delivery, open, click, bounce, …) is also its own table. To reason about a campaign as a whole you must **union the relevant per-channel tables together** into one normalized shape, then aggregate.

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

Other tables exist per channel (delivery, bounce, abort, unsubscribe, mark-as-spam, soft bounce, etc.) — see `data_dictionaries/braze_data_dictionary.md` (index + per-channel files under `data_dictionaries/braze/`). They aren't part of these two templates but follow the same column conventions, so you can add them the same way (e.g., swap `email_send` for `email_delivery` to switch the denominator to delivered).

### Streaming-era tables (added 2026-07)

The switch to streaming ingestion (Currents → `braze_stream` → merged into `braze`) added 50 tables (119 total). Status as of 2026-09-03 (row counts from `__TABLES__`):

- **Active, in the templates**: `banner_impression` (135k), `banner_click` (5k), `rcs_send` (50k), `rcs_delivery` (44k), `rcs_read` (10k), `rcs_click` (6k), `rcs_inboundreceive` (2k).
- **Active, not in the templates** (operational / diagnostic): `rcs_rejection` (6k, `is_sms_fallback` marks RCS→SMS fallback), `rcs_abort`, `email_deferral` (806k), `inappmessage_abort`, `canvas_exit_matchedaudience`, `canvasstep_progression` (287M — granular journey flow), `pushnotification_tokenstatechange` (265k), `webhook_failure` (3.6M), `location` (524k).
- **Present but empty** (channels not in use): `line_*` (LINE), `whatsapp_*` (WhatsApp), `liveactivity_*`, `agentconsole_*`, `featureflag_impression`, `installattribution`, `sms_carriersend`, `pushnotification_iosforeground`, all `*_retry` (incl. `email_retry`), `banner_abort`/`banner_dismiss`, `contentcard_abort`/`contentcard_dismiss`. If these light up, extend the templates the same way.
- **Original-era tables changed too**: 42 of the 69 gained columns — `workspace` everywhere; `is_suspected_bot_click` + `suspected_bot_click_reason` on `email_click` / `sms_shortlinkclick` (and `rcs_click`); `is_sms_fallback` on `sms_delivery` / `sms_deliveryfailure` / `sms_rejection`; `push_token` on push send/bounce.
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
  , coalesce(nullif(campaign_id, ''), canvas_id) as program_id
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

- **`event_date`** (DATE, **America/Denver local date**) — the **partition column**. Always filter it (`where event_date between @start_date and @end_date`) in every base table for cost control. This is the date to group by for "by day". It is the Denver-local calendar day of the event, not the UTC date (measured 2026-09-03: `event_date = date(event_timestamp)` on 100% of `email_send` rows every day sampled; the UTC date `date(timestamp_seconds(time))` only matches ~97–99% — the late-evening rows roll to the next UTC day).
- **`event_timestamp`** (DATETIME, **America/Denver wall-clock, follows US Mountain DST**) — precise event time in Mountain time. **It is NOT UTC**, despite earlier revisions of this file saying so. `extract(hour from event_timestamp)` is already a Mountain-time hour. Never wrap it in `cast(... as timestamp)`, `timestamp(...)`, or `datetime(cast(... as timestamp), 'America/Denver')` — all three assert UTC on a local value and land 6–7 hours early.
- **`time`** (INT64, Unix epoch seconds, **true UTC**) — the only unambiguous UTC clock on the event tables. **For a UTC instant use `timestamp_seconds(<alias>.time)`.** This is the Braze side of every cross-source comparison to `order_timestamp_utc`.
- **`local_event_datetime`** — event time in the *user's* zone (`timezone` column; differs from `event_timestamp` for out-of-Mountain users); not present on every table. Use for user-local daypart only.

> **🚨 Verified 2026-09-03 — `event_timestamp` is Denver local, not UTC (Asana 1217708981759181, 1218166682517918).** Measured against `timestamp_seconds(time)` on `email_send`: the gap is exactly **−7 h on a January day** and **−6 h on every summer day** sampled March → September, 100% of rows, both workspaces, pre-streaming history included — zero variance, so it is a clock definition, not drift, and the DST step confirms the zone. An earlier 2026-08-20 pass found the same 360-minute offset on 16.8M events across 8 tables (`canvas_entry`, `email_send`, `email_open`, `pushnotification_send`, `inappmessage_impression`, `inappmessage_click`, `campaigns_enrollincontrol`, `rcs_send`). Verification query (leading commas, lowercase, partition-bounded):
>
> ```sql
> select
> es.event_date
> , es.workspace
> , datetime_diff(es.event_timestamp, datetime(timestamp_seconds(es.time)), hour) as ts_minus_utc_hours
> , countif(es.event_date = date(es.event_timestamp)) / count(*) as pct_event_date_is_local_date
> , countif(es.event_date = date(timestamp_seconds(es.time))) / count(*) as pct_event_date_is_utc_date
> , count(distinct es.id) as sends
> from `marketing-data-442316`.braze.email_send es
> where 1=1
> and es.event_date in (date '2026-01-15', date '2026-03-05', date '2026-03-10', date '2026-06-15', date '2026-09-03')
> group by es.event_date, es.workspace, ts_minus_utc_hours
> order by es.event_date, es.workspace
> ```
>
> Expected: `ts_minus_utc_hours` = −7 before 2026-03-08 and −6 after; `pct_event_date_is_local_date` = 1.0; `pct_event_date_is_utc_date` < 1.0.
>
> **Practical damage.** A session that followed the previous revision converted an already-local value with `datetime(cast(event_timestamp as timestamp), 'America/Denver')` and looked 6 hours early — a 4:42pm broadcast appeared not to have loaded ("data stops at 4:02pm") when the whole 4–6pm send was present. Any hour-of-day / daypart cut built on the old guidance is off by 6–7 h, and any Braze↔orders window built on `cast(event_timestamp as timestamp)` vs `order_timestamp_utc` puts the exposure 6–7 h *before* it happened — an "order after exposure" test silently sweeps in orders that preceded the message, and a 72-hour window is really −6 h → +66 h. This is the same asserts-UTC-on-a-local-value anti-pattern the order-side section below documents for `timestamp(order_datetime)`, now on the Braze side — and because both errors push their clock *earlier* by a similar amount, they partially cancel on Mountain-time stores, which is likely why neither surfaced for a month.

## Conventions these templates follow (team SQL style)

- All lower case; fully-qualified table names with backticks around **the project only** (`` `marketing-data-442316`.braze.table ``, never `` `marketing-data-442316.braze.table` ``).
- **Steward SQL layout (mandatory 2026-07-23, extended 2026-07-29, 2026-08-20 and 2026-08-21, applies to ALL generated SQL):** select list one column per line with **leading commas followed by one space**; **the first field is flush with `select`, not indented**; **`from` / `group by` / `order by` keep their values on the keyword line** (`group by oc.business_date, oc.store_id`) — only the select list is stacked; column aliases use `as` with **exactly one space before it — never padded or column-aligned**; **a `case` with one `when` stays inline, two or more break with `case` / `end` flush and each `when` / `else` indented one tab — no alignment padding either way**; **indentation appears in exactly two places: successive joins with their `on` lines, and multi-branch `case` branches — nothing else**; **every column reference carries its table alias — no bare column names anywhere, even in single-table queries**; CTEs chained `with a as (...)`, `, b as (...)`; `where 1=1` as the first condition, then one `and ...` per line; each join on its own line with `on ...` on the next line lined up beneath the join, **one extra indent per successive join**; short lowercase table aliases (fixed: `order_customer` → `oc`, `order_lines` → `ol`). See the "SQL style" section of `claude_skills/sales-ops-orders/SKILL.md` for the source of truth — **not** the build scripts in `sql/`, which predate the 2026-08-20 layout rules and stay unreformatted so the repo remains diffable against deployed scheduled-query text.
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
an.event_date
, an.program_type
, an.program_id
, an.program_name
, array_agg(distinct an.channel order by an.channel) as channels_active
, count(distinct an.channel) as channel_count
, count(*) as activity_events
, count(distinct an.external_user_id) as users_reached
from activity_norm an
where 1=1
and an.program_id is not null
group by
an.event_date
, an.program_type
, an.program_id
, an.program_name
order by
an.event_date
, an.program_name;
```

This gives one row per campaign per day, with the channels it ran on and how many customers it reached — the historical "what was live when" view that later analysis builds on. Drop `event_date` from the grain for a per-campaign lifetime summary, or add `channel` to the grain for a day × campaign × channel matrix.

## Pattern 2 — Customer engagement and engagement rate

Full template: **`sql/braze_campaign_engagements.sql`**.

It unions the engagement tables into a CTE `engagements`, normalized to one row per open/click/reply with `program_id`, `channel`, `engagement_type`, the two non-human flags `is_machine_open` and `is_suspected_bot_click`, and their combination **`is_human`** (`not is_machine_open and not is_suspected_bot_click`).

**Did a customer engage with a campaign?** Group the normalized set by `external_user_id` + `program_id` (filter `is_human` for true human engagement). See *Example A* in the template.

**Engagement rate (default denominator = SENT):** the template's *Example B* builds a `sent` base from the send/impression tables and an `engaged` base from the engagement union, then divides distinct engaged users by distinct sent users per `program_id`:

```text
engagement_rate = distinct engaged users / distinct sent users   (per program_id)
```

It reports two variants side by side:

- **`engagement_rate_human`** — `is_human` only: excludes machine opens and suspected bot clicks. Use this as the headline rate.
- **`engagement_rate_all`** — every open/click including machine opens and bot clicks.

Add `channel` to both the `sent` and `engaged` grains for a per-channel engagement-rate breakdown of the same campaign.

### Machine opens (Apple Mail Privacy Protection)

Email `email_open` rows include proxy/"machine" opens (notably Apple MPP) that fire automatically and are **not** human actions. Only `email_open` can be a machine open; the template computes:

```sql
coalesce(lower(machine_open) = 'true', false) as is_machine_open
```

and sets `is_machine_open = false` on all non-email engagements. Default to the human-only metric; keep the all-opens metric available for reconciliation against Braze's dashboard, which counts all opens.

### Bot clicks (added 2026-09-03)

Braze now flags suspected bot / security-scanner clicks with **`is_suspected_bot_click`** (plus a `suspected_bot_click_reason`) on `email_click`, `sms_shortlinkclick`, and `rcs_click`. The template carries it through as `coalesce(is_suspected_bot_click, false)` on those three tables and `false` elsewhere, then folds it with machine opens into `is_human`. Treat bot clicks like machine opens: excluded from the headline rate, retained in the all-events metric.

### Why "sent" as the denominator (and how to switch to delivered)

We default to **sent** because it's consistent across every channel (in-app/banner have no "delivered" event — impressions are the exposure base). It slightly overstates the denominator vs delivered. To switch to a **delivered**-based rate, swap the send tables in the `sent_base` for the delivery tables — `email_delivery`, `sms_delivery`, `rcs_delivery`, and push sends minus `pushnotification_bounce` — and keep impressions for in-app/banner. The rest of the query is unchanged.

## Attribution note (precise vs campaign-level)

> **Window rule (ledger D-026, 2026-09-24): an order is credited to the single most recent qualifying send to the same email in the 24 hours before `order_timestamp_utc`, extended to 48 hours for Saturday sends** (stores are closed Sunday). Attribution channels are email, push, SMS and RCS; content card, banner and in-app are session-gated and never take attribution. Identity bridge is email (D-021). Call the result "last-touch attributed" or "influenced", never "incremental". Any answer using a different window must say so and must not be presented as the same number. Full calculation: `cz-dashboard/docs/decisions/braze-attribution.md`; row: `decisions/DECISIONS.md`.

These templates attribute an engagement to a campaign by matching `program_id` on both sides — correct at campaign / campaign-day grain. For **stricter** attribution (e.g., this open belongs to this exact send), additionally join engagements to sends on `dispatch_id` (and `external_user_id`), available on most tables. For most reporting, `program_id`-level is the right and simpler choice.

## Reference files (read on demand)

This skill is split so a session reads only what the question needs. **`SKILL.md` is always read in full**, and `references/caveats.md` is read before every Braze answer. The others are read when their trigger applies.

| File | Read it when |
|---|---|
| [`references/caveats.md`](references/caveats.md) | before EVERY Braze answer — the per-channel and per-table traps |
| [`references/holdouts.md`](references/holdouts.md) | the question involves control groups, holdouts, lift, incrementality or experiment steps |
| [`references/currents_integrity.md`](references/currents_integrity.md) | counts look low or a day looks missing, or you are checking whether the stream is healthy |
| [`references/writing_out.md`](references/writing_out.md) | the task pushes data to Braze (CDI) or Google Ads offline conversions rather than reading it |
| [`references/channel_value.md`](references/channel_value.md) | the question compares channels (email vs push vs SMS) or channel combinations on value or lift |
| [`references/canvas_message_report.md`](references/canvas_message_report.md) | the question is about canvas-level reporting or automated vs manual sends |

## Files

| File | What it is |
|---|---|
| `claude_skills/braze-campaigns/SKILL.md` | This guide. |
| `sql/braze_campaign_daily_activity.sql` | Normalized cross-channel activity union + campaigns-by-day rollup. |
| `sql/braze_campaign_engagements.sql` | Normalized cross-channel engagement union + engagement-by-customer and engagement-rate examples. |
| `sql/analysis/braze_channel_value_analysis.sql` | Channel and channel-combination value: the descriptive panel, the session-gating diagnostic, the pooled lift by channel mix, and the email x text 2x2 with its independence/placebo checks. |
| `data_dictionaries/braze_data_dictionary.md` (index + per-channel files under `data_dictionaries/braze/`) | Full table & column dictionary for the `braze` dataset — all 119 tables / 2,651 columns, Active/Empty status and row counts, refreshed 2026-09-03 from live `INFORMATION_SCHEMA`. |
| `data_dictionaries/braze_data_dictionary.xlsx` | Same content as a filterable workbook (Read Me, Tables, Data Dictionary, Custom PAYLOAD Fields). |

## When done

If you learned something new about the Braze tables during the session (new gotcha, new canonical definition, data quality issue), do **not** edit this skill or any local copy — only the data steward commits to the repo, and session copies are discarded. Instead, create an Asana task on the **Claude Data** board (workspace cafezupas.com, project `1216769551099591`) titled `KB finding: <short title>`, describing what you observed (include the query that surfaced it) and the proposed change. The steward reviews and merges vetted findings; the next session's fresh clone benefits automatically.
