-- =============================================================================
-- braze_campaign_daily_activity.sql
-- -----------------------------------------------------------------------------
-- purpose : normalized, cross-channel view of braze message ACTIVITY -- i.e.
--           which campaigns / canvases were RUNNING (being sent / shown) on
--           which days, across every channel a campaign can traverse:
--             email, push, sms, rcs, content_card, banner, in_app_message
--
-- grain   : one row per message-activity event.
--           "activity" = a send event for email / push / sms / rcs /
--           content_card. in-app messages and banners have no send event in
--           braze currents, so the closest exposure event (impression) is used
--           and tagged activity_type = 'impression'.
--
-- identity: a "campaign" in the business sense may be delivered either as a
--           braze Campaign (campaign_id / campaign_name) or as a braze Canvas
--           journey (canvas_id / canvas_name). the program_* columns below
--           coalesce the two into a single identity so you can union freely.
--
-- workspace (added with the 2026-07 streaming switch):
--           every table now carries a `workspace` column. values:
--             'cafe_zupas'          -- main workspace (~99% of volume)
--             'cafe_zupas_catering' -- separate catering workspace
--           CANONICAL DEFAULT: filter workspace = 'cafe_zupas'. include the
--           catering workspace only when explicitly asked; if you do, keep
--           workspace in the grain -- campaign ids never cross workspaces.
--
-- usage   : replace @start_date / @end_date with your range. the event_date
--           partition filter is applied in EVERY base cte for cost control --
--           keep it, and keep the workspace filter with it.
--
-- notes   : - all lower case, fully qualified table names, early partition
--             filtering, only the columns needed (per team sql conventions).
--           - is_canvas is 1 when the message came from a Canvas, else 0.
--             streaming-era tables (banner_*, rcs_*) have NO is_canvas column;
--             it is derived from canvas_id there.
--           - banner_* and rcs_read have no send_id / dispatch_id -> nulled.
--           - do NOT apply sales_ops filters here (storeid 1111, catering) --
--             those are order tables, not braze.
-- =============================================================================

with email as (
  select
    event_date
  , event_timestamp
  , workspace
  , 'email'           as channel
  , 'send'            as activity_type
  , campaign_id
  , campaign_name
  , canvas_id
  , canvas_name
  , canvas_step_id
  , canvas_step_name
  , message_variation_id
  , message_variation_name
  , send_id
  , dispatch_id
  , is_canvas
  , external_user_id
  , user_id
  from `marketing-data-442316`.braze.email_send
  where event_date between @start_date and @end_date
  and workspace = 'cafe_zupas'   -- canonical default; see header
)

, push as (
  select
    event_date
  , event_timestamp
  , workspace
  , 'push'            as channel
  , 'send'            as activity_type
  , campaign_id
  , campaign_name
  , canvas_id
  , canvas_name
  , canvas_step_id
  , canvas_step_name
  , message_variation_id
  , message_variation_name
  , send_id
  , dispatch_id
  , is_canvas
  , external_user_id
  , user_id
  from `marketing-data-442316`.braze.pushnotification_send
  where event_date between @start_date and @end_date
  and workspace = 'cafe_zupas'
)

, sms as (
  select
    event_date
  , event_timestamp
  , workspace
  , 'sms'             as channel
  , 'send'            as activity_type
  , campaign_id
  , campaign_name
  , canvas_id
  , canvas_name
  , canvas_step_id
  , canvas_step_name
  , message_variation_id
  , message_variation_name
  , send_id
  , dispatch_id
  , is_canvas
  , external_user_id
  , user_id
  from `marketing-data-442316`.braze.sms_send
  where event_date between @start_date and @end_date
  and workspace = 'cafe_zupas'
)

, rcs as (
  -- rcs (rich communication services) took over most text volume after the
  -- 2026-07 streaming switch. streaming table: no is_canvas -> derived.
  select
    event_date
  , event_timestamp
  , workspace
  , 'rcs'             as channel
  , 'send'            as activity_type
  , campaign_id
  , campaign_name
  , canvas_id
  , canvas_name
  , canvas_step_id
  , canvas_step_name
  , message_variation_id
  , message_variation_name
  , send_id
  , dispatch_id
  , case when coalesce(canvas_id, '') <> '' then 1 else 0 end as is_canvas
  , external_user_id
  , user_id
  from `marketing-data-442316`.braze.rcs_send
  where event_date between @start_date and @end_date
  and workspace = 'cafe_zupas'
)

, content_card as (
  select
    event_date
  , event_timestamp
  , workspace
  , 'content_card'    as channel
  , 'send'            as activity_type
  , campaign_id
  , campaign_name
  , canvas_id
  , canvas_name
  , canvas_step_id
  , canvas_step_name
  , message_variation_id
  , message_variation_name
  , send_id
  , dispatch_id
  , is_canvas
  , external_user_id
  , user_id
  from `marketing-data-442316`.braze.contentcard_send
  where event_date between @start_date and @end_date
  and workspace = 'cafe_zupas'
)

, banner as (
  -- banners (new braze channel, streaming era): no send event -> impression is
  -- the exposure event. no send_id / dispatch_id / is_canvas columns.
  select
    event_date
  , event_timestamp
  , workspace
  , 'banner'          as channel
  , 'impression'      as activity_type
  , campaign_id
  , campaign_name
  , canvas_id
  , canvas_name
  , canvas_step_id
  , canvas_step_name
  , message_variation_id
  , message_variation_name
  , cast(null as string) as send_id
  , cast(null as string) as dispatch_id
  , case when coalesce(canvas_id, '') <> '' then 1 else 0 end as is_canvas
  , external_user_id
  , user_id
  from `marketing-data-442316`.braze.banner_impression
  where event_date between @start_date and @end_date
  and workspace = 'cafe_zupas'
)

, in_app_message as (
  -- in-app messages have no send event; impression is the exposure event.
  select
    event_date
  , event_timestamp
  , workspace
  , 'in_app_message'  as channel
  , 'impression'      as activity_type
  , campaign_id
  , campaign_name
  , canvas_id
  , canvas_name
  , canvas_step_id
  , canvas_step_name
  , message_variation_id
  , message_variation_name
  , send_id
  , dispatch_id
  , is_canvas
  , external_user_id
  , user_id
  from `marketing-data-442316`.braze.inappmessage_impression
  where event_date between @start_date and @end_date
  and workspace = 'cafe_zupas'
)

, activity as (
  select * from email
  union all select * from push
  union all select * from sms
  union all select * from rcs
  union all select * from content_card
  union all select * from banner
  union all select * from in_app_message
)

-- normalized, reusable result set -------------------------------------------
select
  event_date
, workspace
, channel
, activity_type
, case when is_canvas = 1 then 'canvas' else 'campaign' end as program_type
, coalesce(nullif(campaign_id, ''), canvas_id)             as program_id
, coalesce(nullif(campaign_name, ''), canvas_name)         as program_name
, campaign_id
, campaign_name
, canvas_id
, canvas_name
, canvas_step_name
, message_variation_id
, message_variation_name
, send_id
, dispatch_id
, external_user_id
, user_id
from activity
;


-- =============================================================================
-- example rollup : which campaigns ran on which days, and on which channels
-- (wrap the query above as a cte / view named `activity_norm`, or paste the
--  union above in place of the `activity_norm` reference below.)
-- =============================================================================
-- with activity_norm as ( <paste the normalized select above> )
-- select
--   event_date
-- , program_type
-- , program_id
-- , program_name
-- , array_agg(distinct channel order by channel)        as channels_active
-- , count(distinct channel)                             as channel_count
-- , count(*)                                            as activity_events
-- , count(distinct external_user_id)                    as users_reached
-- from activity_norm
-- where program_id is not null
-- group by event_date, program_type, program_id, program_name
-- order by event_date, program_name
-- ;
