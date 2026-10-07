# Braze dictionary — Pipeline / Raw / Audit (plumbing - never query for analysis)

> Part of `data_dictionaries/braze_data_dictionary.md` (read that index first: the four rules, common columns and table index apply to every table here). Split out verbatim on 2026-10-07; column content unchanged, generated 2026-09-04.

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
