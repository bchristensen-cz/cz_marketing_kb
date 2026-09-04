# Braze Dataset - Table Descriptions & Data Dictionary

**Project:** `marketing-data-442316`  **Dataset:** `braze`  
**Tables documented:** 119  **Columns:** 2,651  **Generated:** 2026-09-04 (schema, row counts and sizes read live from INFORMATION_SCHEMA.COLUMNS and __TABLES__)

This dataset is the BigQuery landing for Braze Currents event streams plus Cafe Zupas custom attribute feeds and user-profile exports. Since the 2026-07 streaming switch, events flow Currents -> Pub/Sub (`currents_raw`) -> `braze_stream` -> MERGEd into the typed per-event tables by the `currents_merge` job (progress and lock in `load_watermark`). Most event tables share a common set of Braze identifier and timestamp columns (documented once below); table-specific columns are described in each table's dictionary.

For HOW to query campaigns across channels (canonical union templates, engagement rate, identity rules) see `claude_skills/braze-campaigns/SKILL.md` and `sql/braze_campaign_daily_activity.sql` / `sql/braze_campaign_engagements.sql`. This file is the column reference.

**Status** = Active (has rows) or Empty (0 rows at generation). Empty channel tables (WhatsApp, LINE, Live Activity, Agent Console, Feature Flags, Install Attribution, and the `*_retry` tables) exist because Braze exports the full event catalog; they are not in use.

## Four rules that apply to every event table

1. **Filter `workspace = 'cafe_zupas'`** by default. The other value, `cafe_zupas_catering`, is a separate workspace (~1% of volume); include it only when asked and keep `workspace` in the grain - campaign ids never cross workspaces.
2. **`event_date` and `event_timestamp` are America/Denver local, NOT UTC.** `event_date` is the Denver calendar day (partition column - always filter it); `event_timestamp` is Denver wall-clock and follows DST. `time` (epoch seconds) is the only true-UTC clock: use `timestamp_seconds(time)` for a UTC instant. Never `cast(event_timestamp as timestamp)` - it asserts UTC on a local value and lands 6-7 h early. (Verified 2026-09-03; details in the braze-campaigns skill, "Time columns".)
3. **`id` is the dedupe key.** The merge can emit duplicate rows; event-level counts must be `count(distinct id)`, not `count(*)`. Unique-user counts (`count(distinct external_user_id)`) are unaffected.
4. **Partition-filter with a real date.** A `__NULL__` `event_date` partition exists and is silently dropped by `between`; bounding `event_date` with a possibly-NULL value defeats pruning and scans the whole table.

## Common columns (shared across most event tables)

| Column | Description |
|---|---|
| `id` | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_id` | Identifier of the specific app/platform build the event is tied to. |
| `app_group_id` | Identifier of the Braze app group (workspace) the event belongs to. |
| `workspace` | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |
| `time` | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | User's IANA time zone (e.g., America/Denver) at time of event. |
| `event_timestamp` | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `campaign_id` | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | Name of the Braze campaign. |
| `message_variation_id` | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | Name of the message variation sent. |
| `canvas_id` | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | Name of the Braze Canvas. |
| `canvas_variation_id` | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | Name of the Canvas variation. |
| `canvas_step_id` | ID of the Canvas step that produced the event. |
| `canvas_step_name` | Name of the Canvas step. |
| `send_id` | Identifier grouping all messages from a single send, used for send-level analytics. |
| `dispatch_id` | ID of the message dispatch (one send batch to a user). |
| `cmpgn_id` | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | Legacy/duplicate message variation name field. |
| `is_canvas` | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `is_suspected_bot_click` | TRUE if Braze flagged the click as a suspected bot / security-scanner click rather than a human click. Exclude for human engagement. |
| `suspected_bot_click_reason` | Reason(s) the click was flagged as a suspected bot click. |

> `campaign_*` vs `cmpgn_*`: the original-era tables include both naming styles for the same attributes; `cmpgn_*` is a legacy duplicate. Streaming-era tables (banner_*, rcs_*, canvasstep_progression, etc.) carry only `campaign_*` and do NOT have `is_canvas` - derive it as `case when coalesce(canvas_id,'') <> '' then 1 else 0 end`. `banner_*` tables also lack `send_id` and `dispatch_id`.

## Custom attribute feed tables (shared shape)

The `bz_cid_*`, `cdi_*`, `cat_points_update`, `first_purch_cat_update`, `indiv_*`, `is_vto_cust`, and `l365_has_salad_order` tables all share the same three-column shape: `UPDATED_AT` (TIMESTAMP), `external_id` (STRING customer ID), and `PAYLOAD` (JSON). The meaningful data lives inside `PAYLOAD`; each table's payload keys are documented in its section. These are Cafe Zupas profile/attribute syncs INTO Braze, not campaign events.

## Table index

| Group | Table | Status | Rows | GB | Last modified |
|---|---|---|---:|---:|---|
| User Profile & Identity | `users` | Active | 4,316,908 | 2.12 | 2026-09-04 |
| User Profile & Identity | `stg_users` | Active | 34,064,648 | 6.32 | 2025-08-19 |
| User Profile & Identity | `stg_external_ids` | Empty | 0 | 0.00 | 2025-06-16 |
| User Profile & Identity | `global_holdout` | Active | 162,885 | 0.01 | 2026-09-03 |
| User Profile & Identity | `randombucketnumberupdate` | Active | 5,775,290 | 0.83 | 2026-07-20 |
| App / Session, Purchase & Device Events | `app_firstsession` | Active | 10,720,570 | 3.27 | 2026-09-04 |
| App / Session, Purchase & Device Events | `app_sessionstart` | Active | 44,820,301 | 12.97 | 2026-09-04 |
| App / Session, Purchase & Device Events | `app_sessionend` | Active | 35,953,315 | 10.78 | 2026-09-04 |
| App / Session, Purchase & Device Events | `uninstall` | Active | 259,892 | 0.05 | 2026-09-04 |
| App / Session, Purchase & Device Events | `customevent` | Active | 110,773,033 | 54.74 | 2026-09-04 |
| App / Session, Purchase & Device Events | `purchase` | Active | 15,265,299 | 12.55 | 2026-09-04 |
| App / Session, Purchase & Device Events | `location` | Active | 524,277 | 0.15 | 2026-09-04 |
| App / Session, Purchase & Device Events | `pushnotification_tokenstatechange` | Active | 264,797 | 0.10 | 2026-09-04 |
| App / Session, Purchase & Device Events | `installattribution` | Empty | 0 | 0.00 | 2026-09-04 |
| Email Events | `email_send` | Active | 262,125,719 | 123.13 | 2026-09-04 |
| Email Events | `email_delivery` | Active | 257,597,349 | 133.54 | 2026-09-04 |
| Email Events | `email_open` | Active | 188,896,068 | 110.22 | 2026-09-04 |
| Email Events | `email_click` | Active | 2,178,290 | 1.90 | 2026-09-04 |
| Email Events | `email_bounce` | Active | 68,724 | 0.04 | 2026-09-04 |
| Email Events | `email_softbounce` | Active | 4,668,963 | 3.21 | 2026-09-04 |
| Email Events | `email_deferral` | Active | 806,208 | 0.64 | 2026-09-04 |
| Email Events | `email_markasspam` | Active | 20,786 | 0.01 | 2026-09-04 |
| Email Events | `email_unsubscribe` | Active | 1,166,091 | 0.54 | 2026-09-04 |
| Email Events | `email_abort` | Active | 3,803,435 | 2.26 | 2026-09-04 |
| Email Events | `email_retry` | Empty | 0 | 0.00 | 2026-09-04 |
| Push Notification Events | `pushnotification_send` | Active | 88,485,565 | 44.74 | 2026-09-04 |
| Push Notification Events | `pushnotification_open` | Active | 586,670 | 0.32 | 2026-09-04 |
| Push Notification Events | `pushnotification_bounce` | Active | 188,756 | 0.09 | 2026-09-04 |
| Push Notification Events | `pushnotification_abort` | Active | 347,627 | 0.21 | 2026-09-04 |
| Push Notification Events | `pushnotification_iosforeground` | Empty | 0 | 0.00 | 2026-09-04 |
| Push Notification Events | `pushnotification_retry` | Empty | 0 | 0.00 | 2026-09-04 |
| SMS Events | `sms_send` | Active | 3,613,599 | 1.66 | 2026-09-04 |
| SMS Events | `sms_carriersend` | Empty | 0 | 0.00 | 2026-09-04 |
| SMS Events | `sms_delivery` | Active | 3,387,223 | 1.57 | 2026-09-04 |
| SMS Events | `sms_deliveryfailure` | Active | 65,398 | 0.04 | 2026-09-04 |
| SMS Events | `sms_rejection` | Active | 359,564 | 0.17 | 2026-09-04 |
| SMS Events | `sms_abort` | Active | 1,366 | 0.00 | 2026-09-04 |
| SMS Events | `sms_retry` | Empty | 0 | 0.00 | 2026-09-04 |
| SMS Events | `sms_inboundreceive` | Active | 65,612 | 0.03 | 2026-09-04 |
| SMS Events | `sms_shortlinkclick` | Active | 217,395 | 0.13 | 2026-09-04 |
| RCS Events | `rcs_send` | Active | 50,312 | 0.03 | 2026-09-04 |
| RCS Events | `rcs_delivery` | Active | 44,464 | 0.02 | 2026-09-04 |
| RCS Events | `rcs_read` | Active | 9,882 | 0.00 | 2026-09-04 |
| RCS Events | `rcs_click` | Active | 6,347 | 0.00 | 2026-09-04 |
| RCS Events | `rcs_inboundreceive` | Active | 1,961 | 0.00 | 2026-09-04 |
| RCS Events | `rcs_rejection` | Active | 5,845 | 0.00 | 2026-09-04 |
| RCS Events | `rcs_abort` | Active | 9 | 0.00 | 2026-09-04 |
| Banner Events | `banner_impression` | Active | 135,515 | 0.07 | 2026-09-04 |
| Banner Events | `banner_click` | Active | 5,347 | 0.00 | 2026-09-04 |
| Banner Events | `banner_dismiss` | Empty | 0 | 0.00 | 2026-09-04 |
| Banner Events | `banner_abort` | Empty | 0 | 0.00 | 2026-09-04 |
| Content Card & In-App Message Events | `contentcard_send` | Active | 142,312,565 | 63.30 | 2026-09-04 |
| Content Card & In-App Message Events | `contentcard_impression` | Active | 1,528,020 | 0.86 | 2026-09-04 |
| Content Card & In-App Message Events | `contentcard_click` | Active | 873,784 | 0.47 | 2026-09-04 |
| Content Card & In-App Message Events | `contentcard_dismiss` | Empty | 0 | 0.00 | 2026-09-04 |
| Content Card & In-App Message Events | `contentcard_abort` | Empty | 0 | 0.00 | 2026-09-04 |
| Content Card & In-App Message Events | `inappmessage_impression` | Active | 1,850,531 | 0.82 | 2026-09-04 |
| Content Card & In-App Message Events | `inappmessage_click` | Active | 1,208,507 | 0.54 | 2026-09-04 |
| Content Card & In-App Message Events | `inappmessage_abort` | Active | 109 | 0.00 | 2026-09-04 |
| Campaign & Canvas Events | `campaigns_conversion` | Active | 10,226,635 | 4.28 | 2026-09-04 |
| Campaign & Canvas Events | `campaigns_enrollincontrol` | Active | 99,070 | 0.04 | 2026-09-04 |
| Campaign & Canvas Events | `canvas_entry` | Active | 893,121,682 | 286.23 | 2026-09-04 |
| Campaign & Canvas Events | `canvasstep_progression` | Active | 286,904,816 | 123.35 | 2026-09-04 |
| Campaign & Canvas Events | `canvas_conversion` | Active | 16,246,267 | 8.65 | 2026-09-04 |
| Campaign & Canvas Events | `canvas_exit_performedevent` | Active | 84,767 | 0.03 | 2026-09-04 |
| Campaign & Canvas Events | `canvas_exit_matchedaudience` | Active | 532 | 0.00 | 2026-09-04 |
| Campaign & Canvas Events | `canvas_experimentstep_splitentry` | Active | 273,240,650 | 112.03 | 2026-09-04 |
| Campaign & Canvas Events | `canvas_experimentstep_conversion` | Active | 82,040,674 | 43.53 | 2026-09-04 |
| Subscription & Webhook Events | `subscription_globalstatechange` | Active | 6,447,674 | 1.73 | 2026-09-04 |
| Subscription & Webhook Events | `subscriptiongroup_statechange` | Active | 2,694,055 | 0.71 | 2026-09-04 |
| Subscription & Webhook Events | `webhook_send` | Active | 26,228,680 | 10.49 | 2026-09-04 |
| Subscription & Webhook Events | `webhook_failure` | Active | 3,615,206 | 1.99 | 2026-09-04 |
| Subscription & Webhook Events | `webhook_abort` | Active | 13,484,778 | 6.70 | 2026-09-04 |
| Subscription & Webhook Events | `webhook_retry` | Empty | 0 | 0.00 | 2026-09-04 |
| WhatsApp Events (channel not in use - empty) | `whatsapp_send` | Empty | 0 | 0.00 | 2026-09-04 |
| WhatsApp Events (channel not in use - empty) | `whatsapp_delivery` | Empty | 0 | 0.00 | 2026-09-04 |
| WhatsApp Events (channel not in use - empty) | `whatsapp_read` | Empty | 0 | 0.00 | 2026-09-04 |
| WhatsApp Events (channel not in use - empty) | `whatsapp_click` | Empty | 0 | 0.00 | 2026-09-04 |
| WhatsApp Events (channel not in use - empty) | `whatsapp_inboundreceive` | Empty | 0 | 0.00 | 2026-09-04 |
| WhatsApp Events (channel not in use - empty) | `whatsapp_failure` | Empty | 0 | 0.00 | 2026-09-04 |
| WhatsApp Events (channel not in use - empty) | `whatsapp_abort` | Empty | 0 | 0.00 | 2026-09-04 |
| WhatsApp Events (channel not in use - empty) | `whatsapp_retry` | Empty | 0 | 0.00 | 2026-09-04 |
| LINE Events (channel not in use - empty) | `line_send` | Empty | 0 | 0.00 | 2026-09-04 |
| LINE Events (channel not in use - empty) | `line_click` | Empty | 0 | 0.00 | 2026-09-04 |
| LINE Events (channel not in use - empty) | `line_inboundreceive` | Empty | 0 | 0.00 | 2026-09-04 |
| LINE Events (channel not in use - empty) | `line_abort` | Empty | 0 | 0.00 | 2026-09-04 |
| LINE Events (channel not in use - empty) | `line_retry` | Empty | 0 | 0.00 | 2026-09-04 |
| Live Activity, Feature Flag & Agent Console (not in use - empty) | `liveactivity_send` | Empty | 0 | 0.00 | 2026-09-04 |
| Live Activity, Feature Flag & Agent Console (not in use - empty) | `liveactivity_outcome` | Empty | 0 | 0.00 | 2026-09-04 |
| Live Activity, Feature Flag & Agent Console (not in use - empty) | `liveactivity_pushtostarttokenchange` | Empty | 0 | 0.00 | 2026-09-04 |
| Live Activity, Feature Flag & Agent Console (not in use - empty) | `liveactivity_updatetokenchange` | Empty | 0 | 0.00 | 2026-09-04 |
| Live Activity, Feature Flag & Agent Console (not in use - empty) | `featureflag_impression` | Empty | 0 | 0.00 | 2026-09-04 |
| Live Activity, Feature Flag & Agent Console (not in use - empty) | `agentconsole_agentexecuted` | Empty | 0 | 0.00 | 2026-09-04 |
| Live Activity, Feature Flag & Agent Console (not in use - empty) | `agentconsole_toolinvocation` | Empty | 0 | 0.00 | 2026-09-04 |
| Custom Attribute Feeds (bz_cid_*) | `bz_cid_age_update` | Active | 76 | 0.00 | 2026-09-03 |
| Custom Attribute Feeds (bz_cid_*) | `bz_cid_gender_update` | Active | 126 | 0.00 | 2026-09-03 |
| Custom Attribute Feeds (bz_cid_*) | `bz_cid_is_employee_update` | Active | 11 | 0.00 | 2026-09-03 |
| Custom Attribute Feeds (bz_cid_*) | `bz_cid_has_fav_store_update` | Active | 289 | 0.00 | 2026-09-03 |
| Custom Attribute Feeds (bz_cid_*) | `bz_cid_weather_flag` | Active | 177,002 | 0.00 | 2026-09-03 |
| Custom Attribute Feeds (bz_cid_*) | `bz_cid_bgnbd_palive_churn` | Active | 2,429 | 0.00 | 2026-09-03 |
| Custom Attribute Feeds (bz_cid_*) | `bz_cid_favorite_category_ordered` | Active | 2,366 | 0.00 | 2026-09-03 |
| Custom Attribute Feeds (bz_cid_*) | `bz_cid_first_purch_cat_item` | Active | 3,580 | 0.00 | 2026-09-03 |
| Custom Attribute Feeds (bz_cid_*) | `bz_cid_purchased_core_category` | Active | 9,036 | 0.00 | 2026-09-03 |
| Custom Attribute Feeds (bz_cid_*) | `bz_cid_l90_total_eligible_orders_update` | Active | 17,935 | 0.00 | 2026-09-03 |
| Custom Attribute Feeds (bz_cid_*) | `bz_cid_nested_l90_menu_choices_update` | Active | 18,071 | 0.00 | 2026-09-03 |
| Custom Attribute Feeds (bz_cid_*) | `bz_cid_nested_l90_order_behaviors_update` | Active | 18,005 | 0.00 | 2026-09-03 |
| Custom Attribute Feeds (bz_cid_*) | `bz_cid_nested_l90_order_time_behaviors_update` | Active | 18,197 | 0.00 | 2026-09-03 |
| Custom Attribute Feeds (cdi_* / loyalty / other) | `cdi_order_attributes` | Active | 34,443 | 0.00 | 2026-09-03 |
| Custom Attribute Feeds (cdi_* / loyalty / other) | `cdi_cup_sales_data` | Active | 671 | 0.00 | 2026-09-03 |
| Custom Attribute Feeds (cdi_* / loyalty / other) | `cdi_l365_items_chipote_cups_bowls` | Active | 342,791 | 0.01 | 2026-09-03 |
| Custom Attribute Feeds (cdi_* / loyalty / other) | `cat_points_update` | Active | 44,689 | 0.00 | 2026-09-03 |
| Custom Attribute Feeds (cdi_* / loyalty / other) | `indiv_points_update` | Active | 1,112 | 0.00 | 2026-09-03 |
| Custom Attribute Feeds (cdi_* / loyalty / other) | `indiv_sessionm_user_id` | Active | 525 | 0.00 | 2026-09-03 |
| Custom Attribute Feeds (cdi_* / loyalty / other) | `first_purch_cat_update` | Active | 1,310 | 0.00 | 2026-09-03 |
| Custom Attribute Feeds (cdi_* / loyalty / other) | `is_vto_cust` | Active | 3,459 | 0.00 | 2026-09-03 |
| Custom Attribute Feeds (cdi_* / loyalty / other) | `l365_has_salad_order` | Active | 15,631 | 0.00 | 2026-09-03 |
| Pipeline / Raw / Audit (plumbing - never query for analysis) | `currents_raw` | Active | 612,095,363 | 327.92 | 2026-09-04 |
| Pipeline / Raw / Audit (plumbing - never query for analysis) | `load_watermark` | Active | 2 | 0.00 | 2026-09-04 |
| Pipeline / Raw / Audit (plumbing - never query for analysis) | `table_rec_cnt` | Active | 128 | 0.00 | 2025-06-09 |

---

## User Profile & Identity

### `users`

_Active - 4,316,908 rows, 2.12 GB, 27 columns, table._ User profile export - one row per user with profile attributes and nested JSON arrays for apps, devices, custom attributes, events, purchases, and message history. Profile sync, not a campaign event table.

| Column | Type | Description |
|---|---|---|
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id). |
| `braze_id` | STRING | Braze internal user ID. |
| `email` | STRING | User email. |
| `phone` | STRING | User phone number. |
| `created_at` | TIMESTAMP | Profile creation timestamp. |
| `random_bucket` | INT64 | Random bucket value for sampling/segmentation. |
| `time_zone` | STRING | User time zone. |
| `gender` | STRING | User gender. |
| `dob` | TIMESTAMP | Date of birth. |
| `language` | STRING | Preferred language. |
| `country` | STRING | Country of the user. |
| `home_city` | STRING | Home city. |
| `first_name` | STRING | First name. |
| `last_name` | STRING | Last name. |
| `email_subscribe` | STRING | Email subscription status (opted_in/subscribed/unsubscribed). |
| `email_unsubscribed_at` | TIMESTAMP | When the user unsubscribed from email. |
| `push_subscribe` | STRING | Push subscription status. |
| `push_opted_in_at` | TIMESTAMP | When the user opted in to push. |
| `user_aliases` | JSON | JSON array of user aliases. |
| `apps` | JSON | JSON array of apps the user has used. |
| `devices` | JSON | JSON array of the user's devices. |
| `custom_attributes` | JSON | JSON object of all custom attributes on the profile. |
| `custom_events` | JSON | JSON array of custom event summaries. |
| `purchases` | JSON | JSON array of purchase summaries. |
| `campaigns_received` | JSON | JSON array of campaigns the user received. |
| `canvases_received` | JSON | JSON array of Canvases the user received. |
| `cards_clicked` | JSON | JSON array of Content Cards the user clicked. |

### `stg_users`

_Active - 34,064,648 rows, 6.32 GB, 14 columns, table._ Staging snapshot of user profiles with parsed custom attributes and app usage structs. Plumbing - not for analysis.

| Column | Type | Description |
|---|---|---|
| `email_unsubscribed_at` | TIMESTAMP | When the user unsubscribed from email. |
| `custom_attributes` | STRUCT<encoded_cz_id STRING, amperity_id STRING, sessionM_userid STRING, primary_email STRING, churn_factor FLOAT64, points_balance FLOAT64, points_to_expire_EOM FLOAT64> | STRUCT of selected parsed custom attributes (encoded_cz_id, amperity_id, sessionM_userid, primary_email, churn_factor, points_balance, points_to_expire_EOM). |
| `push_subscribe` | STRING | Push subscription status. |
| `email_subscribe` | STRING | Email subscription status. |
| `phone` | INT64 | User phone number. |
| `created_at` | TIMESTAMP | Profile creation timestamp. |
| `push_opted_in_at` | TIMESTAMP | When the user opted in to push. |
| `external_id` | STRING | Cafe Zupas customer ID. |
| `time_zone` | STRING | User time zone. |
| `braze_id` | STRING | Braze internal user ID. |
| `email` | STRING | User email. |
| `random_bucket` | INT64 | Random bucket value. |
| `push_unsubscribed_at` | TIMESTAMP | When the user unsubscribed from push. |
| `apps` | ARRAY<STRUCT<name STRING, platform STRING, version STRING, sessions INT64, first_used TIMESTAMP, last_used TIMESTAMP>> | ARRAY of STRUCTs describing each app the user used (name, platform, version, sessions, first_used, last_used). |

### `stg_external_ids`

_Empty - 0 rows, 0.00 GB, 1 columns, external._ External table (staging) holding the set of external (customer) IDs. Empty as of generation. Plumbing - not for analysis.

| Column | Type | Description |
|---|---|---|
| `external_id` | INT64 | Cafe Zupas customer ID (numeric). |

### `global_holdout`

_Active - 162,885 rows, 0.01 GB, 6 columns, table._ Users assigned to the global holdout group, who are withheld from messaging for incrementality measurement.

| Column | Type | Description |
|---|---|---|
| `braze_id` | STRING | Braze internal user ID. |
| `created_at` | TIMESTAMP | When the user was added to the holdout. |
| `email` | STRING | User email. |
| `external_id` | STRING | Cafe Zupas customer ID. |
| `phone` | STRING | User phone number. |
| `random_bucket` | FLOAT64 | Random bucket value used for holdout assignment. |

### `randombucketnumberupdate`

_Active - 5,775,290 rows, 0.83 GB, 10 columns, table._ Logs changes to a user's random bucket number (used for random sampling/segmentation), with previous value.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `random_bucket_number` | INT64 | New random bucket number assigned to the user. |
| `prev_random_bucket_number` | INT64 | Previous random bucket number. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |


## App / Session, Purchase & Device Events

### `app_firstsession`

_Active - 10,720,570 rows, 3.27 GB, 21 columns, table._ Records the first app session ever logged for a user, including the originating device, locale, and SDK details.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `session_id` | STRING | Identifier of the session. |
| `gender` | STRING | User gender at first session. |
| `country` | STRING | Country of the user. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `language` | STRING | User language. |
| `device_id` | STRING | Braze device identifier. |
| `sdk_version` | STRING | Braze SDK version on the device. |
| `platform` | STRING | Device platform (e.g., iOS, Android, Web). |
| `os_version` | STRING | Operating system version of the device. |
| `device_model` | STRING | Device model. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `app_sessionstart`

_Active - 44,820,301 rows, 12.97 GB, 15 columns, table._ Logged when an app session begins.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `session_id` | STRING | Identifier of the session. |
| `platform` | STRING | Device platform (e.g., iOS, Android, Web). |
| `os_version` | STRING | Operating system version of the device. |
| `device_model` | STRING | Device model. |
| `device_id` | STRING | Braze device identifier. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `app_sessionend`

_Active - 35,953,315 rows, 10.78 GB, 16 columns, table._ Logged when an app session ends, including session duration.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `duration` | FLOAT64 | Session length in seconds. |
| `session_id` | STRING | Identifier of the session. |
| `platform` | STRING | Device platform (e.g., iOS, Android, Web). |
| `os_version` | STRING | Operating system version of the device. |
| `device_model` | STRING | Device model. |
| `device_id` | STRING | Braze device identifier. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `uninstall`

_Active - 259,892 rows, 0.05 GB, 11 columns, table._ App uninstall event for a user/device.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `device_id` | STRING | Braze device identifier. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `customevent`

_Active - 110,773,033 rows, 54.74 GB, 21 columns, table._ Custom events tracked from the apps or API. The name column holds the event name and properties holds the event payload.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `platform` | STRING | Device platform (e.g., iOS, Android, Web). |
| `os_version` | STRING | Operating system version of the device. |
| `device_model` | STRING | Device model. |
| `device_id` | STRING | Braze device identifier. |
| `name` | STRING | Name of the custom event. |
| `properties` | STRING | Custom event properties (JSON string). |
| `ad_id` | STRING | Advertising identifier (IDFA/GAID) of the device. |
| `ad_id_type` | STRING | Type of advertising identifier (e.g., idfa, google_ad_id). |
| `ad_tracking_enabled` | BOOL | Whether ad tracking is enabled on the device. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `purchase`

_Active - 15,265,299 rows, 12.55 GB, 21 columns, table._ Purchase/revenue event with product, price, and currency.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `platform` | STRING | Device platform (e.g., iOS, Android, Web). |
| `os_version` | STRING | Operating system version of the device. |
| `device_model` | STRING | Device model. |
| `device_id` | STRING | Braze device identifier. |
| `product_id` | STRING | Identifier of the purchased product. |
| `price` | FLOAT64 | Purchase price. |
| `currency` | STRING | ISO currency code of the price. |
| `properties` | STRING | Purchase properties (JSON string). |
| `ad_id` | STRING | Advertising identifier (IDFA/GAID) of the device. |
| `ad_id_type` | STRING | Type of advertising identifier (e.g., idfa, google_ad_id). |
| `ad_tracking_enabled` | BOOL | Whether ad tracking is enabled on the device. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `location`

_Active - 524,277 rows, 0.15 GB, 23 columns, table._ Device location events (latitude/longitude/altitude with accuracy).

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `ad_id` | STRING | Advertising identifier (IDFA/GAID) of the device. |
| `ad_id_type` | STRING | Type of advertising identifier (e.g., idfa, google_ad_id). |
| `ad_tracking_enabled` | BOOL | Whether ad tracking is enabled on the device. |
| `alt_accuracy` | FLOAT64 | Altitude accuracy in meters. |
| `altitude` | FLOAT64 | Altitude. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `device_model` | STRING | Device model. |
| `latitude` | FLOAT64 | Latitude. |
| `ll_accuracy` | FLOAT64 | Horizontal (lat/long) accuracy in meters. |
| `longitude` | FLOAT64 | Longitude. |
| `os_version` | STRING | Operating system version of the device. |
| `platform` | STRING | Device platform (e.g., iOS, Android, Web). |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `pushnotification_tokenstatechange`

_Active - 264,797 rows, 0.10 GB, 24 columns, table._ Push token lifecycle changes (created, updated, invalidated) for mobile and web push.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `ios_push_token_apns_gateway` | INT64 | APNs gateway (production/sandbox) for the iOS token. |
| `platform` | STRING | Device platform (e.g., iOS, Android, Web). |
| `push_token` | STRING | Device push token. |
| `push_token_created_at` | INT64 | Epoch time the push token was created. |
| `push_token_device_id` | STRING | Device ID associated with the push token. |
| `push_token_foreground_push_disabled` | BOOL | Whether foreground push is disabled for this token. |
| `push_token_provisionally_opted_in` | BOOL | Whether the token is provisionally (quiet) opted in (iOS). |
| `push_token_state_change_type` | STRING | Type of push token state change (e.g., created, updated, invalidated). |
| `push_token_updated_at` | INT64 | Epoch time the push token was last updated. |
| `time_ms` | INT64 | Unix epoch timestamp in milliseconds (UTC). |
| `web_push_token_public_key` | STRING | Web push token public key. |
| `web_push_token_user_auth` | STRING | Web push token user auth secret. |
| `web_push_token_vapid_public_key` | STRING | VAPID public key for web push. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `installattribution`

_Empty - 0 rows, 0.00 GB, 12 columns, table._ App install attribution source. Not in use - empty.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `source` | STRING | Install attribution source. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |


## Email Events

### `email_send`

_Active - 262,125,719 rows, 123.13 GB, 33 columns, table._ Email handed off to the email service provider for delivery.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `email_address` | STRING | Recipient email address. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `ip_pool` | STRING | Sending IP pool used by the email service provider. |
| `message_extras` | STRING | Custom key-value metadata attached to the message (JSON string). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `domain` | STRING | Recipient email domain. |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `device_id` | STRING | Braze device identifier. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `email_delivery`

_Active - 257,597,349 rows, 133.54 GB, 35 columns, table._ Email accepted/delivered by the receiving mail server.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `email_address` | STRING | Recipient email address. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `sending_ip` | STRING | Specific IP address the email was sent from. |
| `ip_pool` | STRING | Sending IP pool used by the email service provider. |
| `esp` | STRING | Email service provider that handled the message. |
| `from_domain` | STRING | Sending (from) domain of the email. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `domain` | STRING | Recipient email domain. |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `device_id` | STRING | Braze device identifier. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `email_open`

_Active - 188,896,068 rows, 110.22 GB, 41 columns, table._ Email open event (includes machine/proxy-open detection via machine_open).

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `email_address` | STRING | Recipient email address. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `user_agent` | STRING | User-agent string captured for the event. |
| `ip_pool` | STRING | Sending IP pool used by the email service provider. |
| `machine_open` | STRING | STRING 'true' when the open is a machine/proxy open (e.g., Apple Mail Privacy Protection) rather than a human open. is_machine_open = coalesce(lower(machine_open)='true', false). |
| `esp` | STRING | Email service provider that handled the message. |
| `from_domain` | STRING | Sending (from) domain of the email. |
| `is_amp` | BOOL | TRUE if the open came from an AMP email. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `device_class` | STRING | Class of device. |
| `device_os` | STRING | Device OS. |
| `device_model` | STRING | Device model. |
| `browser` | STRING | Browser used. |
| `mailbox_provider` | STRING | Mailbox provider. |
| `domain` | STRING | Recipient email domain. |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `email_click`

_Active - 2,178,290 rows, 1.90 GB, 46 columns, table._ Email link click event, including the clicked URL, device/client details, and bot-click detection.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `email_address` | STRING | Recipient email address. |
| `url` | STRING | URL that was clicked. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `user_agent` | STRING | User-agent string captured for the event. |
| `ip_pool` | STRING | Sending IP pool used by the email service provider. |
| `link_id` | STRING | Identifier of the tracked link. |
| `link_alias` | STRING | Alias/label of the tracked link. |
| `esp` | STRING | Email service provider that handled the message. |
| `from_domain` | STRING | Sending (from) domain of the email. |
| `is_amp` | BOOL | TRUE if the click came from an AMP email. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `device_class` | STRING | Class of device (e.g., mobile, desktop). |
| `device_os` | STRING | Device operating system. |
| `device_model` | STRING | Device model. |
| `browser` | STRING | Browser used. |
| `mailbox_provider` | STRING | Mailbox provider (e.g., Gmail). |
| `domain` | STRING | Recipient email domain. |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `device_id` | STRING | Braze device identifier. |
| `is_suspected_bot_click` | BOOL | TRUE if Braze flagged the click as a suspected bot / security-scanner click rather than a human click. Exclude for human engagement. |
| `suspected_bot_click_reason` | ARRAY<STRING> | Reason(s) the click was flagged as a suspected bot click. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `email_bounce`

_Active - 68,724 rows, 0.04 GB, 37 columns, table._ Hard bounce - the email was permanently rejected by the receiving server.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `email_address` | STRING | Recipient email address. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `sending_ip` | STRING | Specific IP address the email was sent from. |
| `ip_pool` | STRING | Sending IP pool used by the email service provider. |
| `bounce_reason` | STRING | Reason text for the bounce. |
| `esp` | STRING | Email service provider that handled the message. |
| `from_domain` | STRING | Sending (from) domain of the email. |
| `is_drop` | BOOL | TRUE if the message was dropped rather than attempted. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `domain` | STRING | Recipient email domain. |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `device_id` | STRING | Braze device identifier. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `email_softbounce`

_Active - 4,668,963 rows, 3.21 GB, 36 columns, table._ Soft bounce - temporary delivery failure (e.g., full mailbox).

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `email_address` | STRING | Recipient email address. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `sending_ip` | STRING | Specific IP address the email was sent from. |
| `ip_pool` | STRING | Sending IP pool used by the email service provider. |
| `bounce_reason` | STRING | Reason text for the soft bounce. |
| `esp` | STRING | Email service provider that handled the message. |
| `from_domain` | STRING | Sending (from) domain of the email. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `domain` | STRING | Recipient email domain. |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `device_id` | STRING | Braze device identifier. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `email_deferral`

_Active - 806,208 rows, 0.64 GB, 31 columns, table._ Email temporarily deferred by the receiving server (will be retried), with attempt count and reason.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `attempt_count` | INT64 | Number of delivery attempts made so far. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `deferral_reason` | STRING | Reason the receiving server deferred the email. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `email_address` | STRING | Recipient email address. |
| `esp` | STRING | Email service provider that handled the message. |
| `from_domain` | STRING | Sending (from) domain of the email. |
| `ip_pool` | STRING | Sending IP pool used by the email service provider. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `recipient_domain` | STRING | Recipient email domain. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `sending_ip` | STRING | Specific IP address the email was sent from. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `email_markasspam`

_Active - 20,786 rows, 0.01 GB, 35 columns, table._ Recipient marked the email as spam.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `email_address` | STRING | Recipient email address. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `user_agent` | STRING | User-agent string captured for the event. |
| `ip_pool` | STRING | Sending IP pool used by the email service provider. |
| `esp` | STRING | Email service provider that handled the message. |
| `from_domain` | STRING | Sending (from) domain of the email. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `domain` | STRING | Recipient email domain. |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `device_id` | STRING | Braze device identifier. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `email_unsubscribe`

_Active - 1,166,091 rows, 0.54 GB, 32 columns, table._ Recipient unsubscribed via this email.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `email_address` | STRING | Recipient email address. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `ip_pool` | STRING | Sending IP pool used by the email service provider. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `domain` | STRING | Recipient email domain. |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `device_id` | STRING | Braze device identifier. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `email_abort`

_Active - 3,803,435 rows, 2.26 GB, 35 columns, table._ Email that was aborted before delivery (e.g., suppressed, rate-limited, or invalid), with the abort reason.

| Column | Type | Description |
|---|---|---|
| `abort_log` | STRING | Detailed log message explaining the abort. |
| `abort_type` | STRING | Category of the abort reason. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_message_variation_id` | STRING | Message variation ID within the Canvas step. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `device_id` | STRING | Braze device identifier. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `email_address` | STRING | Recipient email address. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `ip_pool` | STRING | Sending IP pool used by the email service provider. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `domain` | STRING | Recipient email domain. |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `email_retry`

_Empty - 0 rows, 0.00 GB, 28 columns, table._ Email send retry event. Empty as of generation.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `email_address` | STRING | Recipient email address. |
| `ip_pool` | STRING | Sending IP pool used by the email service provider. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `retry_log` | STRING | Detailed log message for the retry. |
| `retry_type` | STRING | Category of the retry reason. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |


## Push Notification Events

### `pushnotification_send`

_Active - 88,485,565 rows, 44.74 GB, 37 columns, table._ Push notification sent to the push provider.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `platform` | STRING | Device platform (e.g., iOS, Android, Web). |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `device_id` | STRING | Braze device identifier. |
| `ad_id` | STRING | Advertising identifier (IDFA/GAID) of the device. |
| `ad_id_type` | STRING | Type of advertising identifier (e.g., idfa, google_ad_id). |
| `ad_tracking_enabled` | BOOL | Whether ad tracking is enabled on the device. |
| `message_extras` | STRING | Custom key-value metadata attached to the message (JSON string). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `locale_key` | STRING | Locale key used to localize the message. |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `push_token` | STRING | Device push token. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `pushnotification_open`

_Active - 586,670 rows, 0.32 GB, 39 columns, table._ Push notification open/tap event, including the button tapped.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_step_message_variation_id` | STRING | Message variation ID within the Canvas step. |
| `platform` | STRING | Device platform (e.g., iOS, Android, Web). |
| `os_version` | STRING | Operating system version of the device. |
| `device_model` | STRING | Device model. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `device_id` | STRING | Braze device identifier. |
| `button_action_type` | STRING | Action type of the tapped push button. |
| `button_string` | STRING | Label of the tapped push button. |
| `ad_id` | STRING | Advertising identifier (IDFA/GAID) of the device. |
| `ad_id_type` | STRING | Type of advertising identifier (e.g., idfa, google_ad_id). |
| `ad_tracking_enabled` | BOOL | Whether ad tracking is enabled on the device. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `pushnotification_bounce`

_Active - 188,756 rows, 0.09 GB, 35 columns, table._ Push notification bounce (token rejected/invalid).

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `platform` | STRING | Device platform (e.g., iOS, Android, Web). |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `device_id` | STRING | Braze device identifier. |
| `ad_id` | STRING | Advertising identifier (IDFA/GAID) of the device. |
| `ad_id_type` | STRING | Type of advertising identifier (e.g., idfa, google_ad_id). |
| `ad_tracking_enabled` | BOOL | Whether ad tracking is enabled on the device. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `push_token` | STRING | Device push token. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `pushnotification_abort`

_Active - 347,627 rows, 0.21 GB, 34 columns, table._ Push notification aborted before send, with the abort reason.

| Column | Type | Description |
|---|---|---|
| `abort_log` | STRING | Detailed log message explaining the abort. |
| `abort_type` | STRING | Category of the abort reason. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_message_variation_id` | STRING | Message variation ID within the Canvas step. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `device_id` | STRING | Braze device identifier. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `platform` | STRING | Device platform (e.g., iOS, Android, Web). |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `pushnotification_iosforeground`

_Empty - 0 rows, 0.00 GB, 31 columns, table._ Push received while the iOS app was in the foreground. Empty as of generation.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `ad_id` | STRING | Advertising identifier (IDFA/GAID) of the device. |
| `ad_id_type` | STRING | Type of advertising identifier (e.g., idfa, google_ad_id). |
| `ad_tracking_enabled` | BOOL | Whether ad tracking is enabled on the device. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `device_model` | STRING | Device model. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `os_version` | STRING | Operating system version of the device. |
| `platform` | STRING | Device platform (e.g., iOS, Android, Web). |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `pushnotification_retry`

_Empty - 0 rows, 0.00 GB, 28 columns, table._ Push send retry event. Empty as of generation.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `platform` | STRING | Device platform (e.g., iOS, Android, Web). |
| `retry_log` | STRING | Detailed log message for the retry. |
| `retry_type` | STRING | Category of the retry reason. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |


## SMS Events

### `sms_send`

_Active - 3,613,599 rows, 1.66 GB, 33 columns, table._ SMS sent to the SMS provider. NOTE: since the 2026-07 streaming switch RCS carries most text volume (~4x SMS) - any text-campaign question must include rcs_* too.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `to_phone_number` | STRING | Destination phone number (E.164). |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `category` | STRING | Message category/classification. |
| `message_extras` | STRING | Custom key-value metadata attached to the message (JSON string). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `device_id` | STRING | Braze device identifier. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `sms_carriersend`

_Empty - 0 rows, 0.00 GB, 27 columns, table._ SMS handed to the carrier. Empty as of generation.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `from_phone_number` | STRING | Origination phone number used to send the message. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `to_phone_number` | STRING | Destination phone number (E.164). |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `sms_delivery`

_Active - 3,387,223 rows, 1.57 GB, 33 columns, table._ SMS delivered to the carrier/recipient. is_sms_fallback marks RCS-to-SMS fallbacks.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `to_phone_number` | STRING | Destination phone number (E.164). |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `from_phone_number` | STRING | Origination phone number used to send the message. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `device_id` | STRING | Braze device identifier. |
| `is_sms_fallback` | BOOL | TRUE if this SMS was sent as a fallback after an RCS message could not be delivered. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `sms_deliveryfailure`

_Active - 65,398 rows, 0.04 GB, 34 columns, table._ SMS delivery failure with carrier error code and message.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `to_phone_number` | STRING | Destination phone number (E.164). |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `error` | STRING | Error message. |
| `provider_error_code` | STRING | Provider/carrier error code. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `device_id` | STRING | Braze device identifier. |
| `is_sms_fallback` | BOOL | TRUE if this SMS was sent as a fallback after an RCS message could not be delivered. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `sms_rejection`

_Active - 359,564 rows, 0.17 GB, 35 columns, table._ SMS rejected by the provider before delivery, with error details.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `to_phone_number` | STRING | Destination phone number (E.164). |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `from_phone_number` | STRING | Origination phone number used to send the message. |
| `error` | STRING | Error message. |
| `provider_error_code` | STRING | Provider/carrier error code. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `device_id` | STRING | Braze device identifier. |
| `is_sms_fallback` | BOOL | TRUE if this SMS was sent as a fallback after an RCS message could not be delivered. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `sms_abort`

_Active - 1,366 rows, 0.00 GB, 28 columns, table._ SMS aborted before send, with the abort reason.

| Column | Type | Description |
|---|---|---|
| `abort_log` | STRING | Detailed log message explaining the abort. |
| `abort_type` | STRING | Category of the abort reason. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_message_variation_id` | STRING | Message variation ID within the Canvas step. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `sms_retry`

_Empty - 0 rows, 0.00 GB, 23 columns, table._ SMS send retry event. Empty as of generation.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `retry_log` | STRING | Detailed log message for the retry. |
| `retry_type` | STRING | Category of the retry reason. |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `sms_inboundreceive`

_Active - 65,612 rows, 0.03 GB, 30 columns, table._ Inbound SMS received from a user (e.g., keyword replies like STOP/HELP), including message body and any media.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `user_phone_number` | STRING | The user's phone number. |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `inbound_phone_number` | STRING | Braze number that received the inbound message. |
| `action` | STRING | Parsed action/keyword from the inbound message (e.g., STOP, HELP). |
| `message_body` | STRING | Text body of the inbound message. |
| `media_urls` | ARRAY<STRING> | Array of media (MMS) URLs included in the message. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `sms_shortlinkclick`

_Active - 217,395 rows, 0.13 GB, 33 columns, table._ Click on a Braze SMS short link, including resolved URL and bot-click detection.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `url` | STRING | Resolved destination URL. |
| `short_url` | STRING | The Braze short link that was clicked. |
| `user_agent` | STRING | User-agent string captured for the event. |
| `user_phone_number` | STRING | The user's phone number. |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `device_id` | STRING | Braze device identifier. |
| `is_suspected_bot_click` | BOOL | TRUE if Braze flagged the click as a suspected bot / security-scanner click rather than a human click. Exclude for human engagement. |
| `suspected_bot_click_reason` | ARRAY<STRING> | Reason(s) the click was flagged as a suspected bot click. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |


## RCS Events

### `rcs_send`

_Active - 50,312 rows, 0.03 GB, 28 columns, table._ RCS (rich communication services) message sent to the provider. Carries most text-message volume since 2026-07.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `category` | STRING | Message category/classification. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `from_rcs_sender` | STRING | RCS sender/agent identity the message was sent from. |
| `message_extras` | STRING | Custom key-value metadata attached to the message (JSON string). |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `to_phone_number` | STRING | Destination phone number (E.164). |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `rcs_delivery`

_Active - 44,464 rows, 0.02 GB, 26 columns, table._ RCS message delivered.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `from_rcs_sender` | STRING | RCS sender/agent identity the message was sent from. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `to_phone_number` | STRING | Destination phone number (E.164). |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `rcs_read`

_Active - 9,882 rows, 0.00 GB, 21 columns, table._ RCS read receipt - a genuine device signal that the recipient viewed the message (treated as an open; never a machine open).

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `to_phone_number` | STRING | Destination phone number (E.164). |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `rcs_click`

_Active - 6,347 rows, 0.00 GB, 32 columns, table._ RCS click / interaction with a suggestion, button, or link, with bot-click detection.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `element_label` | STRING | Label of the RCS element (button/suggestion) interacted with. |
| `element_type` | STRING | Type of RCS element interacted with. |
| `interaction_type` | STRING | Type of RCS interaction (e.g., suggestion tap, link click). |
| `is_suspected_bot_click` | BOOL | TRUE if Braze flagged the click as a suspected bot / security-scanner click rather than a human click. Exclude for human engagement. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `short_url` | STRING | The Braze short link that was clicked. |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `suspected_bot_click_reason` | ARRAY<STRING> | Reason(s) the click was flagged as a suspected bot click. |
| `url` | STRING | Resolved destination URL. |
| `user_agent` | STRING | User-agent string captured for the event. |
| `user_phone_number` | STRING | The user's phone number. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `rcs_inboundreceive`

_Active - 1,961 rows, 0.00 GB, 27 columns, table._ Inbound RCS message received from a user.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `action` | STRING | Parsed action/keyword from the inbound message (e.g., STOP, HELP). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `media_urls` | ARRAY<STRING> | Array of media (MMS) URLs included in the message. |
| `message_body` | STRING | Text body of the inbound message. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `to_rcs_sender` | STRING | RCS sender/agent identity the inbound message was sent to. |
| `user_phone_number` | STRING | The user's phone number. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `rcs_rejection`

_Active - 5,845 rows, 0.00 GB, 29 columns, table._ RCS message rejected by the provider; is_sms_fallback indicates whether it fell back to SMS.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `error` | STRING | Error message. |
| `from_rcs_sender` | STRING | RCS sender/agent identity the message was sent from. |
| `is_sms_fallback` | BOOL | TRUE if this SMS was sent as a fallback after an RCS message could not be delivered. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `provider_error_code` | STRING | Provider/carrier error code. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `to_phone_number` | STRING | Destination phone number (E.164). |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `rcs_abort`

_Active - 9 rows, 0.00 GB, 23 columns, table._ RCS message aborted before send.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `abort_log` | STRING | Detailed log message explaining the abort. |
| `abort_type` | STRING | Category of the abort reason. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |


## Banner Events

### `banner_impression`

_Active - 135,515 rows, 0.07 GB, 32 columns, table._ Banner impression - the Banner channel (on-site / in-app banners) was rendered for the user. No send event exists; this is the exposure event.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `ad_id` | STRING | Advertising identifier (IDFA/GAID) of the device. |
| `ad_id_type` | STRING | Type of advertising identifier (e.g., idfa, google_ad_id). |
| `ad_tracking_enabled` | BOOL | Whether ad tracking is enabled on the device. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `banner_placement_id` | STRING | ID of the Banner placement where the banner was rendered. |
| `browser` | STRING | Browser used. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_message_variation_api_id` | STRING | Public API ID of the message variation within the Canvas step. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `device_model` | STRING | Device model. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `os_version` | STRING | Operating system version of the device. |
| `platform` | STRING | Device platform (e.g., iOS, Android, Web). |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `banner_click`

_Active - 5,347 rows, 0.00 GB, 33 columns, table._ Banner click event.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `ad_id` | STRING | Advertising identifier (IDFA/GAID) of the device. |
| `ad_id_type` | STRING | Type of advertising identifier (e.g., idfa, google_ad_id). |
| `ad_tracking_enabled` | BOOL | Whether ad tracking is enabled on the device. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `banner_placement_id` | STRING | ID of the Banner placement where the banner was rendered. |
| `browser` | STRING | Browser used. |
| `button_id` | STRING | Identifier of the button interacted with. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_message_variation_api_id` | STRING | Public API ID of the message variation within the Canvas step. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `device_model` | STRING | Device model. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `os_version` | STRING | Operating system version of the device. |
| `platform` | STRING | Device platform (e.g., iOS, Android, Web). |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `banner_dismiss`

_Empty - 0 rows, 0.00 GB, 39 columns, table._ Banner dismissed by the user. Empty as of generation.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `ad_id` | STRING | Advertising identifier (IDFA/GAID) of the device. |
| `ad_id_type` | STRING | Type of advertising identifier (e.g., idfa, google_ad_id). |
| `ad_tracking_enabled` | BOOL | Whether ad tracking is enabled on the device. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `banner_placement_id` | STRING | ID of the Banner placement where the banner was rendered. |
| `browser` | STRING | Browser used. |
| `button_id` | STRING | Identifier of the button interacted with. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_message_variation_api_id` | STRING | Public API ID of the message variation within the Canvas step. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `carrier` | STRING | Mobile carrier. |
| `country` | STRING | Country of the user. |
| `device_model` | STRING | Device model. |
| `gender` | STRING | User gender. |
| `language` | STRING | User language. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `os_version` | STRING | Operating system version of the device. |
| `platform` | STRING | Device platform (e.g., iOS, Android, Web). |
| `resolution` | STRING | Device screen resolution. |
| `sdk_version` | STRING | Braze SDK version on the device. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `banner_abort`

_Empty - 0 rows, 0.00 GB, 34 columns, table._ Banner render aborted. Empty as of generation.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `abort_log` | STRING | Detailed log message explaining the abort. |
| `abort_type` | STRING | Category of the abort reason. |
| `ad_id` | STRING | Advertising identifier (IDFA/GAID) of the device. |
| `ad_id_type` | STRING | Type of advertising identifier (e.g., idfa, google_ad_id). |
| `ad_tracking_enabled` | BOOL | Whether ad tracking is enabled on the device. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `banner_placement_id` | STRING | ID of the Banner placement where the banner was rendered. |
| `browser` | STRING | Browser used. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_message_variation_api_id` | STRING | Public API ID of the message variation within the Canvas step. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `device_model` | STRING | Device model. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `os_version` | STRING | Operating system version of the device. |
| `platform` | STRING | Device platform (e.g., iOS, Android, Web). |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |


## Content Card & In-App Message Events

### `contentcard_send`

_Active - 142,312,565 rows, 63.30 GB, 31 columns, table._ Content Card send event.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `content_card_id` | STRING | Identifier of the Content Card. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `device_id` | STRING | Braze device identifier. |
| `message_extras` | STRING | Custom key-value metadata attached to the message (JSON string). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `contentcard_impression`

_Active - 1,528,020 rows, 0.86 GB, 37 columns, table._ Content Card impression (view) event.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `content_card_id` | STRING | Identifier of the Content Card. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `device_id` | STRING | Braze device identifier. |
| `platform` | STRING | Device platform (e.g., iOS, Android, Web). |
| `os_version` | STRING | Operating system version of the device. |
| `device_model` | STRING | Device model. |
| `ad_id` | STRING | Advertising identifier (IDFA/GAID) of the device. |
| `ad_id_type` | STRING | Type of advertising identifier (e.g., idfa, google_ad_id). |
| `ad_tracking_enabled` | BOOL | Whether ad tracking is enabled on the device. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `contentcard_click`

_Active - 873,784 rows, 0.47 GB, 37 columns, table._ Content Card click event.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `content_card_id` | STRING | Identifier of the Content Card. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `device_id` | STRING | Braze device identifier. |
| `platform` | STRING | Device platform (e.g., iOS, Android, Web). |
| `os_version` | STRING | Operating system version of the device. |
| `device_model` | STRING | Device model. |
| `ad_id` | STRING | Advertising identifier (IDFA/GAID) of the device. |
| `ad_id_type` | STRING | Type of advertising identifier (e.g., idfa, google_ad_id). |
| `ad_tracking_enabled` | BOOL | Whether ad tracking is enabled on the device. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `contentcard_dismiss`

_Empty - 0 rows, 0.00 GB, 32 columns, table._ Content Card dismissed by the user. Empty as of generation.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `ad_id` | STRING | Advertising identifier (IDFA/GAID) of the device. |
| `ad_id_type` | STRING | Type of advertising identifier (e.g., idfa, google_ad_id). |
| `ad_tracking_enabled` | BOOL | Whether ad tracking is enabled on the device. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `content_card_id` | STRING | Identifier of the Content Card. |
| `device_model` | STRING | Device model. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `os_version` | STRING | Operating system version of the device. |
| `platform` | STRING | Device platform (e.g., iOS, Android, Web). |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `contentcard_abort`

_Empty - 0 rows, 0.00 GB, 26 columns, table._ Content Card send aborted before delivery. Empty as of generation.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `abort_log` | STRING | Detailed log message explaining the abort. |
| `abort_type` | STRING | Category of the abort reason. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `inappmessage_impression`

_Active - 1,850,531 rows, 0.82 GB, 39 columns, table._ In-app message impression (view) event.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `card_id` | STRING | Identifier of the in-app message card. |
| `platform` | STRING | Device platform (e.g., iOS, Android, Web). |
| `os_version` | STRING | Operating system version of the device. |
| `device_model` | STRING | Device model. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `device_id` | STRING | Braze device identifier. |
| `ad_id` | STRING | Advertising identifier (IDFA/GAID) of the device. |
| `ad_id_type` | STRING | Type of advertising identifier (e.g., idfa, google_ad_id). |
| `ad_tracking_enabled` | BOOL | Whether ad tracking is enabled on the device. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `message_extras` | STRING | Custom key-value metadata attached to the message (JSON string). |
| `locale_key` | STRING | Locale key used to localize the message. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `inappmessage_click`

_Active - 1,208,507 rows, 0.54 GB, 38 columns, table._ In-app message click event.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `card_id` | STRING | Identifier of the in-app message card. |
| `platform` | STRING | Device platform (e.g., iOS, Android, Web). |
| `os_version` | STRING | Operating system version of the device. |
| `device_model` | STRING | Device model. |
| `button_id` | STRING | Identifier of the button interacted with. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `device_id` | STRING | Braze device identifier. |
| `ad_id` | STRING | Advertising identifier (IDFA/GAID) of the device. |
| `ad_id_type` | STRING | Type of advertising identifier (e.g., idfa, google_ad_id). |
| `ad_tracking_enabled` | BOOL | Whether ad tracking is enabled on the device. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `inappmessage_abort`

_Active - 109 rows, 0.00 GB, 34 columns, table._ In-app message aborted before display, with the abort reason.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `abort_log` | STRING | Detailed log message explaining the abort. |
| `abort_type` | STRING | Category of the abort reason. |
| `ad_id` | STRING | Advertising identifier (IDFA/GAID) of the device. |
| `ad_id_type` | STRING | Type of advertising identifier (e.g., idfa, google_ad_id). |
| `ad_tracking_enabled` | BOOL | Whether ad tracking is enabled on the device. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `card_id` | STRING | Identifier of the in-app message card. |
| `device_model` | STRING | Device model. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `os_version` | STRING | Operating system version of the device. |
| `platform` | STRING | Device platform (e.g., iOS, Android, Web). |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |


## Campaign & Canvas Events

### `campaigns_conversion`

_Active - 10,226,635 rows, 4.28 GB, 20 columns, table._ A conversion event attributed to a Braze campaign (the user performed the campaign's configured conversion behavior).

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `conversion_behavior_index` | INT64 | Index (0-based) of the conversion behavior that fired for the campaign. |
| `conversion_behavior` | STRING | JSON describing the configured conversion behavior. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `campaigns_enrollincontrol`

_Active - 99,070 rows, 0.04 GB, 19 columns, table._ Records when a user was placed in a campaign's control (holdout) group and intentionally not messaged.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `device_id` | STRING | Braze device identifier. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `canvas_entry`

_Active - 893,121,682 rows, 286.23 GB, 18 columns, table._ Logged when a user enters a Canvas, including whether they landed in the control group. Very large (~890M rows) - always partition-filter. Had duplicate ids under investigation 2026-07-28; count distinct id.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `in_control_group` | BOOL | TRUE if the user entered the Canvas control group. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `canvasstep_progression`

_Active - 286,904,816 rows, 123.35 GB, 21 columns, table._ Canvas step progression - one row each time a user advances from a Canvas step to the next (or exits). Very large (~287M rows); the most granular view of journey flow.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `canvas_entry_id` | STRING | ID of the specific Canvas entry (journey run) for the user. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `exit_reason` | STRING | Reason the user exited the Canvas, if this progression is an exit. |
| `is_canvas_entry` | STRING | Whether this progression record is the entry into the Canvas. |
| `next_step_id` | STRING | ID of the next Canvas step the user progressed to. |
| `progression_type` | STRING | Type of progression (e.g., advanced to next step, exited). |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `canvas_conversion`

_Active - 16,246,267 rows, 8.65 GB, 20 columns, table._ A conversion event attributed to a Braze Canvas (journey).

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `conversion_behavior_index` | INT64 | Index of the conversion behavior that fired. |
| `conversion_behavior` | STRING | JSON describing the configured conversion behavior. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `canvas_exit_performedevent`

_Active - 84,767 rows, 0.03 GB, 19 columns, table._ Logged when a user exits a Canvas because they performed a configured exit event.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `app_group_api_id` | STRING | Public API identifier of the Braze app group. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_api_id` | STRING | Public API ID of the Canvas. |
| `canvas_variation_api_id` | STRING | Public API ID of the Canvas variation. |
| `canvas_step_api_id` | STRING | Public API ID of the Canvas step. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `canvas_exit_matchedaudience`

_Active - 532 rows, 0.00 GB, 16 columns, table._ Logged when a user exits a Canvas because they matched a configured exit audience.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `canvas_experimentstep_splitentry`

_Active - 273,240,650 rows, 112.03 GB, 18 columns, table._ Records the experiment-path split a user was assigned to at a Canvas Experiment step.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `experiment_step_id` | STRING | ID of the Canvas Experiment step. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `experiment_split_id` | STRING | ID of the assigned split path. |
| `experiment_split_name` | STRING | Name of the assigned split path. |
| `in_control_group` | BOOL | TRUE if assigned to the control split. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `canvas_experimentstep_conversion`

_Active - 82,040,674 rows, 43.53 GB, 20 columns, table._ A conversion attributed to a specific Experiment Path split within a Canvas.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `experiment_step_id` | STRING | ID of the Canvas Experiment step. |
| `experiment_split_id` | STRING | ID of the experiment split path. |
| `experiment_split_name` | STRING | Name of the experiment split path. |
| `conversion_behavior_index` | INT64 | Index of the conversion behavior that fired. |
| `conversion_behavior` | STRING | JSON describing the conversion behavior. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |


## Subscription & Webhook Events

### `subscription_globalstatechange`

_Active - 6,447,674 rows, 1.73 GB, 33 columns, table._ Global (channel-level) subscription state change for a user.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `email_address` | STRING | Recipient email address. |
| `state_change_source` | STRING | Source that triggered the subscription state change. |
| `subscription_status` | STRING | Subscription status value (e.g., subscribed, unsubscribed, opted_in). |
| `channel` | STRING | Messaging channel (e.g., email, push, sms). |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `channel_identifier` | STRING | Channel-specific identifier (email address / phone) the state change applies to. |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `subscriptiongroup_statechange`

_Active - 2,694,055 rows, 0.71 GB, 37 columns, table._ Subscription group membership state change (opted in/out of a specific group).

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `email_address` | STRING | Recipient email address. |
| `phone_number` | STRING | Phone number associated with the subscription group change. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `subscription_status` | STRING | Subscription status value (e.g., subscribed, unsubscribed, opted_in). |
| `channel` | STRING | Messaging channel (e.g., email, push, sms). |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `state_change_source` | STRING | Source that triggered the subscription state change. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `channel_identifier` | STRING | Channel-specific identifier (email address / phone) the state change applies to. |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `device_id` | STRING | Braze device identifier. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `webhook_send`

_Active - 26,228,680 rows, 10.49 GB, 29 columns, table._ Webhook message sent from a campaign/Canvas.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `message_extras` | STRING | Custom key-value metadata attached to the message (JSON string). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `webhook_failure`

_Active - 3,615,206 rows, 1.99 GB, 32 columns, table._ Webhook call failed - endpoint, HTTP status, response, retry count, and whether the failure is terminal.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `content_length` | INT64 | Content length of the response. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `endpoint_url` | STRING | Webhook endpoint URL called. |
| `host` | STRING | Host of the webhook endpoint. |
| `http_status_code` | INT64 | HTTP status code returned by the endpoint. |
| `is_terminal` | BOOL | TRUE if the failure is terminal (no further retries). |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `raw_response` | STRING | Raw response body returned by the endpoint. |
| `retry_count` | INT64 | Number of retries attempted. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `url_path` | STRING | Path portion of the webhook URL. |
| `webhook_duration` | INT64 | Duration of the webhook call (ms). |
| `webhook_failure_source` | STRING | Where the failure originated (e.g., endpoint, network). |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `webhook_abort`

_Active - 13,484,778 rows, 6.70 GB, 32 columns, table._ Webhook message aborted before send, with the abort reason.

| Column | Type | Description |
|---|---|---|
| `abort_log` | STRING | Detailed log message explaining the abort. |
| `abort_type` | STRING | Category of the abort reason. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_message_variation_id` | STRING | Message variation ID within the Canvas step. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `device_id` | STRING | Braze device identifier. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). Not present on streaming-era tables; derive as case when coalesce(canvas_id,'') <> '' then 1 else 0 end. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `webhook_retry`

_Empty - 0 rows, 0.00 GB, 26 columns, table._ Webhook retry event. Empty as of generation.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `retry_log` | STRING | Detailed log message for the retry. |
| `retry_type` | STRING | Category of the retry reason. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |


## WhatsApp Events (channel not in use - empty)

### `whatsapp_send`

_Empty - 0 rows, 0.00 GB, 32 columns, table._ WhatsApp message sent. Channel not in use - empty.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `bsuid` | STRING | WhatsApp Business Solution user ID. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `flow_id` | STRING | WhatsApp Flow ID. |
| `from_phone_number` | STRING | Origination phone number used to send the message. |
| `message_extras` | STRING | Custom key-value metadata attached to the message (JSON string). |
| `message_id` | STRING | Message identifier. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `template_name` | STRING | WhatsApp message template name. |
| `to_phone_number` | STRING | Destination phone number (E.164). |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `whatsapp_delivery`

_Empty - 0 rows, 0.00 GB, 31 columns, table._ WhatsApp message delivered. Channel not in use - empty.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `bsuid` | STRING | WhatsApp Business Solution user ID. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `flow_id` | STRING | WhatsApp Flow ID. |
| `from_phone_number` | STRING | Origination phone number used to send the message. |
| `message_id` | STRING | Message identifier. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `template_name` | STRING | WhatsApp message template name. |
| `to_phone_number` | STRING | Destination phone number (E.164). |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `whatsapp_read`

_Empty - 0 rows, 0.00 GB, 31 columns, table._ WhatsApp message read. Channel not in use - empty.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `bsuid` | STRING | WhatsApp Business Solution user ID. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `flow_id` | STRING | WhatsApp Flow ID. |
| `from_phone_number` | STRING | Origination phone number used to send the message. |
| `message_id` | STRING | Message identifier. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `template_name` | STRING | WhatsApp message template name. |
| `to_phone_number` | STRING | Destination phone number (E.164). |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `whatsapp_click`

_Empty - 0 rows, 0.00 GB, 26 columns, table._ WhatsApp link click. Channel not in use - empty.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `short_url` | STRING | The Braze short link that was clicked. |
| `url` | STRING | URL that was clicked. |
| `user_agent` | STRING | User-agent string captured for the event. |
| `user_phone_number` | STRING | The user's phone number. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `whatsapp_inboundreceive`

_Empty - 0 rows, 0.00 GB, 36 columns, table._ Inbound WhatsApp message. Channel not in use - empty.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `action` | STRING | Parsed action/keyword from the inbound message (e.g., STOP, HELP). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `bsuid` | STRING | WhatsApp Business Solution user ID. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `catalog_id` | STRING | WhatsApp catalog ID. |
| `flow_id` | STRING | WhatsApp Flow ID. |
| `flow_response_json` | STRING | WhatsApp Flow response payload (JSON string). |
| `in_reply_to` | STRING | Message ID this inbound message replies to. |
| `inbound_phone_number` | STRING | Braze number that received the inbound message. |
| `media_urls` | ARRAY<STRING> | Array of media (MMS) URLs included in the message. |
| `message_body` | STRING | Text body of the inbound message. |
| `message_id` | STRING | Message identifier. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `product_id` | STRING | Product ID referenced in the message. |
| `quick_reply_text` | STRING | Quick-reply button text selected. |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `user_phone_number` | STRING | The user's phone number. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `whatsapp_failure`

_Empty - 0 rows, 0.00 GB, 33 columns, table._ WhatsApp delivery failure. Channel not in use - empty.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `bsuid` | STRING | WhatsApp Business Solution user ID. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `flow_id` | STRING | WhatsApp Flow ID. |
| `from_phone_number` | STRING | Origination phone number used to send the message. |
| `message_id` | STRING | Message identifier. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `provider_error_code` | STRING | Provider/carrier error code. |
| `provider_error_title` | STRING | Provider error title. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `template_name` | STRING | WhatsApp message template name. |
| `to_phone_number` | STRING | Destination phone number (E.164). |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `whatsapp_abort`

_Empty - 0 rows, 0.00 GB, 28 columns, table._ WhatsApp send aborted. Channel not in use - empty.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `abort_log` | STRING | Detailed log message explaining the abort. |
| `abort_type` | STRING | Category of the abort reason. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `bsuid` | STRING | WhatsApp Business Solution user ID. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `to_phone_number` | STRING | Destination phone number (E.164). |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `whatsapp_retry`

_Empty - 0 rows, 0.00 GB, 28 columns, table._ WhatsApp send retry. Channel not in use - empty.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `bsuid` | STRING | WhatsApp Business Solution user ID. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `retry_log` | STRING | Detailed log message for the retry. |
| `retry_type` | STRING | Category of the retry reason. |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `to_phone_number` | STRING | Destination phone number (E.164). |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |


## LINE Events (channel not in use - empty)

### `line_send`

_Empty - 0 rows, 0.00 GB, 26 columns, table._ LINE message sent. Channel not in use - empty.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `line_channel_id` | STRING | LINE channel ID. |
| `line_channel_name` | STRING | LINE channel name. |
| `message_extras` | STRING | Custom key-value metadata attached to the message (JSON string). |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `native_line_id` | STRING | User's native LINE ID. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `line_click`

_Empty - 0 rows, 0.00 GB, 29 columns, table._ LINE link click. Channel not in use - empty.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `is_suspected_bot_click` | BOOL | TRUE if Braze flagged the click as a suspected bot / security-scanner click rather than a human click. Exclude for human engagement. |
| `line_channel_id` | STRING | LINE channel ID. |
| `line_channel_name` | STRING | LINE channel name. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `native_line_id` | STRING | User's native LINE ID. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `short_url` | STRING | The Braze short link that was clicked. |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `url` | STRING | URL that was clicked. |
| `user_agent` | STRING | User-agent string captured for the event. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `line_inboundreceive`

_Empty - 0 rows, 0.00 GB, 27 columns, table._ Inbound LINE message. Channel not in use - empty.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `line_channel_id` | STRING | LINE channel ID. |
| `line_channel_name` | STRING | LINE channel name. |
| `media_id` | STRING | LINE media ID. |
| `message_body` | STRING | Text body of the inbound message. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `native_line_id` | STRING | User's native LINE ID. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `line_abort`

_Empty - 0 rows, 0.00 GB, 27 columns, table._ LINE send aborted. Channel not in use - empty.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `abort_log` | STRING | Detailed log message explaining the abort. |
| `abort_type` | STRING | Category of the abort reason. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `line_channel_id` | STRING | LINE channel ID. |
| `line_channel_name` | STRING | LINE channel name. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `native_line_id` | STRING | User's native LINE ID. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `line_retry`

_Empty - 0 rows, 0.00 GB, 27 columns, table._ LINE send retry. Channel not in use - empty.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `line_channel_id` | STRING | LINE channel ID. |
| `line_channel_name` | STRING | LINE channel name. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `native_line_id` | STRING | User's native LINE ID. |
| `retry_log` | STRING | Detailed log message for the retry. |
| `retry_type` | STRING | Category of the retry reason. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |


## Live Activity, Feature Flag & Agent Console (not in use - empty)

### `liveactivity_send`

_Empty - 0 rows, 0.00 GB, 16 columns, table._ iOS Live Activity update sent. Not in use - empty.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `activity_attributes_type` | STRING | Live Activity attributes type. |
| `activity_id` | STRING | iOS Live Activity ID. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `live_activity_event_type` | STRING | Live Activity event type. |
| `push_to_start_token` | STRING | Live Activity push-to-start token. |
| `update_token` | STRING | Live Activity update token. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `liveactivity_outcome`

_Empty - 0 rows, 0.00 GB, 17 columns, table._ iOS Live Activity event outcome. Not in use - empty.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `activity_attributes_type` | STRING | Live Activity attributes type. |
| `activity_id` | STRING | iOS Live Activity ID. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `live_activity_event_outcome` | STRING | Live Activity event outcome. |
| `live_activity_event_type` | STRING | Live Activity event type. |
| `push_to_start_token` | STRING | Live Activity push-to-start token. |
| `update_token` | STRING | Live Activity update token. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `liveactivity_pushtostarttokenchange`

_Empty - 0 rows, 0.00 GB, 16 columns, table._ iOS Live Activity push-to-start token change. Not in use - empty.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `activity_attributes_type` | STRING | Live Activity attributes type. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `ios_push_token_apns_gateway` | INT64 | APNs gateway (production/sandbox) for the iOS token. |
| `push_to_start_token` | STRING | Live Activity push-to-start token. |
| `push_token_state_change_type` | STRING | Type of push token state change (e.g., created, updated, invalidated). |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `liveactivity_updatetokenchange`

_Empty - 0 rows, 0.00 GB, 16 columns, table._ iOS Live Activity update token change. Not in use - empty.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `activity_id` | STRING | iOS Live Activity ID. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `ios_push_token_apns_gateway` | INT64 | APNs gateway (production/sandbox) for the iOS token. |
| `push_token_state_change_type` | STRING | Type of push token state change (e.g., created, updated, invalidated). |
| `update_token` | STRING | Live Activity update token. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `featureflag_impression`

_Empty - 0 rows, 0.00 GB, 28 columns, table._ Braze Feature Flag impression. Not in use - empty.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `browser` | STRING | Browser used. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `device_model` | STRING | Device model. |
| `feature_flag_id_name` | STRING | Feature flag ID/name. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `os_version` | STRING | Operating system version of the device. |
| `platform` | STRING | Device platform (e.g., iOS, Android, Web). |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `device_id` | STRING | Braze device identifier. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `agentconsole_agentexecuted`

_Empty - 0 rows, 0.00 GB, 35 columns, table._ Braze Agent Console (AI agent) execution log - model, tokens, input/output, duration. Not in use - empty.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `agent_id` | STRING | Braze AI agent ID. |
| `agent_name` | STRING | Braze AI agent name. |
| `cache_hit` | BOOL | Whether a cache hit occurred. |
| `cache_tokens` | INT64 | Cached tokens. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `completion_tokens` | INT64 | Completion tokens used. |
| `duration` | INT64 | Duration (ms). |
| `error` | STRING | Error message. |
| `input` | STRING | Agent input text. |
| `invocation_id` | STRING | Agent invocation ID. |
| `invocation_source` | STRING | What invoked the agent. |
| `is_error` | BOOL | Whether the execution errored. |
| `llm_owned_by_customer` | BOOL | Whether the LLM is customer-owned (BYO key). |
| `model_name` | STRING | LLM model name. |
| `model_provider` | STRING | LLM provider. |
| `output` | STRING | Agent output text. |
| `prompt_tokens` | INT64 | Prompt tokens used. |
| `provider_request_id` | STRING | LLM provider request ID. |
| `reasoning_tokens` | INT64 | Reasoning tokens used. |
| `request_id` | STRING | Request ID. |
| `total_tokens` | INT64 | Total tokens used. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |

### `agentconsole_toolinvocation`

_Empty - 0 rows, 0.00 GB, 16 columns, table._ Tool invocation by a Braze AI agent. Not in use - empty.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique event identifier (UUID) and the DEDUPE KEY: the currents_merge job can emit duplicate rows, so event-level counts must be count(distinct id), never count(*). |
| `agent_id` | STRING | Braze AI agent ID. |
| `agent_name` | STRING | Braze AI agent name. |
| `duration` | INT64 | Duration (ms). |
| `invocation_source` | STRING | What invoked the agent. |
| `is_error` | BOOL | Whether the execution errored. |
| `request_id` | STRING | Request ID. |
| `tool_arguments` | STRING | Arguments passed to the tool (JSON string). |
| `tool_call_id` | STRING | Tool call ID. |
| `tool_name` | STRING | Tool invoked by the agent. |
| `time` | INT64 | Unix epoch seconds - the ONLY true-UTC clock on the event tables. For a UTC instant use timestamp_seconds(time). This is the Braze side of any comparison to order_timestamp_utc. |
| `event_date` | DATE | America/Denver LOCAL calendar date of the event (= date(event_timestamp)); the partition column - always filter it. Not the UTC date. A __NULL__ partition exists (event_date is null rows) and is silently dropped by a between filter. |
| `event_timestamp` | DATETIME | Event time as a DATETIME in America/Denver WALL-CLOCK time (follows US Mountain DST). NOT UTC. extract(hour ...) is already Mountain. Never cast(event_timestamp as timestamp) or datetime(cast(..),'America/Denver') - both assert UTC on a local value and land 6-7 h early. |
| `local_event_datetime` | DATETIME | Event datetime in the USER's own time zone (per the timezone column); differs from event_timestamp for out-of-Mountain users. Use for user-local daypart only. |
| `create_datetime` | DATETIME | current_datetime() at insert (UTC civil time) - when the row LANDED in the warehouse, not when the event happened. Useful for isolating rows from one load. |
| `workspace` | STRING | Braze workspace: 'cafe_zupas' (main, ~99% of volume) or 'cafe_zupas_catering'. CANONICAL DEFAULT: filter workspace = 'cafe_zupas'; include catering only when asked and keep workspace in the grain (campaign ids never cross workspaces). |


## Custom Attribute Feeds (bz_cid_*)

### `bz_cid_age_update`

_Active - 76 rows, 0.00 GB, 3 columns, table._ Custom attribute feed of customer age.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `age` | Customer age in years. |

### `bz_cid_gender_update`

_Active - 126 rows, 0.00 GB, 3 columns, table._ Custom attribute feed of customer gender.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `gender` | Customer gender. |

### `bz_cid_is_employee_update`

_Active - 11 rows, 0.00 GB, 3 columns, table._ Custom attribute feed flagging whether the customer is an employee.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `is_employee` | 1 if the customer is an employee, else 0. |

### `bz_cid_has_fav_store_update`

_Active - 289 rows, 0.00 GB, 3 columns, table._ Custom attribute feed flagging whether the customer has set a favorite store.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `has_favorite_store` | 1 if the customer has a favorite store set, else 0. |

### `bz_cid_weather_flag`

_Active - 177,002 rows, 0.00 GB, 3 columns, table._ Custom attribute feed of a weather classification flag for the customer (e.g., hot/cold).

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `weather_flag` | Weather classification for the customer (e.g., hot, cold). |

### `bz_cid_bgnbd_palive_churn`

_Active - 2,429 rows, 0.00 GB, 3 columns, table._ Custom attribute feed of the customer's churn risk band from a BG/NBD P(alive) model.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `risk_band` | Churn risk band from the BG/NBD P(alive) model (e.g., at_risk). |

### `bz_cid_favorite_category_ordered`

_Active - 2,366 rows, 0.00 GB, 3 columns, table._ Custom attribute feed of the customer's favorite (most-ordered) menu category.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `favorite_category_ordered` | Customer's most-ordered menu category (e.g., Bowls, Salads). |

### `bz_cid_first_purch_cat_item`

_Active - 3,580 rows, 0.00 GB, 3 columns, table._ Custom attribute feed of the item ID of the customer's first purchased category item.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `first_purch_cat_item` | Item ID of the first category item the customer purchased. |

### `bz_cid_purchased_core_category`

_Active - 9,036 rows, 0.00 GB, 3 columns, table._ Custom attribute feed recording the most recent date the customer purchased each core category.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `purchased_<category>` | One key per core category (e.g., purchased_salads) holding the most recent date that category was purchased. |

### `bz_cid_l90_total_eligible_orders_update`

_Active - 17,935 rows, 0.00 GB, 3 columns, table._ Custom attribute feed of the customer's total loyalty-eligible orders in the last 90 days.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `l90_total_eligible_orders` | Count of loyalty-eligible orders in the last 90 days (null if none). |

### `bz_cid_nested_l90_menu_choices_update`

_Active - 18,071 rows, 0.00 GB, 3 columns, table._ Nested custom attribute feed of last-90-day menu-choice behavior flags (bowl, salad, soup, sandwich, etc.).

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `l90_menu_choices_count` | Nested object of last-90-day menu-choice flags/counts: l90_bowl_cust, l90_cold_sandwich_cust, l90_dessert_cup_cust, l90_is_cup_cust, l90_kid_meal_cust, l90_low_cal_cust, l90_protein_cust, l90_salad_cust, l90_sandwich_cust, l90_soup_cust, l90_sweet_main_cust, l90_texmex_cust, l90_try2_cust, l90_warm_sandwich_cust. |

### `bz_cid_nested_l90_order_behaviors_update`

_Active - 18,005 rows, 0.00 GB, 3 columns, table._ Nested custom attribute feed of last-90-day ordering-channel/behavior flags (app, delivery, drive-thru, online, etc.).

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `l90_order_behaviors_count` | Nested object of last-90-day ordering-behavior flags/counts: l90_android_cust, l90_app_cust, l90_delivery_cust, l90_desktop_cust, l90_drive_thru_cust, l90_good_life_lane_cust, l90_iOS_cust, l90_mobile_web_cust, l90_oneline_takeout_cust, l90_online_cust, l90_scanned_cust, l90_takeout_cust, l90_unique_location_count. |

### `bz_cid_nested_l90_order_time_behaviors_update`

_Active - 18,197 rows, 0.00 GB, 3 columns, table._ Nested custom attribute feed of last-90-day order-timing behavior flags (daypart, day of week, season).

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `l90_order_time_behaviors_count` | Nested object of last-90-day order-timing flags: l90_dinner_cust, l90_lunch_cust (dayparts); l90_monday_cust..l90_saturday_cust, l90_weekday_cust (day of week); l90_fall_cust, l90_spring_cust, l90_summer_cust, l90_winter_cust (season). |


## Custom Attribute Feeds (cdi_* / loyalty / other)

### `cdi_order_attributes`

_Active - 34,443 rows, 0.00 GB, 3 columns, table._ Custom attribute feed of customer order-history metrics (first/latest order, L90/L180/L365 counts, avg ticket, net sales).

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `first_order_datetime` | Timestamp of the customer's first order. |
| `latest_order_datetime` | Timestamp of the customer's most recent order. |
| `l90_order_count` | Order count in the last 90 days. |
| `l180_order_count` | Order count in the last 180 days. |
| `l365_order_count` | Order count in the last 365 days. |
| `l90_avg_days_btwn_orders` | Average days between orders over the last 90 days. |
| `l90_avg_ticket` | Average ticket (order value) over the last 90 days. |
| `l90_netsales` | Net sales over the last 90 days. |

### `cdi_cup_sales_data`

_Active - 671 rows, 0.00 GB, 3 columns, table._ Nested custom attribute feed of per-cup-product order counts and latest order dates (seasonal dessert cups).

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `cup_sales_data` | Nested object with, per cup product, an order_count and a latest_order_date (e.g., mini_chocolate_strawberry_cup_order_count, mini_chocolate_strawberry_cup_latest_order_date, dubai_cup_*, chocolate_strawberry_cup_*, strawberries_cream_cup_*, golden_spice_apple_cup_*, chocolate_duo_apple_cup_*). |

### `cdi_l365_items_chipote_cups_bowls`

_Active - 342,791 rows, 0.01 GB, 3 columns, table._ Custom attribute feed of last-365-day counts for chipotle-glazed salad, cup items, and bowl items.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `l365_bowl_items_ordered` | Count of bowl items ordered in the last 365 days. |
| `l365_chipotle_glazed_salad_ordered` | Count of chipotle-glazed salads ordered in the last 365 days. |
| `l365_cup_items_ordered` | Count of cup items ordered in the last 365 days. |

### `cat_points_update`

_Active - 44,689 rows, 0.00 GB, 3 columns, table._ Nested custom attribute feed of SessionM/Cafe Zupas loyalty data (points, tier, CZ dollars).

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `sm_loyalty_data` | Nested loyalty object: current_points, cz_dollars, points_to_next_level, tier (e.g., Silver), visa_card_value. |

### `indiv_points_update`

_Active - 1,112 rows, 0.00 GB, 3 columns, table._ Custom attribute feed of the customer's loyalty points balance and points expiring at end of month.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `points_balance` | Current loyalty points balance. |
| `points_to_expire_EOM` | Points expiring at end of month. |

### `indiv_sessionm_user_id`

_Active - 525 rows, 0.00 GB, 3 columns, table._ Custom attribute feed mapping the customer to their SessionM user ID.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `sessionM_userid` | The customer's SessionM user ID. |

### `first_purch_cat_update`

_Active - 1,310 rows, 0.00 GB, 3 columns, table._ Custom attribute feed of the customer's first-purchase category (pilot - ~500 users).

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `first_purch_cat` | Category of the customer's first purchase (e.g., Bowls-Soups). |

### `is_vto_cust`

_Active - 3,459 rows, 0.00 GB, 3 columns, table._ Custom attribute feed of the count of unique VTO (value/test offer) items the customer has purchased.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `unique_vto_items_purchased` | Count of unique VTO items the customer has purchased. |

### `l365_has_salad_order`

_Active - 15,631 rows, 0.00 GB, 3 columns, table._ Custom attribute feed flagging whether the customer ordered a salad in the last 365 days.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `l365_has_salad_order` | 1 if the customer ordered a salad in the last 365 days, else 0. |


## Pipeline / Raw / Audit (plumbing - never query for analysis)

### `currents_raw`

_Active - 612,095,363 rows, 327.92 GB, 5 columns, table._ Raw Braze Currents landing - one row per Pub/Sub message with the event as JSON, feeding the currents_merge pipeline (Currents -> braze_stream -> merged into the typed braze tables). ~612M rows / ~328 GB and NOT partitioned by event date. Plumbing - never query for analysis; use the typed tables.

| Column | Type | Description |
|---|---|---|
| `subscription_name` | STRING | Pub/Sub subscription the message arrived on. |
| `message_id` | STRING | Message identifier. |
| `publish_time` | TIMESTAMP | Pub/Sub publish timestamp. |
| `data` | JSON | Raw Currents event payload (JSON). |
| `attributes` | JSON | Pub/Sub message attributes (JSON). |

### `load_watermark`

_Active - 2 rows, 0.00 GB, 3 columns, table._ Pipeline control table for the currents_merge job: a progress row and a lock row. A future-dated watermark means the merge holds the lock and is mid-write - do not trust reads taken in that state. Plumbing.

| Column | Type | Description |
|---|---|---|
| `job_name` | STRING | Pipeline job the row belongs to: 'currents_merge' (progress) or 'currents_merge_lock' (lock row). |
| `watermark` | TIMESTAMP | High-water mark TIMESTAMP the job has processed through. A FUTURE-dated watermark means the merge is holding the lock and is mid-write - do not trust reads taken in that state. Already a TIMESTAMP; do not cast. |
| `updated_at` | TIMESTAMP | When the watermark row was last updated. |

### `table_rec_cnt`

_Active - 128 rows, 0.00 GB, 3 columns, table._ Internal audit table recording row counts per table and when they were captured. Plumbing.

| Column | Type | Description |
|---|---|---|
| `table_name` | STRING | Name of the table the count is for. |
| `rec_cnt` | INT64 | Recorded row count. |
| `create_timestamp` | TIMESTAMP | When the count was captured. |

