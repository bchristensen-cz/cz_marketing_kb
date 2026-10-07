# Braze dictionary — Custom Attribute Feeds (bz_cid_*)

> Part of `data_dictionaries/braze_data_dictionary.md` (read that index first: the four rules, common columns and table index apply to every table here). Split out verbatim on 2026-10-07; column content unchanged, generated 2026-09-04.

## Custom Attribute Feeds (bz_cid_*)

### `bz_cid_age_update`

_Active - 76 rows, 0.00 GB, 3 columns, table._ Custom attribute feed of customer age.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `age` | Customer age in years. |

### `bz_cid_gender_update`

_Active - 126 rows, 0.00 GB, 3 columns, table._ Custom attribute feed of customer gender.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `gender` | Customer gender. |

### `bz_cid_is_employee_update`

_Active - 11 rows, 0.00 GB, 3 columns, table._ Custom attribute feed flagging whether the customer is an employee.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `is_employee` | 1 if the customer is an employee, else 0. |

### `bz_cid_has_fav_store_update`

_Active - 289 rows, 0.00 GB, 3 columns, table._ Custom attribute feed flagging whether the customer has set a favorite store.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `has_favorite_store` | 1 if the customer has a favorite store set, else 0. |

### `bz_cid_weather_flag`

_Active - 177,002 rows, 0.00 GB, 3 columns, table._ Custom attribute feed of a weather classification flag for the customer (e.g., hot/cold).

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `weather_flag` | Weather classification for the customer (e.g., hot, cold). |

### `bz_cid_bgnbd_palive_churn`

_Active - 2,429 rows, 0.00 GB, 3 columns, table._ Custom attribute feed of the customer's churn risk band from a BG/NBD P(alive) model.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `risk_band` | Churn risk band from the BG/NBD P(alive) model (e.g., at_risk). |

### `bz_cid_favorite_category_ordered`

_Active - 2,366 rows, 0.00 GB, 3 columns, table._ Custom attribute feed of the customer's favorite (most-ordered) menu category.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `favorite_category_ordered` | Customer's most-ordered menu category (e.g., Bowls, Salads). |

### `bz_cid_first_purch_cat_item`

_Active - 3,580 rows, 0.00 GB, 3 columns, table._ Custom attribute feed of the item ID of the customer's first purchased category item.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `first_purch_cat_item` | Item ID of the first category item the customer purchased. |

### `bz_cid_purchased_core_category`

_Active - 9,036 rows, 0.00 GB, 3 columns, table._ Custom attribute feed recording the most recent date the customer purchased each core category.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `purchased_<category>` | One key per core category (e.g., purchased_salads) holding the most recent date that category was purchased. |

### `bz_cid_l90_total_eligible_orders_update`

_Active - 17,935 rows, 0.00 GB, 3 columns, table._ Custom attribute feed of the customer's total loyalty-eligible orders in the last 90 days.

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `l90_total_eligible_orders` | Count of loyalty-eligible orders in the last 90 days (null if none). |

### `bz_cid_nested_l90_menu_choices_update`

_Active - 18,071 rows, 0.00 GB, 3 columns, table._ Nested custom attribute feed of last-90-day menu-choice behavior flags (bowl, salad, soup, sandwich, etc.).

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `l90_menu_choices_count` | Nested object of last-90-day menu-choice flags/counts: l90_bowl_cust, l90_cold_sandwich_cust, l90_dessert_cup_cust, l90_is_cup_cust, l90_kid_meal_cust, l90_low_cal_cust, l90_protein_cust, l90_salad_cust, l90_sandwich_cust, l90_soup_cust, l90_sweet_main_cust, l90_texmex_cust, l90_try2_cust, l90_warm_sandwich_cust. |

### `bz_cid_nested_l90_order_behaviors_update`

_Active - 18,005 rows, 0.00 GB, 3 columns, table._ Nested custom attribute feed of last-90-day ordering-channel/behavior flags (app, delivery, drive-thru, online, etc.).

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `l90_order_behaviors_count` | Nested object of last-90-day ordering-behavior flags/counts: l90_android_cust, l90_app_cust, l90_delivery_cust, l90_desktop_cust, l90_drive_thru_cust, l90_good_life_lane_cust, l90_iOS_cust, l90_mobile_web_cust, l90_oneline_takeout_cust, l90_online_cust, l90_scanned_cust, l90_takeout_cust, l90_unique_location_count. |

### `bz_cid_nested_l90_order_time_behaviors_update`

_Active - 18,197 rows, 0.00 GB, 3 columns, table._ Nested custom attribute feed of last-90-day order-timing behavior flags (daypart, day of week, season).

| Column | Type | Description |
|---|---|---|
| `UPDATED_AT` | TIMESTAMP | Timestamp the attribute value was last updated for the user. |
| `external_id` | STRING | Cafe Zupas customer ID (Braze external_id) the attribute belongs to. |
| `PAYLOAD` | JSON | JSON object containing the custom attribute value(s); see payload fields below. |

**`PAYLOAD` JSON fields:**

| Field | Description |
|---|---|
| `l90_order_time_behaviors_count` | Nested object of last-90-day order-timing flags: l90_dinner_cust, l90_lunch_cust (dayparts); l90_monday_cust..l90_saturday_cust, l90_weekday_cust (day of week); l90_fall_cust, l90_spring_cust, l90_summer_cust, l90_winter_cust (season). |
