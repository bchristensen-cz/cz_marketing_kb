select distinct concat('em:', oc.mapped_email_hash) as anchor_key
from `marketing-data-442316.claude.order_lines` ol
	join `marketing-data-442316.claude.order_customer` oc
	on oc.brink_order_id = ol.brink_order_id
	and oc.business_date = ol.business_date
where 1=1
and ol.business_date between @from_date and @to_date
and oc.business_date between @from_date and @to_date
and oc.customer_type = 'person'
and oc.mapped_email_hash is not null
and not oc.is_catering
and ol.line_item_type in ('item', 'modifier')
and coalesce(ol.parent_rev_center_name, '') not in ('Box Lunches', 'Party Trays & Food')
and trim(ol.item_name) in ('Athlete Bowl', 'Fall Bacon Grilled Cheese', 'Fall Bacon Sandwhich', 'Italian Sausage Gnocchi Soup')
