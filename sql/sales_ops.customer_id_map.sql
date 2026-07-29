-- =====================================================================================
-- sales_ops.customer_id_map — canonical customer identity crosswalk
-- =====================================================================================
-- Status : DRAFT / NOT DEPLOYED. Written 2026-07-28. Reviewed by: nobody yet.
-- Design : design/crm_identity_hygiene_plan.md
-- Dict   : data_dictionaries/sales_ops.customer_id_map.md
--
-- Purpose
--   Collapse the many mapped_cust_ids that belong to one human onto a single
--   canonical_cust_id, permanently, auditably, and without ever losing the fact that
--   124 was mapped to 123.
--
-- Why this exists
--   Guest checkout (live 2026-07-01) makes Pulse mint a new customer_id per guest order.
--   Duplicate-id creation went from ~28/business day to ~280/business day. 97,721
--   surplus person ids exist as of 2026-07-25, carrying 539,034 orders / $21.5M net.
--
-- Steward rules encoded here — do not "simplify" these away
--   1. Match key is normalized email ONLY: lower(trim(mapped_email)). No dot-stripping,
--      no +tag removal, no phone, no fuzzy name. Phone is a review queue, not a key.
--   2. Survivor = earliest first_order_date, tie-break lowest cust_id.
--   3. STICKY: this is a MERGE, never a create-or-replace. A canonical id already acted
--      on in Braze is a published fact; letting it drift produces contradictory Braze
--      merges, which are irreversible. (Contrast customer_attribute, which is a full
--      daily rebuild on purpose — it holds derived measures, this holds decisions.)
--   4. An id with braze_state = 'merged_away' can never be promoted back to canonical.
--   5. Singletons get a row too, so consumers never need a coalesce.
--   6. order_customer does NOT join this table (that would be circular — this is built
--      from it). Canonicalization happens in the claude views and customer_attribute.
-- =====================================================================================


-- =====================================================================================
-- SECTION 1 — DDL (run once)
-- =====================================================================================

create table if not exists `marketing-data-442316.sales_ops.customer_id_map`
(
  cust_id            int64   not null options(description = 'Source mapped_cust_id from order_customer. Primary key.'),
  canonical_cust_id  int64   not null options(description = 'The surviving id this cust_id resolves to. Always itself a canonical row.'),
  is_canonical       bool    not null options(description = 'cust_id = canonical_cust_id.'),
  match_key          string           options(description = "How the cluster was formed: 'email' or 'singleton'."),
  match_email        string           options(description = 'Normalized email that formed the cluster. NULL for emailless singletons.'),
  cluster_size       int64            options(description = 'Number of cust_ids resolving to this canonical_cust_id.'),
  survivor_reason    string           options(description = "'earliest_first_order' | 'sticky_existing_canonical' | 'singleton'."),
  first_order_date   date             options(description = 'Earliest business_date for this cust_id. Drives survivor election.'),
  last_order_date    date             options(description = 'Latest business_date for this cust_id.'),
  lifetime_orders    int64            options(description = 'Person orders on this cust_id, store 1111 excluded, catering included.'),
  braze_state        string  not null options(description = "'pending' | 'renamed' | 'merged_away' | 'not_required' | 'failed'. Maintained by the identity worker."),
  braze_state_at     timestamp        options(description = 'When braze_state last changed.'),
  map_version        int64   not null options(description = 'Increments every time canonical_cust_id changes for this cust_id.'),
  first_mapped_at    timestamp not null options(description = 'When this cust_id first entered the map.'),
  mapping_changed_at timestamp        options(description = 'When canonical_cust_id last changed.'),
  updated_at         timestamp not null options(description = 'Last build that touched the row.')
)
cluster by cust_id, canonical_cust_id
options(description = 'Canonical customer identity crosswalk. 1 row per mapped_cust_id ever seen (person only). See design/crm_identity_hygiene_plan.md.');


-- Append-only lineage. THIS is the "never lose that 124 -> 123" guarantee.
-- Nothing in this table is ever deleted or overwritten except closing valid_to.
create table if not exists `marketing-data-442316.sales_ops.customer_id_map_history`
(
  cust_id           int64     not null,
  canonical_cust_id int64     not null,
  valid_from        timestamp not null,
  valid_to          timestamp          options(description = 'NULL = current assignment.'),
  change_reason     string    not null options(description = "'initial_mapping' | 'cluster_absorbed' | 'canonical_reassigned' | 'manual_override'."),
  map_version       int64     not null,
  recorded_at       timestamp not null
)
partition by date(valid_from)
cluster by cust_id
options(description = 'Append-only history of every cust_id -> canonical_cust_id assignment. Never truncate.');


-- Every Braze API call attempt, request and response. Brent's "tracked in GCP" requirement.
create table if not exists `marketing-data-442316.sales_ops.braze_identity_action_log`
(
  action_id         string    not null options(description = 'UUID generated by the worker per queue row per attempt.'),
  batch_id          string    not null options(description = 'One id per API request (up to 50 rows share it).'),
  action            string    not null options(description = "'merge' | 'rename' | 'remove_deprecated' | 'delete'."),
  cust_id           int64              options(description = 'The id being merged away / renamed / deleted.'),
  canonical_cust_id int64              options(description = 'The surviving id.'),
  uuid_external_id  string             options(description = 'Set instead of cust_id for UUID-profile actions.'),
  map_version       int64              options(description = 'map_version of the row that produced this action, for idempotency.'),
  request_payload   string    not null options(description = 'Exact JSON body sent to Braze.'),
  http_status       int64              options(description = 'HTTP status. 202 = accepted, NOT applied.'),
  response_body     string             options(description = 'Raw Braze response, including rename_errors.'),
  attempt           int64     not null options(description = 'Attempt number, starting at 1.'),
  status            string    not null options(description = "'sent' | 'succeeded' | 'failed' | 'verified'."),
  error_message     string,
  requested_at      timestamp not null,
  completed_at      timestamp,
  verified_at       timestamp          options(description = 'When /users/export/ids confirmed the change. 202 alone is not confirmation.')
)
partition by date(requested_at)
cluster by action, status, cust_id
options(description = 'Audit log of every Braze identity mutation. Append + update-in-place on status only.');


-- UUID-keyed Braze profiles (283,825 as of 2026-07-28, first seen 2023-05-12).
create table if not exists `marketing-data-442316.sales_ops.braze_uuid_profile_map`
(
  uuid_external_id  string    not null,
  email             string,
  resolved_cust_id  int64              options(description = 'Integer external_id this profile should become. NULL when unresolvable.'),
  resolution        string    not null options(description = "'merge' | 'rename' | 'no_map_no_email' | 'no_map_has_email'."),
  email_subscribe   string,
  profile_created_at timestamp,
  braze_state       string    not null options(description = "'pending' | 'renamed' | 'merged_away' | 'deleted' | 'held' | 'failed'."),
  updated_at        timestamp not null
)
cluster by resolution, uuid_external_id
options(description = 'UUID Braze external_ids and the integer id they resolve to. Deletes are held pending steward decision (see plan section 9.1).');


-- =====================================================================================
-- SECTION 2 — Incremental build (schedule: daily 05:30 America/Denver, AFTER the 04:00
--             order_customer reload and the 05:00 customer_attribute rebuild)
-- =====================================================================================

declare start_date date default '2023-03-01';   -- customer identity capture effectively begins 2023-03-06
declare run_ts timestamp default current_timestamp();


-- 2.1 Current state per cust_id, with its most recent email.
--     Email tie-break (order_datetime desc, brink_order_id desc) matches the convention
--     used by order_sequence and customer_attribute so all three agree on "most recent".
create temp table cur_ids as
select
  oc.mapped_cust_id as cust_id,
  array_agg(lower(trim(oc.mapped_email)) ignore nulls
            order by oc.order_datetime desc, oc.brink_order_id desc limit 1)[safe_offset(0)] as match_email,
  min(oc.business_date) as first_order_date,
  max(oc.business_date) as last_order_date,
  count(distinct oc.brink_order_id) as lifetime_orders
from `marketing-data-442316.sales_ops.order_customer` oc
where oc.business_date between start_date and current_date()
  and oc.store_id <> 1111
  and oc.mapped_cust_id is not null
  and oc.customer_type = 'person'
group by 1;


-- 2.2 Existing canonicals that are still eligible to win.
--     merged_away ids are excluded: Braze has already collapsed them into someone else
--     and re-promoting them would fire a contradictory merge (steward rule 4).
create temp table eligible_canon as
select
  c.match_email,
  m.canonical_cust_id,
  min(m.first_order_date) as canon_first_order_date
from cur_ids c
join `marketing-data-442316.sales_ops.customer_id_map` m
  on m.cust_id = c.cust_id
join `marketing-data-442316.sales_ops.customer_id_map` cm
  on cm.cust_id = m.canonical_cust_id
where c.match_email is not null
  and cm.braze_state <> 'merged_away'
group by 1, 2;


-- 2.3 Elect one canonical per email cluster.
--     Sticky first: if any member already has an eligible canonical, that wins (earliest
--     first order, then lowest id). Only a brand-new cluster elects fresh.
create temp table elected as
with sticky as (
  select match_email, canonical_cust_id, canon_first_order_date,
         row_number() over (partition by match_email
                            order by canon_first_order_date asc, canonical_cust_id asc) as rn
  from eligible_canon
),
fresh as (
  select match_email,
         array_agg(cust_id order by first_order_date asc, cust_id asc limit 1)[offset(0)] as canonical_cust_id
  from cur_ids
  where match_email is not null
  group by 1
)
select
  f.match_email,
  coalesce(s.canonical_cust_id, f.canonical_cust_id) as canonical_cust_id,
  case when s.canonical_cust_id is null then 'earliest_first_order'
       else 'sticky_existing_canonical' end as survivor_reason
from fresh f
left join sticky s
  on s.match_email = f.match_email and s.rn = 1;


-- 2.4 Proposed edges, then resolve chains to a root.
--     A chain appears when an id's email changes and two clusters collide: cluster E points
--     at X, but X now belongs to cluster F and points at Y. Consumers must never see
--     canonical_cust_id pointing at a non-canonical id, so walk to the terminal node.
create temp table proposed_edges as
select c.cust_id, e.canonical_cust_id, e.survivor_reason, 'email' as match_key, c.match_email
from cur_ids c
join elected e on e.match_email = c.match_email
union all
-- emailless ids (SessionM in-store scanners with no email on any order) are singletons by
-- definition. Do not guess at their identity.
select c.cust_id, c.cust_id, 'singleton', 'singleton', cast(null as string)
from cur_ids c
where c.match_email is null;

create temp table resolved_edges as
with recursive edges as (
  select cust_id, canonical_cust_id from proposed_edges
),
walk as (
  select cust_id, canonical_cust_id as canon, 0 as depth
  from edges
  union all
  select w.cust_id, e.canonical_cust_id, w.depth + 1
  from walk w
  join edges e on e.cust_id = w.canon
  where e.canonical_cust_id <> w.canon
    and w.depth < 10                       -- cycle guard; assertion in section 4 must return 0
)
select cust_id, canon as canonical_cust_id
from walk
qualify row_number() over (partition by cust_id order by depth desc) = 1;


-- 2.5 Final target state.
create temp table final_map as
select
  r.cust_id,
  r.canonical_cust_id,
  r.cust_id = r.canonical_cust_id as is_canonical,
  p.match_key,
  p.match_email,
  count(*) over (partition by r.canonical_cust_id) as cluster_size,
  case when r.cust_id = r.canonical_cust_id and p.match_key = 'singleton' then 'singleton'
       else p.survivor_reason end as survivor_reason,
  c.first_order_date,
  c.last_order_date,
  c.lifetime_orders
from resolved_edges r
join proposed_edges p on p.cust_id = r.cust_id
join cur_ids c on c.cust_id = r.cust_id;


-- 2.6 What changed (captured BEFORE the merge so history is exact).
create temp table changes as
select
  f.cust_id,
  f.canonical_cust_id as new_canon,
  t.canonical_cust_id as old_canon,
  coalesce(t.map_version, 0) as old_version,
  coalesce(t.is_canonical, false) as was_canonical
from final_map f
left join `marketing-data-442316.sales_ops.customer_id_map` t on t.cust_id = f.cust_id
where t.cust_id is null
   or t.canonical_cust_id <> f.canonical_cust_id;


begin transaction;

-- 2.7 Apply.
merge `marketing-data-442316.sales_ops.customer_id_map` t
using final_map s
on t.cust_id = s.cust_id
when matched and t.canonical_cust_id <> s.canonical_cust_id then update set
  canonical_cust_id  = s.canonical_cust_id,
  is_canonical       = s.is_canonical,
  match_key          = s.match_key,
  match_email        = s.match_email,
  cluster_size       = s.cluster_size,
  survivor_reason    = s.survivor_reason,
  first_order_date   = s.first_order_date,
  last_order_date    = s.last_order_date,
  lifetime_orders    = s.lifetime_orders,
  braze_state        = 'pending',              -- remapped, so Braze needs to act again
  braze_state_at     = run_ts,
  map_version        = t.map_version + 1,
  mapping_changed_at = run_ts,
  updated_at         = run_ts
when matched then update set                   -- mapping unchanged; refresh facts only
  cluster_size       = s.cluster_size,
  match_email        = s.match_email,
  first_order_date   = s.first_order_date,
  last_order_date    = s.last_order_date,
  lifetime_orders    = s.lifetime_orders,
  updated_at         = run_ts
when not matched then insert
  (cust_id, canonical_cust_id, is_canonical, match_key, match_email, cluster_size,
   survivor_reason, first_order_date, last_order_date, lifetime_orders,
   braze_state, braze_state_at, map_version, first_mapped_at, mapping_changed_at, updated_at)
values
  (s.cust_id, s.canonical_cust_id, s.is_canonical, s.match_key, s.match_email, s.cluster_size,
   s.survivor_reason, s.first_order_date, s.last_order_date, s.lifetime_orders,
   case when s.is_canonical then 'not_required' else 'pending' end, run_ts,
   1, run_ts, run_ts, run_ts);

-- 2.8 Close superseded history rows.
update `marketing-data-442316.sales_ops.customer_id_map_history` h
set valid_to = run_ts
where h.valid_to is null
  and h.cust_id in (select cust_id from changes where old_canon is not null);

-- 2.9 Write the new history rows.
insert into `marketing-data-442316.sales_ops.customer_id_map_history`
  (cust_id, canonical_cust_id, valid_from, valid_to, change_reason, map_version, recorded_at)
select
  c.cust_id,
  c.new_canon,
  run_ts,
  null,
  case when c.old_canon is null then 'initial_mapping'
       when c.was_canonical    then 'cluster_absorbed'
       else 'canonical_reassigned' end,
  c.old_version + 1,
  run_ts
from changes c;

commit transaction;


-- =====================================================================================
-- SECTION 3 — Braze work queue
-- =====================================================================================
-- Which API call each pending loser needs depends on which side already has a profile.
-- Measured 2026-07-28 over the 97,721 surplus ids:
--   survivor no  / loser yes -> RENAME  54,469   (the dominant case: survivors predate the
--                                                Nov-2023 Braze sync, losers are new guest ids)
--   survivor no  / loser no  -> none    28,748
--   survivor yes / loser no  -> none     8,635
--   survivor yes / loser yes -> MERGE    5,869
--
-- ORDER MATTERS. Within a cluster whose survivor has no profile, exactly one loser profile
-- is renamed onto the survivor id (action_order 1); any other loser profiles are then merged
-- into it (action_order 2). Reverse the order and the rename fails with
-- "new_external_id is already in use".
--
-- Braze limits: /users/external_ids/rename 50 per request, 1,000 req/min, no data points,
-- no MAU impact. /users/merge 50 per request, 20,000 req/min shared with /users/delete,
-- /users/identify and /users/alias/*.
create or replace view `marketing-data-442316.sales_ops.v_braze_identity_queue` as
with bz as (
  select distinct safe_cast(external_id as int64) as ext_id
  from `marketing-data-442316.braze.users`
  where regexp_contains(external_id, r'^[0-9]+$')
),
pending as (
  select
    m.cust_id,
    m.canonical_cust_id,
    m.map_version,
    m.lifetime_orders,
    lb.ext_id is not null as loser_has_profile,
    sb.ext_id is not null as survivor_has_profile
  from `marketing-data-442316.sales_ops.customer_id_map` m
  left join bz lb on lb.ext_id = m.cust_id
  left join bz sb on sb.ext_id = m.canonical_cust_id
  where not m.is_canonical
    and m.braze_state = 'pending'
),
donor as (
  select *,
    row_number() over (partition by canonical_cust_id
                       order by lifetime_orders desc, cust_id asc) as donor_rank
  from pending
  where loser_has_profile and not survivor_has_profile
)
select
  cust_id, canonical_cust_id, map_version, lifetime_orders,
  'rename' as action, 1 as action_order
from donor where donor_rank = 1
union all
select
  cust_id, canonical_cust_id, map_version, lifetime_orders,
  'merge' as action, 2 as action_order
from donor where donor_rank > 1
union all
select
  cust_id, canonical_cust_id, map_version, lifetime_orders,
  'merge' as action, 2 as action_order
from pending where loser_has_profile and survivor_has_profile
union all
select
  cust_id, canonical_cust_id, map_version, lifetime_orders,
  'not_required' as action, 99 as action_order
from pending where not loser_has_profile;


-- Canonical-resolved order fact, for the claude interface layer.
-- This is what analysts and customer_attribute should aggregate on — never raw mapped_cust_id.
create or replace view `marketing-data-442316.sales_ops.v_order_customer_canonical` as
select
  oc.*,
  coalesce(m.canonical_cust_id, oc.mapped_cust_id) as canonical_cust_id
from `marketing-data-442316.sales_ops.order_customer` oc
left join `marketing-data-442316.sales_ops.customer_id_map` m
  on m.cust_id = oc.mapped_cust_id;


-- =====================================================================================
-- SECTION 4 — Post-build assertions. ANY non-zero result is a build failure, not a warning.
-- =====================================================================================
-- 4.1 No mapping chains — every canonical_cust_id must itself be canonical
select 'broken_chains' as check_name, count(*) as violations
from `marketing-data-442316.sales_ops.customer_id_map` m
left join `marketing-data-442316.sales_ops.customer_id_map` c
  on c.cust_id = m.canonical_cust_id and c.is_canonical
where c.cust_id is null
union all
-- 4.2 One canonical per email cluster
select 'split_clusters', count(*) from (
  select match_email
  from `marketing-data-442316.sales_ops.customer_id_map`
  where match_email is not null
  group by 1
  having count(distinct canonical_cust_id) > 1
)
union all
-- 4.3 No merged-away id promoted back to canonical
select 'illegal_promotions', countif(is_canonical and braze_state = 'merged_away')
from `marketing-data-442316.sales_ops.customer_id_map`
union all
-- 4.4 Exactly one open history row per cust_id
select 'history_open_row_defects', count(*) from (
  select cust_id
  from `marketing-data-442316.sales_ops.customer_id_map_history`
  where valid_to is null
  group by 1
  having count(*) <> 1
)
union all
-- 4.5 Every id in the map exists in the map's own canonical set (no orphan canonicals)
select 'orphan_canonicals', count(distinct canonical_cust_id)
from `marketing-data-442316.sales_ops.customer_id_map` m
where not exists (
  select 1 from `marketing-data-442316.sales_ops.customer_id_map` c where c.cust_id = m.canonical_cust_id
);

-- 4.6 Conservation check — run separately, compare the two rows by hand the first time.
-- The map redistributes orders and net sales between ids; it must never create or destroy any.
with canon as (
  select count(distinct oc.brink_order_id) as orders, round(sum(oc.net_sales), 2) as net_sales
  from `marketing-data-442316.sales_ops.order_customer` oc
  join `marketing-data-442316.sales_ops.customer_id_map` m on m.cust_id = oc.mapped_cust_id
  where oc.business_date between '2023-03-01' and current_date()
    and oc.store_id <> 1111 and oc.customer_type = 'person'
),
raw as (
  select count(distinct oc.brink_order_id) as orders, round(sum(oc.net_sales), 2) as net_sales
  from `marketing-data-442316.sales_ops.order_customer` oc
  where oc.business_date between '2023-03-01' and current_date()
    and oc.store_id <> 1111 and oc.customer_type = 'person'
    and oc.mapped_cust_id is not null
)
select 'via_map' as source, * from canon
union all
select 'raw', * from raw;
