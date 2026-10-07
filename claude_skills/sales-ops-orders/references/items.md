# `sales_ops.items` — the item-grain table

> Part of the `sales-ops-orders` skill. Read `../SKILL.md` first; this file is loaded on demand. **Read it when:** the question is about an item itself: launch date, price, status, catering-only, digital menu.
> Content moved verbatim from `SKILL.md` on 2026-10-07 (progressive-disclosure restructure); the rules and dates inside are unchanged.

## `sales_ops.items` — the item-grain table (new 2026-09-14)

**Reach for this before writing your own `group by item_id` over `order_lines`.** If a question
is about an *item* rather than about sales — what is it, what size, what does it cost, when did
it launch, is it still selling, is it catering-only, is it on the app — the aggregate already
exists and every session gets the same answer from it. One row per Brink `item_id`, 3,242 rows,
rebuilt daily at 07:30 MT. Built on `sales_ops.item_daily` (item × day, partitioned on
`business_date`), which is also the right table for an item trend line.

| Need | Column |
|---|---|
| Resolve a name to the real SKU | `item_id`, `item_name`, `item_size`, `avg_unit_price_90d` |
| Is it still on the menu | `item_status` (`selling` / `dormant` / `discontinued` / `never_sold`), `stores_selling_28d` |
| When did it launch | `launch_date` (chain rollout) vs `first_sold_date` (first sale anywhere) |
| Price | `current_price`, `price_min`, `price_max` |
| Catering-only SKU | `is_catering_item` (60 ids), `catering_unit_share` |
| Sold as a modifier, not an item | `sold_as` |
| Digital menu | `pulse_item_id`, `is_on_digital_menu`, `pulse_category_name` |

`items.item_name` and `items.item_size` are **identical to the `order_lines` values** for the
same id — verified on 548 of 548 ids sold in the trailing 45 days, zero mismatches — so the
join is safe and no re-derivation is needed.

Three things to know before using it:

1. **`item_name` is still not a product key.** That rule does not change because a dimension
   exists. Resolve to `item_id` first; `items` just makes resolving cheap, and
   `avg_unit_price_90d` next to each candidate is what makes a wrong pick visible.
2. **96 item_ids carry different products at different stores** (`640934279` is
   `Combo Turkey Cranbry Sand` at 37 stores and `Combo Turkey Avocado Club` at 29). The table
   publishes the most-stores name and flags the rest with
   `is_name_ambiguous_across_stores`. A store-specific question cannot be answered from this
   table.
3. **Join it only to sellable lines.** On `discount` / `promotion` / `surcharge` lines
   `order_lines.item_id` is a DiscountId / PromotionId / SurchargeId, not an item id.

`launch_date` is **derived**: the first business date the item sold in at least 25% of the
stores it ever reached. Brink itself carries no item dates — `CreatedTime`, `StartDate`,
`EndDate` and `LastEditedTime` are blank or NULL on all 214,182 master rows. 1,565 of 2,234
sold items have `launch_date` later than `first_sold_date`, so quoting the wrong one turns a
three-store test into a chain launch.

`has_ever_sold` is the filter that matters, not `is_active_anywhere`: 1,008 ids have never
sold and 962 of those are still Active in Brink, most of them POS config artifacts
(`*** For 31 ***` guest-count markers, `** DEST TRAY **`).

Full column list: [`data_dictionaries/sales_ops.items.md`](../../../data_dictionaries/sales_ops.items.md)
and [`data_dictionaries/sales_ops.item_daily.md`](../../../data_dictionaries/sales_ops.item_daily.md).

⚠️ There is **no `claude` view over either table yet** — standard users cannot reach them.
Name it as a mart gap if a user needs it.
