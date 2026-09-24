-- Braze campaign x message variation report, sends from 2025-12-29 (companion to braze_canvas_message_report.sql)
-- grain: campaign_id x message_variation_id x channel; Braze leaves message_variation_name NULL on most push/multichannel campaigns
-- attribution: D-026 (last touch, 24h from send instant, 48h for Saturday sends), email bridge D-021,
--   workspace cafe_zupas, non-catering, non-employee, identified orders only; canvas sends stay in the
--   last-touch competition, only the campaign rows are emitted
-- webhook campaigns emit no channel send event, so they are excluded structurally; the name guard is belt and braces
-- no holdout rows: campaign control groups live in campaigns_enrollincontrol (not built here)
create or replace table `marketing-data-442316`.scratch.braze_campaign_message_report_20260924
options (expiration_timestamp = timestamp_add(current_timestamp(), interval 21 day))
as
with sends_raw as (
select
'email' as channel
, es.id as id
, es.event_date as event_date
, timestamp_seconds(es.time) as send_ts
, coalesce(nullif(es.campaign_id, ''), es.canvas_id) as program_id
, nullif(es.campaign_id, '') as campaign_id
, es.campaign_name as campaign_name
, es.message_variation_id as message_variation_id
, es.message_variation_name as message_variation_name
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
, nullif(ps.campaign_id, '') as campaign_id
, ps.campaign_name as campaign_name
, ps.message_variation_id as message_variation_id
, ps.message_variation_name as message_variation_name
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
, nullif(ss.campaign_id, '') as campaign_id
, ss.campaign_name as campaign_name
, ss.message_variation_id as message_variation_id
, ss.message_variation_name as message_variation_name
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
, nullif(rs.campaign_id, '') as campaign_id
, rs.campaign_name as campaign_name
, rs.message_variation_id as message_variation_id
, rs.message_variation_name as message_variation_name
, ud.email as em
from `marketing-data-442316`.braze.rcs_send rs
	left join `marketing-data-442316`.dashboard.braze_user_dim ud
	on ud.external_id = rs.external_user_id
where 1=1
and rs.event_date between date '2025-12-29' and current_date('America/Denver')
and rs.workspace = 'cafe_zupas'
)
, sends as (
select
sr.channel
, sr.id
, sr.event_date
, sr.send_ts
, sr.program_id
, sr.campaign_id
, sr.campaign_name
, sr.message_variation_id
, sr.message_variation_name
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
select 'email' as channel, ed.campaign_id, ed.message_variation_id, ed.id
from `marketing-data-442316`.braze.email_delivery ed
where 1=1
and ed.event_date between date '2025-12-29' and current_date('America/Denver')
and ed.workspace = 'cafe_zupas'
and coalesce(ed.campaign_id, '') <> ''
union all
select 'sms' as channel, sd.campaign_id, sd.message_variation_id, sd.id
from `marketing-data-442316`.braze.sms_delivery sd
where 1=1
and sd.event_date between date '2025-12-29' and current_date('America/Denver')
and sd.workspace = 'cafe_zupas'
and coalesce(sd.campaign_id, '') <> ''
union all
select 'rcs' as channel, rd.campaign_id, rd.message_variation_id, rd.id
from `marketing-data-442316`.braze.rcs_delivery rd
where 1=1
and rd.event_date between date '2025-12-29' and current_date('America/Denver')
and rd.workspace = 'cafe_zupas'
and coalesce(rd.campaign_id, '') <> ''
)
, push_bounces as (
select pb.campaign_id, pb.message_variation_id, count(distinct pb.id) as bounces
from `marketing-data-442316`.braze.pushnotification_bounce pb
where 1=1
and pb.event_date between date '2025-12-29' and current_date('America/Denver')
and pb.workspace = 'cafe_zupas'
and coalesce(pb.campaign_id, '') <> ''
group by pb.campaign_id, pb.message_variation_id
)
, opens as (
select 'email' as channel, eo.campaign_id, eo.message_variation_id, eo.id
from `marketing-data-442316`.braze.email_open eo
where 1=1
and eo.event_date between date '2025-12-29' and current_date('America/Denver')
and eo.workspace = 'cafe_zupas'
and coalesce(eo.campaign_id, '') <> ''
and not coalesce(lower(eo.machine_open) = 'true', false)
union all
select 'push' as channel, po.campaign_id, po.message_variation_id, po.id
from `marketing-data-442316`.braze.pushnotification_open po
where 1=1
and po.event_date between date '2025-12-29' and current_date('America/Denver')
and po.workspace = 'cafe_zupas'
and coalesce(po.campaign_id, '') <> ''
union all
select 'rcs' as channel, rr.campaign_id, rr.message_variation_id, rr.id
from `marketing-data-442316`.braze.rcs_read rr
where 1=1
and rr.event_date between date '2025-12-29' and current_date('America/Denver')
and rr.workspace = 'cafe_zupas'
and coalesce(rr.campaign_id, '') <> ''
)
, clicks as (
select 'email' as channel, ec.campaign_id, ec.message_variation_id, ec.id
from `marketing-data-442316`.braze.email_click ec
where 1=1
and ec.event_date between date '2025-12-29' and current_date('America/Denver')
and ec.workspace = 'cafe_zupas'
and coalesce(ec.campaign_id, '') <> ''
and not coalesce(ec.is_suspected_bot_click, false)
union all
select 'sms' as channel, sc.campaign_id, sc.message_variation_id, sc.id
from `marketing-data-442316`.braze.sms_shortlinkclick sc
where 1=1
and sc.event_date between date '2025-12-29' and current_date('America/Denver')
and sc.workspace = 'cafe_zupas'
and coalesce(sc.campaign_id, '') <> ''
and not coalesce(sc.is_suspected_bot_click, false)
union all
select 'rcs' as channel, rc.campaign_id, rc.message_variation_id, rc.id
from `marketing-data-442316`.braze.rcs_click rc
where 1=1
and rc.event_date between date '2025-12-29' and current_date('America/Denver')
and rc.workspace = 'cafe_zupas'
and coalesce(rc.campaign_id, '') <> ''
and not coalesce(rc.is_suspected_bot_click, false)
)
, treatment as (
select
s.campaign_id
, s.campaign_name
, s.message_variation_id
, s.message_variation_name
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
and s.campaign_id is not null
and not regexp_contains(lower(coalesce(s.campaign_name, '')), r'webhook')
group by s.campaign_id, s.campaign_name, s.message_variation_id, s.message_variation_name, s.channel
)
, dl as (
select d.channel, d.campaign_id, d.message_variation_id, count(distinct d.id) as deliveries
from deliveries d
group by d.channel, d.campaign_id, d.message_variation_id
)
, op as (
select o.channel, o.campaign_id, o.message_variation_id, count(distinct o.id) as opens
from opens o
group by o.channel, o.campaign_id, o.message_variation_id
)
, ck as (
select c.channel, c.campaign_id, c.message_variation_id, count(distinct c.id) as clicks
from clicks c
group by c.channel, c.campaign_id, c.message_variation_id
)
, campaign_days as (
select s.campaign_id, count(distinct s.event_date) as campaign_send_days
from sends s
where 1=1
and s.campaign_id is not null
group by s.campaign_id
)
select
false as is_holdout
, t.campaign_id as canvas_id
, t.campaign_name as canvas_name
-- is_automated: same rule as the canvas leg; audience token deliberately not used
, case
	when regexp_contains(lower(t.campaign_name), r'\| *automated *\||st:automat') then true
	when regexp_contains(lower(t.campaign_name), r'\| *broadcast *\||st:broadcast') then false
	when regexp_contains(lower(t.campaign_name), r'cm:[^|]*automat') then true
	when coalesce(cd.campaign_send_days, 0) >= 5 then true
	else false
end as is_automated
, case
	when regexp_contains(lower(t.campaign_name), r'\| *automated *\||st:automat|\| *broadcast *\||st:broadcast') then 'name: send-type token'
	when regexp_contains(lower(t.campaign_name), r'cm:[^|]*automat') then 'name: cm token says automated'
	else concat('cadence: ', cast(coalesce(cd.campaign_send_days, 0) as string), ' send days (5+ = automated)')
end as is_automated_source
, t.message_variation_id as canvas_step_id
, t.message_variation_name as canvas_message
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
	and dl.campaign_id = t.campaign_id
	and coalesce(dl.message_variation_id, '') = coalesce(t.message_variation_id, '')
		left join push_bounces pb
		on pb.campaign_id = t.campaign_id
		and coalesce(pb.message_variation_id, '') = coalesce(t.message_variation_id, '')
			left join op
			on op.channel = t.channel
			and op.campaign_id = t.campaign_id
			and coalesce(op.message_variation_id, '') = coalesce(t.message_variation_id, '')
				left join ck
				on ck.channel = t.channel
				and ck.campaign_id = t.campaign_id
				and coalesce(ck.message_variation_id, '') = coalesce(t.message_variation_id, '')
					left join campaign_days cd
					on cd.campaign_id = t.campaign_id
order by t.campaign_name, t.first_send_date, t.message_variation_name
