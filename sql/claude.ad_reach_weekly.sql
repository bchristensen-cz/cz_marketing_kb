-- =====================================================================================
-- claude.ad_reach_weekly — Claude-facing union of the edi weekly reach tables.
-- Docs and the non-additivity rule: data_dictionaries/claude.ad_reach_weekly.md
-- Reach is deduplicated WITHIN one (platform, campaign, reach_week) only — never sum it
-- across campaigns, weeks or reach_level.
-- =====================================================================================

create or replace view `marketing-data-442316`.claude.ad_reach_weekly as
with campaign_level as (
select
fb.reach_week as reach_week
, 'facebook' as platform
, fb.datasource as datasource
, fb.account_name as account_name
, fb.campaign as campaign
, cast(null as string) as ad_set
, 'campaign' as reach_level
, cast(fb.campaign_reach as int64) as reach
from `marketing-data-442316`.edi.facebook_weekly_reach_campaign fb
union all
select
sc.reach_week
, 'snapchat'
, sc.datasource
, sc.account_name
, sc.campaign
, cast(null as string)
, 'campaign'
, cast(sc.campaign_reach as int64)
from `marketing-data-442316`.edi.snapchat_weekly_reach_campaign sc
union all
select
tt.reach_week
, 'tiktok'
, tt.datasource
, tt.account_name
, tt.campaign
, cast(null as string)
, 'campaign'
, cast(tt.campaign_reach as int64)
from `marketing-data-442316`.edi.tiktok_weekly_reach_campaign tt
)
, ad_set_level as (
select
fb.reach_week as reach_week
, 'facebook' as platform
, fb.datasource as datasource
, fb.account_name as account_name
, fb.campaign as campaign
, fb.adset_name as ad_set
, 'ad_set' as reach_level
, cast(fb.campaign_reach as int64) as reach
from `marketing-data-442316`.edi.facebook_weekly_reach_ad_set fb
union all
select
sc.reach_week
, 'snapchat'
, sc.datasource
, sc.account_name
, sc.campaign
, sc.adset_name
, 'ad_set'
, cast(sc.campaign_reach as int64)
from `marketing-data-442316`.edi.snapchat_weekly_reach_ad_set sc
union all
select
tt.reach_week
, 'tiktok'
, tt.datasource
, tt.account_name
, tt.campaign
, tt.adset_name
, 'ad_set'
, cast(tt.campaign_reach as int64)
from `marketing-data-442316`.edi.tiktok_weekly_reach_ad_set tt
)
, unioned as (
select * from campaign_level
union all
select * from ad_set_level
)
select
u.reach_week
, rr.reach_year_week as reach_year_week
, u.platform
, u.datasource
, u.account_name
, u.campaign
, u.ad_set
, u.reach_level
, u.reach
from unioned u
  left join `marketing-data-442316`.edi.reach_rel_date rr
    on rr.reach_week = u.reach_week
;
