-- integrity checks for scratch.sessionm_phone_sync_plan. every "must be 0" column is a build failure, not a warning.
-- run after every rebuild of the plan and before every live batch. 2026-09-04 result: all zeros.
with sm_rows as (
  select lower(user_id) as sm_user_id, regexp_replace(phone_number, r'\D', '') as digits
  from `marketing-data-442316`.sessionM.user_phone_numbers
  where create_date >= '2000-01-01' and phone_number is not null
  qualify row_number() over (partition by phone_number_id, user_id order by etl_time desc, updated_at desc) = 1
    and deleted_at is null
)
, cur as (select distinct sm_user_id, digits from sm_rows)
, plan as (select * from `marketing-data-442316`.scratch.sessionm_phone_sync_plan)
, final_state as (
  select p.sm_user_id, d as digits from plan p, unnest(p.desired_phones) d
  union all
  select c.sm_user_id, c.digits from cur c where not exists (select 1 from plan p where p.sm_user_id = c.sm_user_id)
)
, dup_final as (select digits, count(*) as n from final_state group by 1 having n > 1)
, removals as (select p.sm_user_id, r as digits, p.phase from plan p, unnest(p.phones_removed) r)
, adds as (select p.sm_user_id, a as digits, p.phase from plan p, unnest(p.phones_added) a)
, add_blockers as (
  select a.sm_user_id, a.digits, a.phase, c.sm_user_id as holder
    , (select min(phase) from removals r where r.sm_user_id = c.sm_user_id and r.digits = a.digits) as holder_removal_phase
  from adds a
  join cur c on c.digits = a.digits and c.sm_user_id <> a.sm_user_id
)
select (select count(*) from plan) as plan_rows
  , (select count(distinct sm_user_id) from plan) as plan_users                       -- must equal plan_rows
  , (select count(*) from dup_final) as final_phones_on_multiple_users                 -- must be 0
  , (select count(*) from final_state where digits = repeat(substr(digits, 1, 1), 10) or substr(digits, 1, 1) in ('0', '1') or length(digits) <> 10) as final_junk  -- must be 0
  , (select count(*) from add_blockers where holder_removal_phase is null) as adds_blocked_forever            -- must be 0
  , (select count(*) from add_blockers where holder_removal_phase >= phase) as adds_blocked_same_or_later_phase  -- must be 0
  , (select count(*) from plan where array_length(desired_phones) > 1) as users_left_with_multiple_phones
