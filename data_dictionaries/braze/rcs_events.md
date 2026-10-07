# Braze dictionary — RCS Events

> Part of `data_dictionaries/braze_data_dictionary.md` (read that index first: the four rules, common columns and table index apply to every table here). Split out verbatim on 2026-10-07; column content unchanged, generated 2026-09-04.

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
