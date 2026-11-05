create table if not exists `marketing-data-442316.holdout.braze_cdi_state` (
braze_id string not null
, synced_global boolean options (description = 'cz_global_holdout value last sent to Braze')
, synced_codes array<string> options (description = 'cz_program_holdouts value last sent to Braze; codes are only ever added (D-054)')
, payload json options (description = 'Only the keys that changed on the last update')
, updated_at timestamp not null options (description = 'Run time of the change; Braze CDI syncs rows newer than its last watermark')
)
cluster by updated_at, braze_id
options (description = 'Braze CDI state for holdout attributes, one row per Braze profile ever written. A row changes only when a value changes, so CDI never resends unchanged data (each attribute write costs a data point).');

create or replace view `marketing-data-442316.holdout.braze_cdi_feed_v`
options (description = 'Braze Cloud Data Ingestion source for cz_global_holdout / cz_program_holdouts, keyed by BRAZE_ID.')
as
select
s.updated_at
, s.braze_id
, s.payload
from `marketing-data-442316.holdout.braze_cdi_state` s;

create or replace procedure `marketing-data-442316.holdout.refresh_braze_feed`()
options (description = 'Step 4 of the nightly job: compares braze_feed_desired with braze_cdi_state and records only changed values, with a payload holding only the changed keys.')
begin
merge `marketing-data-442316.holdout.braze_cdi_state` t
using (
with d as (
select
coalesce(s.braze_id, f.braze_id) as braze_id
, s.synced_global
, s.synced_codes
, ifnull(f.cz_global_holdout, false) as want_global
, array(
	select distinct c
	from unnest(array_concat(ifnull(s.synced_codes, []), ifnull(f.cz_program_holdouts, []))) c
	order by c
	) as want_codes
from `marketing-data-442316.holdout.braze_cdi_state` s
	full outer join `marketing-data-442316.holdout.braze_feed_desired` f
	on f.braze_id = s.braze_id
)
select
braze_id
, want_global
, want_codes
, ifnull(synced_global, false) != want_global as global_changed
, to_json_string(ifnull(synced_codes, [])) != to_json_string(want_codes) as codes_changed
from d
) n
on t.braze_id = n.braze_id
when matched and (n.global_changed or n.codes_changed) then
	update set
	synced_global = n.want_global
	, synced_codes = n.want_codes
	, payload = json_strip_nulls(json_object(
		'cz_global_holdout', if(n.global_changed, to_json(n.want_global), null)
		, 'cz_program_holdouts', if(n.codes_changed, to_json(n.want_codes), null)
		))
	, updated_at = current_timestamp()
when not matched and (n.global_changed or n.codes_changed) then
	insert (braze_id, synced_global, synced_codes, payload, updated_at)
	values (
	n.braze_id
	, n.want_global
	, n.want_codes
	, json_strip_nulls(json_object(
		'cz_global_holdout', if(n.global_changed, to_json(n.want_global), null)
		, 'cz_program_holdouts', if(n.codes_changed, to_json(n.want_codes), null)
		))
	, current_timestamp()
	);
end;
