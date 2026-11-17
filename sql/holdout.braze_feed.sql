create table if not exists `marketing-data-442316.holdout.braze_cdi_state` (
braze_id string not null
, synced_global boolean options (description = 'cz_global_holdout value last sent to Braze')
, synced_codes array<string> options (description = 'cz_program_holdouts value last sent to Braze; codes are only ever added (D-054)')
, payload json options (description = 'Only the keys that changed on the last update')
, updated_at timestamp not null options (description = 'Run time of the change; Braze CDI syncs rows newer than its last watermark')
)
cluster by updated_at, braze_id
options (description = 'Braze CDI state for holdout attributes, one row per Braze profile ever written. A row changes only when a value changes, so CDI never resends unchanged data (each attribute write costs a data point).');

alter table `marketing-data-442316.holdout.braze_cdi_state`
add column if not exists synced_test_arms array<string> options (description = 'cz_test_arms value last sent to Braze; arm codes <layer_code>:<arm> are only ever added (D-057)');

create or replace view `marketing-data-442316.holdout.braze_cdi_feed_v`
options (description = 'Braze Cloud Data Ingestion source for cz_global_holdout / cz_program_holdouts, keyed by BRAZE_ID.')
as
select
s.updated_at
, s.braze_id
, s.payload
from `marketing-data-442316.holdout.braze_cdi_state` s;

create or replace view `marketing-data-442316.holdout.test_arm_v`
options (description = 'Treatment arms of test layers, one row per anchor. braze_mark = the arm is written to Braze as cz_test_arms (the unmarked arm gets every message by default). Union new test layers in here.')
as
select
'2611_channel_mix' as layer_code
, m.anchor_key
, m.test_arm
, concat('2611_channel_mix:', m.test_arm) as arm_code
, m.test_arm in ('email_only', 'push_only') as braze_mark
from `marketing-data-442316.holdout.channel_mix_arm` m;

create or replace view `marketing-data-442316.holdout.braze_feed_desired`
options (description = 'Desired Braze attribute state per profile for active layers: cz_global_holdout, cz_program_holdouts (flight and test holdouts) and cz_test_arms (marked treatment arms of test layers). Only em/ph-anchored profiles with at least one mark appear; bz profiles are never written (no order link, D-052).')
as
with marks as (
select
a.anchor_key
, if(r.layer_type = 'global', 'global', 'program') as kind
, a.layer_code as code
from `marketing-data-442316.holdout.assignment` a
	join `marketing-data-442316.holdout.layer_register` r
	on r.layer_code = a.layer_code
	and r.status = 'active'
where 1=1
and a.arm = 'holdout'
and a.released_at is null
union all
select
t.anchor_key
, 'arm' as kind
, t.arm_code as code
from `marketing-data-442316.holdout.test_arm_v` t
	join `marketing-data-442316.holdout.layer_register` r
	on r.layer_code = t.layer_code
	and r.status = 'active'
where 1=1
and t.braze_mark
)
select
p.braze_id
, p.external_id
, logical_or(m.kind = 'global') as cz_global_holdout
, array_agg(if(m.kind = 'program', m.code, null) ignore nulls order by m.code) as cz_program_holdouts
, array_agg(if(m.kind = 'arm', m.code, null) ignore nulls order by m.code) as cz_test_arms
from `marketing-data-442316.holdout.profile_anchor` p
	join marks m
	on m.anchor_key = p.anchor_key
where 1=1
and p.anchor_type in ('em', 'ph')
group by 1, 2;

create or replace procedure `marketing-data-442316.holdout.refresh_braze_feed`()
options (description = 'Step 4 of the nightly job: compares braze_feed_desired with braze_cdi_state and records only changed values, with a payload holding only the changed keys (cz_global_holdout, cz_program_holdouts, cz_test_arms).')
begin
merge `marketing-data-442316.holdout.braze_cdi_state` t
using (
with d as (
select
coalesce(s.braze_id, f.braze_id) as braze_id
, s.synced_global
, s.synced_codes
, s.synced_test_arms
, ifnull(f.cz_global_holdout, false) as want_global
, array(
	select distinct c
	from unnest(array_concat(ifnull(s.synced_codes, []), ifnull(f.cz_program_holdouts, []))) c
	order by c
	) as want_codes
, array(
	select distinct c
	from unnest(array_concat(ifnull(s.synced_test_arms, []), ifnull(f.cz_test_arms, []))) c
	order by c
	) as want_arms
from `marketing-data-442316.holdout.braze_cdi_state` s
	full outer join `marketing-data-442316.holdout.braze_feed_desired` f
	on f.braze_id = s.braze_id
)
select
braze_id
, want_global
, want_codes
, want_arms
, ifnull(synced_global, false) != want_global as global_changed
, to_json_string(ifnull(synced_codes, [])) != to_json_string(want_codes) as codes_changed
, to_json_string(ifnull(synced_test_arms, [])) != to_json_string(want_arms) as arms_changed
from d
) n
on t.braze_id = n.braze_id
when matched and (n.global_changed or n.codes_changed or n.arms_changed) then
	update set
	synced_global = n.want_global
	, synced_codes = n.want_codes
	, synced_test_arms = n.want_arms
	, payload = json_strip_nulls(json_object(
		'cz_global_holdout', if(n.global_changed, to_json(n.want_global), null)
		, 'cz_program_holdouts', if(n.codes_changed, to_json(n.want_codes), null)
		, 'cz_test_arms', if(n.arms_changed, to_json(n.want_arms), null)
		))
	, updated_at = current_timestamp()
when not matched and (n.global_changed or n.codes_changed or n.arms_changed) then
	insert (braze_id, synced_global, synced_codes, synced_test_arms, payload, updated_at)
	values (
	n.braze_id
	, n.want_global
	, n.want_codes
	, n.want_arms
	, json_strip_nulls(json_object(
		'cz_global_holdout', if(n.global_changed, to_json(n.want_global), null)
		, 'cz_program_holdouts', if(n.codes_changed, to_json(n.want_codes), null)
		, 'cz_test_arms', if(n.arms_changed, to_json(n.want_arms), null)
		))
	, current_timestamp()
	);
end;
