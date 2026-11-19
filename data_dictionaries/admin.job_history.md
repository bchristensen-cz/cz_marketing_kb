# admin.job_history

**Steward-only.** Permanent archive of BigQuery job history for `marketing-data-442316`. Not
granted to `claude` users and not a business-data source.

- **Why it exists:** `region-us.INFORMATION_SCHEMA.JOBS_BY_PROJECT` keeps 180 days. On 2026-11-19 a
  question about how the Q1 2026 DoorDash refund was calculated could not be answered because those
  jobs had already rolled off. This table keeps every job from 2026-05-23 forward.
- **Build:** `sql/admin.job_history.sql`. Created and backfilled 2026-11-19 (180-day lookback,
  2,032,118 jobs, 0 duplicate `job_id`s). Daily scheduled query "admin.job_history daily archive",
  02:15 MT, merges the trailing 3 days.
- **Grain:** one row per `job_id`. Child jobs of scripts are separate rows linked by `parent_job_id`.
- **Partition / cluster:** `date(creation_time)` (UTC day); clustered `user_email, job_type,
  statement_type`. Filter `creation_time` first, as with every partitioned table.

| Column | Type | Notes |
|---|---|---|
| `creation_time`, `start_time`, `end_time` | TIMESTAMP | UTC |
| `job_date_mt` | DATE | `creation_time` in America/Denver, for "what day did I run this" questions |
| `project_id`, `job_id`, `parent_job_id` | STRING | `scheduled_query_*` = a scheduled-query parent; `script_job_*` = a child statement |
| `user_email` | STRING | Human or service account. DBeaver runs as `dbeaver-bigquery@`, so it hides which person ran the query |
| `job_type`, `statement_type`, `priority`, `state` | STRING | As in `JOBS_BY_PROJECT` |
| `error_reason`, `error_message` | STRING | From `error_result`; NULL on success |
| `cache_hit` | BOOL | |
| `total_bytes_processed`, `total_bytes_billed`, `total_slot_ms` | INT64 | |
| `destination_table` | STRING | `project.dataset.table` or NULL |
| `referenced_tables` | ARRAY<STRING> | `project.dataset.table`; views are expanded to their base tables |
| `labels` | ARRAY<STRUCT<key, value>> | `goog-mcp-server = true` marks Claude/MCP queries |
| `query` | STRING | Full SQL text |
| `archived_at` | TIMESTAMP | When the row was last written by the archive job |

Example, every query that mentioned Free Delivery, by Denver date:

```sql
select
  jh.job_date_mt
, jh.user_email
, jh.job_id
, jh.query
from `marketing-data-442316.admin.job_history` jh
where 1=1
and jh.creation_time >= timestamp('2026-05-01')
and jh.job_type = 'QUERY'
and regexp_contains(lower(jh.query), r'free delivery')
order by jh.creation_time
```
