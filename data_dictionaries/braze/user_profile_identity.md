# Braze dictionary — User Profile & Identity

> Part of `data_dictionaries/braze_data_dictionary.md` (read that index first: the four rules, common columns and table index apply to every table here). Split out verbatim on 2026-10-07; column content unchanged, generated 2026-09-04.

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
