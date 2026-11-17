-- 2611_channel_mix: flight-level channel-mix test, week of 2026-11-16
-- question: does a customer who gets email AND push respond differently from one who gets only one?
-- base: identified person buyers (12 months, ex catering) with a deliverable email AND a push token proven by a send in the last 60 days
-- arms off one bucket draw (seed = layer_code): 0-999 holdout, 1000-3999 email_only, 4000-6999 push_only, 7000-9999 email_push
-- layer_type = 'test': the nightly job keeps it but braze_feed_desired writes nothing for it (no data points);
-- Braze reads the two exclusion views below through CDI Segment Extensions (no data points logged)

-- 1. register (planned until the freeze)
insert into `marketing-data-442316.holdout.layer_register` (layer_code, layer_type, holdout_pct, status, start_date, end_date, conversion_window_days, freeze_date, decision_date, audience_definition, owner, notes, created_at, updated_at)
values (
'2611_channel_mix'
, 'test'
, numeric '10.00'
, 'planned'
, null
, null
, 2
, null
, null
, 'Identified person buyers in claude.order_customer in the 12 months to the freeze (ex catering) with an em anchor where at least one Braze profile is email subscribed/opted_in with no email bounce in 6 months AND at least one profile received a push in the last 60 days. Frozen once; see sql/holdout_flights/2611_channel_mix.sql step 4.'
, 'bchristensen'
, 'Arms: bucket 0-999 holdout, 1000-3999 email_only, 4000-6999 push_only, 7000-9999 email_push. Outcome per person = any order in the D-026 window (24h, Saturday 48h) of any flight send instant, intent to treat by assigned arm.'
, current_timestamp()
, current_timestamp()
);

-- 2. arm per anchor
create or replace view `marketing-data-442316.holdout.channel_mix_arm`
options (description = '2611_channel_mix arm per anchor, derived from assignment.bucket: holdout <1000, email_only <4000, push_only <7000, else email_push.')
as
select
a.anchor_key
, a.bucket
, case
	when a.arm = 'holdout' then 'holdout'
	when a.bucket < 4000 then 'email_only'
	when a.bucket < 7000 then 'push_only'
	else 'email_push'
end as test_arm
, a.assigned_at
from `marketing-data-442316.holdout.assignment` a
where 1=1
and a.layer_code = '2611_channel_mix'
and a.released_at is null;

-- 3. CDI Segment Extension sources (external_user_id, every profile behind the anchor, including profiles created after the freeze)
create or replace view `marketing-data-442316.holdout.cdi_seg_2611_channel_mix_no_email`
options (description = 'Braze CDI Segment Extension: profiles that must NOT get the 2611_channel_mix email (holdout, push_only).')
as
select distinct
p.external_id as external_user_id
from `marketing-data-442316.holdout.channel_mix_arm` m
	join `marketing-data-442316.holdout.profile_anchor` p
	on p.anchor_key = m.anchor_key
where 1=1
and m.test_arm in ('holdout', 'push_only')
and p.external_id is not null;

create or replace view `marketing-data-442316.holdout.cdi_seg_2611_channel_mix_no_push`
options (description = 'Braze CDI Segment Extension: profiles that must NOT get the 2611_channel_mix push (holdout, email_only).')
as
select distinct
p.external_id as external_user_id
from `marketing-data-442316.holdout.channel_mix_arm` m
	join `marketing-data-442316.holdout.profile_anchor` p
	on p.anchor_key = m.anchor_key
where 1=1
and m.test_arm in ('holdout', 'email_only')
and p.external_id is not null;

-- 4. FREEZE: run once, the day before the first drop, after the nightly job (replace the dates)
-- insert into `marketing-data-442316.holdout.layer_audience` (layer_code, anchor_key, added_at)
-- with push_ok as (
-- select distinct
-- user_id as braze_id
-- from `marketing-data-442316.braze.pushnotification_send`
-- where event_date between date_sub(current_date('America/Denver'), interval 60 day) and current_date('America/Denver')
-- )
-- , email_bad as (
-- select distinct
-- user_id as braze_id
-- from `marketing-data-442316.braze.email_bounce`
-- where event_date between date_sub(current_date('America/Denver'), interval 6 month) and current_date('America/Denver')
-- )
-- , reach as (
-- select
-- p.anchor_key
-- from `marketing-data-442316.holdout.profile_anchor` p
-- 	join `marketing-data-442316.braze.users` u
-- 	on u.braze_id = p.braze_id
-- 	left join push_ok po
-- 	on po.braze_id = p.braze_id
-- 	left join email_bad eb
-- 	on eb.braze_id = p.braze_id
-- where p.anchor_type = 'em'
-- group by 1
-- having logical_or(u.email_subscribe in ('subscribed', 'opted_in') and eb.braze_id is null)
-- and logical_or(po.braze_id is not null)
-- )
-- , buyers as (
-- select distinct
-- concat('em:', oc.mapped_email_hash) as anchor_key
-- from `marketing-data-442316.claude.order_customer` oc
-- where oc.business_date between date_sub(current_date('America/Denver'), interval 365 day) and date_sub(current_date('America/Denver'), interval 1 day)
-- and oc.customer_type = 'person'
-- and not oc.is_catering
-- and oc.mapped_email_hash is not null
-- )
-- select
-- '2611_channel_mix'
-- , r.anchor_key
-- , current_timestamp()
-- from reach r
-- 	join buyers b
-- 	on b.anchor_key = r.anchor_key
-- where not exists (select 1 from `marketing-data-442316.holdout.layer_audience` x where x.layer_code = '2611_channel_mix');
--
-- call `marketing-data-442316.holdout.write_assignments`('2611_channel_mix');
--
-- update `marketing-data-442316.holdout.layer_register`
-- set status = 'active'
-- , freeze_date = current_date('America/Denver')
-- , start_date = date '<first drop>'
-- , end_date = date '<last drop>'
-- , decision_date = date '<last drop + 3>'
-- , updated_at = current_timestamp()
-- where layer_code = '2611_channel_mix';
