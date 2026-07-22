-- =============================================================================
-- braze_campaign_daily_activity.sql
-- -----------------------------------------------------------------------------
-- purpose : normalized, cross-channel view of braze message ACTIVITY -- i.e.
--           which campaigns / canvases were RUNNING (being sent / shown) on
--           which days, across every channel a campaign can traverse:
--             email, push, sms, content_card (on-site banners), in_app_message
--
-- grain   : one row per message-activity event.
--           "activity" = a send event for email / push / sms / content_card.
--           in-app messages have no send event in braze currents, so the
--           closest exposure event (impression) is used and tagged
--           activity_type = 'impression'.
--
-- identity: a "campaign" in the business sense may be delivered either as a
--           braze Campaign (campaign_id / campaign_name) or as a braze Canvas
--           journey (canvas_id / canvas_name). the program_* columns below
--           coalesce the two into a single identity so you can union freely.
--
-- usage   : replace @start_date / @end_date with your range. the event_date
--           partition filter is applied in EVERY base cte for cost control --
--           keep it. then build on the `activity` cte (or the final select).
--
-- notes   : - all lower case, fully qualified table names, early partition
--             filtering, only the columns needed (per team sql conventions).
--           - is_canvas is 1 when the message came from a Canvas, else 0.
--           - do NOT apply sales_ops filters here (storeid 1111, catering) --
--             those are order tables, not braze.
-- =============================================================================

with email as (
  select
    event_date
  , event_timestamp
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
)

, push as (
  select
    event_date
  , event_timestamp
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
)

, sms as (
  select
    event_date
  , event_timestamp
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
)

, content_card as (
  select
    event_date
  , event_timestamp
  , 'content_card'    as channel   -- on-site / in-app banners
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
)

, in_app_message as (
  -- in-app messages have no send event; impression is the exposure event.
  select
    event_date
  , event_timestamp
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
)

, activity as (
  select * from email
  union all select * from push
  union all select * from sms
  union all select * from content_card
  union all select * from in_app_message
)

-- normalized, reusable result set -------------------------------------------
select
  event_date
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
