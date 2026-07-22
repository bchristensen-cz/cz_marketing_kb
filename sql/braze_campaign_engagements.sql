-- =============================================================================
-- braze_campaign_engagements.sql
-- -----------------------------------------------------------------------------
-- purpose : normalized, cross-channel view of CUSTOMER ENGAGEMENT with braze
--           messages -- opens, clicks and replies across every channel a
--           campaign can traverse: email, push, sms, content_card (banners),
--           in_app_message. use this to answer "did this customer engage with
--           campaign X?" and to compute campaign engagement rate.
--
-- grain   : one row per engagement event.
--
-- engagement_type values:
--           'open'  -> email_open, pushnotification_open
--           'click' -> email_click, inappmessage_click, contentcard_click,
--                      sms_shortlinkclick
--           'reply' -> sms_inboundreceive (inbound texts incl. STOP/HELP --
--                      treat with care; not always positive engagement)
--
-- machine opens:
--           email opens include Apple Mail Privacy Protection (MPP) and other
--           proxy "machine" opens that are not human actions. the
--           is_machine_open flag isolates them so you can report human-only
--           engagement (default) AND all-opens side by side. only email_open
--           can be a machine open; everything else is false.
--
-- identity: program_* columns coalesce braze Campaign vs Canvas identity, the
--           same way braze_campaign_daily_activity.sql does, so the two line up.
--
-- usage   : replace @start_date / @end_date. keep the event_date partition
--           filter in every base cte. default engagement rate uses SENT as the
--           denominator (see the engagement-rate example at the bottom).
-- =============================================================================

with email_opens as (
  select
    event_date
  , event_timestamp
  , 'email'  as channel
  , 'open'   as engagement_type
  , coalesce(lower(machine_open) = 'true', false) as is_machine_open
  , campaign_id
  , campaign_name
  , canvas_id
  , canvas_name
  , message_variation_id
  , send_id
  , is_canvas
  , external_user_id
  , user_id
  from `marketing-data-442316`.braze.email_open
  where event_date between @start_date and @end_date
)

, email_clicks as (
  select
    event_date
  , event_timestamp
  , 'email'  as channel
  , 'click'  as engagement_type
  , false    as is_machine_open
  , campaign_id
  , campaign_name
  , canvas_id
  , canvas_name
  , message_variation_id
  , send_id
  , is_canvas
  , external_user_id
  , user_id
  from `marketing-data-442316`.braze.email_click
  where event_date between @start_date and @end_date
)

, push_opens as (
  select
    event_date
  , event_timestamp
  , 'push'   as channel
  , 'open'   as engagement_type
  , false    as is_machine_open
  , campaign_id
  , campaign_name
  , canvas_id
  , canvas_name
  , message_variation_id
  , send_id
  , is_canvas
  , external_user_id
  , user_id
  from `marketing-data-442316`.braze.pushnotification_open
  where event_date between @start_date and @end_date
)

, inapp_clicks as (
  select
    event_date
  , event_timestamp
  , 'in_app_message' as channel
  , 'click'          as engagement_type
  , false            as is_machine_open
  , campaign_id
  , campaign_name
  , canvas_id
  , canvas_name
  , message_variation_id
  , send_id
  , is_canvas
  , external_user_id
  , user_id
  from `marketing-data-442316`.braze.inappmessage_click
  where event_date between @start_date and @end_date
)

, content_card_clicks as (
  select
    event_date
  , event_timestamp
  , 'content_card'   as channel
  , 'click'          as engagement_type
  , false            as is_machine_open
  , campaign_id
  , campaign_name
  , canvas_id
  , canvas_name
  , message_variation_id
  , send_id
  , is_canvas
  , external_user_id
  , user_id
  from `marketing-data-442316`.braze.contentcard_click
  where event_date between @start_date and @end_date
)

, sms_clicks as (
  -- sms_shortlinkclick has no send_id column -> null it to keep the shape
  select
    event_date
  , event_timestamp
  , 'sms'    as channel
  , 'click'  as engagement_type
  , false    as is_machine_open
  , campaign_id
  , campaign_name
  , canvas_id
  , canvas_name
  , message_variation_id
  , cast(null as string) as send_id
  , is_canvas
  , external_user_id
  , user_id
  from `marketing-data-442316`.braze.sms_shortlinkclick
  where event_date between @start_date and @end_date
)

, sms_replies as (
  -- inbound texts (incl. STOP / HELP). include or exclude per analysis.
  select
    event_date
  , event_timestamp
  , 'sms'    as channel
  , 'reply'  as engagement_type
  , false    as is_machine_open
  , campaign_id
  , campaign_name
  , canvas_id
  , canvas_name
  , message_variation_id
  , cast(null as string) as send_id
  , is_canvas
  , external_user_id
  , user_id
  from `marketing-data-442316`.braze.sms_inboundreceive
  where event_date between @start_date and @end_date
)

, engagements as (
  select * from email_opens
  union all select * from email_clicks
  union all select * from push_opens
  union all select * from inapp_clicks
  union all select * from content_card_clicks
  union all select * from sms_clicks
  union all select * from sms_replies
)

-- normalized, reusable engagement result set --------------------------------
select
  event_date
, event_timestamp
, channel
, engagement_type
, is_machine_open
, case when is_canvas = 1 then 'canvas' else 'campaign' end as program_type
, coalesce(nullif(campaign_id, ''), canvas_id)             as program_id
, coalesce(nullif(campaign_name, ''), canvas_name)         as program_name
, campaign_id
, campaign_name
, canvas_id
, canvas_name
, message_variation_id
, send_id
, external_user_id
, user_id
from engagements
;


-- =============================================================================
-- example A : did a given customer engage with a given campaign?
-- =============================================================================
-- with engagements_norm as ( <paste the normalized select above> )
-- select
--   external_user_id
-- , program_id
-- , program_name
-- , min(event_timestamp)                          as first_engaged_at
-- , max(event_timestamp)                          as last_engaged_at
-- , count(*)                                       as engagement_events
-- , array_agg(distinct channel order by channel)  as channels_engaged
-- from engagements_norm
-- where not is_machine_open                        -- human engagement only
--   and program_id is not null
-- group by external_user_id, program_id, program_name
-- ;


-- =============================================================================
-- example B : campaign engagement rate (denominator = SENT; cross-channel)
-- -----------------------------------------------------------------------------
-- builds a minimal SENT base from the send / impression tables (matching
-- braze_campaign_daily_activity.sql) and a minimal ENGAGED base from the
-- engagement union above, then divides distinct engaged users by distinct
-- sent users per program. reports human-only and all-opens variants.
-- =============================================================================
-- with sent_base as (
--   select coalesce(nullif(campaign_id,''), canvas_id) as program_id,
--          coalesce(nullif(campaign_name,''), canvas_name) as program_name,
--          external_user_id
--   from `marketing-data-442316`.braze.email_send
--   where event_date between @start_date and @end_date
--   union all
--   select coalesce(nullif(campaign_id,''), canvas_id),
--          coalesce(nullif(campaign_name,''), canvas_name), external_user_id
--   from `marketing-data-442316`.braze.pushnotification_send
--   where event_date between @start_date and @end_date
--   union all
--   select coalesce(nullif(campaign_id,''), canvas_id),
--          coalesce(nullif(campaign_name,''), canvas_name), external_user_id
--   from `marketing-data-442316`.braze.sms_send
--   where event_date between @start_date and @end_date
--   union all
--   select coalesce(nullif(campaign_id,''), canvas_id),
--          coalesce(nullif(campaign_name,''), canvas_name), external_user_id
--   from `marketing-data-442316`.braze.contentcard_send
--   where event_date between @start_date and @end_date
--   union all
--   select coalesce(nullif(campaign_id,''), canvas_id),
--          coalesce(nullif(campaign_name,''), canvas_name), external_user_id
--   from `marketing-data-442316`.braze.inappmessage_impression  -- in-app exposure
--   where event_date between @start_date and @end_date
-- )
-- , sent as (
--   select program_id, program_name,
--          count(distinct external_user_id) as sent_users
--   from sent_base
--   where program_id is not null
--   group by program_id, program_name
-- )
-- , engaged as (
--   select program_id,
--          count(distinct case when not is_machine_open then external_user_id end) as engaged_users_human,
--          count(distinct external_user_id) as engaged_users_all
--   from engagements_norm                      -- <- the normalized engagement set
--   where program_id is not null
--   group by program_id
-- )
-- select
--   s.program_id
-- , s.program_name
-- , s.sent_users
-- , e.engaged_users_human
-- , e.engaged_users_all
-- , safe_divide(e.engaged_users_human, s.sent_users) as engagement_rate_human
-- , safe_divide(e.engaged_users_all,   s.sent_users) as engagement_rate_all
-- from sent s
-- left join engaged e using (program_id)
-- order by s.sent_users desc
-- ;
-- -- tip: for human-only vs all-opens, filter the engaged cte on
-- --      `not is_machine_open` (human) vs no filter (all). split into two ctes
-- --      for clean side-by-side columns. group by channel too for a per-channel
-- --      engagement-rate breakdown.
