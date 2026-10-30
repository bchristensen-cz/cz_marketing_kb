-- braze cdi: ldip_<item> = last datetime the person bought each entree (plus ldip_kids_combo)
-- ldip_cc_<item> = same for a short product list, also crediting unidentified orders by card match
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
, ('Fall Bacon Sandwhich', 'Fall Bacon Grilled Cheese')
])
)
-- ldip_cc_: card-hash credit mapping. a card seen at a store on >= 80% of one person's identified orders
-- claims that card's unidentified orders at that store
, card_orders as (
select oc.brink_order_id
, oc.business_date
, oc.store_id
, oc.mapped_cust_id
, oc.customer_type
, concat(cast(p.last4 as string), case when lower(p.network) = 'american express' then 'amex' else lower(p.network) end) as cc_hash
from `marketing-data-442316`.pulse.stripe_order_payments p
	join `marketing-data-442316`.claude.order_customer oc
	on oc.pulse_order_id = p.order_id
where oc.business_date >= current_date('America/Denver') - 730
and not oc.is_catering
and p.last4 is not null
and p.network is not null
and not (ifnull(oc.mapped_email_domain, '') = 'cafezupas.com')
union distinct
select oc.brink_order_id
, oc.business_date
, oc.store_id
, oc.mapped_cust_id
, oc.customer_type
, concat(p.cardint, case when lower(t.Name) = 'american express' then 'amex' else lower(t.Name) end) as cc_hash
from `marketing-data-442316`.brink.brinkOrderPayment p
	join `marketing-data-442316`.claude.order_customer oc
	on oc.brink_order_id = p.orderid
	left join (select distinct t.Id, t.Name from `marketing-data-442316`.brink.brinkTenders t) t
	on t.Id = p.tenderid
where oc.business_date >= current_date('America/Denver') - 730
and not oc.is_catering
and p.CardInt is not null
and p.TenderId in (8,9,14,15)
and not (ifnull(oc.mapped_email_domain, '') = 'cafezupas.com')
)
, hash_map as (
select e.cc_hash
, e.store_id
, e.mapped_cust_id
, e.n_orders
, safe_divide(e.n_orders, sum(e.n_orders) over (partition by e.cc_hash, e.store_id)) as share
from (
	select co.cc_hash, co.store_id, co.mapped_cust_id, count(distinct co.brink_order_id) as n_orders
	from card_orders co
	where co.mapped_cust_id is not null
	and co.customer_type = 'person'
	group by 1, 2, 3
	) e
qualify share >= 0.80
)
, cc_lines as (
select oc.brink_order_id
, oc.business_date
, oc.order_timestamp_utc
, oc.mapped_cust_id
, 'ldip_cc_' || trim(regexp_replace(lower(replace(trim(coalesce(nm.clean_name, ol.item_name)), "'", '')), r'[^a-z0-9]+', '_'), '_') as attribute
from `marketing-data-442316`.claude.order_lines ol
	join `marketing-data-442316`.claude.order_customer oc
	on oc.brink_order_id = ol.brink_order_id
	and oc.business_date = ol.business_date
	left join name_map nm
	on nm.item_name = trim(ol.item_name)
where ol.business_date >= current_date('America/Denver') - 730
and oc.business_date >= current_date('America/Denver') - 730
-- clean names (after name_map); add a product here to give it an ldip_cc_ attribute
and coalesce(nm.clean_name, trim(ol.item_name)) in ('Athlete Bowl', 'Fall Bacon Grilled Cheese', 'Chocolate Duo Apple Cup', 'Golden Spice Apple Cup')
and ol.line_item_type in ('item', 'modifier')
and coalesce(ol.parent_rev_center_name, '') not in ('Box Lunches', 'Party Trays & Food')
and not oc.is_catering
and oc.store_id not in (1111, 999)
and oc.order_timestamp_utc is not null
and (oc.mapped_cust_id is null or oc.customer_type in ('person', 'internal'))
)
, cc_resolved as (
select cl.attribute
, cl.order_timestamp_utc
, coalesce(cl.mapped_cust_id, hm.mapped_cust_id) as mapped_cust_id
from cc_lines cl
	left join card_orders co
	on co.brink_order_id = cl.brink_order_id
	and co.business_date = cl.business_date
	and cl.mapped_cust_id is null
	left join hash_map hm
	on hm.cc_hash = co.cc_hash
	and hm.store_id = co.store_id
qualify row_number() over (partition by cl.brink_order_id, cl.attribute order by hm.share desc, hm.n_orders desc) = 1
)
(
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
-- internal = @cafezupas.com / tkxel staff, kept for braze testing; kiosk (%outdoor%@cafezupas.com) stays out
and oc.customer_type in ('person', 'internal')
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
)
union all
select
  cast(r.mapped_cust_id as string) as external_id
, r.attribute
, max(r.order_timestamp_utc) as last_purchase_utc
from cc_resolved r
where cast(r.mapped_cust_id as string) in (select bu.external_id from `marketing-data-442316`.braze.users bu)
group by 1, 2
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
