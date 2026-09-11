-- =====================================================================================
-- claude.ad_spend_daily — Claude-facing union of the five edi paid-media daily tables.
-- Docs, gotchas and metric definitions: data_dictionaries/claude.ad_spend_daily.md
-- Sources: edi.facebook_daily, edi.google_ads_daily, edi.snapchat_daily,
--          edi.spotify_daily, edi.tiktok_daily (refreshed 04:00 MT from windsor.ai).
-- =====================================================================================

create or replace view `marketing-data-442316`.claude.ad_spend_daily as
with facebook as (
select
fb.date as business_date
, 'facebook' as platform
, fb.datasource as datasource
, fb.account_name as account_name
, fb.objective as objective
, cast(null as string) as campaign_type
, fb.campaign as campaign
, nullif(fb.ad_group_name, '') as ad_group
, nullif(fb.ad_name, '') as ad_name
, nullif(fb.asset_group_name, '') as asset_group
, cast(fb.spend as numeric) as spend
, cast(fb.impressions as int64) as impressions
, cast(fb.clicks as int64) as clicks
, cast(fb.link_clicks as int64) as link_clicks
, cast(fb.actions_purchase as numeric) as conversions
, cast(fb.action_values_omni_purchase as numeric) as conversion_value
, cast(fb.actions_add_to_cart as int64) as adds_to_cart
, cast(fb.actions_landing_page_view as int64) as landing_page_views
from `marketing-data-442316`.edi.facebook_daily fb
)
, google_ads as (
select
gg.date as business_date
, 'google_ads' as platform
, gg.datasource as datasource
, gg.account_name as account_name
, cast(null as string) as objective
, gg.campaign_type as campaign_type
, gg.campaign as campaign
, nullif(gg.ad_group_name, '') as ad_group
, nullif(gg.ad_name, '') as ad_name
, nullif(gg.asset_group_name, '') as asset_group
, cast(gg.spend as numeric) as spend
, cast(gg.impressions as int64) as impressions
, cast(gg.clicks as int64) as clicks
, gg.link_clicks as link_clicks
, cast(gg.conversions as numeric) as conversions
, cast(gg.conversion_value as numeric) as conversion_value
, gg.adds_to_cart as adds_to_cart
, gg.landing_page_view as landing_page_views
from `marketing-data-442316`.edi.google_ads_daily gg
)
, snapchat as (
select
sc.date as business_date
, 'snapchat' as platform
, sc.datasource as datasource
, sc.account_name as account_name
, sc.objective as objective
, cast(null as string) as campaign_type
, sc.campaign as campaign
, nullif(sc.ad_group_name, '') as ad_group
, nullif(sc.ad_name, '') as ad_name
, nullif(sc.asset_group_name, '') as asset_group
, cast(sc.spend as numeric) as spend
, cast(sc.total_impressions as int64) as impressions
, cast(sc.clicks as int64) as clicks
, sc.link_clicks as link_clicks
, cast(sc.transactions as numeric) as conversions
, cast(sc.transactionrevenue as numeric) as conversion_value
, sc.adds_to_cart as adds_to_cart
, sc.landing_page_view as landing_page_views
from `marketing-data-442316`.edi.snapchat_daily sc
)
, spotify as (
select
sp.date as business_date
, 'spotify' as platform
, sp.datasource as datasource
, sp.account_name as account_name
, cast(sp.objective_type as string) as objective
, cast(null as string) as campaign_type
, sp.campaign as campaign
, nullif(sp.ad_set, '') as ad_group
, nullif(sp.ad_name, '') as ad_name
, cast(sp.asset_group_name as string) as asset_group
, cast(sp.spend as numeric) as spend
, cast(sp.impressions as int64) as impressions
, cast(sp.clicks as int64) as clicks
, sp.link_clicks as link_clicks
, cast(sp.conversions as numeric) as conversions
, cast(sp.total_complete_payment_rate as numeric) as conversion_value
, sp.web_event_add_to_cart as adds_to_cart
, sp.total_landing_page_view as landing_page_views
from `marketing-data-442316`.edi.spotify_daily sp
)
, tiktok as (
select
tt.date as business_date
, 'tiktok' as platform
, tt.datasource as datasource
, tt.account_name as account_name
, tt.objective_type as objective
, cast(null as string) as campaign_type
, tt.campaign as campaign
, nullif(tt.ad_group_name, '') as ad_group
, nullif(tt.ad_name, '') as ad_name
, nullif(tt.asset_group_name, '') as asset_group
, cast(tt.spend as numeric) as spend
, cast(tt.impressions as int64) as impressions
, cast(tt.clicks as int64) as clicks
, tt.link_clicks as link_clicks
, cast(tt.conversions as numeric) as conversions
, cast(tt.total_complete_payment_rate as numeric) as conversion_value
, cast(tt.web_event_add_to_cart as int64) as adds_to_cart
, cast(tt.total_landing_page_view as int64) as landing_page_views
from `marketing-data-442316`.edi.tiktok_daily tt
)
, unioned as (
select * from facebook
union all
select * from google_ads
union all
select * from snapchat
union all
select * from spotify
union all
select * from tiktok
)
select
u.business_date
, u.business_date as date
, u.* except(business_date)
from unioned u
;
