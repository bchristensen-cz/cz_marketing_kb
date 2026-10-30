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

### `cdi_ldip_items` / `cdi_ldip_items_v`

_Active since 2026-10-29. One row per (person, item): 5,320,531 rows, 944,929 people, 59 attributes on the first load._ `ldip_<item>` = the last datetime (UTC) the person bought that entree, plus `ldip_kids_combo`. Build: [`sql/braze.cdi_ldip_items.sql`](../../sql/braze.cdi_ldip_items.sql), scheduled query `braze cdi_ldip_items (ldip_ last item purchase)` (config `6aeff49a-0000-2b24-8d57-7474463c9685`, every day 13:00 UTC = 07:00 MDT / 06:00 MST). **Braze CDI reads the view `cdi_ldip_items_v`**; the table carries the state.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | When the build saw the value change (run time), **not** the purchase time. That is what lets late orders, people new to Braze and items newly over the buyer floor sync without landing behind the CDI watermark. |
| `external_id` | STRING | `mapped_cust_id`; only ids already in `braze.users`, so CDI never creates profiles. |
| `PAYLOAD` | JSON | One key per row, e.g. `{"ldip_lobster_bisque":"2026-10-22T00:47:07.932Z"}`. |

Rules: `item_type = 'Entree'` in Bowls / Salads / Sandwiches / Soups, Try 2 combo slots included (digital `modifier` lines), kids entrees excluded, `Kids Combo` header once per order; `customer_type in ('person', 'internal')` (internal = `@cafezupas.com` / `tkxel` staff, added 2026-10-30 for Braze testing; `kiosk` `%outdoor%@cafezupas.com` accounts stay out), not catering, `% Box` items excluded, stores 1111/999 out; 730-day window; an attribute ships only with >= 500 buyers in the window (drops retired / test stragglers with no list). The attribute name is `ldip_` + the lowercased, underscored `item_name`, after a small cosmetic `name_map` that fixes POS abbreviations and size-split names (`BBQ Ck Salad` -> `bbq_chicken_salad`, `Strwbry` -> `strawberry`). New items need no edit; renaming one later leaves the old attribute in Braze at its last value. Pulse menu names were tested as the name source and rejected (Kids Combo -> `SPECIAL ITEM`, suffixes dropped).

**`ldip_cc_<item>`** (added 2026-10-30, same table, job and view): the same last-purchase datetime for a fixed product list (`Athlete Bowl`, `Fall Bacon Grilled Cheese`, `Chocolate Duo Apple Cup`, `Golden Spice Apple Cup`), but unidentified orders are also credited by **card match**. A card hash (`last4` + network from `pulse.stripe_order_payments`, `CardInt` + tender name from `brink.brinkOrderPayment` tenders 8/9/14/15) maps to a person when >= 80% of that card's identified `person` orders at that store belong to them (730-day window, `cafezupas.com` accounts excluded from the map). Identified orders keep their own id (`person` or `internal`). Item and modifier (Try 2 slot) lines count; box-lunch and party-tray components do not. No buyer floor; add a product by adding its clean name to the list in `cc_lines`. `Fall Bacon Sandwhich` (643649920, catering component) is mapped onto `Fall Bacon Grilled Cheese` in `name_map`. First load 137,525 rows: athlete bowl 33,754 people (vs 26,734 identified-only), fall bacon 75,099 (vs 58,267), chocolate duo 17,017, golden spice 11,655. Card-match logic is Brent's athlete-bowl query; expected to move upstream into the item table.

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
