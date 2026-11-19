/*
admin.job_history: permanent archive of BigQuery job history for marketing-data-442316.

Why: region-us.INFORMATION_SCHEMA.JOBS_BY_PROJECT keeps only 180 days. Anything older
(including the Q1 2026 queries behind the DoorDash free delivery refund) is unrecoverable
once it rolls off. This table keeps every job forever.

Schedule: BigQuery scheduled query "admin.job_history daily archive", daily 02:15 America/Denver.
Each run merges the trailing 3 days (overlap covers late-finishing jobs and a missed run).
Idempotent: keyed on job_id, a re-run updates the row instead of duplicating it.
Backfill: run once with lookback_days = 180 (done 2026-11-19, oldest day kept = 2026-05-23).

Cost: JOBS_BY_PROJECT bills ~5 GB per 180-day scan; the 3-day daily run is a small fraction.
*/

declare lookback_days int64 default 3;

create schema if not exists `marketing-data-442316.admin`
options (location = 'US', description = 'Steward-only admin tables (job history archive).');

create table if not exists `marketing-data-442316.admin.job_history`
(
creation_time timestamp
, start_time timestamp
, end_time timestamp
, job_date_mt date
, project_id string
, job_id string
, parent_job_id string
, user_email string
, job_type string
, statement_type string
, priority string
, state string
, error_reason string
, error_message string
, cache_hit bool
, total_bytes_processed int64
, total_bytes_billed int64
, total_slot_ms int64
, destination_table string
, referenced_tables array<string>
, labels array<struct<key string, value string>>
, query string
, archived_at timestamp
)
partition by date(creation_time)
cluster by user_email, job_type, statement_type
options (description = 'Permanent copy of INFORMATION_SCHEMA.JOBS_BY_PROJECT (180-day retention upstream). Build: cz_marketing_kb/sql/admin.job_history.sql');

merge `marketing-data-442316.admin.job_history` t
using (
	select
	j.creation_time
	, j.start_time
	, j.end_time
	, date(j.creation_time, 'America/Denver') as job_date_mt
	, j.project_id
	, j.job_id
	, j.parent_job_id
	, j.user_email
	, j.job_type
	, j.statement_type
	, j.priority
	, j.state
	, j.error_result.reason as error_reason
	, j.error_result.message as error_message
	, j.cache_hit
	, j.total_bytes_processed
	, j.total_bytes_billed
	, j.total_slot_ms
	, if(j.destination_table.table_id is null, null, concat(j.destination_table.project_id, '.', j.destination_table.dataset_id, '.', j.destination_table.table_id)) as destination_table
	, array(select concat(r.project_id, '.', r.dataset_id, '.', r.table_id) from unnest(j.referenced_tables) r) as referenced_tables
	, array(select as struct l.key, l.value from unnest(j.labels) l) as labels
	, j.query
	, current_timestamp() as archived_at
	from `marketing-data-442316`.`region-us`.INFORMATION_SCHEMA.JOBS_BY_PROJECT j
	where 1=1
	and j.creation_time >= timestamp_sub(current_timestamp(), interval lookback_days day)
) s
on t.job_id = s.job_id
and date(t.creation_time) >= date_sub(current_date(), interval lookback_days + 1 day)
when matched and t.state <> 'DONE' then update set
	end_time = s.end_time
	, state = s.state
	, error_reason = s.error_reason
	, error_message = s.error_message
	, cache_hit = s.cache_hit
	, total_bytes_processed = s.total_bytes_processed
	, total_bytes_billed = s.total_bytes_billed
	, total_slot_ms = s.total_slot_ms
	, archived_at = s.archived_at
when not matched then insert row;
