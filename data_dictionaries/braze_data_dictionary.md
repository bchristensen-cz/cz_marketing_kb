# Braze Dataset - Table Descriptions & Data Dictionary

**Project:** `marketing-data-442316`  **Dataset:** `braze`  
**Tables documented:** 69  **Generated:** 2026-06-11

This dataset is the BigQuery landing for Braze Currents event streams plus Cafe Zupas custom attribute feeds and user-profile exports. Most event tables share a common set of Braze identifier and timestamp columns (documented once below); table-specific columns are described in each table's dictionary.

**Freshness:** `braze.load_watermark` (not an event table) holds the load high-water mark per job — columns `job_name`, `watermark`, `updated_at`. Check it before assuming today's events are complete.

**Pipeline internals — never query for analysis:** `braze.currents_raw` (raw pub/sub feed), `braze_stream.*` (shadow/validation copy of the event tables), and `staging.users_messages_*` are ingestion plumbing. They duplicate or precede what lands in the `braze` event tables and are not deduplicated/normalized.

**Custom attributes on `braze.users`:** `custom_attributes` is a JSON column; read fields with `lax_string()`, e.g. `lax_string(u.custom_attributes.first_purch_cat)`. Known Cafe Zupas attributes: `first_purch_cat` (first-order menu-category classification pushed from BigQuery, 2026-07) and `guest_test_email` (guest-checkout email capture). Related custom event: `customevent` rows with `name = 'guest_email_from_order'` carry `$.order_id` in `properties`, linking guest-checkout orders to emails.

## Common columns (shared across most event tables)

| Column | Description |
|---|---|
| `id` | Unique identifier (UUID) for this event record. |
| `user_id` | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_id` | Identifier of the specific app/platform build the event is tied to. |
| `app_group_id` | Identifier of the Braze app group (workspace) the event belongs to. |
| `workspace` | Human-readable Braze workspace name: `'cafe_zupas'` (retail, ~97.5% of email_send rows) or `'cafe_zupas_catering'`. Added/backfilled 2026-07-22 across event tables (full history to 2024-06). **Filter `workspace = 'cafe_zupas'` for retail-only campaign analyses** — catering campaign events are mixed into the same tables. |
| `time` | Unix epoch timestamp (seconds, UTC) when the event occurred. |
| `timezone` | User's IANA time zone (e.g., America/Denver) at time of event. |
| `event_timestamp` | Event time as a UTC DATETIME (derived from time). |
| `event_date` | UTC date of the event; typically the partition column. |
| `local_event_datetime` | Event datetime expressed in the user's local time zone. |
| `create_datetime` | Datetime the record was loaded into the warehouse. |
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
| `is_canvas` | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |

> Note on `campaign_*` vs `cmpgn_*`: Braze exports include both naming styles for the same campaign attributes; the `cmpgn_*` set is a legacy duplicate.

## Custom attribute feed tables (shared shape)

The `bz_cid_*`, `cdi_*`, `cat_points_update`, `first_purch_cat_update`, `indiv_*`, `is_vto_cust`, and `l365_has_salad_order` tables all share the same three-column shape: `UPDATED_AT` (TIMESTAMP), `external_id` (STRING customer ID), and `PAYLOAD` (JSON). The meaningful data lives inside `PAYLOAD`; each table's payload keys are documented in its section.

---

## User Profile & Identity

### `users`

_27 columns._ User profile export - one row per user with profile attributes and nested JSON arrays for apps, devices, custom attributes, events, purchases, and message history.

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
| `country` | STRING | Country. |
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

_14 columns._ Staging snapshot of user profiles with parsed custom attributes and app usage structs.

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

_1 columns._ Staging table holding the set of external (customer) IDs.

| Column | Type | Description |
|---|---|---|
| `external_id` | INT64 | Cafe Zupas customer ID (numeric). |

### `global_holdout`

_6 columns._ Users assigned to the global holdout group, who are withheld from messaging for incrementality measurement.

| Column | Type | Description |
|---|---|---|
| `braze_id` | STRING | Braze internal user ID. |
| `created_at` | TIMESTAMP | When the user was added to the holdout. |
| `email` | STRING | User email. |
| `external_id` | STRING | Cafe Zupas customer ID. |
| `phone` | STRING | User phone number. |
| `random_bucket` | FLOAT64 | Random bucket value used for holdout assignment. |

### `randombucketnumberupdate`

_10 columns._ Logs changes to a user's random bucket number (used for random sampling/segmentation), with previous value.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
| `random_bucket_number` | INT64 | New random bucket number assigned to the user. |
| `prev_random_bucket_number` | INT64 | Previous random bucket number. |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |


## App / Session & Purchase Events

### `app_firstsession`

_20 columns._ Records the first app session ever logged for a user, including the originating device, locale, and SDK details.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
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
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `app_sessionstart`

_14 columns._ Logged when an app session begins.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
| `session_id` | STRING | Identifier of the session. |
| `platform` | STRING | Device platform (e.g., iOS, Android, Web). |
| `os_version` | STRING | Operating system version of the device. |
| `device_model` | STRING | Device model. |
| `device_id` | STRING | Braze device identifier. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `app_sessionend`

_15 columns._ Logged when an app session ends, including session duration.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
| `duration` | FLOAT64 | Session length in seconds. |
| `session_id` | STRING | Identifier of the session. |
| `platform` | STRING | Device platform (e.g., iOS, Android, Web). |
| `os_version` | STRING | Operating system version of the device. |
| `device_model` | STRING | Device model. |
| `device_id` | STRING | Braze device identifier. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `uninstall`

_10 columns._ App uninstall event for a user/device.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `device_id` | STRING | Braze device identifier. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `customevent`

_20 columns._ Custom events tracked from the apps or API. The name column holds the event name and properties holds the event payload.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
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
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `purchase`

_20 columns._ Purchase/revenue event with product, price, and currency.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
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
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |


## Email Events

### `email_send`

_31 columns._ Email handed off to the email service provider for delivery.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
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
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `email_delivery`

_33 columns._ Email accepted/delivered by the receiving mail server.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
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
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `email_open`

_40 columns._ Email open event (includes machine/proxy-open detection).

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
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
| `machine_open` | STRING | Indicates a machine/proxy open (e.g., Apple MPP) rather than a human open. |
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
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `email_click`

_42 columns._ Email link click event, including the clicked URL and device/client details.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
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
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `email_bounce`

_35 columns._ Hard bounce - the email was permanently rejected by the receiving server.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
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
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `email_softbounce`

_34 columns._ Soft bounce - temporary delivery failure (e.g., full mailbox).

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
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
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `email_markasspam`

_33 columns._ Recipient marked the email as spam.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
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
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `email_unsubscribe`

_30 columns._ Recipient unsubscribed via this email.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
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
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `email_abort`

_34 columns._ Email that was aborted before delivery (e.g., suppressed, rate-limited, or invalid), with the abort reason.

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
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `ip_pool` | STRING | Sending IP pool used by the email service provider. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `domain` | STRING | Recipient email domain. |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |


## Push Notification Events

### `pushnotification_send`

_35 columns._ Push notification sent to the push provider.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
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
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `pushnotification_open`

_38 columns._ Push notification open/tap event, including the button tapped.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
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
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `pushnotification_bounce`

_33 columns._ Push notification bounce (token rejected/invalid).

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
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
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `pushnotification_abort`

_33 columns._ Push notification aborted before send, with the abort reason.

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
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `platform` | STRING | Device platform (e.g., iOS, Android, Web). |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |


## SMS Events

### `sms_send`

_31 columns._ SMS sent to the SMS provider.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
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
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `sms_delivery`

_30 columns._ SMS delivered to the carrier/recipient.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `to_phone_number` | STRING | Destination phone number (E.164). |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `from_phone_number` | STRING | Origination phone number used to send the SMS. |
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
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `sms_deliveryfailure`

_31 columns._ SMS delivery failure with carrier error code and message.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `to_phone_number` | STRING | Destination phone number (E.164). |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `error` | STRING | Delivery failure error message. |
| `provider_error_code` | STRING | Carrier/provider error code. |
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
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `sms_rejection`

_32 columns._ SMS rejected by the provider before delivery, with error details.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `to_phone_number` | STRING | Destination phone number (E.164). |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `from_phone_number` | STRING | Origination phone number used to send the SMS. |
| `error` | STRING | Rejection error message. |
| `provider_error_code` | STRING | Provider error code. |
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
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `sms_abort`

_27 columns._ SMS aborted before send, with the abort reason.

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
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `sms_inboundreceive`

_29 columns._ Inbound SMS received from a user (e.g., keyword replies like STOP/HELP), including message body and any media.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
| `user_phone_number` | STRING | The user's phone number. |
| `subscription_group_id` | STRING | Braze subscription group identifier. |
| `inbound_phone_number` | STRING | Braze number that received the inbound message. |
| `action` | STRING | Parsed action/keyword from the inbound message (e.g., STOP, HELP). |
| `message_body` | STRING | Text body of the inbound SMS. |
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
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `sms_shortlinkclick`

_29 columns._ Click on a Braze SMS short link, including resolved URL.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
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
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |


## Content Card & In-App Message Events

### `contentcard_send`

_30 columns._ Content Card send event.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `content_card_id` | STRING | Identifier of the Content Card. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
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
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `contentcard_impression`

_36 columns._ Content Card impression (view) event.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `content_card_id` | STRING | Identifier of the Content Card. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
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
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `contentcard_click`

_36 columns._ Content Card click event.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `content_card_id` | STRING | Identifier of the Content Card. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
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
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `inappmessage_impression`

_38 columns._ In-app message impression (view) event.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
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
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `inappmessage_click`

_37 columns._ In-app message click event.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
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
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |


## Campaign & Canvas Events

### `campaigns_conversion`

_19 columns._ A conversion event attributed to a Braze campaign (the user performed the campaign's configured conversion behavior).

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
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
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `campaigns_enrollincontrol`

_17 columns._ Records when a user was placed in a campaign's control (holdout) group and intentionally not messaged.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `campaign_id` | STRING | Braze campaign ID that sent/triggered the message. |
| `campaign_name` | STRING | Name of the Braze campaign. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `dispatch_id` | STRING | ID of the message dispatch (one send batch to a user). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `canvas_entry`

_17 columns._ Logged when a user enters a Canvas, including whether they landed in the control group.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `in_control_group` | BOOL | TRUE if the user entered the Canvas control group. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `canvas_conversion`

_19 columns._ A conversion event attributed to a Braze Canvas (journey).

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
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
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `canvas_exit_performedevent`

_18 columns._ Logged when a user exits a Canvas because they performed a configured exit event.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `app_group_api_id` | STRING | Public API identifier of the Braze app group. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
| `canvas_id` | STRING | Braze Canvas (journey) ID associated with the message. |
| `canvas_variation_id` | STRING | ID of the Canvas variation the user is in. |
| `canvas_step_id` | STRING | ID of the Canvas step that produced the event. |
| `canvas_name` | STRING | Name of the Braze Canvas. |
| `canvas_variation_name` | STRING | Name of the Canvas variation. |
| `canvas_step_name` | STRING | Name of the Canvas step. |
| `canvas_api_id` | STRING | Public API ID of the Canvas. |
| `canvas_variation_api_id` | STRING | Public API ID of the Canvas variation. |
| `canvas_step_api_id` | STRING | Public API ID of the Canvas step. |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `canvas_experimentstep_splitentry`

_17 columns._ Records the experiment-path split a user was assigned to at a Canvas Experiment step.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
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
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `canvas_experimentstep_conversion`

_19 columns._ A conversion attributed to a specific Experiment Path split within a Canvas.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `app_id` | STRING | Identifier of the specific app/platform build the event is tied to. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
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
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |


## Subscription & Webhook Events

### `subscription_globalstatechange`

_31 columns._ Global (channel-level) subscription state change for a user.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `email_address` | STRING | Recipient email address. |
| `state_change_source` | STRING | Source that triggered the subscription state change. |
| `subscription_status` | STRING | Subscription status value (e.g., subscribed, unsubscribed, opted_in). |
| `channel` | STRING | Messaging channel (e.g., email, push, sms). |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `app_group_id` | STRING | Identifier of the Braze app group (workspace) the event belongs to. |
| `app_id` | STRING | App identifier. |
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
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `subscriptiongroup_statechange`

_35 columns._ Subscription group membership state change (opted in/out of a specific group).

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
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
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
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
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `webhook_send`

_28 columns._ Webhook message sent from a campaign/Canvas.

| Column | Type | Description |
|---|---|---|
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `external_user_id` | STRING | Externally provided user ID (external_id) - the Cafe Zupas customer ID used to join to source systems. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
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
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |

### `webhook_abort`

_31 columns._ Webhook message aborted before send, with the abort reason.

| Column | Type | Description |
|---|---|---|
| `abort_log` | STRING |  |
| `abort_type` | STRING |  |
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
| `id` | STRING | Unique identifier (UUID) for this event record. |
| `message_variation_id` | STRING | ID of the message variation (A/B test variant) sent. |
| `message_variation_name` | STRING | Name of the message variation sent. |
| `send_id` | STRING | Identifier grouping all messages from a single send, used for send-level analytics. |
| `time` | INT64 | Unix epoch timestamp (seconds, UTC) when the event occurred. |
| `timezone` | STRING | User's IANA time zone (e.g., America/Denver) at time of event. |
| `user_id` | STRING | Braze internal user identifier (braze_id) for the user. |
| `cmpgn_id` | STRING | Legacy/duplicate campaign ID field included in the export. |
| `cmpgn_name` | STRING | Legacy/duplicate campaign name field included in the export. |
| `cmpgn_variation_id` | STRING | Legacy/duplicate message variation ID field. |
| `cmpgn_variation_name` | STRING | Legacy/duplicate message variation name field. |
| `is_canvas` | INT64 | Flag (1/0) indicating whether the message originated from a Canvas (1) vs a Campaign (0). |
| `event_timestamp` | DATETIME | Event time as a UTC DATETIME (derived from time). |
| `event_date` | DATE | UTC date of the event; typically the partition column. |
| `local_event_datetime` | DATETIME | Event datetime expressed in the user's local time zone. |
| `create_datetime` | DATETIME | Datetime the record was loaded into the warehouse. |


## Custom Attribute Feeds (bz_cid_*)

### `bz_cid_age_update`

_3 columns._ Custom attribute feed of customer age.

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

_3 columns._ Custom attribute feed of customer gender.

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

_3 columns._ Custom attribute feed flagging whether the customer is an employee.

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

_3 columns._ Custom attribute feed flagging whether the customer has set a favorite store.

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

_3 columns._ Custom attribute feed of a weather classification flag for the customer (e.g., hot/cold).

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `weather_flag` | Weather classification for the customer (e.g., hot, cold). |

### `bz_cid_favorite_category_ordered`

_3 columns._ Custom attribute feed of the customer's favorite (most-ordered) menu category.

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

_3 columns._ Custom attribute feed of the item ID of the customer's first purchased category item.

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

_3 columns._ Custom attribute feed recording the most recent date the customer purchased each core category.

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

_3 columns._ Custom attribute feed of the customer's total loyalty-eligible orders in the last 90 days.

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

_3 columns._ Nested custom attribute feed of last-90-day menu-choice behavior flags (bowl, salad, soup, sandwich, etc.).

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

_3 columns._ Nested custom attribute feed of last-90-day ordering-channel/behavior flags (app, delivery, drive-thru, online, etc.).

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

_3 columns._ Nested custom attribute feed of last-90-day order-timing behavior flags (daypart, day of week, season).

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

_3 columns._ Custom attribute feed of customer order-history metrics (first/latest order, L90/L180/L365 counts, avg ticket, net sales).

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

_3 columns._ Nested custom attribute feed of per-cup-product order counts and latest order dates (seasonal dessert cups).

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

_3 columns._ Custom attribute feed of last-365-day counts for chipotle-glazed salad, cup items, and bowl items.

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

_3 columns._ Nested custom attribute feed of SessionM/Cafe Zupas loyalty data (points, tier, CZ dollars).

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

_3 columns._ Custom attribute feed of the customer's loyalty points balance and points expiring at end of month.

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

_3 columns._ Custom attribute feed mapping the customer to their SessionM user ID.

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

_3 columns._ Custom attribute feed of the customer's first-purchase category.

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

_3 columns._ Custom attribute feed of the count of unique VTO (value/test offer) items the customer has purchased.

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

_3 columns._ Custom attribute feed flagging whether the customer ordered a salad in the last 365 days.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `l365_has_salad_order` | 1 if the customer ordered a salad in the last 365 days, else 0. |


## Internal / Audit

### `table_rec_cnt`

_3 columns._ Internal audit table recording row counts per table and when they were captured.

| Column | Type | Description |
|---|---|---|
| `table_name` | STRING | Name of the table the count is for. |
| `rec_cnt` | INT64 | Recorded row count. |
| `create_timestamp` | TIMESTAMP | When the count was captured. |

