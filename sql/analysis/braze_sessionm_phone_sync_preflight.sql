-- =============================================================================
-- braze_sessionm_phone_sync_preflight.sql
-- -----------------------------------------------------------------------------
-- purpose : read-only pre-flight for pushing braze phone numbers into sessionm.
--           produces the full action plan at (sm_user_id) grain plus the
--           category counts quoted in design/braze_sessionm_phone_sync_plan.md.
--           steward-only: reads raw braze.* and sessionM.* (no mart holds phones).
--
-- rules   : phone10   = digits only; 10 digits kept, 11 digits starting with 1
--                       drop the leading 1, anything else invalid.
--           junk      = all one digit (9999999999 ...), 1234567890 / 0123456789 /
--                       1231231234, or first digit 0/1 (not a NANP area code).
--           primary owner of a phone shared by several braze profiles =
--                       most recent activity (last order date or last human
--                       engagement date, 365d) desc, lifetime_net_sales desc,
--                       human engagements 365d desc, lowest external_id.
--           braze external_id -> sessionm user_id via
--                       sessionM.external_user_mappings (external_user_id_type
--                       = 'cafezupas'), latest updated_at per external_user_id.
--           sessionm current phones = user_phone_numbers, latest row per
--                       (phone_number_id, user_id), deleted_at is null.
-- =============================================================================

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
, winners as (select * from ranked where rn = 1)
, braze_losers as (select * from ranked where rn > 1)          -- clear phone on these braze profiles
, sm_map as (
  select lower(user_id) as sm_user_id, external_user_id
  from `marketing-data-442316`.sessionM.external_user_mappings
  where external_user_id_type = 'cafezupas'
  qualify row_number() over (partition by external_user_id order by updated_at desc) = 1
)
, sm_cur as (
  select sm_user_id, digits
    , digits = repeat(substr(digits, 1, 1), 10)
      or digits in ('1234567890', '0123456789', '1231231234')
      or substr(digits, 1, 1) in ('0', '1')
      or length(digits) <> 10 as is_junk
  from (
    select lower(user_id) as sm_user_id, regexp_replace(phone_number, r'\D', '') as digits
    from `marketing-data-442316`.sessionM.user_phone_numbers
    where create_date >= '2000-01-01'
    qualify row_number() over (partition by phone_number_id, user_id order by etl_time desc, updated_at desc) = 1
      and deleted_at is null)
)
, desired as (
  select m.sm_user_id, w.external_id, w.cust_id, w.phone10
    , count(*) over (partition by m.sm_user_id) as winners_per_sm_user
    , row_number() over (partition by m.sm_user_id order by w.cust_id) as rn
  from winners w
  join sm_map m on m.external_user_id = w.external_id
)
, d1 as (select * from desired where rn = 1)
, cur_owner as (
  select digits, array_agg(sm_user_id) as owners, count(*) as n_owners
  from sm_cur where not is_junk group by 1
)
, plan as (
  select d.sm_user_id, d.external_id, d.phone10
    , exists (select 1 from sm_cur c where c.sm_user_id = d.sm_user_id and c.digits = d.phone10) as sm_already_has_it
    , (select count(*) from sm_cur c where c.sm_user_id = d.sm_user_id) as sm_phones_on_user
    , coalesce((select n_owners from cur_owner o where o.digits = d.phone10 and d.sm_user_id not in unnest(o.owners)), 0) as other_sm_users_holding_phone
  from d1 d
)
select case
    when sm_already_has_it and sm_phones_on_user = 1 and other_sm_users_holding_phone = 0 then '1 noop_already_correct'
    when sm_already_has_it then '2 has_it_drop_extras_or_other_holders'
    when sm_phones_on_user = 0 then '3 add_phone'
    else '4 replace_phone'
  end as action
  , count(*) as sm_users
  , countif(other_sm_users_holding_phone > 0) as with_conflict_on_other_sm_user
  , sum(other_sm_users_holding_phone) as conflict_rows_to_remove_first
from plan
group by 1 order by 1
