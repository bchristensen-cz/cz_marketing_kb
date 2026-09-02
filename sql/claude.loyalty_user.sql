-- =====================================================================================
-- claude.loyalty_user — identity spine. One row per sm_external_user_id.
--
-- MATERIALIZED 2026-09-01 (steward). Was section 1 of claude.loyalty_views.sql, deployed as a
-- view. Measured that day: the view cost ~2.6M slot-ms per evaluation (three window-function
-- CTEs over 1.8M users / 3.1M mappings / 1.8M tier events, none partition-prunable), and
-- claude.order_customer LEFT JOINs it for one column (account_type), so every order query
-- paid it — 483k slot-ms for a 30-day aggregate that costs 2.4k with the table. SessionM loads
-- once daily, so a view bought no freshness.
--
-- Deployed as a scheduled query: daily 04:30 America/Denver, after the SessionM load.
-- Deployed text below is authoritative (copied from the scheduled query 2026-09-01). Diff against
-- the scheduled-query config before every redeploy.
--
-- ⚠️ COLUMN RENAME 2026-09-01 (steward), same day as materialization:
--   old `email`            (raw SessionM address, keeps cater_ prefix, unique per member) -> `full_email`
--   old `email_normalized` (cater_ stripped)                                            -> `email`
-- `email` is therefore NO LONGER unique: 91,829 rows are stripped, 45,544 addresses are shared by
-- 2+ members. Identity matching against SessionM must use full_email; `email` is the person's
-- real address for comms and for comparing to order_customer.mapped_email (which is also stripped).
-- =====================================================================================

create or replace table `marketing-data-442316.claude.loyalty_user` 
cluster by sm_external_user_id, email, member_program
as 

with cafezupas_id as (
  select
    eum.user_id
  , eum.external_user_id
  , row_number() over (
      partition by eum.user_id
      order by eum.updated_at desc, eum.external_user_id
    ) as rn
  from `marketing-data-442316`.sessionM.external_user_mappings eum
  where 1=1
    and eum.external_user_id_type = 'cafezupas'
)
-- Program membership comes from the TIER SYSTEM, not the point account (steward,
-- 2026-07-28). Two live systems:
--   0B6461B8-B1D5-4D81-8C31-2F21A914DE1C  Cafe Zupas VIP Program       (individual)
--   1D7B47AB-E3FE-4E62-916F-01973964B662  Cafe Zupas Catering Program  (catering)
--   23755DBF-29D9-4A7B-AD2E-0E411EDF7815  [CATest] test system         (excluded)
-- The tier split is far cleaner than the point-account split: only 4 members sit in
-- both systems, vs 264 holding both point accounts. It is also broader — 89,801
-- catering members by tier vs 42,899 holding a catering point account, because the
-- point account only materialises once a member has points.
, tier_membership as (
  select
    tmh.user_id
  , tmh.tier_system_id
  , tl.name as tier_level_name
  , tl.rank as tier_level_rank
  , date(tmh.joined_at) as tier_joined_date
  , row_number() over (
      partition by tmh.user_id, tmh.tier_system_id
      order by tmh.joined_at desc, tmh.created_at desc
    ) as rn
  from `marketing-data-442316`.sessionM.tier_member_history tmh
  left join `marketing-data-442316`.sessionM.tier_levels tl
    on tl.tier_level_id = tmh.tier_level_id
  where 1=1
    and tmh.exited_at is null
    and tmh.user_id != '00000000-0000-0000-DEAD-000000000000'  -- tombstone sentinel, not a person
    and tmh.tier_system_id in (
      '0B6461B8-B1D5-4D81-8C31-2F21A914DE1C'
    , '1D7B47AB-E3FE-4E62-916F-01973964B662'
    )
)
, program as (
  select
    user_id
  , logical_or(tier_system_id = '0B6461B8-B1D5-4D81-8C31-2F21A914DE1C') as is_individual_member
  , logical_or(tier_system_id = '1D7B47AB-E3FE-4E62-916F-01973964B662') as is_catering_member
  , max(if(tier_system_id = '1D7B47AB-E3FE-4E62-916F-01973964B662', tier_level_name, null)) as catering_tier_name
  , max(if(tier_system_id = '1D7B47AB-E3FE-4E62-916F-01973964B662', tier_level_rank, null)) as catering_tier_rank
  , max(if(tier_system_id = '1D7B47AB-E3FE-4E62-916F-01973964B662', tier_joined_date, null)) as catering_tier_joined_date
  , max(if(tier_system_id = '0B6461B8-B1D5-4D81-8C31-2F21A914DE1C', tier_joined_date, null)) as individual_joined_date
  from tier_membership
  where 1=1
    and rn = 1
  group by 1
)
-- Catering tier history WITHOUT the exited_at filter, so the view can answer
-- point-in-time and lapse questions. `tier_membership` above is current-state only;
-- an exited catering member correctly shows is_catering_member = false there, which
-- makes the exit invisible. This CTE keeps it.
--
-- Why this matters (steward, 2026-07-29): the `cater_` email prefix CANNOT substitute
-- for tier membership. All 181 members who exited the catering tier still carry the
-- prefix — it is provisioning history, not current state. See the gotcha in
-- data_dictionaries/claude.loyalty_user.md.
, catering_history as (
  select
    tmh.user_id                        as user_id
  , min(date(tmh.joined_at))           as catering_first_joined_date
  , max(date(tmh.exited_at))           as catering_last_exited_date  -- max() skips nulls
  from `marketing-data-442316`.sessionM.tier_member_history tmh
  where 1=1
    and tmh.tier_system_id = '1D7B47AB-E3FE-4E62-916F-01973964B662'
    and tmh.user_id != '00000000-0000-0000-DEAD-000000000000'  -- tombstone sentinel, 61 tier events
  group by 1
)
select
  u.user_id
, safe_cast(cz.external_user_id as int64) as sm_external_user_id
, u.player_id
, lower(trim(u.email)) as full_email
, split(lower(trim(u.email)), '@')[safe_offset(1)] as email_domain
-- Catering accounts are provisioned in SessionM with a 'cater_' prefix because SessionM
-- enforces unique emails. email_normalized strips it for display/comms ONLY — it is NOT
-- an identity key: 39,500 stripped catering addresses collide with a real individual
-- account, which is the exact collision the prefix exists to prevent.
, regexp_replace(lower(trim(u.email)), r'^cater_', '') as email
, starts_with(lower(trim(u.email)), 'cater_') as is_cater_email
, u.first_name
, u.last_name
, u.birthdate
, u.zip
, u.country
, date(u.registered_timestamp) as registered_date
, u.loyalty_status
, u.registered_application_id
, case
    when p.is_individual_member and p.is_catering_member then 'both'
    when p.is_catering_member then 'catering'
    when p.is_individual_member then 'individual'
    else null
  end as member_program
, ifnull(p.is_individual_member, false) as is_individual_member
, ifnull(p.is_catering_member, false) as is_catering_member
, p.catering_tier_name
, p.catering_tier_rank
, p.catering_tier_joined_date
, p.individual_joined_date
-- Catering lifecycle. is_catering_member is CURRENT state; these three carry history.
, ch.user_id is not null as was_ever_catering_member
, ch.catering_first_joined_date
, ch.catering_last_exited_date
, date(u.created_at) as created_date
, date(u.updated_at) as updated_date
from `marketing-data-442316`.sessionM.users u
left join cafezupas_id cz
  on cz.user_id = u.user_id
 and cz.rn = 1
left join program p
  on p.user_id = u.user_id
left join catering_history ch
  on ch.user_id = u.user_id
-- GRAIN CHANGE 2026-07-29 (steward): one row per sm_external_user_id, not per user_id.
-- The cafezupas_id CTE dedupes one direction (many mappings -> one user_id); the collision
-- is the OTHER direction. 420 external ids carried two sessionM user_ids each (840 rows),
-- so any join from an order mart on sm_external_user_id fanned out and silently broke
-- order_customer's one-row-per-brink_order_id guarantee.
--
-- Tiebreak is updated_at, NOT created_at: created_at is identical on both rows in most
-- clusters (e.g. ext id 94469, both 2023-05-08) so it cannot separate them. updated_at
-- separates every cluster and picks the live record — the losers are overwhelmingly
-- synthetic (126 temp-<extid>-2@example.com, 181 @privaterelay.appleid.com).
--
-- `or cz.external_user_id is null` is REQUIRED: BigQuery groups all NULLs into one
-- partition, so without it the 325 users with no cafezupas mapping collapse to a single row.
--
-- KNOWN COST (measured 2026-07-29): all 420 losing user_ids have campaign participation,
-- 407 have offer usage, 198 have points activity. The other loyalty_* views LEFT JOIN this
-- one from the activity side, so those rows survive but their identity columns go NULL —
-- the activity becomes unattributed rather than disappearing. See the gotcha in
-- data_dictionaries/claude.loyalty_user.md.
qualify row_number() over(
  partition by safe_cast(cz.external_user_id as int64)
  order by u.updated_at desc, u.registered_timestamp desc, u.user_id
) = 1
   or cz.external_user_id is null
;
