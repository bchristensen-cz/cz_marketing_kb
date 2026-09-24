-- Braze canvas x canvas message report, sends from 2025-12-29
-- grain: canvas_id x canvas_step_id x channel (treatment rows) + canvas_id x experiment step x split (holdout rows)
-- attribution: D-026 (last touch, 24h from send instant, 48h for Saturday sends), email bridge D-021,
--   workspace cafe_zupas, non-catering, non-employee, identified orders only
-- holdout rows: users assigned to a control split in canvas_experimentstep_splitentry; their orders in the
--   same window measured from the split-entry instant (no send exists for them)
create or replace table `marketing-data-442316`.scratch.braze_canvas_message_report_20260924
options (expiration_timestamp = timestamp_add(current_timestamp(), interval 21 day))
as
with sends_raw as (
select
'email' as channel
, es.id as id
, es.event_date as event_date
, timestamp_seconds(es.time) as send_ts
, coalesce(nullif(es.campaign_id, ''), es.canvas_id) as program_id
, coalesce(nullif(es.campaign_name, ''), es.canvas_name) as program_name
, es.canvas_id as canvas_id
, es.canvas_name as canvas_name
, es.canvas_step_id as canvas_step_id
, es.canvas_step_name as canvas_step_name
, lower(es.email_address) as em
from `marketing-data-442316`.braze.email_send es
where 1=1
and es.event_date between date '2025-12-29' and current_date('America/Denver')
and es.workspace = 'cafe_zupas'
union all
select
'push' as channel
, ps.id as id
, ps.event_date as event_date
, timestamp_seconds(ps.time) as send_ts
, coalesce(nullif(ps.campaign_id, ''), ps.canvas_id) as program_id
, coalesce(nullif(ps.campaign_name, ''), ps.canvas_name) as program_name
, ps.canvas_id as canvas_id
, ps.canvas_name as canvas_name
, ps.canvas_step_id as canvas_step_id
, ps.canvas_step_name as canvas_step_name
, ud.email as em
from `marketing-data-442316`.braze.pushnotification_send ps
	left join `marketing-data-442316`.dashboard.braze_user_dim ud
	on ud.external_id = ps.external_user_id
where 1=1
and ps.event_date between date '2025-12-29' and current_date('America/Denver')
and ps.workspace = 'cafe_zupas'
union all
select
'sms' as channel
, ss.id as id
, ss.event_date as event_date
, timestamp_seconds(ss.time) as send_ts
, coalesce(nullif(ss.campaign_id, ''), ss.canvas_id) as program_id
, coalesce(nullif(ss.campaign_name, ''), ss.canvas_name) as program_name
, ss.canvas_id as canvas_id
, ss.canvas_name as canvas_name
, ss.canvas_step_id as canvas_step_id
, ss.canvas_step_name as canvas_step_name
, ud.email as em
from `marketing-data-442316`.braze.sms_send ss
	left join `marketing-data-442316`.dashboard.braze_user_dim ud
	on ud.external_id = ss.external_user_id
where 1=1
and ss.event_date between date '2025-12-29' and current_date('America/Denver')
and ss.workspace = 'cafe_zupas'
union all
select
'rcs' as channel
, rs.id as id
, rs.event_date as event_date
, timestamp_seconds(rs.time) as send_ts
, coalesce(nullif(rs.campaign_id, ''), rs.canvas_id) as program_id
, coalesce(nullif(rs.campaign_name, ''), rs.canvas_name) as program_name
, rs.canvas_id as canvas_id
, rs.canvas_name as canvas_name
, rs.canvas_step_id as canvas_step_id
, rs.canvas_step_name as canvas_step_name
, ud.email as em
from `marketing-data-442316`.braze.rcs_send rs
	left join `marketing-data-442316`.dashboard.braze_user_dim ud
	on ud.external_id = rs.external_user_id
where 1=1
and rs.event_date between date '2025-12-29' and current_date('America/Denver')
and rs.workspace = 'cafe_zupas'
)
-- all sends (campaigns too) stay in scope so last touch competes correctly; canvas rows are cut at the end
, sends as (
select
sr.channel
, sr.id
, sr.event_date
, sr.send_ts
, sr.program_id
, sr.canvas_id
, sr.canvas_name
, sr.canvas_step_id
, sr.canvas_step_name
, sr.em
from sends_raw sr
where 1=1
and sr.program_id is not null
qualify row_number() over (partition by sr.id order by sr.send_ts) = 1
)
, orders as (
select
oc.brink_order_id as order_id
, oc.mapped_email as em
, oc.order_timestamp_utc as order_ts
, oc.net_sales as net_sales
from `marketing-data-442316`.claude.order_customer oc
where 1=1
and oc.business_date between date '2025-12-29' and current_date('America/Denver')
and oc.is_catering = false
and oc.mapped_email is not null
and oc.order_timestamp_utc is not null
and ifnull(oc.mapped_email_domain, '') not in ('cafezupas.com', 'tkxel.com')
)
-- every (order, send) pair inside 72h; the window rule and last-touch flag are applied on top
, pairs as (
select
s.id as send_id
, o.order_id
, o.net_sales
, timestamp_diff(o.order_ts, s.send_ts, minute) as mins_since
, format_date('%a', s.event_date) = 'Sat' as is_sat_send
, row_number() over (partition by o.order_id order by s.send_ts desc) = 1 as is_last_touch
from orders o
	join sends s
	on s.em = o.em
	and s.send_ts < o.order_ts
	and s.send_ts >= timestamp_sub(o.order_ts, interval 72 hour)
)
, attr as (
select
p.send_id
, countif(p.is_last_touch and (p.mins_since < 1440 or (p.is_sat_send and p.mins_since < 2880))) as attr_orders
, sum(if(p.is_last_touch and (p.mins_since < 1440 or (p.is_sat_send and p.mins_since < 2880)), p.net_sales, 0)) as attr_net_sales
, countif(p.mins_since < 1440 or (p.is_sat_send and p.mins_since < 2880)) as window_orders
, sum(if(p.mins_since < 1440 or (p.is_sat_send and p.mins_since < 2880), p.net_sales, 0)) as window_net_sales
from pairs p
group by p.send_id
)
, deliveries as (
select 'email' as channel, ed.canvas_id, ed.canvas_step_id, ed.id
from `marketing-data-442316`.braze.email_delivery ed
where 1=1
and ed.event_date between date '2025-12-29' and current_date('America/Denver')
and ed.workspace = 'cafe_zupas'
and coalesce(ed.canvas_id, '') <> ''
union all
select 'sms' as channel, sd.canvas_id, sd.canvas_step_id, sd.id
from `marketing-data-442316`.braze.sms_delivery sd
where 1=1
and sd.event_date between date '2025-12-29' and current_date('America/Denver')
and sd.workspace = 'cafe_zupas'
and coalesce(sd.canvas_id, '') <> ''
union all
select 'rcs' as channel, rd.canvas_id, rd.canvas_step_id, rd.id
from `marketing-data-442316`.braze.rcs_delivery rd
where 1=1
and rd.event_date between date '2025-12-29' and current_date('America/Denver')
and rd.workspace = 'cafe_zupas'
and coalesce(rd.canvas_id, '') <> ''
)
, push_bounces as (
select pb.canvas_id, pb.canvas_step_id, count(distinct pb.id) as bounces
from `marketing-data-442316`.braze.pushnotification_bounce pb
where 1=1
and pb.event_date between date '2025-12-29' and current_date('America/Denver')
and pb.workspace = 'cafe_zupas'
and coalesce(pb.canvas_id, '') <> ''
group by pb.canvas_id, pb.canvas_step_id
)
, opens as (
select 'email' as channel, eo.canvas_id, eo.canvas_step_id, eo.id
from `marketing-data-442316`.braze.email_open eo
where 1=1
and eo.event_date between date '2025-12-29' and current_date('America/Denver')
and eo.workspace = 'cafe_zupas'
and coalesce(eo.canvas_id, '') <> ''
and not coalesce(lower(eo.machine_open) = 'true', false)
union all
select 'push' as channel, po.canvas_id, po.canvas_step_id, po.id
from `marketing-data-442316`.braze.pushnotification_open po
where 1=1
and po.event_date between date '2025-12-29' and current_date('America/Denver')
and po.workspace = 'cafe_zupas'
and coalesce(po.canvas_id, '') <> ''
union all
select 'rcs' as channel, rr.canvas_id, rr.canvas_step_id, rr.id
from `marketing-data-442316`.braze.rcs_read rr
where 1=1
and rr.event_date between date '2025-12-29' and current_date('America/Denver')
and rr.workspace = 'cafe_zupas'
and coalesce(rr.canvas_id, '') <> ''
)
, clicks as (
select 'email' as channel, ec.canvas_id, ec.canvas_step_id, ec.id
from `marketing-data-442316`.braze.email_click ec
where 1=1
and ec.event_date between date '2025-12-29' and current_date('America/Denver')
and ec.workspace = 'cafe_zupas'
and coalesce(ec.canvas_id, '') <> ''
and not coalesce(ec.is_suspected_bot_click, false)
union all
select 'sms' as channel, sc.canvas_id, sc.canvas_step_id, sc.id
from `marketing-data-442316`.braze.sms_shortlinkclick sc
where 1=1
and sc.event_date between date '2025-12-29' and current_date('America/Denver')
and sc.workspace = 'cafe_zupas'
and coalesce(sc.canvas_id, '') <> ''
and not coalesce(sc.is_suspected_bot_click, false)
union all
select 'rcs' as channel, rc.canvas_id, rc.canvas_step_id, rc.id
from `marketing-data-442316`.braze.rcs_click rc
where 1=1
and rc.event_date between date '2025-12-29' and current_date('America/Denver')
and rc.workspace = 'cafe_zupas'
and coalesce(rc.canvas_id, '') <> ''
and not coalesce(rc.is_suspected_bot_click, false)
)
, treatment as (
select
s.canvas_id
, s.canvas_name
, s.canvas_step_id
, s.canvas_step_name
, s.channel
, min(s.event_date) as first_send_date
, max(s.event_date) as last_send_date
, count(distinct s.event_date) as send_days
, count(distinct s.id) as sends
, count(distinct s.em) as recipients_with_email
, sum(a.attr_orders) as attr_orders
, sum(a.attr_net_sales) as attr_net_sales
, sum(a.window_orders) as window_orders
, sum(a.window_net_sales) as window_net_sales
from sends s
	left join attr a
	on a.send_id = s.id
where 1=1
and coalesce(s.canvas_id, '') <> ''
group by s.canvas_id, s.canvas_name, s.canvas_step_id, s.canvas_step_name, s.channel
)
, dl as (
select d.channel, d.canvas_id, d.canvas_step_id, count(distinct d.id) as deliveries
from deliveries d
group by d.channel, d.canvas_id, d.canvas_step_id
)
, op as (
select o.channel, o.canvas_id, o.canvas_step_id, count(distinct o.id) as opens
from opens o
group by o.channel, o.canvas_id, o.canvas_step_id
)
, ck as (
select c.channel, c.canvas_id, c.canvas_step_id, count(distinct c.id) as clicks
from clicks c
group by c.channel, c.canvas_id, c.canvas_step_id
)
-- holdout legs: control split assignments; window measured from the split-entry instant
, holdout_entries as (
select
se.canvas_id
, se.canvas_name
, se.canvas_step_id
, se.canvas_step_name
, se.experiment_split_name
, se.external_user_id
, se.event_date
, timestamp_seconds(se.time) as entry_ts
, ud.email as em
from `marketing-data-442316`.braze.canvas_experimentstep_splitentry se
	left join `marketing-data-442316`.dashboard.braze_user_dim ud
	on ud.external_id = se.external_user_id
where 1=1
and se.event_date between date '2025-12-29' and current_date('America/Denver')
and se.workspace = 'cafe_zupas'
and (se.in_control_group
	or regexp_contains(lower(coalesce(se.experiment_split_name, '')), r'hold|control|ctrl|suppress|baseline'))
qualify row_number() over (partition by se.id order by se.time) = 1
)
, holdout_orders as (
select
h.canvas_id
, h.canvas_step_id
, h.experiment_split_name
, o.order_id
, o.net_sales
from holdout_entries h
	join orders o
	on o.em = h.em
	and o.order_ts > h.entry_ts
	and (timestamp_diff(o.order_ts, h.entry_ts, minute) < 1440
		or (format_date('%a', h.event_date) = 'Sat' and timestamp_diff(o.order_ts, h.entry_ts, minute) < 2880))
qualify row_number() over (partition by h.canvas_id, h.canvas_step_id, h.experiment_split_name, o.order_id order by h.entry_ts desc) = 1
)
, holdout as (
select
h.canvas_id
, h.canvas_name
, h.canvas_step_id
, h.canvas_step_name
, h.experiment_split_name
, min(h.event_date) as first_entry_date
, max(h.event_date) as last_entry_date
, count(distinct h.event_date) as entry_days
, count(distinct h.external_user_id) as holdout_users
, count(distinct h.em) as holdout_users_with_email
from holdout_entries h
group by h.canvas_id, h.canvas_name, h.canvas_step_id, h.canvas_step_name, h.experiment_split_name
)
, ho as (
select
x.canvas_id
, x.canvas_step_id
, x.experiment_split_name
, count(distinct x.order_id) as window_orders
, sum(x.net_sales) as window_net_sales
from holdout_orders x
group by x.canvas_id, x.canvas_step_id, x.experiment_split_name
)
-- canvas-level cadence for the is_automated fallback
, canvas_days as (
select s.canvas_id, count(distinct s.event_date) as canvas_send_days
from sends s
where 1=1
and coalesce(s.canvas_id, '') <> ''
group by s.canvas_id
)
, rows_out as (
select
false as is_holdout
, t.canvas_id
, t.canvas_name
, t.canvas_step_id
, t.canvas_step_name as canvas_message
, t.channel
, t.first_send_date
, t.last_send_date
, t.send_days
, t.sends
, case
	when t.channel = 'push' then t.sends - coalesce(pb.bounces, 0)
	else dl.deliveries
end as deliveries
, case when t.channel = 'sms' then null else op.opens end as opens
, case when t.channel = 'push' then null else ck.clicks end as clicks
, t.attr_orders
, t.attr_net_sales
, t.window_orders
, t.window_net_sales
, t.recipients_with_email as users_with_email
, cast(null as int64) as holdout_users
from treatment t
	left join dl
	on dl.channel = t.channel
	and dl.canvas_id = t.canvas_id
	and dl.canvas_step_id = t.canvas_step_id
		left join push_bounces pb
		on pb.canvas_id = t.canvas_id
		and pb.canvas_step_id = t.canvas_step_id
			left join op
			on op.channel = t.channel
			and op.canvas_id = t.canvas_id
			and op.canvas_step_id = t.canvas_step_id
				left join ck
				on ck.channel = t.channel
				and ck.canvas_id = t.canvas_id
				and ck.canvas_step_id = t.canvas_step_id
union all
select
true as is_holdout
, h.canvas_id
, h.canvas_name
, h.canvas_step_id
, concat(coalesce(h.canvas_step_name, 'Step'), ' / ', coalesce(h.experiment_split_name, 'Control')) as canvas_message
, 'holdout' as channel
, h.first_entry_date as first_send_date
, h.last_entry_date as last_send_date
, h.entry_days as send_days
, cast(null as int64) as sends
, cast(null as int64) as deliveries
, cast(null as int64) as opens
, cast(null as int64) as clicks
, cast(null as int64) as attr_orders
, cast(null as numeric) as attr_net_sales
, ho.window_orders
, ho.window_net_sales
, h.holdout_users_with_email as users_with_email
, h.holdout_users
from holdout h
	left join ho
	on ho.canvas_id = h.canvas_id
	and ho.canvas_step_id = h.canvas_step_id
	and coalesce(ho.experiment_split_name, '') = coalesce(h.experiment_split_name, '')
)
select
r.is_holdout
, r.canvas_id
, r.canvas_name
-- is_automated: explicit send-type token first, then a cm: token saying automated, then cadence.
-- The audience token (a:new, a:all, a:utah_idaho ...) is deliberately NOT used: it says who was
-- targeted, not what triggers the canvas (a:all_remaining / a:coldweatherstores are one-day broadcasts).
, case
	when regexp_contains(lower(r.canvas_name), r'\| *automated *\||st:automat') then true
	when regexp_contains(lower(r.canvas_name), r'\| *broadcast *\||st:broadcast') then false
	when regexp_contains(lower(r.canvas_name), r'cm:[^|]*automat') then true
	when coalesce(cd.canvas_send_days, 0) >= 5 then true
	else false
end as is_automated
, case
	when regexp_contains(lower(r.canvas_name), r'\| *automated *\||st:automat|\| *broadcast *\||st:broadcast') then 'name: send-type token'
	when regexp_contains(lower(r.canvas_name), r'cm:[^|]*automat') then 'name: cm token says automated'
	else concat('cadence: ', cast(coalesce(cd.canvas_send_days, 0) as string), ' send days (5+ = automated)')
end as is_automated_source
, r.canvas_step_id
, r.canvas_message
, r.channel
, r.first_send_date
, r.last_send_date
, r.send_days
, r.sends
, r.deliveries
, r.opens
, r.clicks
, r.attr_orders
, r.attr_net_sales
, r.window_orders
, r.window_net_sales
, r.users_with_email
, r.holdout_users
from rows_out r
	left join canvas_days cd
	on cd.canvas_id = r.canvas_id
order by r.canvas_name, r.is_holdout, r.first_send_date, r.canvas_message
