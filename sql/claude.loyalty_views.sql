-- =====================================================================================
-- claude.loyalty_* — SessionM loyalty interface layer
-- =====================================================================================
-- Authorized views over sessionM.* answering the five most-asked loyalty questions:
--   1. loyalty_user                  identity spine (sessionM user_id <-> cafezupas id <-> email)
--   2. loyalty_points_balance        current points balance per member
--   3. loyalty_points_expiring       unspent lots with the date they will expire
--   4. loyalty_points_activity       points issued / redeemed / expired / adjusted ledger
--   5. loyalty_offer_usage           offers issued and redeemed
--   6. loyalty_campaign_participation  campaign achievement + award participation
--
-- Design decisions (2026-07-28, steward):
--   * Views, not tables. The whole point ledger is 11.6M rows / ~1.5 GB, so even the FIFO
--     lot allocation in loyalty_points_expiring runs cheaply on the fly. Views cannot go
--     stale, which avoids the repo-committed-but-not-deployed gap.
--   * Identity is exposed three ways on every view: sessionM user_id, sm_external_user_id
--     (joins to sales_ops.order_customer.sm_external_user_id), and email.
--   * external_user_mappings holds 'cafezupas' and 'amperity' id types. Cafe Zupas uses
--     ONLY 'cafezupas' (steward, 2026-07-28) — the amperity ids are not used and are not
--     exposed. Always filter external_user_id_type = 'cafezupas'.
--   * Inactive test point accounts ([CATest], [SMTest]) are excluded everywhere.
--
-- Point expiration rules (business rules confirmed by Brent 2026-07-28, validated against
-- actual sweep events — lots earned April 2025 were swept 2026-05-01):
--   * Spendable Points          expire one year from the END of the earned month.
--                               Earned 2026-02-01 and 2026-02-28 both expire 2027-02-28.
--                               expires_on = last_day(earn_month) + 1 year
--   * Catering Spendable Points expire annually at end of day November 30.
--   * SessionM sweeps expired points on the day AFTER expires_on (a batch on the 1st of
--     the following month), so the ledger debit date is expires_on + 1 day.
-- =====================================================================================


-- =====================================================================================
-- 1. claude.loyalty_user — identity spine. One row per sessionM loyalty user.
-- =====================================================================================
create or replace view `marketing-data-442316`.claude.loyalty_user as
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
select
  u.user_id
, safe_cast(cz.external_user_id as int64) as sm_external_user_id
, u.player_id
, lower(trim(u.email)) as email
, split(lower(trim(u.email)), '@')[safe_offset(1)] as email_domain
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
, date(u.created_at) as created_date
, date(u.updated_at) as updated_date
from `marketing-data-442316`.sessionM.users u
left join cafezupas_id cz
  on cz.user_id = u.user_id
 and cz.rn = 1
left join program p
  on p.user_id = u.user_id
;


-- =====================================================================================
-- 2. claude.loyalty_points_balance — one row per member per point account.
--    A member should only ever hold ONE account type (Spendable OR Catering).
--    264 members violate that rule; is_account_rule_violation flags them.
-- =====================================================================================
create or replace view `marketing-data-442316`.claude.loyalty_points_balance as
with account_rows as (
  select
    upa.user_id
  , upa.point_account_id
  , sum(upa.current_balance) as current_balance
  , sum(upa.lifetime_value) as lifetime_points
  , min(date(upa.created_at)) as account_created_date
  , max(date(upa.updated_at)) as account_updated_date
  , count(*) as source_row_count
  from `marketing-data-442316`.sessionM.user_point_accounts upa
  join `marketing-data-442316`.sessionM.point_accounts pa
    on pa.point_account_id = upa.point_account_id
  where 1=1
    and pa.active = 'true'
  group by 1,2
)
, account_count as (
  select
    user_id
  , count(distinct point_account_id) as active_account_types
  from account_rows
  group by 1
)
select
  ar.user_id
, lu.sm_external_user_id
, lu.email
, pa.name as point_account_name
, ar.point_account_id
, ar.current_balance
, ar.lifetime_points
, ar.lifetime_points - ar.current_balance as points_used_or_expired_lifetime
, lu.member_program
, lu.catering_tier_name
, lu.registered_date
, ar.account_created_date
, ar.account_updated_date
, ac.active_account_types > 1 as is_account_rule_violation
, ar.source_row_count > 1 as is_duplicate_source_row
from account_rows ar
join `marketing-data-442316`.sessionM.point_accounts pa
  on pa.point_account_id = ar.point_account_id
join account_count ac
  on ac.user_id = ar.user_id
left join `marketing-data-442316`.claude.loyalty_user lu
  on lu.user_id = ar.user_id
;


-- =====================================================================================
-- 3. claude.loyalty_points_expiring — one row per member per expiry date.
--    Built by FIFO-allocating debits against credit lots. The stored
--    user_point_transactions.points_remaining column is NOT used: it over-states the
--    balance by 32.7M points (628.6M vs an actual 595.9M) because it is not reliably
--    decremented. FIFO on point_modification reconciles to current_balance for 99.8%
--    of accounts.
-- =====================================================================================
create or replace view `marketing-data-442316`.claude.loyalty_points_expiring as
with ledger as (
  select
    upt.user_id
  , upt.point_account_id
  , upt.point_transaction_id
  , date(upt.time_of_occurrence) as occurred_date
  , upt.point_modification
  from `marketing-data-442316`.sessionM.user_point_transactions upt
  join `marketing-data-442316`.sessionM.point_accounts pa
    on pa.point_account_id = upt.point_account_id
  where 1=1
    and pa.active = 'true'
)
, debit_total as (
  select
    user_id
  , point_account_id
  , abs(sum(if(point_modification < 0, point_modification, 0))) as total_debits
  from ledger
  group by 1,2
)
, credit_lot as (
  select
    l.user_id
  , l.point_account_id
  , l.occurred_date as earned_date
  , l.point_modification as lot_points
  , sum(l.point_modification) over (
      partition by l.user_id, l.point_account_id
      order by l.occurred_date, l.point_transaction_id
      rows between unbounded preceding and current row
    ) as cumulative_credits
  from ledger l
  where 1=1
    and l.point_modification > 0
)
-- FIFO: debits consume the oldest lots first. What survives on a lot is the part of its
-- cumulative credit total that the debits never reached, capped at the lot size.
, surviving_lot as (
  select
    cl.user_id
  , cl.point_account_id
  , cl.earned_date
  , least(cl.lot_points, cl.cumulative_credits - dt.total_debits) as points_remaining
  from credit_lot cl
  join debit_total dt
    on dt.user_id = cl.user_id
   and dt.point_account_id = cl.point_account_id
  where 1=1
    and cl.cumulative_credits > dt.total_debits
)
, with_expiry as (
  select
    sl.user_id
  , sl.point_account_id
  , pa.name as point_account_name
  , sl.earned_date
  , sl.points_remaining
  , case pa.name
      -- Spendable: one year from the end of the month the points were earned in.
      when 'Spendable Points'
        then date_add(last_day(sl.earned_date, month), interval 1 year)
      -- Catering: annual sweep at end of day November 30. Points earned on or before
      -- Nov 30 expire that year; anything earned in December rolls to the next Nov 30.
      when 'Catering Spendable Points'
        then if(
               sl.earned_date <= date(extract(year from sl.earned_date), 11, 30)
             , date(extract(year from sl.earned_date), 11, 30)
             , date(extract(year from sl.earned_date) + 1, 11, 30)
             )
    end as expires_on
  from surviving_lot sl
  join `marketing-data-442316`.sessionM.point_accounts pa
    on pa.point_account_id = sl.point_account_id
)
select
  we.user_id
, lu.sm_external_user_id
, lu.email
, we.point_account_name
, we.expires_on
, date_add(we.expires_on, interval 1 day) as sessionm_sweep_date
, date_diff(we.expires_on, current_date('America/Denver'), day) as days_until_expiry
, we.expires_on < current_date('America/Denver') as is_past_due_not_yet_swept
, sum(we.points_remaining) as points_expiring
, min(we.earned_date) as earliest_earned_date
, max(we.earned_date) as latest_earned_date
, count(*) as lot_count
, lu.member_program
, lu.catering_tier_name
from with_expiry we
left join `marketing-data-442316`.claude.loyalty_user lu
  on lu.user_id = we.user_id
where 1=1
  and we.points_remaining > 0
group by 1,2,3,4,5,6,7,8,13,14
;


-- =====================================================================================
-- 4. claude.loyalty_points_activity — one row per point transaction.
--    activity_type is derived from audit_type_bitmask, which is the ONLY reliable
--    classifier. reference_type is free text (agent names, ticket reasons, campaign
--    names) and must never be used as an enum.
-- =====================================================================================
create or replace view `marketing-data-442316`.claude.loyalty_points_activity as
select
  upt.point_transaction_id
, upt.user_id
, lu.sm_external_user_id
, lu.email
, pa.name as point_account_name
, upt.point_account_id
, date(upt.time_of_occurrence) as activity_date
, upt.time_of_occurrence
, upt.create_date as etl_create_date
, case upt.audit_type_bitmask
    when 1 then 'issued'
    when 2 then 'redeemed_or_deducted'
    when 4 then 'expired'
    when 16 then 'issued_adjustment'
    else 'unknown'
  end as activity_type
, upt.audit_type_bitmask
, upt.point_modification as points
, if(upt.point_modification > 0, upt.point_modification, 0) as points_issued
, if(upt.point_modification < 0, abs(upt.point_modification), 0) as points_removed
, if(upt.audit_type_bitmask = 2, abs(upt.point_modification), 0) as points_redeemed
, if(upt.audit_type_bitmask = 4, abs(upt.point_modification), 0) as points_expired
, upt.reference_type as reference_note
, upt.reference_id
, upt.transaction_id as pos_transaction_id
, ps.name as point_source_name
, lu.member_program
, lu.catering_tier_name
from `marketing-data-442316`.sessionM.user_point_transactions upt
join `marketing-data-442316`.sessionM.point_accounts pa
  on pa.point_account_id = upt.point_account_id
left join `marketing-data-442316`.sessionM.point_sources ps
  on ps.point_source_id = upt.point_source_id
left join `marketing-data-442316`.claude.loyalty_user lu
  on lu.user_id = upt.user_id
where 1=1
  and pa.active = 'true'
;


-- =====================================================================================
-- 5. claude.loyalty_offer_usage — one row per offer issued to a member.
--
--    *** ALWAYS split on offer_kind before quoting a redemption rate. ***
--    offers.reward_store is a boolean-as-string, not a store name, and it separates two
--    populations whose redemption behaviour is nothing alike (Aug 2025 – Jul 2026):
--      'points_purchase' (reward_store = 'true')   236,785 issued,  90.5% redeemed
--      'promotional'     (reward_store = 'false') 2,117,210 issued,   3.2% redeemed
--    A points purchase is a deliberate member action, so it nearly always redeems. A
--    promotional offer is pushed to a large audience (e.g. Birthday Free Dessert, 347k
--    issued / 2.8% redeemed). Blending the two produces a meaningless number.
--
--    NOTE the 2023 mass-provisioning artifact: 24.8M of the 33.1M rows landed in 2023
--    when the reward catalog was bulk-issued to every member. is_bulk_provisioned_2023
--    flags them. Exclude them from any "offers issued" count unless you specifically
--    want the catalog load.
-- =====================================================================================
create or replace view `marketing-data-442316`.claude.loyalty_offer_usage as
select
  uo.user_offers_id
, uo.user_id
, lu.sm_external_user_id
, lu.email
, uo.offer_id
, uo.root_offer_id
, o.name as offer_name
, case o.reward_store
    when 'true'  then 'points_purchase'
    when 'false' then 'promotional'
    else 'unknown'
  end as offer_kind
, o.reward_store
, o.points_required
, o.discount_amount
, o.percent_off
, o.fixed_price
, o.pos_discount_id
, uo.create_date as issued_date
, date(uo.acquire_date) as acquire_date
, date(uo.redeem_date) as redeem_date
, uo.redeem_date is not null as is_redeemed
, date(uo.redemption_start_date) as redemption_start_date
, date(uo.redemption_end_date) as redemption_end_date
, if(
    uo.redeem_date is null
      and uo.redemption_end_date is not null
      and date(uo.redemption_end_date) < current_date('America/Denver')
  , true
  , false
  ) as is_expired_unredeemed
, if(
    uo.redeem_date is not null and uo.acquire_date is not null
  , date_diff(date(uo.redeem_date), date(uo.acquire_date), day)
  , null
  ) as days_to_redeem
, uo.points_spent
, uo.quantity
, uo.status as user_offer_status
, uo.store_id
, uo.pos_offer_id
, uo.additional_description
, extract(year from uo.create_date) = 2023 as is_bulk_provisioned_2023
, lu.member_program
, lu.catering_tier_name
from `marketing-data-442316`.sessionM.user_offers uo
left join `marketing-data-442316`.sessionM.offers o
  on o.offer_id = uo.offer_id
left join `marketing-data-442316`.claude.loyalty_user lu
  on lu.user_id = uo.user_id
;


-- =====================================================================================
-- 6. claude.loyalty_campaign_participation — one row per participation event.
--    sessionM.campaign_activity is ~1.4 BILLION rows / 140 GB. This view drops the
--    ~1.1B messaging-delivery rows (platform_processing / platform_processed /
--    triggered / sent / dropped / deferred — that is Braze's domain, use the
--    braze-campaigns skill) and keeps only behaviour and reward participation.
--
--    *** ALWAYS filter on create_date. An unbounded query here scans hundreds of GB. ***
--
--    action_category separates real participation from rule-engine noise:
--      'achievement_earned' — member completed the achievement (real participation)
--      'reward_awarded'     — member was awarded an offer or points
--      'rule_evaluated'     — the rules engine merely looked at an event. HIGH VOLUME
--                             NOISE (one campaign fired 8.2M of these for 140k members
--                             in 27 days). Never count these as participation.
-- =====================================================================================
create or replace view `marketing-data-442316`.claude.loyalty_campaign_participation as
select
  ca.create_date
, ca.user_id
, lu.sm_external_user_id
, lu.email
, ca.campaign_id
, cat.name as campaign_name
, cat.external_name as campaign_external_name
, cat.campaign_type
, cat.starts_at as campaign_starts_at
, cat.ends_at as campaign_ends_at
, cat.optin_required = 1 as campaign_optin_required
, ca.action
, case
    when ca.action in ('goal:achievement:earned','composite:achievement:earned')
      then 'achievement_earned'
    when ca.action in ('outcome:awarded:offer','outcome:awarded:incentives','eligible_offer_issued','eligible_offer_added')
      then 'reward_awarded'
    when ca.action in ('goal:achievement:event','composite:achievement:event')
      then 'rule_evaluated'
    when ca.action like 'outcome:error%'
      then 'error'
    when ca.action in ('goal:achievement:forfeited','composite:achievement:forfeited','composite:achievement:regress','outcome:revoked:incentives')
      then 'reversed'
    else 'other'
  end as action_category
, ca.creative_type
, ca.achievement_id
, cach.name as achievement_name
, cach.achievement_type
-- campaign_achievements.points is 0 on all 1,508 rows upstream, so it is deliberately
-- NOT exposed here. For points awarded by a campaign, use loyalty_points_activity.
, ca.unit_id
, cau.name as activity_unit_name
, cau.message_type
, ca.application_id
, app.name as application_name
, app.platform as application_platform
, ca.transaction_id as pos_transaction_id
, ca.created_at
, lu.member_program
, lu.catering_tier_name
from `marketing-data-442316`.sessionM.campaign_activity ca
left join `marketing-data-442316`.sessionM.campaign_attributes cat
  on cat.campaign_id = ca.campaign_id
left join `marketing-data-442316`.sessionM.campaign_achievements cach
  on cach.achievement_id = ca.achievement_id
left join `marketing-data-442316`.sessionM.campaign_activity_units cau
  on cau.unit_id = ca.unit_id
left join `marketing-data-442316`.sessionM.applications app
  on app.applications_id = ca.application_id
left join `marketing-data-442316`.claude.loyalty_user lu
  on lu.user_id = ca.user_id
where 1=1
  and ca.creative_type in ('behavior','cpa-instant-reward','messaging')
;
