# Data Dictionary: `marketing-data-442316.claude.order_payment_tender`

**One row per `brink_order_id`** — same grain and population as `claude.order_customer`
(rolling 3-year window, `store_id <> 1111`). View over the raw payment tables
(`pulse.order_payments`, `pulse.stripe_order_payments`, `pulse.tenders`,
`brink.brinkOrderPayment`, `brink.brinkTenders`). Build script:
[`sql/claude.order_payment_tender.sql`](../sql/claude.order_payment_tender.sql).
Deployed 2026-08-05.

**This view is the sanctioned wrapper around the raw payment tables. Never query those
directly** — they contain cancelled, failed, refunded, and soft-deleted payment rows that
this view already filters out (~230K rows / $43M of non-settled noise in
`pulse.order_payments` alone).

## Why it exists

Payment tender was requested for a recent (and possibly short-lived) effort. It is
deliberately a **standalone view, not columns on `order_customer`**: payment questions are
rare, a view deploys with one statement (no scheduled-query redeploy risk), and it can be
retired without touching the canonical mart. If payment questions become frequent, the
upgrade path is a small scheduled mart table partitioned on `business_date`.

## Columns

| Column | Type | Notes |
|---|---|---|
| `brink_order_id` | INTEGER | Join key to `claude.order_customer` |
| `pulse_order_id` | INTEGER | NULL for POS-only orders |
| `business_date` | DATE | Same value as on `order_customer`. Always filter it |
| `payment_network` | STRING | **The answer column.** Lowercase. Multi-tender orders are comma-joined, largest amount first (`'cash, visa'`). See values below |
| `pulse_tender_names` | STRING | Debugging — the pulse-side names before the coalesce |
| `pulse_payment_amount` | FLOAT | Debugging — pulse-side settled amount |
| `brink_tender_names` | STRING | Debugging — the brink-side names before the coalesce |
| `total_payment_amount` | FLOAT | Amount tendered, from Brink. **Duplicates `order_customer.total_payment_amount`** (verified 128,806 of 128,829 orders match over 7 days) |
| `total_tip_amount` | FLOAT | From Brink payment rows |
| `total_change` | FLOAT | From Brink payment rows |

The view's real payload is the **names**; the amount columns exist for convenience and
validation and should tie to the same columns on `order_customer`.

## How `payment_network` is built

1. **Pulse names win** (they carry digital-wallet detail): `coalesce(digital_payment_medium_name, network, tenders.name)` per payment, from settled pulse payments only.
2. Else **Brink tender names**, normalized: `american express` → `amex`; any `TenderType = 'Cash'` quick-button (`exact $ amount`, `next $ amount`) → `cash`; `house account` → `house_account` (pulse spelling).
3. Else `'discount'` when `total_discount_amount + total_promotions_amount > 0` and `net_sales < 1` (fully-discounted orders).
4. Else `'no_payment'`.

Typical week (2026-07-29 → 2026-08-04): visa ~47%, doordash ~11%, mastercard ~10%,
apple pay ~7.5%, cash ~5.4%, amex ~5.3%, ubereats ~3.2%, discount ~1.9%, discover ~1.8%,
google pay, grubhub, postmates, gift card, givex, house_account, no_payment, unknown, and
a long tail of comma-joined split tenders (~0.3% of orders).

**Settled-payments-in semantics:** pulse rows must be processed and not
cancelled/failed/refunded/removed/deleted; stripe detail only from `status = 'succeeded'`;
brink rows exclude `isDeleted`. **Refund transactions are excluded**, so this reflects
money in at purchase time and ignores later refunds.

## Join pattern

```sql
select
  opt.payment_network
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

Every `order_customer` row has exactly one row here and `payment_network` is never NULL,
so inner vs left join gives the same result — left is the house convention.

## Gotchas

- **🛑 Access: the view reads `pulse` and `brink`, which need the authorized-dataset
  entry.** `sales_ops` carries `{dataset: claude, targetTypes: [VIEWS]}` in its access
  list; as of 2026-08-05 **`pulse` and `brink` do not**, so a standard user querying this
  view gets `Access Denied` until the `claude` dataset is authorized on both (BigQuery
  console → dataset → Sharing → Authorize datasets). Remove this bullet once granted.
- **The latest loaded business_date shows `'stripe'` as a placeholder network.** Online
  card orders land in `pulse.order_payments` (tender name `Stripe`) before
  `pulse.stripe_order_payments` records the succeeded charge with its network detail, so
  the freshest day reads `stripe` instead of `visa` / `apple pay` / etc. Verified
  2026-08-05: 2,661 of 26,044 orders (10.2%) on the latest loaded date, **zero on all six
  earlier dates** — it self-heals once the stripe table catches up. For tender-mix
  reporting, exclude the latest loaded `business_date` or annotate it.
- **`payment_network` is not a clean enum.** Split tenders produce comma-joined values
  ordered by amount, so `'cash, visa'` and `'visa, cash'` are different strings. For a
  clean breakdown, either bucket any value containing a comma as `'split'` or accept the
  long tail (~0.3% of orders).
- **A tender breakdown is not a channel breakdown.** `doordash` / `ubereats` / `grubhub` /
  `postmates` here are how third-party orders *pay*. If the question is about sales
  channels, the axis is `revenue_category` on `order_customer`.
- **`total_payment_amount` is gross tendered, not sales.** It includes tips and is made
  change against; gift-card loads and tax ride along. `order_customer.net_sales` remains
  the only sales figure to quote.
- **~130 orders/month are pulse-only**: tender names present, Brink amount columns NULL.
- **23 of 128,829 orders (0.018%) mismatch `oc.total_payment_amount`** (net −$190 over 7
  days). Unexplained; immaterial. Open item on the Claude Data board.
- **`unknown`** = settled payments whose tender name is unresolvable (~500/week, amounts
  near $0).
- **Every query scans ~2.7 GB** regardless of date range — the raw payment tables are
  unpartitioned, so `business_date` filters prune only the `order_customer` side. About
  1.5¢ per query at on-demand pricing; fine at occasional volume.
