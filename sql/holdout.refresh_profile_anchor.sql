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
