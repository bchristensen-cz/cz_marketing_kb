create schema if not exists `marketing-data-442316.holdout`
options (
location = 'US'
, description = 'Owned holdout assignment: anchors, layers (global and flights), append-only assignments, Braze attribute feed. Steward-owned. Hashes and Braze ids only, no raw email or phone.'
);

create or replace function `marketing-data-442316.holdout.bucket`(seed string, anchor_key string)
returns int64
options (description = 'Holdout bucket 0-9999: sha256(seed|anchor_key), first 8 hex digits as a number, mod 10000. Matches the Python reference.')
as (
mod(cast(concat('0x', substr(to_hex(sha256(concat(seed, '|', anchor_key))), 1, 8)) as int64), 10000)
);

create or replace function `marketing-data-442316.holdout.email_anchor`(email string)
returns string
options (description = 'em: + sha256 hex of lower(trim(email)). Equals concat(em:, claude.order_customer.mapped_email_hash). NULL when blank or no @.')
as (
if(regexp_contains(lower(trim(email)), r'^[^@\s]+@[^@\s]+$'), concat('em:', to_hex(sha256(lower(trim(email))))), null)
);

create or replace function `marketing-data-442316.holdout.phone_anchor`(phone string)
returns string
options (description = 'ph: + sha256 hex of +1XXXXXXXXXX. 10 digits get a leading 1; 11 digits must start with 1; placeholder numbers return NULL.')
as (
(
select
if(
	d is null or d in ('19999999999', '10000000000', '11111111111', '11234567890', '15555555555')
	, null
	, concat('ph:', to_hex(sha256(concat('+', d))))
)
from (
select
case
	when length(regexp_replace(phone, r'[^0-9]', '')) = 10 then concat('1', regexp_replace(phone, r'[^0-9]', ''))
	when length(regexp_replace(phone, r'[^0-9]', '')) = 11 and starts_with(regexp_replace(phone, r'[^0-9]', ''), '1') then regexp_replace(phone, r'[^0-9]', '')
	else null
end as d
)
)
);

create table if not exists `marketing-data-442316.holdout.layer_register` (
layer_code string not null options (description = 'The seed. Flights: the flight code (yymm_name). Global: global_<year>.')
, layer_type string not null options (description = 'global or flight')
, holdout_pct numeric not null options (description = 'Percent held out, e.g. 5.00. Holdout = bucket < holdout_pct * 100.')
, status string not null options (description = 'planned, active, closed. Only active layers reach Braze.')
, start_date date options (description = 'First drop (flight) or first day of the global holdout')
, end_date date options (description = 'Last drop (flight) or last day of the global holdout')
, conversion_window_days int64 options (description = 'Days after end_date that orders still count')
, freeze_date date options (description = 'Flights: date the audience is frozen and holdout rows are written, at least 2 days before start_date')
, decision_date date options (description = 'The one date the result is read')
, audience_definition string options (description = 'Plain-English audience plus the BigQuery logic that reproduces it')
, owner string
, notes string
, created_at timestamp not null
, updated_at timestamp not null
)
cluster by layer_code
options (description = 'One row per holdout layer. The layer_code is the hash seed and must never change once status leaves planned.');

create table if not exists `marketing-data-442316.holdout.profile_anchor` (
braze_id string not null options (description = 'Braze internal user id; one row per profile')
, external_id string options (description = 'Braze external_id, refreshed nightly; not used for bucketing')
, anchor_key string not null options (description = 'em:<sha256 email>, else ph:<sha256 +1 phone>, else bz:<braze_id>. Sticky: set once, upgraded only from bz/ph to em.')
, anchor_type string not null options (description = 'em, ph or bz. Only em anchors join to orders, so only em anchors enter the read.')
, first_seen_at timestamp not null
, updated_at timestamp not null
)
cluster by anchor_key, braze_id
options (description = 'Phase 1 identity: one anchor per Braze profile, email-first. Profiles sharing an email share an anchor and therefore a group.');

create table if not exists `marketing-data-442316.holdout.anchor_change_log` (
braze_id string not null
, old_anchor_key string
, new_anchor_key string
, reason string not null
, changed_at timestamp not null
)
options (description = 'Every change to a profile anchor after first sight.');

create table if not exists `marketing-data-442316.holdout.assignment` (
layer_code string not null options (description = 'FK to layer_register.layer_code')
, anchor_key string not null
, bucket int64 not null options (description = 'holdout.bucket(layer_code, anchor_key)')
, arm string not null options (description = 'holdout or treatment')
, assigned_at timestamp not null
, released_at timestamp options (description = 'Set when the layer closes; the row is never deleted')
)
cluster by layer_code, arm, anchor_key
options (description = 'Append-only record of truth: who was in which group of which layer, and when. Reporting reads this, never Braze.');

create table if not exists `marketing-data-442316.holdout.layer_audience` (
layer_code string not null options (description = 'FK to layer_register.layer_code')
, anchor_key string not null
, added_at timestamp not null options (description = 'When the anchor entered the layer audience (freeze time for flights, nightly for the global layer)')
)
cluster by layer_code, anchor_key
options (description = 'Who is eligible for each layer, before the draw. Append-only. Global: every em/ph anchor. Flights: the audience snapshot taken at freeze_date.');

create or replace procedure `marketing-data-442316.holdout.write_assignments`(p_layer_code string)
options (description = 'Appends assignment rows (holdout or treatment) for every layer_audience anchor of this layer that has none yet. Never updates or deletes.')
begin
declare v_pct numeric default (
select
holdout_pct
from `marketing-data-442316.holdout.layer_register`
where layer_code = p_layer_code
);
if v_pct is null then
raise using message = concat('holdout.write_assignments: unknown layer_code ', p_layer_code);
end if;
insert into `marketing-data-442316.holdout.assignment` (layer_code, anchor_key, bucket, arm, assigned_at, released_at)
select
a.layer_code
, a.anchor_key
, `marketing-data-442316.holdout.bucket`(a.layer_code, a.anchor_key) as bucket
, if(`marketing-data-442316.holdout.bucket`(a.layer_code, a.anchor_key) < v_pct * 100, 'holdout', 'treatment') as arm
, current_timestamp()
, cast(null as timestamp)
from (
select distinct
layer_code
, anchor_key
from `marketing-data-442316.holdout.layer_audience`
where layer_code = p_layer_code
) a
where not exists (
select 1
from `marketing-data-442316.holdout.assignment` x
where x.layer_code = a.layer_code
and x.anchor_key = a.anchor_key
);
end;

create or replace view `marketing-data-442316.holdout.braze_feed_desired`
options (description = 'Desired Braze attribute state per profile for active layers: cz_global_holdout and cz_program_holdouts. Only em/ph-anchored profiles with at least one holdout appear; bz profiles are never written (no order link, D-052).')
as
select
p.braze_id
, p.external_id
, logical_or(r.layer_type = 'global') as cz_global_holdout
, array_agg(if(r.layer_type = 'flight', a.layer_code, null) ignore nulls order by a.layer_code) as cz_program_holdouts
from `marketing-data-442316.holdout.profile_anchor` p
	join `marketing-data-442316.holdout.assignment` a
	on a.anchor_key = p.anchor_key
	and a.arm = 'holdout'
	and a.released_at is null
	join `marketing-data-442316.holdout.layer_register` r
	on r.layer_code = a.layer_code
	and r.status = 'active'
where 1=1
and p.anchor_type in ('em', 'ph')
group by 1, 2;
