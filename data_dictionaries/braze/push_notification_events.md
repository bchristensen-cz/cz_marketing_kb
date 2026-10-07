# Braze dictionary — Push Notification Events

> Part of `data_dictionaries/braze_data_dictionary.md` (read that index first: the four rules, common columns and table index apply to every table here). Split out verbatim on 2026-10-07; column content unchanged, generated 2026-09-04.

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
