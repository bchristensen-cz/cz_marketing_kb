# Data Dictionary: `marketing-data-442316.sales_ops.order_customer`

**One row per order.** Order-level financials, channel attribution, and customer identity. This is the canonical table for sales, order counts, channel mix, and customer/loyalty questions.

## Table facts

| Property | Value |
|---|---|
| Grain | 1 row per `brink_order_id` (verified unique) |
| Row count | ~50M orders, 2018-08-07 to present |
| Partitioned by | `BusinessDate` (DAY) — **always filter on it** |
| Clustered by | `brink_order_id`, `mapped_cust_id`, `store_id`, `store_name` |
| Refresh | Hourly at minute :02. Intraday runs (8am–11pm MT) reload **today only**. 4am daily reloads 8 days; Monday 4am reloads 5 weeks; 1st of month 4am reloads ~13 months (delete + insert by `BusinessDate >= start_date`). |
| Source build script | `sql/sales_ops.order_customer.sql` in this repo |
| Upstream | `brink.*` (POS), `pulse.*` (digital ordering), `sessionM.*` (loyalty), `sales_ops.store_info` |

## Columns

### Identifiers
| Column | Type | Description |
|---|---|---|
| `brink_order_id` | INTEGER | POS order id. Primary key. Join key to `order_lines`. |
| `pulse_order_id` | INTEGER | Digital order id. NULL for in-store-only orders (~60% of orders). |
| `pulse_customer_id` | INTEGER | Customer id from the digital ordering platform (Pulse). |
| `sm_external_user_id` | INTEGER | Loyalty (SessionM) user mapped to a cafezupas external id. Captures in-store loyalty scans. |
| `mapped_cust_id` | INTEGER | **Canonical customer key** = `coalesce(pulse_customer_id, sm_external_user_id)`. ~53% of orders in the last year have one. Use this for customer counts, frequency, retention. |
| `mapped_email` | STRING | Best-available email = loyalty email → booking email → order email. |
| `email`, `phone` | STRING | Raw contact info captured on the order (pulse order_customers). |

### Dates & times
| Column | Type | Description |
|---|---|---|
| `BusinessDate` | DATE | Operating day (partition column). Canonical date for all reporting. |
| `order_datetime` | DATETIME | Local time. Normally `ClosedTime`; if the order closed on a later day than its BusinessDate (catering / advance orders), falls back to `promise_time` then `OpenedTime`. |
| `order_timestamp_utc` | TIMESTAMP | `order_datetime` converted to UTC using the store's timezone. |
| `opened_time` | DATETIME | Raw POS opened time. |
| `loyalty_signup_date` | DATE | Customer's loyalty enrollment date (NULL for guests). |

### Store & channel
| Column | Type | Description |
|---|---|---|
| `store_id` | INTEGER | FK to `sales_ops.store_info`. **Store 1111 is a test/training store — ALWAYS exclude it** (`store_id <> 1111`) in all sales/order metrics. No exceptions (steward rule 2026-07-23). |
| `store_name` | STRING | Store name (denormalized). |
| `state` | STRING | Store state. Current footprint: Utah (30 stores), Arizona (14), Minnesota (12), Nevada (9), Wisconsin (8), Idaho (7), Illinois (6), Ohio (3), Texas (1). |
| `destination` | STRING | Raw Brink destination. Common values: To Stay, Takeout, DoorDash, Online Takeout, Drive Thru, Good Life Lane, UberEats, CZ Delivery, GrubHub, Catering Online Delivery/Takeout, Postmates, Fundraiser, EZ Cater Delivery/Takeout. |
| `source` | STRING | Raw pulse order source. NULL for in-store orders. |
| `revenue_category` | STRING | **Canonical channel rollup**: `In-Store`, `Digital`, `Third_Party`, `Catering`, `Fundraiser`, `Other`. Derived from `destination`. |
| `order_source` | STRING | Cleaned digital source: `Checkmate` (3rd-party integration), `iOS`, `Android`, `Mobile Web`, `Web`, `Outdoor Kiosk`, `Operator`, `ezcater`. NULL = in-store POS order. |
| `in_store_scan` | INTEGER (0/1) | 1 = loyalty member scanned in-store with no digital order attached. |

### Flags
| Column | Type | Description |
|---|---|---|
| `is_catering` | BOOLEAN | TRUE when the pulse order is flagged catering. FALSE/NULL-safe (NULL treated as FALSE at build). |
| `is_guest_order` | INTEGER (0/1) | 1 = no loyalty user linked (via pulse.customers.loyalty_user_id). |
| `is_employee_discount` | INTEGER (0/1) | 1 when the order used an employee/team discount — matched via Brink discount names (`%Team%`, `%Employee%`) or SessionM offers (`%Meal%`, `%Emp%`, `%Team%`). ~1.5% of orders. |

### Financials (all FLOAT, dollars)
| Column | Description |
|---|---|
| `gross_sales` | Order gross sales from Brink (`brinkOrder.GrossSales`). |
| `net_sales` | **Canonical net sales** (`brinkOrder.NetSales`). Use this for sales reporting. |
| `subtotal` | Brink subtotal. |
| `tax` | Sales tax. |
| `rounding` | Cash rounding adjustment. |
| `item_gross_sales` / `item_net_sales` | Sum of item-level gross/net, **excluding tip items**. |
| `item_netsales_with_mods` | Item net including modifier contribution (`brinkOrderItem.NetSales`). |
| `mods_gross_sales` / `mods_net_sales` | Modifier-level gross/net sums. |
| `total_gift_card_amount` | Gift card purchases on the order (not redemptions). |
| `total_discount_amount` | Sum of applied discounts (positive number). |
| `total_promotions_amount` | Sum of applied promotions. |
| `total_tip_amount` | Tips from payments (`brinkOrderPayment.TipAmount`). |
| `total_delivery_tip_amount` | Tips rung as the delivery-tip item (item id 640943560). |
| `total_other_tip_amount` | Tips rung as any other tip item. |
| `total_fees_amount` | Fee items (item name matches `\bfee\b` — delivery/service fees). |
| `total_payment_amount` | Sum of payments. |
| `total_change` | Change given. |

### Customer behavior (window functions over `mapped_cust_id`)
| Column | Description |
|---|---|
| `order_count` | Lifetime sequential order number for the customer (1 = first order). NULL for unidentified orders. Recomputed each load within the reload window — treat as approximate near window boundaries. |
| `days_since_prev_order` | Days since the customer's previous order. NULL on first order or unidentified. |

## Gotchas
- **Always filter `BusinessDate`** — table is partitioned on it; unfiltered queries scan 50M rows.
- `order_count` and `days_since_prev_order` are computed **within each reload window**, not across all history. For a given customer's true lifetime sequence, compute it fresh with a window function over their full history.
- Orders with zero item sales are excluded (build keeps orders with item gross or net > 0).
- Tips: `total_tip_amount` (payment tips) and delivery/other tip items are **separate mechanisms** — don't add them blindly.
- `is_guest_order` is loyalty-based; a guest can still have `mapped_cust_id` NULL and an email present.
- `revenue_category = 'Other'` is a catch-all (~5 orders/yr) — safe to ignore.
- Deduped on `brink_order_id` at build (latest insertion job wins).
