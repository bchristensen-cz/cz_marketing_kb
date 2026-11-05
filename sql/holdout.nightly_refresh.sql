alter table `marketing-data-442316.holdout.layer_register`
add column if not exists audience_sql string options (description = 'Flights: a select returning anchor_key for qualifying buyers between @from_date and @to_date (dates, America/Denver business dates). Run nightly by holdout.nightly_refresh while status = active. NULL for the global layer, which takes every em/ph anchor.');

create or replace procedure `marketing-data-442316.holdout.nightly_refresh`()
options (description = 'Nightly holdout job (scheduled query "holdout nightly refresh"): 1) refresh profile_anchor from braze.users, 2) append new audience anchors for every active layer, 3) draw assignments for them, 4) record changed Braze attribute values in braze_cdi_state for CDI. Every step only appends or upgrades, so reruns are safe.')
begin
declare v_to_date date default date_sub(current_date('America/Denver'), interval 1 day);

-- 1. profile anchors: new profiles get an anchor, bz/ph anchors upgrade to em when an email appears, nothing else changes
create temp table src as
select
u.braze_id
, any_value(u.external_id) as external_id
, any_value(coalesce(
	`marketing-data-442316.holdout.email_anchor`(u.email)
	, `marketing-data-442316.holdout.phone_anchor`(u.phone)
	, concat('bz:', u.braze_id)
)) as anchor_key
from `marketing-data-442316.braze.users` u
where 1=1
and u.braze_id is not null
group by 1;

insert into `marketing-data-442316.holdout.anchor_change_log` (braze_id, old_anchor_key, new_anchor_key, reason, changed_at)
select
t.braze_id
, t.anchor_key
, s.anchor_key
, concat('upgrade_', t.anchor_type, '_to_em')
, current_timestamp()
from `marketing-data-442316.holdout.profile_anchor` t
	join src s
	on s.braze_id = t.braze_id
where 1=1
and t.anchor_type in ('bz', 'ph')
and starts_with(s.anchor_key, 'em:');

merge `marketing-data-442316.holdout.profile_anchor` t
using src s
on t.braze_id = s.braze_id
when not matched then
	insert (braze_id, external_id, anchor_key, anchor_type, first_seen_at, updated_at)
	values (s.braze_id, s.external_id, s.anchor_key, substr(s.anchor_key, 1, 2), current_timestamp(), current_timestamp())
when matched and t.anchor_type in ('bz', 'ph') and starts_with(s.anchor_key, 'em:') then
	update set anchor_key = s.anchor_key, anchor_type = 'em', external_id = s.external_id, updated_at = current_timestamp()
when matched and ifnull(t.external_id, '') != ifnull(s.external_id, '') then
	update set external_id = s.external_id, updated_at = current_timestamp();

drop table src;

-- 2 and 3. audiences and assignments for active layers
for layer in (
select
layer_code
, layer_type
, audience_sql
, start_date
from `marketing-data-442316.holdout.layer_register`
where 1=1
and status = 'active'
and (end_date is null or end_date >= v_to_date)
)
do
	if layer.layer_type = 'global' then
		insert into `marketing-data-442316.holdout.layer_audience` (layer_code, anchor_key, added_at)
		select distinct
		layer.layer_code
		, p.anchor_key
		, current_timestamp()
		from `marketing-data-442316.holdout.profile_anchor` p
		where 1=1
		and p.anchor_type in ('em', 'ph')
		and not exists (
		select 1
		from `marketing-data-442316.holdout.layer_audience` x
		where x.layer_code = layer.layer_code
		and x.anchor_key = p.anchor_key
		);
	elseif layer.audience_sql is not null then
		-- 3-day lookback picks up orders whose identity resolved late; not exists keeps reruns from duplicating
		execute immediate concat(
			'insert into `marketing-data-442316.holdout.layer_audience` (layer_code, anchor_key, added_at) '
			, 'select distinct @layer_code, a.anchor_key, current_timestamp() from ('
			, layer.audience_sql
			, ') a where a.anchor_key is not null and not exists (select 1 from `marketing-data-442316.holdout.layer_audience` x '
			, 'where x.layer_code = @layer_code and x.anchor_key = a.anchor_key)'
		)
		using
			layer.layer_code as layer_code
			, greatest(coalesce(layer.start_date, v_to_date), date_sub(v_to_date, interval 2 day)) as from_date
			, v_to_date as to_date;
	end if;

	call `marketing-data-442316.holdout.write_assignments`(layer.layer_code);
end for;

-- 4. record only changed Braze attribute values for the CDI sync
call `marketing-data-442316.holdout.refresh_braze_feed`();
end;
