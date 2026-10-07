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

## Per-group column files

Column-level docs are split by table group so a session reads only the channel it needs. The **Group** column in the table index above maps to these files.

| Group | File | Tables |
|---|---|---:|
| User Profile & Identity | [`braze/user_profile_identity.md`](braze/user_profile_identity.md) | 5 |
| App / Session, Purchase & Device Events | [`braze/app_session_purchase_device_events.md`](braze/app_session_purchase_device_events.md) | 9 |
| Email Events | [`braze/email_events.md`](braze/email_events.md) | 11 |
| Push Notification Events | [`braze/push_notification_events.md`](braze/push_notification_events.md) | 6 |
| SMS Events | [`braze/sms_events.md`](braze/sms_events.md) | 9 |
| RCS Events | [`braze/rcs_events.md`](braze/rcs_events.md) | 7 |
| Banner Events | [`braze/banner_events.md`](braze/banner_events.md) | 4 |
| Content Card & In-App Message Events | [`braze/content_card_in_app_message_events.md`](braze/content_card_in_app_message_events.md) | 8 |
| Campaign & Canvas Events | [`braze/campaign_canvas_events.md`](braze/campaign_canvas_events.md) | 9 |
| Subscription & Webhook Events | [`braze/subscription_webhook_events.md`](braze/subscription_webhook_events.md) | 6 |
| WhatsApp Events (channel not in use - empty) | [`braze/whatsapp_events.md`](braze/whatsapp_events.md) | 8 |
| LINE Events (channel not in use - empty) | [`braze/line_events.md`](braze/line_events.md) | 5 |
| Live Activity, Feature Flag & Agent Console (not in use - empty) | [`braze/live_activity_feature_flag_agent_console.md`](braze/live_activity_feature_flag_agent_console.md) | 7 |
| Custom Attribute Feeds (bz_cid_*) | [`braze/custom_attribute_feeds_bz_cid.md`](braze/custom_attribute_feeds_bz_cid.md) | 13 |
| Custom Attribute Feeds (cdi_* / loyalty / other) | [`braze/custom_attribute_feeds_cdi_loyalty_other.md`](braze/custom_attribute_feeds_cdi_loyalty_other.md) | 9 |
| Pipeline / Raw / Audit (plumbing - never query for analysis) | [`braze/pipeline_raw_audit_plumbing_never_query_for_analysis.md`](braze/pipeline_raw_audit_plumbing_never_query_for_analysis.md) | 3 |
