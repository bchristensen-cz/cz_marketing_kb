# Net sales: definition history and the sanctioned validation

> Part of the `sales-ops-orders` skill. Read `../SKILL.md` first; this file is loaded on demand. **Read it when:** you decompose, validate or reconcile net sales, or someone asks why net sales changed in August 2026.
> Content moved verbatim from `SKILL.md` on 2026-10-14 (router split); the rules and dates inside are unchanged.

> **🚩 CORRECTION 2026-08-20 — the net-sales decomposition, in three parts. Read all three; the middle one is my own error.**
>
> **(a) The formula this skill published was unusable.** It read
> `net_sales = gross_sales - total_discount_amount - total_promotions_amount`. **`total_promotions_amount` does not exist** on the table — the discount columns are `discount_amount`, `promotions_amount`, `total_discount_amount` — so anyone copying it got `Unrecognized name`. And promotions are already inside `total_discount_amount`, so the formula double-counted them as well.
>
> **(b) 🔻 RETRACTED — my "9.2% don't reconcile" finding was mostly my own sign error.** **The discount columns are stored NEGATIVE.** `discount_amount` and `promotions_amount` come from `sum(amount) * -1` in the build, so net is `gross_sales` **+** `total_discount_amount`, not minus. Subtracting a negative added the discount back, and the 130,171 "matches" I reported were simply the orders with no discount at all. The lesson, and it is the same one this KB keeps relearning: **check the sign of a column before reporting a reconciliation gap** — a plausible-looking mismatch percentage was an artifact of my arithmetic, not of the data.
>
> **(c) ✅ FIXED 2026-08-21 — `net_sales` now deducts promotions.** The build had computed
> `bo.GrossSales + coalesce(d.total_discount_amount,0)` — the *discount* CTE only — while its own
> comment defined net sales as *"gross sales - discounts - promotions"*. `promotions_amount` was
> computed, exposed, rolled into `total_discount_amount`, and never subtracted, so net sales was
> overstated by exactly the promotions total on every promotion order (1,287 orders / $15,805.69 in
> the week measured). The steward added the term and full-refreshed all history:
>
> ```sql
> , bo.GrossSales + coalesce(d.total_discount_amount,0) + coalesce(bp.total_promotions_amount,0) as net_sales
> ```
>
> **The basis for calling it fixed is definitional, not a tie-out**: the steward's stated definition
> of net sales is gross less discounts less promotions, and the expression now matches it. That is
> the whole claim, and it is enough.
>
> **🔻 RETRACTED 2026-08-21 — do NOT validate `net_sales` against `brink_net_sales`.** An earlier
> version of this section published a year-by-year "tie-out" against that column and concluded net
> sales was "reconciled to Brink from 2022 forward" with ~$1.15M unexplained before that.
> **Steward ruling: `brink_net_sales` exists for his own purposes and is not an accuracy
> reference.** Every conclusion that rested on it is withdrawn — the per-year mismatch table, the
> 2022 reconciliation boundary, and the pre-2022 "$1.15M discrepancy," which was never a finding
> about our data at all. Do not reintroduce it, and do not quote net sales as "reconciled" on that
> basis.
>
### ✅ The sanctioned validation for net sales: `order_lines` rolled up against `order_customer` (steward 2026-08-21)

**This is the check to run, and it is the only one in the KB with the steward's blessing.** It reconciles the
line grain against the order header through different filters and joins, and it "exposes much more
detail" than a header-level comparison — when it disagrees you can see *which lines*. (The steward
also holds an external validation outside BigQuery; that is the genuinely independent source, and it
is not available to a session.)

```sql
with oc as (
  select
    oc.brink_order_id
  , oc.item_gross_sales + oc.mods_gross_sales as oc_detail_gross
  , oc.discount_amount
  , oc.promotions_amount
  from `marketing-data-442316`.sales_ops.order_customer oc
  where 1=1
  and oc.business_date between @start_date and @end_date
  and oc.store_id not in (1111, 999)
)
, ol as (
  select
    ol.brink_order_id
  , sum(if(ol.line_item_type in ('item','modifier','fee'), ol.item_gross_sales, 0)) as line_gross
  , sum(if(ol.line_item_type = 'discount' , ol.amount, 0)) as line_discounts
  , sum(if(ol.line_item_type = 'promotion', ol.amount, 0)) as line_promotions
  from `marketing-data-442316`.sales_ops.order_lines ol
  where 1=1
  and ol.business_date between @start_date and @end_date
  and ol.store_id not in (1111, 999)
  group by 1
)
select
  count(*) as orders_in_both
, countif(abs(oc.oc_detail_gross   - ol.line_gross)      < 0.005) as gross_match
, countif(abs(oc.discount_amount   - ol.line_discounts)  < 0.005) as discounts_match
, countif(abs(oc.promotions_amount - ol.line_promotions) < 0.005) as promotions_match
from oc
    join ol
    on ol.brink_order_id = oc.brink_order_id
```

**Result 2026-08-01 → 08-16, 350,761 orders present in both: gross 350,761/350,761 ($0.00), discounts
350,761/350,761 ($0.00), promotions 350,760/350,761 ($3.19 on one order).** That is the cross-path
confirmation of the promotions fix.

Three things that will trip you up running it:

1. **`line_item_type = 'fee'` MUST be in the gross sum.** `order_customer.item_gross_sales` excludes
   only *tip* items, so it includes fees, while `order_lines` breaks fees out as their own line type.
   Omitting `'fee'` manufactures a discrepancy — it produced a **$132,949.74 / 8,147-order** phantom
   gap on the first attempt here, which is exactly `sum(total_fees_amount)` for the window.
2. **~1.4% of `order_customer` orders are absent from `order_lines` by design** — 4,939 of 355,700 in
   that window, dropped by the `valid_order_lines` gate (no line with positive gross or net). Use an
   inner join and report the excluded count; a left join leaves NULLs that quietly skip `sum()` and
   fail `countif()`, making the reconciliation look worse than it is.
3. **The discount and promotion legs share a source** — both marts read `brink.brinkOrderDiscount`
   and `brinkOrderPromotion` — so those legs test the *path*, not the figure. The **gross** leg is
   the strong one: Brink's header `GrossSales` against independently summed line detail. For
   reference, header vs `order_customer`'s own detail columns summed to **−$6.48** across the same
   window.
>
> **🧰 Method note — this write-up was wrong twice, in opposite directions, and both are instructive.**
>
> **First error, circular evidence.** I "proved" the promotions gap with tests comparing `net_sales`
> to `gross_sales + discount_amount` and to `gross_sales + total_discount_amount`. Both are
> **algebraically implied by the build script** — `net_sales` *is* `gross + discount_amount`, so the
> 143,407/143,407 result was a tautology, and the second necessarily fails exactly where
> `promotions_amount <> 0`. It confirmed the table matches its own SQL and nothing more, while being
> presented as evidence about correctness. **If a reconciliation test's inputs all come from the same
> build expression, it cannot fail for an interesting reason.**
>
> **Second error, and it is the subtler one: I picked a reference column without confirming it WAS a
> reference.** Corrected, I reached for `brink_net_sales` — which this skill and the build script
> both label "for validation only" — and treated that phrase as authority. The steward's meaning was
> narrower: it is *his* cross-check, not a source of truth, and explicitly **not** to be used for
> accuracy. On that false footing I published a per-year tie-out, a "reconciled from 2022 forward"
> rule, and a ~$1.15M pre-2022 discrepancy — a confident, precise, plausible finding about nothing.
>
> The generalisable lesson is sharper than "use an independent source": **an independent source has
> to be independent *and* sanctioned as authoritative, and only the steward can confer that.** A
> column sitting in the same table, populated by the same upstream vendor, described by an ambiguous
> comment, is not automatically ground truth. Ask whose definition a column encodes before you
> measure anything against it — and note the failure mode, which is that the wrong reference
> produces answers that look *more* rigorous, not less.
>
> **Practical rule: `net_sales` is a column, not a formula — select it.** If you must decompose, use `gross_sales + discount_amount` (plus, because the column is negative) and state that promotions are not netted out.
