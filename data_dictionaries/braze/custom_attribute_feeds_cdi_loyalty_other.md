# Braze dictionary — Custom Attribute Feeds (cdi_* / loyalty / other)

> Part of `data_dictionaries/braze_data_dictionary.md` (read that index first: the four rules, common columns and table index apply to every table here). Split out verbatim on 2026-10-07; column content unchanged, generated 2026-09-04.

## Custom Attribute Feeds (cdi_* / loyalty / other)

### `cdi_order_attributes`

_Active - 34,443 rows, 0.00 GB, 3 columns, table._ Custom attribute feed of customer order-history metrics (first/latest order, L90/L180/L365 counts, avg ticket, net sales).

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `first_order_datetime` | Timestamp of the customer's first order. |
| `latest_order_datetime` | Timestamp of the customer's most recent order. |
| `l90_order_count` | Order count in the last 90 days. |
| `l180_order_count` | Order count in the last 180 days. |
| `l365_order_count` | Order count in the last 365 days. |
| `l90_avg_days_btwn_orders` | Average days between orders over the last 90 days. |
| `l90_avg_ticket` | Average ticket (order value) over the last 90 days. |
| `l90_netsales` | Net sales over the last 90 days. |

### `cdi_cup_sales_data`

_Active - 671 rows, 0.00 GB, 3 columns, table._ Nested custom attribute feed of per-cup-product order counts and latest order dates (seasonal dessert cups).

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `cup_sales_data` | Nested object with, per cup product, an order_count and a latest_order_date (e.g., mini_chocolate_strawberry_cup_order_count, mini_chocolate_strawberry_cup_latest_order_date, dubai_cup_*, chocolate_strawberry_cup_*, strawberries_cream_cup_*, golden_spice_apple_cup_*, chocolate_duo_apple_cup_*). |

### `cdi_l365_items_chipote_cups_bowls`

_Active - 342,791 rows, 0.01 GB, 3 columns, table._ Custom attribute feed of last-365-day counts for chipotle-glazed salad, cup items, and bowl items.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `l365_bowl_items_ordered` | Count of bowl items ordered in the last 365 days. |
| `l365_chipotle_glazed_salad_ordered` | Count of chipotle-glazed salads ordered in the last 365 days. |
| `l365_cup_items_ordered` | Count of cup items ordered in the last 365 days. |

### `cat_points_update`

_Active - 44,689 rows, 0.00 GB, 3 columns, table._ Nested custom attribute feed of SessionM/Cafe Zupas loyalty data (points, tier, CZ dollars).

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `sm_loyalty_data` | Nested loyalty object: current_points, cz_dollars, points_to_next_level, tier (e.g., Silver), visa_card_value. |

### `indiv_points_update`

_Active - 1,112 rows, 0.00 GB, 3 columns, table._ Custom attribute feed of the customer's loyalty points balance and points expiring at end of month.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `points_balance` | Current loyalty points balance. |
| `points_to_expire_EOM` | Points expiring at end of month. |

### `indiv_sessionm_user_id`

_Active - 525 rows, 0.00 GB, 3 columns, table._ Custom attribute feed mapping the customer to their SessionM user ID.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `sessionM_userid` | The customer's SessionM user ID. |

### `first_purch_cat_update`

_Active - 1,310 rows, 0.00 GB, 3 columns, table._ Custom attribute feed of the customer's first-purchase category (pilot - ~500 users).

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `first_purch_cat` | Category of the customer's first purchase (e.g., Bowls-Soups). |

### `is_vto_cust`

_Active - 3,459 rows, 0.00 GB, 3 columns, table._ Custom attribute feed of the count of unique VTO (value/test offer) items the customer has purchased.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `unique_vto_items_purchased` | Count of unique VTO items the customer has purchased. |

### `l365_has_salad_order`

_Active - 15,631 rows, 0.00 GB, 3 columns, table._ Custom attribute feed flagging whether the customer ordered a salad in the last 365 days.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `l365_has_salad_order` | 1 if the customer ordered a salad in the last 365 days, else 0. |
