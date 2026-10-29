-- braze cdi: ldip_<item> = last datetime the person bought each entree (plus ldip_kids_combo)
-- scheduled daily after the 5am order reload. braze cdi reads braze.cdi_ldip_items_v
-- updated_at = when this job saw the value change, so late orders, new braze users and items that
-- newly pass the buyer floor all sync on the next run, never behind the watermark

create table if not exists `marketing-data-442316`.braze.cdi_ldip_items (
  external_id string
, attribute string
, last_purchase_utc timestamp
, updated_at timestamp
)
cluster by updated_at;

merge `marketing-data-442316`.braze.cdi_ldip_items t
using (
with name_map as (
-- cosmetic only: pos abbreviations and size-split names -> one name. an unmapped new item still syncs under its own name
select * from unnest([
  struct('BBQ Ck Salad' as item_name, 'BBQ Chicken Salad' as clean_name)
, ('Glazed Chipotle Salad', 'Chipotle Glazed Salad')
, ('Chipotle Glazed Chicken', 'Chipotle Glazed Salad')
, ('Chipotle Glazed Pork', 'Chipotle Glazed Salad')
, ('Dressd Tortilla Soup', 'Dressed Up Chicken Tortilla Soup')
, ('Strwbry Harvest Salad', 'Strawberry Harvest Salad')
, ('Mushrm Bisque', 'Mushroom Bisque')
, ('Chicken Ench Chili', 'Chicken Enchilada Chili')
, ('Cali Cobb Salad', 'California Cobb Salad')
, ('BYO Your Own Greens & Grains', 'BYO Greens & Grains Bowl')
, ('BYO Your Own Greens Bowl', 'BYO Greens Bowl')
, ('BYO Your Own Rice Bowl', 'BYO Rice Bowl')
])
)
select
  cast(oc.mapped_cust_id as string) as external_id
, 'ldip_' || trim(regexp_replace(lower(replace(trim(coalesce(nm.clean_name, ol.item_name)), "'", '')), r'[^a-z0-9]+', '_'), '_') as attribute
, max(oc.order_timestamp_utc) as last_purchase_utc
from `marketing-data-442316`.claude.order_lines ol
	join `marketing-data-442316`.claude.order_customer oc
	on oc.brink_order_id = ol.brink_order_id
	and oc.business_date = ol.business_date
	left join name_map nm
	on nm.item_name = trim(ol.item_name)
where ol.business_date >= current_date('America/Denver') - 730
and oc.business_date >= current_date('America/Denver') - 730
and oc.customer_type = 'person'
and not oc.is_catering
and oc.store_id not in (1111, 999)
and oc.mapped_cust_id is not null
and oc.order_timestamp_utc is not null
and (
	(ol.item_type = 'Entree' and ol.rev_center_name in ('Bowls','Salads','Sandwiches','Soups'))
	or ol.item_name = 'Kids Combo'
	)
and ol.item_name not like '% Box'
and cast(oc.mapped_cust_id as string) in (select bu.external_id from `marketing-data-442316`.braze.users bu)
group by 1, 2
-- buyer floor drops retired / test stragglers without a list; a new entree clears it on day one
qualify count(*) over (partition by attribute) >= 500
) s
on t.external_id = s.external_id
and t.attribute = s.attribute
when matched and s.last_purchase_utc > t.last_purchase_utc then update set
  last_purchase_utc = s.last_purchase_utc
, updated_at = current_timestamp()
when not matched by target then insert (external_id, attribute, last_purchase_utc, updated_at)
values (s.external_id, s.attribute, s.last_purchase_utc, current_timestamp());

create or replace view `marketing-data-442316`.braze.cdi_ldip_items_v as
select
  t.updated_at
, t.external_id
, json_object(t.attribute, format_timestamp('%Y-%m-%dT%H:%M:%E3SZ', t.last_purchase_utc)) as payload
from `marketing-data-442316`.braze.cdi_ldip_items t;
