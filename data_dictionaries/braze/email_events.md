# Braze dictionary — Email Events

> Part of `data_dictionaries/braze_data_dictionary.md` (read that index first: the four rules, common columns and table index apply to every table here). Split out verbatim on 2026-10-07; column content unchanged, generated 2026-09-04.

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
