/*
claude.order_payment_tender
---------------------------
Order-level payment tender for the Claude surface. One row per brink_order_id
(same grain and population as claude.order_customer: business_date >= jan 1 three
calendar years back, store_id <> 1111).

This view is the sanctioned wrapper around the raw payment tables
(pulse.order_payments, pulse.stripe_order_payments, pulse.tenders,
brink.brinkOrderPayment, brink.brinkTenders). Never query those directly.

Join pattern:
    from `marketing-data-442316`.claude.order_customer oc
        left join `marketing-data-442316`.claude.order_payment_tender opt
        on opt.brink_order_id = oc.brink_order_id
    where 1=1
    and oc.business_date >= ...   -- always bound business_date

Columns: brink_order_id, pulse_order_id, business_date, payment_tender,
total_payment_amount. (Trimmed 2026-08-05 from the first deploy: the answer
column was renamed payment_network -> payment_tender, and the debug name
columns, tips, and change were dropped — tips and change live on
order_customer as total_tip_amount / total_change.)

Semantics / assumptions:
- Settled payments in, ignoring refunds. Pulse rows must be processed and not
  cancelled / failed / refund / removed / soft-deleted; stripe detail only from
  status = 'succeeded' and not soft-deleted; brink rows exclude isDeleted.
- payment_tender prefers pulse tender names (digital wallet detail: apple pay,
  google pay, card network) over brink tender names, then falls back to
  'discount' (fully discounted orders) and 'no_payment'.
- Brink tender names are normalized: 'american express' -> 'amex'; any
  TenderType = 'Cash' tender ('exact $ amount', 'next $ amount') -> 'cash';
  'house account' -> 'house_account' (matches the pulse spelling).
- total_payment_amount is the amount tendered from Brink (tips included) and
  duplicates order_customer.total_payment_amount; brink covers ~97% of paid
  orders, so pulse-only orders (~130/month) show a tender with a NULL amount.
- Multi-tender orders: names are comma-joined, largest amount first.

Deploy: run this script once in the BigQuery console. It is a plain view — no
scheduled query, no refresh. Sources are unpartitioned raw tables, so each
query scans them fully (~4 GB unfiltered); acceptable for occasional use. If
payment questions become frequent, promote to a scheduled mart table.
*/

create or replace view `marketing-data-442316`.claude.order_payment_tender as

with pulse_payments as (
select
  op.order_id as pulse_order_id
, coalesce(sop.digital_payment_medium_name, sop.network, t.name) as pulse_tender
, sum(op.amount) as pulse_payment_amount
from `marketing-data-442316`.pulse.order_payments op
	left join `marketing-data-442316`.pulse.stripe_order_payments sop
	on sop.order_payment_id = op.id
	and ifnull(sop.status, 'unknown') = 'succeeded'
	and sop.deleted_at is null
		left join `marketing-data-442316`.pulse.tenders t
		on t.id = op.tender_id
where 1=1
and op.order_id is not null
and ifnull(op.is_processed, false) = true
and ifnull(op.is_cancelled, false) = false
and ifnull(op.is_failed, false) = false
and ifnull(op.is_refund, false) = false
and ifnull(op.is_removed, false) = false
and op.deleted_at is null
group by 1, 2
)

, pulse_tenders as (
select
  p.pulse_order_id
, string_agg(ifnull(p.pulse_tender, 'unknown'), ', ' order by p.pulse_payment_amount desc) as pulse_tender_names
, sum(p.pulse_payment_amount) as pulse_payment_amount
from pulse_payments p
group by 1
)

, oc_base as (
select
  oc.brink_order_id
, oc.pulse_order_id
, oc.business_date
, oc.store_id
, oc.net_sales
, oc.total_discount_amount
--, oc.total_promotions_amount
from `marketing-data-442316`.sales_ops.order_customer oc
where 1=1
and oc.business_date >= date_trunc(date_sub(current_date, interval 3 year), year)
and oc.store_id not in (1111, 999)
)

/* store_id on order_customer matches brinkOrder.FKStoreId (verified 2026-08-05,
   287,065/287,065 over 14 days), so no brinkOrder join is needed — the tender
   lookup uses oc.store_id. */
, brink_payments as (
select
  b.brink_order_id
, case
    when lower(t.Name) = 'american express' then 'amex'
    when t.TenderType = 'Cash' then 'cash'
    when lower(t.Name) = 'house account' then 'house_account'
    else t.Name
  end as brink_tender
, sum(p.Amount) as payment_amount
, sum(p.TipAmount) as tip_amount
, sum(p.Change) as change_amount
from oc_base b
	join `marketing-data-442316`.brink.brinkOrderPayment p
	on p.orderId = b.brink_order_id
	and ifnull(p.isDeleted, false) = false
	and p.BusinessDate >= date_trunc(date_sub(current_date, interval 3 year), year)
		left join `marketing-data-442316`.brink.brinkTenders t
		on t.Id = p.TenderId
		and t.StoreID = b.store_id
group by 1, 2
)

, brink_tenders as (
select
  bp.brink_order_id
, string_agg(ifnull(bp.brink_tender, 'unknown'), ', ' order by bp.payment_amount desc) as brink_tender_names
, sum(bp.payment_amount) as total_payment_amount
, sum(bp.tip_amount) as total_tip_amount
, sum(bp.change_amount) as total_change
from brink_payments bp
group by 1
)

select
  b.brink_order_id
, b.pulse_order_id
, b.business_date
, lower(coalesce(
    pt.pulse_tender_names
  , bt.brink_tender_names
  , case when ifnull(b.total_discount_amount, 0) <> 0 and ifnull(b.net_sales, 0) < 0 then 'discount' end
  , 'no_payment'
  )) as payment_tender
, bt.total_payment_amount
from oc_base b
	left join pulse_tenders pt
	on pt.pulse_order_id = b.pulse_order_id
		left join brink_tenders bt
		on bt.brink_order_id = b.brink_order_id
