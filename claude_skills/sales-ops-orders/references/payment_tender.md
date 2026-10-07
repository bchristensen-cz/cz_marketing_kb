# Payment method / tender

> Part of the `sales-ops-orders` skill. Read `../SKILL.md` first; this file is loaded on demand. **Read it when:** the question is about how people pay (cash, card, wallets, split tenders).
> Content moved verbatim from `SKILL.md` on 2026-10-07 (progressive-disclosure restructure); the rules and dates inside are unchanged.

## Payment method / tender — `claude.order_payment_tender` (new 2026-08-05)

Payment questions ("how do people pay?", "cash vs card", "apple pay share") finally have a
home: **`claude.order_payment_tender`**, one row per `brink_order_id` on the same
population as `claude.order_customer`. The answer column is **`payment_tender`**
(lowercase; pulse digital-wallet names preferred over Brink tender names; `'discount'` and
`'no_payment'` fallbacks; split tenders comma-joined largest-first). It is a view over the
raw payment tables — **which remain off-limits directly**.

```sql
select
opt.payment_tender
, count(*) as order_qty
, round(sum(oc.net_sales), 2) as net_sales
from `marketing-data-442316`.claude.order_customer oc
	left join `marketing-data-442316`.claude.order_payment_tender opt
	on opt.brink_order_id = oc.brink_order_id
where 1=1
and oc.business_date between @start and @end
and opt.business_date between @start and @end
and oc.store_id <> 1111
group by 1
order by 2 desc
```

Before using it, scan the gotchas in
[`data_dictionaries/claude.order_payment_tender.md`](../../../data_dictionaries/claude.order_payment_tender.md)
— the four that produce wrong answers fastest:

1. **The latest loaded `business_date` shows `'stripe'` as a placeholder** for online card
   orders until `pulse.stripe_order_payments` catches up (10.2% of the freshest day,
   verified 2026-08-05; zero on all earlier days). Exclude or annotate the latest day in
   any tender-mix report.
2. **A tender breakdown is not a channel breakdown** — `doordash` here is how an order
   *paid*, not the `Third_Party` channel; that axis is `revenue_category`.
3. **`total_payment_amount` is gross tendered (includes tips), not sales** — quote
   `net_sales` from `order_customer` for sales, always.
4. **Split tenders make `payment_tender` a non-enum** — `'cash, visa'` ≠ `'visa, cash'`;
   bucket comma values as `'split'` for clean breakdowns (~0.3% of orders).
