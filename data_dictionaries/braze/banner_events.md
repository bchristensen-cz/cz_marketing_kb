# Braze dictionary — Banner Events

> Part of `data_dictionaries/braze_data_dictionary.md` (read that index first: the four rules, common columns and table index apply to every table here). Split out verbatim on 2026-10-07; column content unchanged, generated 2026-09-04.

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
