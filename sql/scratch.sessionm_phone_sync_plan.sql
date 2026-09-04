-- =============================================================================
-- scratch.sessionm_phone_sync_plan  (+ scratch.braze_phone_clear_plan, scratch.sessionm_phone_sync_log)
-- -----------------------------------------------------------------------------
-- desired-state plan for the braze -> sessionm phone sync. one row per sessionm
-- user whose phone list must change. nothing here calls an api; the worker
-- drains this table in (phase, action_id) order and writes to _log.
-- rules: see design/braze_sessionm_phone_sync_plan.md (confirmed 2026-09-04).
-- api semantics verified 2026-09-04: PUT replaces the whole phone_numbers list;
-- an empty array removes every phone.
-- =============================================================================

-- 1. braze phone winners: one owner per clean phone, plus every ranked loser (rn > 1) for the braze clear plan
create or replace table `marketing-data-442316`.scratch.braze_phone_ranked as
with braze_raw as (
  select external_id
    , safe_cast(external_id as int64) as cust_id
    , regexp_replace(phone, r'\D', '') as raw_digits
  from `marketing-data-442316`.braze.users
  where phone is not null and phone <> ''
    and regexp_contains(external_id, r'^\d+$')
)
, braze_valid as (
  select external_id, cust_id, phone10
    , phone10 = repeat(substr(phone10, 1, 1), 10)
      or phone10 in ('1234567890', '0123456789', '1231231234')
      or substr(phone10, 1, 1) in ('0', '1') as is_junk
  from (
    select *
      , case when length(raw_digits) = 10 then raw_digits
             when length(raw_digits) = 11 and starts_with(raw_digits, '1') then substr(raw_digits, 2)
        end as phone10
    from braze_raw)
  where phone10 is not null
)
, eng as (
  select external_user_id
    , count(*) as human_eng_365
    , max(event_date) as last_eng_date
  from (
    select external_user_id, event_date from `marketing-data-442316`.braze.email_open
      where event_date >= date_sub(current_date(), interval 365 day) and not coalesce(lower(machine_open) = 'true', false)
    union all select external_user_id, event_date from `marketing-data-442316`.braze.email_click
      where event_date >= date_sub(current_date(), interval 365 day) and not coalesce(is_suspected_bot_click, false)
    union all select external_user_id, event_date from `marketing-data-442316`.braze.pushnotification_open
      where event_date >= date_sub(current_date(), interval 365 day)
    union all select external_user_id, event_date from `marketing-data-442316`.braze.sms_shortlinkclick
      where event_date >= date_sub(current_date(), interval 365 day) and not coalesce(is_suspected_bot_click, false)
    union all select external_user_id, event_date from `marketing-data-442316`.braze.rcs_click
      where event_date >= date_sub(current_date(), interval 365 day) and not coalesce(is_suspected_bot_click, false)
    union all select external_user_id, event_date from `marketing-data-442316`.braze.rcs_read
      where event_date >= date_sub(current_date(), interval 365 day)
  )
  where external_user_id is not null
  group by 1
)
, ranked as (
  select b.*
    , ca.last_order_date
    , ca.lifetime_net_sales
    , e.human_eng_365
    , e.last_eng_date
    , count(*) over (partition by b.phone10) as n_profiles_on_phone
    , row_number() over (partition by b.phone10
        order by greatest(coalesce(ca.last_order_date, date '1900-01-01'), coalesce(e.last_eng_date, date '1900-01-01')) desc
          , coalesce(ca.lifetime_net_sales, 0) desc
          , coalesce(e.human_eng_365, 0) desc
          , b.cust_id asc) as rn
  from braze_valid b
  left join `marketing-data-442316`.sales_ops.customer_attribute ca on ca.mapped_cust_id = b.cust_id
  left join eng e on e.external_user_id = b.external_id
  where not b.is_junk
)
select * from ranked;

-- 2. sessionm desired-state plan (one row per sessionm user whose list changes)
create or replace table `marketing-data-442316`.scratch.sessionm_phone_sync_plan
cluster by phase, sm_user_id as
with winners as (select * from `marketing-data-442316`.scratch.braze_phone_ranked where rn = 1)
, sm_map as (
  select lower(user_id) as sm_user_id, external_user_id
  from `marketing-data-442316`.sessionM.external_user_mappings
  where external_user_id_type = 'cafezupas'
  qualify row_number() over (partition by external_user_id order by updated_at desc) = 1
)
, sm_rows as (
  select lower(user_id) as sm_user_id, regexp_replace(phone_number, r'\D', '') as digits, updated_at
  from `marketing-data-442316`.sessionM.user_phone_numbers
  where create_date >= '2000-01-01' and phone_number is not null
  qualify row_number() over (partition by phone_number_id, user_id order by etl_time desc, updated_at desc) = 1
    and deleted_at is null
)
, sm_cur as (
  select sm_user_id, digits, max(updated_at) as updated_at
    , digits = repeat(substr(digits, 1, 1), 10)
      or digits in ('1234567890', '0123456789', '1231231234')
      or substr(digits, 1, 1) in ('0', '1')
      or length(digits) <> 10 as is_junk
  from sm_rows
  group by 1, 2
)
-- one braze winner per sessionm user (69 users receive two; lowest ext id kept)
, targets as (
  select m.sm_user_id, w.external_id, w.phone10, w.n_profiles_on_phone
    , w.last_order_date, w.lifetime_net_sales, w.human_eng_365, w.last_eng_date
  from winners w
  join sm_map m on m.external_user_id = w.external_id
  qualify row_number() over (partition by m.sm_user_id order by w.cust_id) = 1
)
, claimed as (select distinct phone10 as digits from targets)
-- non-target holders of clean, unclaimed phones: if several hold one number, the most recently updated keeps it
, keep_nontarget as (
  select c.sm_user_id, c.digits
  from sm_cur c
  left join targets t on t.sm_user_id = c.sm_user_id
  left join claimed k on k.digits = c.digits
  where t.sm_user_id is null and k.digits is null and not c.is_junk
  qualify row_number() over (partition by c.digits order by c.updated_at desc, c.sm_user_id) = 1
)
, users as (
  select sm_user_id from sm_cur
  union distinct select sm_user_id from targets
)
, cur_agg as (
  select sm_user_id
    , array_agg(digits order by digits) as current_phones
    , array_agg(if(is_junk, digits, null) ignore nulls order by digits) as current_junk
  from sm_cur group by 1
)
, keep_agg as (select sm_user_id, array_agg(digits order by digits) as keep_phones from keep_nontarget group by 1)
, state as (
  select u.sm_user_id
    , t.external_id
    , t.n_profiles_on_phone
    , t.last_order_date, t.lifetime_net_sales, t.human_eng_365, t.last_eng_date
    , coalesce(c.current_phones, []) as current_phones
    , coalesce(c.current_junk, []) as current_junk
    , case when t.sm_user_id is not null then [t.phone10] else coalesce(k.keep_phones, []) end as desired_phones
  from users u
  left join targets t on t.sm_user_id = u.sm_user_id
  left join cur_agg c on c.sm_user_id = u.sm_user_id
  left join keep_agg k on k.sm_user_id = u.sm_user_id
)
, diff as (
  select *
    , array(select d from unnest(current_phones) d where d not in unnest(desired_phones)) as phones_removed
    , array(select d from unnest(desired_phones) d where d not in unnest(current_phones)) as phones_added
  from state
)
, actions as (
  select *
    , case when array_length(phones_added) = 0 and array_length(desired_phones) = 0 then 'remove_all'
           when array_length(phones_added) = 0 then 'remove_some'
           when array_length(phones_removed) = 0 and array_length(current_phones) = 0 then 'add'
           when array_length(phones_removed) = 0 then 'add_alongside'
           else 'replace' end as action_type
    -- phase 1 = pure removals, 2 = replaces, 3 = pure adds. a number is always freed before it is granted.
    , case when array_length(phones_added) = 0 then 1
           when array_length(phones_removed) > 0 then 2
           else 3 end as phase
    , (select count(*) from unnest(phones_removed) r join claimed k on k.digits = r) as removed_claimed_by_winner
  from diff
  where array_length(phones_removed) > 0 or array_length(phones_added) > 0
)
select row_number() over (order by phase, sm_user_id) as action_id
  , phase
  , action_type
  , case when external_id is not null and array_length(phones_removed) > 0 and array_length(phones_added) = 0 then 'braze_winner_drop_extras'
         when external_id is not null and array_length(phones_added) > 0 and array_length(phones_removed) > 0 then 'braze_winner_replace'
         when external_id is not null then 'braze_winner_add'
         when array_length(current_junk) = array_length(phones_removed) then 'junk_only'
         when removed_claimed_by_winner > 0 then 'conflict_holder_for_braze_winner'
         else 'sessionm_duplicate_loser' end as reason
  , sm_user_id
  , external_id as braze_external_id
  , current_phones
  , desired_phones
  , phones_removed
  , phones_added
  , n_profiles_on_phone as braze_profiles_sharing_winner_phone
  , last_order_date, lifetime_net_sales, human_eng_365, last_eng_date
  , to_json_string(struct(struct(
        array(select as struct d as phone_number, 'mobile' as phone_type, ['primary'] as preference_flags, false as verified_ownership
              from unnest(desired_phones) d) as phone_numbers) as user)) as request_body
  , 'planned' as status
  , current_timestamp() as built_at
from actions;

-- 3. braze side: clear the phone on junk and losing profiles so the next sync does not recreate conflicts
create or replace table `marketing-data-442316`.scratch.braze_phone_clear_plan as
with braze_raw as (
  select external_id, regexp_replace(phone, r'\D', '') as raw_digits
  from `marketing-data-442316`.braze.users
  where phone is not null and phone <> '' and regexp_contains(external_id, r'^\d+$')
)
, flagged as (
  select external_id, phone10
    , phone10 is null
      or phone10 = repeat(substr(phone10, 1, 1), 10)
      or phone10 in ('1234567890', '0123456789', '1231231234')
      or substr(phone10, 1, 1) in ('0', '1') as is_junk
  from (
    select external_id
      , case when length(raw_digits) = 10 then raw_digits
             when length(raw_digits) = 11 and starts_with(raw_digits, '1') then substr(raw_digits, 2) end as phone10
    from braze_raw)
)
select f.external_id
  , f.phone10
  , case when f.is_junk then 'junk' else 'lost_to_other_profile' end as reason
  , r.rn as braze_rank_on_phone
  , (select w.external_id from `marketing-data-442316`.scratch.braze_phone_ranked w where w.phone10 = f.phone10 and w.rn = 1) as winner_external_id
  , 'planned' as status
  , current_timestamp() as built_at
from flagged f
left join `marketing-data-442316`.scratch.braze_phone_ranked r on r.external_id = f.external_id
where f.is_junk or r.rn > 1;

-- 4. api call log (append-only)
create table if not exists `marketing-data-442316`.scratch.sessionm_phone_sync_log (
    log_id            string
  , action_id         int64
  , sm_user_id        string
  , attempt           int64
  , requested_at      timestamp
  , http_status       int64
  , request_body      string
  , response_body     string
  , result            string        -- succeeded | failed | conflict
  , batch_label       string
);
