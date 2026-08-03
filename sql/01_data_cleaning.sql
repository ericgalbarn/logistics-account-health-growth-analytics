-- =============================================================================
-- 01_data_cleaning.sql
-- Logistics Account Health & Growth Analytics — Data Cleaning
-- Section A: Keys / IDs / Dates
-- =============================================================================


-- -----------------------------------------------------------------------------
-- A.1 — DIAGNOSTIC QUERIES (run against raw table before cleaning)
-- -----------------------------------------------------------------------------

-- A.1.1 Row count vs distinct Order Item Id (should match if unique per row)
SELECT
  COUNT(*) AS total_rows,
  COUNT(DISTINCT order_item_id) AS distinct_order_item_ids
FROM `logistic-analytics-project.logistic_analytics_dataset.logistic_analytics_table`;

-- A.1.2 Find the actual duplicate Order Item Ids
SELECT order_item_id, COUNT(*) AS cnt
FROM `logistic-analytics-project.logistic_analytics_dataset.logistic_analytics_table`
GROUP BY order_item_id
HAVING cnt > 1
ORDER BY cnt DESC;

-- A.1.3 Check Customer Id vs Order Customer Id consistency
SELECT COUNT(*) AS mismatch_count
FROM `logistic-analytics-project.logistic_analytics_dataset.logistic_analytics_table`
WHERE customer_id != order_customer_id;

-- A.1.4 Check for exact full-row duplicates
SELECT COUNT(*) - COUNT(DISTINCT TO_JSON_STRING(t)) AS duplicate_row_count
FROM `logistic-analytics-project.logistic_analytics_dataset.logistic_analytics_table` t;

-- A.1.5 Check column data types (confirm IDs loaded as INT64, not STRING)
SELECT column_name, data_type
FROM `logistic-analytics-project.logistic_analytics_dataset.INFORMATION_SCHEMA.COLUMNS`
WHERE table_name = 'logistic_analytics_table'
  AND column_name IN (
    'customer_id', 'order_customer_id', 'order_id',
    'order_item_id', 'product_card_id', 'order_item_cardprod_id'
  );


-- -----------------------------------------------------------------------------
-- A.2 — CLEANING LOGIC
--
-- What this does, in order:
--   1. Removes exact full-row duplicates (~3,300 rows)
--   2. Parses order_date and shipping_date, trying both month-first and
--      day-first interpretations for slash-formatted strings, since the raw
--      data genuinely mixes both conventions
--   3. Resolves date ambiguity:
--      - If one column's two interpretations agree (unambiguous), or only one
--        parses successfully, that's the "forced" value
--      - If one side is forced, use it to pick the matching interpretation on
--        the other side (order <= shipping)
--      - If both sides are ambiguous, prefer whichever SAME-CONVENTION pair
--        (both month-first, or both day-first) keeps shipping >= order
--   4. Resolves order_item_id collisions (rows sharing an ID that are NOT
--      exact duplicates) by keeping the earliest valid order_date_clean
--   5. Adds permanent data-quality flag columns instead of silently dropping
--      rows: is_order_date_missing, is_shipping_date_missing,
--      is_ship_before_order_flag
--
-- Result: order_date_clean / shipping_date_clean are DATE type (day precision
-- is sufficient since real_shipping_days / scheduled_days_for_shipment already
-- carry the delay metrics numerically).
-- -----------------------------------------------------------------------------

CREATE OR REPLACE TABLE `logistic-analytics-project.logistic_analytics_dataset.stg_orders_deduped` AS

WITH remove_exact_duplicates AS (
  SELECT * EXCEPT(rn) FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY TO_JSON_STRING(t)) AS rn
    FROM `logistic-analytics-project.logistic_analytics_dataset.logistic_analytics_table` t
  ) WHERE rn = 1
),

parse_candidates AS (
  SELECT *,
    DATE(COALESCE(
      SAFE.PARSE_DATETIME('%Y-%m-%d %H:%M:%S', order_date),
      SAFE.PARSE_DATETIME('%m/%d/%Y %H:%M',    order_date),
      SAFE.PARSE_DATETIME('%m/%d/%Y',          order_date),
      SAFE.PARSE_DATETIME('%d-%b-%y',          order_date),
      SAFE.PARSE_DATETIME('%B %d, %Y',         order_date),
      SAFE.PARSE_DATETIME('%Y/%m/%d',          order_date)
    )) AS order_date_monthfirst,
    DATE(COALESCE(
      SAFE.PARSE_DATETIME('%Y-%m-%d %H:%M:%S', order_date),
      SAFE.PARSE_DATETIME('%d/%m/%Y %H:%M',    order_date),
      SAFE.PARSE_DATETIME('%d/%m/%Y',          order_date),
      SAFE.PARSE_DATETIME('%d-%b-%y',          order_date),
      SAFE.PARSE_DATETIME('%B %d, %Y',         order_date),
      SAFE.PARSE_DATETIME('%Y/%m/%d',          order_date)
    )) AS order_date_dayfirst,
    DATE(COALESCE(
      SAFE.PARSE_DATETIME('%Y-%m-%d %H:%M:%S', shipping_date),
      SAFE.PARSE_DATETIME('%m/%d/%Y %H:%M',    shipping_date),
      SAFE.PARSE_DATETIME('%m/%d/%Y',          shipping_date),
      SAFE.PARSE_DATETIME('%d-%b-%y',          shipping_date),
      SAFE.PARSE_DATETIME('%B %d, %Y',         shipping_date),
      SAFE.PARSE_DATETIME('%Y/%m/%d',          shipping_date)
    )) AS shipping_date_monthfirst,
    DATE(COALESCE(
      SAFE.PARSE_DATETIME('%Y-%m-%d %H:%M:%S', shipping_date),
      SAFE.PARSE_DATETIME('%d/%m/%Y %H:%M',    shipping_date),
      SAFE.PARSE_DATETIME('%d/%m/%Y',          shipping_date),
      SAFE.PARSE_DATETIME('%d-%b-%y',          shipping_date),
      SAFE.PARSE_DATETIME('%B %d, %Y',         shipping_date),
      SAFE.PARSE_DATETIME('%Y/%m/%d',          shipping_date)
    )) AS shipping_date_dayfirst
  FROM remove_exact_duplicates
),

forced_values AS (
  -- "forced" = the ONE value a column can be, when only one interpretation
  -- is valid, or both interpretations agree (i.e. it's not really ambiguous)
  SELECT *,
    CASE
      WHEN order_date_monthfirst IS NULL THEN order_date_dayfirst
      WHEN order_date_dayfirst IS NULL THEN order_date_monthfirst
      WHEN order_date_monthfirst = order_date_dayfirst THEN order_date_monthfirst
      ELSE NULL  -- genuinely ambiguous: both valid and different
    END AS order_date_forced,
    CASE
      WHEN shipping_date_monthfirst IS NULL THEN shipping_date_dayfirst
      WHEN shipping_date_dayfirst IS NULL THEN shipping_date_monthfirst
      WHEN shipping_date_monthfirst = shipping_date_dayfirst THEN shipping_date_monthfirst
      ELSE NULL
    END AS shipping_date_forced
  FROM parse_candidates
),

resolve_ambiguity AS (
  SELECT *,
    CASE
      -- Case 1: one side is unambiguous -> use it to disambiguate the other
      WHEN order_date_forced IS NOT NULL THEN order_date_forced
      WHEN shipping_date_forced IS NOT NULL AND order_date_monthfirst <= shipping_date_forced THEN order_date_monthfirst
      WHEN shipping_date_forced IS NOT NULL AND order_date_dayfirst   <= shipping_date_forced THEN order_date_dayfirst
      -- Case 2: both ambiguous -> try same-convention pairs, prefer month-first if both work
      WHEN order_date_monthfirst <= shipping_date_monthfirst THEN order_date_monthfirst
      WHEN order_date_dayfirst   <= shipping_date_dayfirst   THEN order_date_dayfirst
      ELSE order_date_monthfirst
    END AS order_date_clean,
    CASE
      WHEN shipping_date_forced IS NOT NULL THEN shipping_date_forced
      WHEN order_date_forced IS NOT NULL AND shipping_date_monthfirst >= order_date_forced THEN shipping_date_monthfirst
      WHEN order_date_forced IS NOT NULL AND shipping_date_dayfirst   >= order_date_forced THEN shipping_date_dayfirst
      WHEN order_date_monthfirst <= shipping_date_monthfirst THEN shipping_date_monthfirst
      WHEN order_date_dayfirst   <= shipping_date_dayfirst   THEN shipping_date_dayfirst
      ELSE shipping_date_monthfirst
    END AS shipping_date_clean
  FROM forced_values
),

resolve_id_collisions AS (
  -- For rows where order_item_id repeats but the rows are NOT exact
  -- duplicates (already removed above), keep one row per order_item_id,
  -- using the parsed order date as tie-breaker (earliest wins).
  SELECT * EXCEPT(rn2) FROM (
    SELECT *,
      ROW_NUMBER() OVER (
        PARTITION BY order_item_id
        ORDER BY order_date_clean ASC NULLS LAST
      ) AS rn2
    FROM resolve_ambiguity
  ) WHERE rn2 = 1
),

add_quality_flags AS (
  SELECT
    * EXCEPT(order_date_monthfirst, order_date_dayfirst, shipping_date_monthfirst,
             shipping_date_dayfirst, order_date_forced, shipping_date_forced),
    CASE WHEN order_date_clean IS NULL THEN TRUE ELSE FALSE END AS is_order_date_missing,
    CASE WHEN shipping_date_clean IS NULL THEN TRUE ELSE FALSE END AS is_shipping_date_missing,
    CASE
      WHEN order_date_clean IS NOT NULL AND shipping_date_clean IS NOT NULL
       AND shipping_date_clean < order_date_clean
      THEN TRUE ELSE FALSE
    END AS is_ship_before_order_flag
  FROM resolve_id_collisions
)

SELECT * FROM add_quality_flags;


-- -----------------------------------------------------------------------------
-- A.3 — VALIDATION QUERIES (run against stg_orders_deduped after cleaning)
-- -----------------------------------------------------------------------------

-- A.3.1 order_item_id should now be fully unique (primary key check)
SELECT
  COUNT(*) AS total_rows,
  COUNT(DISTINCT order_item_id) AS distinct_order_item_ids
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_deduped`;

-- A.3.2 Date quality summary
-- Expected result as of last validation (2026):
--   total_rows: 219,571
--   missing_order_dates:    19,199  (~8.74%  — genuinely unparseable, by design)
--   missing_shipping_dates: 19,302  (~8.79%  — genuinely unparseable, by design)
--   ship_before_order_cases: 0      (fully resolved via same-convention pairing)
SELECT
  COUNT(*) AS total_rows,
  COUNTIF(order_date_clean IS NULL) AS missing_order_dates,
  COUNTIF(shipping_date_clean IS NULL) AS missing_shipping_dates,
  COUNTIF(is_ship_before_order_flag) AS ship_before_order_cases,
  ROUND(COUNTIF(is_ship_before_order_flag) / COUNT(*) * 100, 2) AS pct_ship_before_order
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_deduped`;

-- A.3.3 Customer Id / Order Customer Id consistency (should still be 0)
SELECT COUNT(*) AS mismatch_count
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_deduped`
WHERE customer_id != order_customer_id;


-- -----------------------------------------------------------------------------
-- KNOWN DATA-QUALITY LIMITATIONS (documented, not further "fixed")
-- -----------------------------------------------------------------------------
-- ~8.7% of rows have an unparseable order_date and/or shipping_date
-- (intentional junk values: NULL, "0000-00-00", "NaT", "####", "not a date",
-- invalid calendar dates, malformed strings). These rows are KEPT in
-- stg_orders_deduped but flagged via is_order_date_missing /
-- is_shipping_date_missing. Downstream date-dependent modules (funnel,
-- cohort, churn/RFM) should filter WHERE order_date_clean IS NOT NULL,
-- while non-date-dependent aggregates can still use these rows.
-- =============================================================================


-- =============================================================================
-- Section B: Delivery / Status columns
--   order_status, delivery_status, shipping_mode,
--   late_delivery_risk, real_shipping_days, scheduled_days_for_shipment
-- =============================================================================

-- -----------------------------------------------------------------------------
-- B.1 — DIAGNOSTIC QUERIES (run against stg_orders_deduped before cleaning)
-- -----------------------------------------------------------------------------

-- B.1.1 Distinct raw values + counts for order_status
SELECT order_status, COUNT(*) AS cnt
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_deduped`
GROUP BY order_status
ORDER BY cnt DESC;

-- B.1.2 Distinct raw values + counts for delivery_status
SELECT delivery_status, COUNT(*) AS cnt
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_deduped`
GROUP BY delivery_status
ORDER BY cnt DESC;

-- B.1.3 Distinct raw values + counts for shipping_mode
SELECT shipping_mode, COUNT(*) AS cnt
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_deduped`
GROUP BY shipping_mode
ORDER BY cnt DESC;

-- B.1.4 Distinct raw values + counts for late_delivery_risk
SELECT late_delivery_risk, COUNT(*) AS cnt
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_deduped`
GROUP BY late_delivery_risk
ORDER BY cnt DESC;

-- B.1.5a Confirm data types for the two day-count columns
SELECT column_name, data_type
FROM `logistic-analytics-project.logistic_analytics_dataset.INFORMATION_SCHEMA.COLUMNS`
WHERE table_name = 'stg_orders_deduped'
  AND column_name IN ('real_shipping_days', 'scheduled_days_for_shipment');

-- B.1.5b Range/outlier check using SAFE_CAST (works regardless of underlying type;
-- both columns loaded as STRING because null-flavor placeholders forced
-- BigQuery's schema auto-detection away from INT64)
SELECT
  MIN(SAFE_CAST(real_shipping_days AS INT64)) AS min_real_days,
  MAX(SAFE_CAST(real_shipping_days AS INT64)) AS max_real_days,
  COUNTIF(SAFE_CAST(real_shipping_days AS INT64) < 0) AS negative_real_days,
  COUNTIF(real_shipping_days IS NOT NULL AND SAFE_CAST(real_shipping_days AS INT64) IS NULL) AS unparseable_real_days,
  MIN(SAFE_CAST(scheduled_days_for_shipment AS INT64)) AS min_scheduled_days,
  MAX(SAFE_CAST(scheduled_days_for_shipment AS INT64)) AS max_scheduled_days,
  COUNTIF(SAFE_CAST(scheduled_days_for_shipment AS INT64) < 0) AS negative_scheduled_days,
  COUNTIF(scheduled_days_for_shipment IS NOT NULL AND SAFE_CAST(scheduled_days_for_shipment AS INT64) IS NULL) AS unparseable_scheduled_days
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_deduped`;


-- -----------------------------------------------------------------------------
-- B.2 — CLEANING LOGIC
--
-- What this does, in order:
--   1. Strips HTML/junk substrings from shipping_mode (&nbsp;, <br>, ###,
--      "N/A - check later", tabs, zero-width spaces) BEFORE trimming/casing
--   2. shipping_mode: pattern-match onto 4 canonical values, merging the
--      "2nd Class" / "Second Class" synonym; unrecognized/null-flavor -> NULL
--   3. order_status: trim + uppercase, merging the CANCELLED/CANCELED
--      spelling collision into one canonical value; null-flavors -> NULL
--   4. delivery_status: trim + case-normalize onto 4 canonical values;
--      null-flavors -> NULL
--   5. late_delivery_risk: normalize every representation
--      (0/1, TRUE/FALSE, YES/NO, Y/N) to clean INT64 0/1
--   6. real_shipping_days / scheduled_days_for_shipment: SAFE_CAST from
--      STRING to INT64 (embedded null-flavors forced STRING typing on load)
--   7. Adds permanent data-quality flag columns for every field cleaned here
--      instead of silently dropping rows
--
-- Validated: late_delivery_risk_clean is 100% internally consistent with
-- real_shipping_days_clean > scheduled_days_for_shipment_clean across all
-- 193,765 rows where both day-count columns are non-null (see B.4 below) —
-- confirmed safe to use as-is for Module 1.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE TABLE `logistic-analytics-project.logistic_analytics_dataset.stg_orders_clean` AS

WITH strip_shipping_mode_junk AS (
  SELECT *,
    TRIM(
      REPLACE(
        REPLACE(
          REPLACE(
            REPLACE(
              REPLACE(
                REPLACE(shipping_mode, '&nbsp;', ' '),
              '<br>', ' '),
            '###', ' '),
          'N/A - check later', ' '),
        '\t', ' '),
      '\u200b', ' ')
    ) AS shipping_mode_stripped
  FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_deduped`
),

apply_mappings AS (
  SELECT *,

    -- shipping_mode: strip -> uppercase match -> canonical value
    CASE
      WHEN REGEXP_CONTAINS(UPPER(shipping_mode_stripped), r'STANDARD') THEN 'Standard Class'
      WHEN REGEXP_CONTAINS(UPPER(shipping_mode_stripped), r'FIRST')    THEN 'First Class'
      WHEN REGEXP_CONTAINS(UPPER(shipping_mode_stripped), r'2ND|SECOND') THEN 'Second Class'
      WHEN REGEXP_CONTAINS(UPPER(shipping_mode_stripped), r'SAME')     THEN 'Same Day'
      ELSE NULL
    END AS shipping_mode_clean,

    -- order_status: trim + uppercase, merge CANCELLED/CANCELED spelling collision
    CASE
      WHEN TRIM(order_status) IS NULL OR TRIM(order_status) = '' THEN NULL
      WHEN UPPER(TRIM(order_status)) IN ('N/A','NULL','NONE','-','??') THEN NULL
      WHEN UPPER(TRIM(order_status)) IN ('CANCELLED','CANCELED') THEN 'CANCELED'
      ELSE UPPER(TRIM(order_status))
    END AS order_status_clean,

    -- delivery_status: trim + case-normalize onto 4 canonical values
    CASE
      WHEN UPPER(TRIM(delivery_status)) = 'ADVANCE SHIPPING'  THEN 'Advance shipping'
      WHEN UPPER(TRIM(delivery_status)) = 'LATE DELIVERY'     THEN 'Late delivery'
      WHEN UPPER(TRIM(delivery_status)) = 'SHIPPING CANCELED' THEN 'Shipping canceled'
      WHEN UPPER(TRIM(delivery_status)) = 'SHIPPING ON TIME'  THEN 'Shipping on time'
      ELSE NULL
    END AS delivery_status_clean,

    -- late_delivery_risk: normalize every representation to INT64 0/1
    CASE
      WHEN UPPER(TRIM(CAST(late_delivery_risk AS STRING))) IN ('1','TRUE','YES','Y') THEN 1
      WHEN UPPER(TRIM(CAST(late_delivery_risk AS STRING))) IN ('0','FALSE','NO','N') THEN 0
      ELSE NULL
    END AS late_delivery_risk_clean,

    -- day-count columns: safe cast to INT64
    SAFE_CAST(real_shipping_days AS INT64) AS real_shipping_days_clean,
    SAFE_CAST(scheduled_days_for_shipment AS INT64) AS scheduled_days_for_shipment_clean

  FROM strip_shipping_mode_junk
),

add_quality_flags AS (
  SELECT
    * EXCEPT(shipping_mode_stripped),
    CASE WHEN shipping_mode_clean IS NULL THEN TRUE ELSE FALSE END AS is_shipping_mode_missing,
    CASE WHEN order_status_clean IS NULL THEN TRUE ELSE FALSE END AS is_order_status_missing,
    CASE WHEN delivery_status_clean IS NULL THEN TRUE ELSE FALSE END AS is_delivery_status_missing,
    CASE WHEN late_delivery_risk_clean IS NULL THEN TRUE ELSE FALSE END AS is_late_risk_missing,
    CASE WHEN real_shipping_days_clean IS NULL THEN TRUE ELSE FALSE END AS is_real_days_missing,
    CASE WHEN scheduled_days_for_shipment_clean IS NULL THEN TRUE ELSE FALSE END AS is_scheduled_days_missing
  FROM apply_mappings
)

SELECT * FROM add_quality_flags;


-- -----------------------------------------------------------------------------
-- B.3 — VALIDATION QUERIES (run against stg_orders_clean after cleaning)
-- -----------------------------------------------------------------------------

-- B.3.1 Confirm shipping_mode collapsed to exactly 4 canonical values (+ NULL)
-- Expected: Second Class 51,760 | Same Day 51,718 | First Class 51,442
--           Standard Class 51,429 | NULL 13,222
SELECT shipping_mode_clean, COUNT(*) AS cnt
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_clean`
GROUP BY shipping_mode_clean
ORDER BY cnt DESC;

-- B.3.2 Confirm order_status collapsed correctly (CANCELED = merged spelling variants)
-- Expected: CANCELED 29,835 | COMPLETE 29,622 | PENDING 29,533 | PROCESSING 29,411
--           CLOSED 29,124 | PAYMENT_REVIEW 14,789 | SUSPECTED_FRAUD 14,695
--           ON_HOLD 14,669 | PENDING_PAYMENT 14,660 | NULL 13,233
SELECT order_status_clean, COUNT(*) AS cnt
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_clean`
GROUP BY order_status_clean
ORDER BY cnt DESC;

-- B.3.3 Confirm delivery_status collapsed to exactly 4 canonical values (+ NULL)
-- Expected: Late delivery 77,233 | Advance shipping 51,626
--           Shipping on time 51,467 | Shipping canceled 26,096 | NULL 13,149
SELECT delivery_status_clean, COUNT(*) AS cnt
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_clean`
GROUP BY delivery_status_clean
ORDER BY cnt DESC;

-- B.3.4 Confirm late_delivery_risk_clean is now clean binary, zero NULLs
-- Expected: 0 -> 119,614 | 1 -> 99,957
SELECT late_delivery_risk_clean, COUNT(*) AS cnt
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_clean`
GROUP BY late_delivery_risk_clean
ORDER BY cnt DESC;

-- B.3.5 Cross-check: late_delivery_risk_clean vs. actual day-count comparison
-- Confirmed 100% consistent across all 193,765 comparable rows (0 inconsistent)
SELECT
  COUNT(*) AS total_comparable_rows,
  COUNTIF(
    (real_shipping_days_clean > scheduled_days_for_shipment_clean AND late_delivery_risk_clean = 1)
    OR (real_shipping_days_clean <= scheduled_days_for_shipment_clean AND late_delivery_risk_clean = 0)
  ) AS consistent_rows,
  COUNTIF(
    (real_shipping_days_clean > scheduled_days_for_shipment_clean AND late_delivery_risk_clean = 0)
    OR (real_shipping_days_clean <= scheduled_days_for_shipment_clean AND late_delivery_risk_clean = 1)
  ) AS inconsistent_rows
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_clean`
WHERE real_shipping_days_clean IS NOT NULL
  AND scheduled_days_for_shipment_clean IS NOT NULL;


-- -----------------------------------------------------------------------------
-- KNOWN DATA-QUALITY LIMITATIONS — Section B (documented, not further "fixed")
-- -----------------------------------------------------------------------------
-- ~6% of rows have a NULL shipping_mode_clean, order_status_clean, or
-- delivery_status_clean after standardization (intentional null-flavor
-- placeholders in the source data: N/A, NULL, None, -, ??, blank). These
-- rows are KEPT in stg_orders_clean and flagged via is_shipping_mode_missing /
-- is_order_status_missing / is_delivery_status_missing.
--
-- ~5% of rows have NULL real_shipping_days_clean / scheduled_days_for_shipment_clean
-- for the same reason, flagged via is_real_days_missing / is_scheduled_days_missing.
--
-- Downstream modules should filter out NULLs on a per-analysis basis (e.g.
-- Module 1's late-delivery-rate-by-shipping-mode should exclude rows where
-- shipping_mode_clean IS NULL) rather than dropping them from the whole table.
-- =============================================================================


-- =============================================================================
-- Section C: Money / Quantity columns
--   sales, order_item_total, order_item_product_price, order_item_discount,
--   order_item_discount_rate, order_profit_per_order, benefit_per_order,
--   sales_per_customer, order_item_profit_ratio, order_item_quantity
-- =============================================================================

-- -----------------------------------------------------------------------------
-- C.1 — DIAGNOSTIC QUERIES (run against stg_orders_clean before cleaning)
-- -----------------------------------------------------------------------------

-- C.1.1 Confirm data types across all money/quantity columns
SELECT column_name, data_type
FROM `logistic-analytics-project.logistic_analytics_dataset.INFORMATION_SCHEMA.COLUMNS`
WHERE table_name = 'stg_orders_clean'
  AND column_name IN (
    'sales', 'order_item_total', 'order_item_quantity',
    'order_item_product_price', 'order_item_discount',
    'order_item_discount_rate', 'order_profit_per_order',
    'benefit_per_order', 'order_item_profit_ratio', 'sales_per_customer'
  );

-- C.1.2 Sample raw values that don't cast cleanly, to see the dirty formats in play
SELECT DISTINCT sales AS raw_value
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_clean`
WHERE SAFE_CAST(sales AS FLOAT64) IS NULL AND sales IS NOT NULL
LIMIT 30;

-- C.1.3 Range/outlier check on order_item_quantity (expect negatives and zeros)
SELECT
  SAFE_CAST(order_item_quantity AS INT64) AS qty,
  COUNT(*) AS cnt
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_clean`
GROUP BY qty
ORDER BY qty ASC;

-- C.1.4 Range check on order_item_discount_rate
SELECT
  MIN(SAFE_CAST(order_item_discount_rate AS FLOAT64)) AS min_rate,
  MAX(SAFE_CAST(order_item_discount_rate AS FLOAT64)) AS max_rate,
  COUNTIF(SAFE_CAST(order_item_discount_rate AS FLOAT64) < 0
       OR SAFE_CAST(order_item_discount_rate AS FLOAT64) > 1) AS out_of_range_count,
  COUNTIF(order_item_discount_rate IS NULL) AS null_count
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_clean`;

-- C.1.5 Range check on order_item_profit_ratio
SELECT
  MIN(SAFE_CAST(order_item_profit_ratio AS FLOAT64)) AS min_ratio,
  MAX(SAFE_CAST(order_item_profit_ratio AS FLOAT64)) AS max_ratio,
  COUNTIF(order_item_profit_ratio IS NULL) AS null_count
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_clean`;

-- C.1.6 Null counts across remaining money columns in one pass
SELECT
  COUNTIF(order_item_total IS NULL) AS null_order_item_total,
  COUNTIF(order_item_product_price IS NULL) AS null_product_price,
  COUNTIF(order_item_discount IS NULL) AS null_discount,
  COUNTIF(order_profit_per_order IS NULL) AS null_profit_per_order,
  COUNTIF(benefit_per_order IS NULL) AS null_benefit_per_order,
  COUNTIF(sales_per_customer IS NULL) AS null_sales_per_customer
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_clean`;


-- -----------------------------------------------------------------------------
-- C.2 — CLEANING LOGIC
--
-- Dirty format pattern identified from C.1.2 sampling:
--   - Null-flavors: None, N/A, ??, -, NULL, null, blank/whitespace-only
--   - '$' present  -> strip '$' and commas (comma = thousands separator),
--                     e.g. "$1,504.42" -> 1504.42
--   - no '$', comma present -> comma IS the decimal separator (European-style),
--                     e.g. "2256,63" -> 2256.63
--   - otherwise -> plain numeric cast
--
-- order_item_discount_rate / order_item_profit_ratio never received $/comma
-- formatting in the source -> straight SAFE_CAST is sufficient.
--
-- order_item_quantity: -1 and 0 are business-invalid (not unparseable) ->
-- flagged via is_quantity_invalid rather than nulled, since ~21% of rows
-- carry this by design and dropping them would lose real order-line data.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE TABLE `logistic-analytics-project.logistic_analytics_dataset.stg_orders_money_clean` AS

WITH clean_money AS (
  SELECT *,

    CASE
      WHEN UPPER(TRIM(sales)) IN ('NONE','N/A','??','-','NULL') OR TRIM(sales) = '' THEN NULL
      WHEN sales LIKE '$%' THEN SAFE_CAST(REPLACE(REPLACE(TRIM(sales),'$',''),',','') AS FLOAT64)
      WHEN REGEXP_CONTAINS(sales, r',') THEN SAFE_CAST(REPLACE(TRIM(sales),',','.') AS FLOAT64)
      ELSE SAFE_CAST(TRIM(sales) AS FLOAT64)
    END AS sales_clean,

    CASE
      WHEN UPPER(TRIM(order_item_total)) IN ('NONE','N/A','??','-','NULL') OR TRIM(order_item_total) = '' THEN NULL
      WHEN order_item_total LIKE '$%' THEN SAFE_CAST(REPLACE(REPLACE(TRIM(order_item_total),'$',''),',','') AS FLOAT64)
      WHEN REGEXP_CONTAINS(order_item_total, r',') THEN SAFE_CAST(REPLACE(TRIM(order_item_total),',','.') AS FLOAT64)
      ELSE SAFE_CAST(TRIM(order_item_total) AS FLOAT64)
    END AS order_item_total_clean,

    CASE
      WHEN UPPER(TRIM(order_item_product_price)) IN ('NONE','N/A','??','-','NULL') OR TRIM(order_item_product_price) = '' THEN NULL
      WHEN order_item_product_price LIKE '$%' THEN SAFE_CAST(REPLACE(REPLACE(TRIM(order_item_product_price),'$',''),',','') AS FLOAT64)
      WHEN REGEXP_CONTAINS(order_item_product_price, r',') THEN SAFE_CAST(REPLACE(TRIM(order_item_product_price),',','.') AS FLOAT64)
      ELSE SAFE_CAST(TRIM(order_item_product_price) AS FLOAT64)
    END AS order_item_product_price_clean,

    CASE
      WHEN UPPER(TRIM(order_item_discount)) IN ('NONE','N/A','??','-','NULL') OR TRIM(order_item_discount) = '' THEN NULL
      WHEN order_item_discount LIKE '$%' THEN SAFE_CAST(REPLACE(REPLACE(TRIM(order_item_discount),'$',''),',','') AS FLOAT64)
      WHEN REGEXP_CONTAINS(order_item_discount, r',') THEN SAFE_CAST(REPLACE(TRIM(order_item_discount),',','.') AS FLOAT64)
      ELSE SAFE_CAST(TRIM(order_item_discount) AS FLOAT64)
    END AS order_item_discount_clean,

    CASE
      WHEN UPPER(TRIM(order_profit_per_order)) IN ('NONE','N/A','??','-','NULL') OR TRIM(order_profit_per_order) = '' THEN NULL
      WHEN order_profit_per_order LIKE '$%' THEN SAFE_CAST(REPLACE(REPLACE(TRIM(order_profit_per_order),'$',''),',','') AS FLOAT64)
      WHEN REGEXP_CONTAINS(order_profit_per_order, r',') THEN SAFE_CAST(REPLACE(TRIM(order_profit_per_order),',','.') AS FLOAT64)
      ELSE SAFE_CAST(TRIM(order_profit_per_order) AS FLOAT64)
    END AS order_profit_per_order_clean,

    CASE
      WHEN UPPER(TRIM(benefit_per_order)) IN ('NONE','N/A','??','-','NULL') OR TRIM(benefit_per_order) = '' THEN NULL
      WHEN benefit_per_order LIKE '$%' THEN SAFE_CAST(REPLACE(REPLACE(TRIM(benefit_per_order),'$',''),',','') AS FLOAT64)
      WHEN REGEXP_CONTAINS(benefit_per_order, r',') THEN SAFE_CAST(REPLACE(TRIM(benefit_per_order),',','.') AS FLOAT64)
      ELSE SAFE_CAST(TRIM(benefit_per_order) AS FLOAT64)
    END AS benefit_per_order_clean,

    CASE
      WHEN UPPER(TRIM(sales_per_customer)) IN ('NONE','N/A','??','-','NULL') OR TRIM(sales_per_customer) = '' THEN NULL
      WHEN sales_per_customer LIKE '$%' THEN SAFE_CAST(REPLACE(REPLACE(TRIM(sales_per_customer),'$',''),',','') AS FLOAT64)
      WHEN REGEXP_CONTAINS(sales_per_customer, r',') THEN SAFE_CAST(REPLACE(TRIM(sales_per_customer),',','.') AS FLOAT64)
      ELSE SAFE_CAST(TRIM(sales_per_customer) AS FLOAT64)
    END AS sales_per_customer_clean,

    SAFE_CAST(order_item_discount_rate AS FLOAT64) AS order_item_discount_rate_clean,
    SAFE_CAST(order_item_profit_ratio AS FLOAT64) AS order_item_profit_ratio_clean,
    SAFE_CAST(order_item_quantity AS INT64) AS order_item_quantity_clean

  FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_clean`
),

add_quality_flags AS (
  SELECT *,
    CASE WHEN sales_clean IS NULL THEN TRUE ELSE FALSE END AS is_sales_missing,
    CASE WHEN order_item_total_clean IS NULL THEN TRUE ELSE FALSE END AS is_order_item_total_missing,
    CASE WHEN order_item_product_price_clean IS NULL THEN TRUE ELSE FALSE END AS is_product_price_missing,
    CASE WHEN order_item_discount_clean IS NULL THEN TRUE ELSE FALSE END AS is_discount_missing,
    CASE WHEN order_profit_per_order_clean IS NULL THEN TRUE ELSE FALSE END AS is_profit_per_order_missing,
    CASE WHEN benefit_per_order_clean IS NULL THEN TRUE ELSE FALSE END AS is_benefit_per_order_missing,
    CASE WHEN sales_per_customer_clean IS NULL THEN TRUE ELSE FALSE END AS is_sales_per_customer_missing,
    CASE WHEN order_item_discount_rate_clean IS NULL THEN TRUE ELSE FALSE END AS is_discount_rate_missing,
    CASE WHEN order_item_profit_ratio_clean IS NULL THEN TRUE ELSE FALSE END AS is_profit_ratio_missing,
    CASE WHEN order_item_quantity_clean IS NULL THEN TRUE ELSE FALSE END AS is_quantity_missing,
    CASE WHEN order_item_quantity_clean <= 0 THEN TRUE ELSE FALSE END AS is_quantity_invalid
  FROM clean_money
)

SELECT * FROM add_quality_flags;


-- -----------------------------------------------------------------------------
-- C.3 — VALIDATION QUERIES (run against stg_orders_money_clean after cleaning)
-- -----------------------------------------------------------------------------

-- C.3.1 Confirm all money columns parse cleanly once blank/space strings are
-- excluded alongside the other null-flavors (all counts expected to be 0)
SELECT
  COUNTIF(sales IS NOT NULL AND sales_clean IS NULL AND UPPER(TRIM(sales)) NOT IN ('NONE','N/A','??','-','NULL') AND TRIM(sales) != '') AS bad_sales,
  COUNTIF(order_item_total IS NOT NULL AND order_item_total_clean IS NULL AND UPPER(TRIM(order_item_total)) NOT IN ('NONE','N/A','??','-','NULL') AND TRIM(order_item_total) != '') AS bad_total,
  COUNTIF(order_item_product_price IS NOT NULL AND order_item_product_price_clean IS NULL AND UPPER(TRIM(order_item_product_price)) NOT IN ('NONE','N/A','??','-','NULL') AND TRIM(order_item_product_price) != '') AS bad_price,
  COUNTIF(order_item_discount IS NOT NULL AND order_item_discount_clean IS NULL AND UPPER(TRIM(order_item_discount)) NOT IN ('NONE','N/A','??','-','NULL') AND TRIM(order_item_discount) != '') AS bad_discount,
  COUNTIF(order_profit_per_order IS NOT NULL AND order_profit_per_order_clean IS NULL AND UPPER(TRIM(order_profit_per_order)) NOT IN ('NONE','N/A','??','-','NULL') AND TRIM(order_profit_per_order) != '') AS bad_profit,
  COUNTIF(benefit_per_order IS NOT NULL AND benefit_per_order_clean IS NULL AND UPPER(TRIM(benefit_per_order)) NOT IN ('NONE','N/A','??','-','NULL') AND TRIM(benefit_per_order) != '') AS bad_benefit,
  COUNTIF(sales_per_customer IS NOT NULL AND sales_per_customer_clean IS NULL AND UPPER(TRIM(sales_per_customer)) NOT IN ('NONE','N/A','??','-','NULL') AND TRIM(sales_per_customer) != '') AS bad_spc
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_money_clean`;

-- C.3.2 Sanity check: sales_clean magnitude is reasonable
-- Confirmed: min $0.00, max $9,930.00, avg ~$2,002 — consistent with product
-- price range (5-2000) x quantity
SELECT MIN(sales_clean) AS min_sales, MAX(sales_clean) AS max_sales, AVG(sales_clean) AS avg_sales
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_money_clean`
WHERE sales_clean IS NOT NULL;

-- C.3.3 Quantity invalid/missing breakdown
-- Confirmed: 13,054 missing (5.9%) + 46,113 invalid <=0 (21%), both flagged,
-- not dropped — matches expected injection rate from the source generator
SELECT
  COUNTIF(is_quantity_missing) AS missing_qty,
  COUNTIF(is_quantity_invalid AND NOT is_quantity_missing) AS invalid_qty_le_zero,
  COUNT(*) AS total_rows
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_money_clean`;


-- -----------------------------------------------------------------------------
-- KNOWN DATA-QUALITY LIMITATIONS — Section C (documented, not further "fixed")
-- -----------------------------------------------------------------------------
-- ~5-6% of rows have NULL values across the money columns (sales,
-- order_item_total, order_item_product_price, order_item_discount,
-- order_profit_per_order, benefit_per_order, sales_per_customer) due to
-- intentional null-flavor placeholders in the source. Flagged via
-- is_sales_missing / is_order_item_total_missing / etc.
--
-- order_item_quantity: 5.9% missing + 21% business-invalid (<=0). These rows
-- are KEPT (not dropped) but flagged via is_quantity_missing /
-- is_quantity_invalid, since excluding 27% of rows outright would
-- meaningfully distort LTV and funnel counts. Modules that depend on a valid
-- quantity (e.g. any revenue calc using sales = price x quantity) should
-- filter WHERE NOT is_quantity_invalid explicitly.
-- =============================================================================


-- =============================================================================
-- Section D: Segmentation dimensions
--   customer_segment, order_region, market, order_country, order_state
-- =============================================================================

-- -----------------------------------------------------------------------------
-- D.1 — DIAGNOSTIC QUERIES (run against stg_orders_money_clean before cleaning)
-- -----------------------------------------------------------------------------

-- D.1.1 Distinct raw values + counts for customer_segment
SELECT customer_segment, COUNT(*) AS cnt
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_money_clean`
GROUP BY customer_segment
ORDER BY cnt DESC;

-- D.1.2 Distinct raw values + counts for order_region
SELECT order_region, COUNT(*) AS cnt
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_money_clean`
GROUP BY order_region
ORDER BY cnt DESC;

-- D.1.3 Distinct raw values + counts for market
SELECT market, COUNT(*) AS cnt
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_money_clean`
GROUP BY market
ORDER BY cnt DESC;

-- D.1.4 Distinct raw values + counts for order_country (expect the most variants)
SELECT order_country, COUNT(*) AS cnt
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_money_clean`
GROUP BY order_country
ORDER BY cnt DESC
LIMIT 60;

-- D.1.5 order_state: check cardinality (naturally high, not necessarily dirty)
SELECT COUNT(DISTINCT order_state) AS distinct_states, COUNTIF(order_state IS NULL) AS null_states
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_money_clean`;


-- -----------------------------------------------------------------------------
-- D.2 — CLEANING LOGIC
--
-- customer_segment, order_region, market: same junk-strip + trim/case pattern
-- as shipping_mode in Section B, collapsed onto their canonical value sets.
--
-- order_country: variants are genuinely DIFFERENT spellings/abbreviations
-- (USA/US/u.s.a./United States), not just casing -> needs an explicit
-- mapping table rather than a pattern match. Covers the 7 countries present
-- in this dataset: United States, Vietnam, Ireland, Germany, Mexico, Brazil,
-- Australia.
--
-- order_state: naturally high-cardinality (67 distinct values, state
-- abbreviations) -> just null-flavor handling + case normalization, no
-- canonical mapping needed.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE TABLE `logistic-analytics-project.logistic_analytics_dataset.stg_orders_final` AS

WITH strip_junk AS (
  SELECT *,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
      customer_segment, '&nbsp;', ' '), '<br>', ' '), '###', ' '),
      'N/A - check later', ' '), '\t', ' '), '\u200b', ' ')
    ) AS customer_segment_stripped,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
      order_region, '&nbsp;', ' '), '<br>', ' '), '###', ' '),
      'N/A - check later', ' '), '\t', ' '), '\u200b', ' ')
    ) AS order_region_stripped,
    TRIM(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
      market, '&nbsp;', ' '), '<br>', ' '), '###', ' '),
      'N/A - check later', ' '), '\t', ' '), '\u200b', ' ')
    ) AS market_stripped
  FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_money_clean`
),

apply_mappings AS (
  SELECT *,

    CASE
      WHEN REGEXP_CONTAINS(UPPER(customer_segment_stripped), r'CONSUMER') THEN 'Consumer'
      WHEN REGEXP_CONTAINS(UPPER(customer_segment_stripped), r'CORPORATE') THEN 'Corporate'
      WHEN REGEXP_CONTAINS(UPPER(customer_segment_stripped), r'HOME OFFICE') THEN 'Home Office'
      ELSE NULL
    END AS customer_segment_clean,

    CASE UPPER(order_region_stripped)
      WHEN 'SOUTHEAST ASIA'  THEN 'Southeast Asia'
      WHEN 'SOUTH ASIA'      THEN 'South Asia'
      WHEN 'OCEANIA'         THEN 'Oceania'
      WHEN 'EASTERN ASIA'    THEN 'Eastern Asia'
      WHEN 'WEST ASIA'       THEN 'West Asia'
      WHEN 'WEST AFRICA'     THEN 'West Africa'
      WHEN 'CENTRAL AFRICA'  THEN 'Central Africa'
      WHEN 'NORTH AFRICA'    THEN 'North Africa'
      WHEN 'WESTERN EUROPE'  THEN 'Western Europe'
      WHEN 'NORTHERN EUROPE' THEN 'Northern Europe'
      WHEN 'SOUTHERN EUROPE' THEN 'Southern Europe'
      WHEN 'EASTERN EUROPE'  THEN 'Eastern Europe'
      WHEN 'CARIBBEAN'       THEN 'Caribbean'
      WHEN 'SOUTH AMERICA'   THEN 'South America'
      WHEN 'CENTRAL AMERICA' THEN 'Central America'
      WHEN 'NORTH AMERICA'   THEN 'North America'
      ELSE NULL
    END AS order_region_clean,

    CASE UPPER(market_stripped)
      WHEN 'USCA'         THEN 'USCA'
      WHEN 'LATAM'        THEN 'LATAM'
      WHEN 'PACIFIC ASIA' THEN 'Pacific Asia'
      WHEN 'EUROPE'       THEN 'Europe'
      WHEN 'AFRICA'       THEN 'Africa'
      ELSE NULL
    END AS market_clean,

    CASE
      WHEN UPPER(TRIM(order_country)) IN ('USA','US','U.S.A.','UNITED STATES') THEN 'United States'
      WHEN UPPER(TRIM(order_country)) IN ('VN','VIETNAM','VIET NAM') THEN 'Vietnam'
      WHEN UPPER(TRIM(order_country)) IN ('IE','IRELAND','REP. OF IRELAND') THEN 'Ireland'
      WHEN UPPER(TRIM(order_country)) IN ('DE','GERMANY','DEUTSCHLAND') THEN 'Germany'
      WHEN UPPER(TRIM(order_country)) IN ('MX','MEXICO','MÉXICO') THEN 'Mexico'
      WHEN UPPER(TRIM(order_country)) IN ('BR','BRAZIL','BRASIL') THEN 'Brazil'
      WHEN UPPER(TRIM(order_country)) IN ('AU','AUSTRALIA') THEN 'Australia'
      ELSE NULL
    END AS order_country_clean,

    CASE
      WHEN order_state IS NULL THEN NULL
      WHEN UPPER(TRIM(order_state)) IN ('N/A','NULL','NONE','-','??','') THEN NULL
      ELSE UPPER(TRIM(order_state))
    END AS order_state_clean

  FROM strip_junk
),

add_quality_flags AS (
  SELECT
    * EXCEPT(customer_segment_stripped, order_region_stripped, market_stripped),
    CASE WHEN customer_segment_clean IS NULL THEN TRUE ELSE FALSE END AS is_segment_missing,
    CASE WHEN order_region_clean IS NULL THEN TRUE ELSE FALSE END AS is_region_missing,
    CASE WHEN market_clean IS NULL THEN TRUE ELSE FALSE END AS is_market_missing,
    CASE WHEN order_country_clean IS NULL THEN TRUE ELSE FALSE END AS is_country_missing,
    CASE WHEN order_state_clean IS NULL THEN TRUE ELSE FALSE END AS is_state_missing
  FROM apply_mappings
)

SELECT * FROM add_quality_flags;


-- -----------------------------------------------------------------------------
-- D.3 — VALIDATION QUERIES (run against stg_orders_final after cleaning)
-- -----------------------------------------------------------------------------

-- D.3.1 Confirm customer_segment collapsed to 3 canonical values + NULL
-- Confirmed: Consumer 69,660 | Corporate 69,616 | Home Office 67,104 | NULL 13,191
SELECT customer_segment_clean, COUNT(*) AS cnt
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_final`
GROUP BY customer_segment_clean ORDER BY cnt DESC;

-- D.3.2 Confirm order_region collapsed to 16 canonical values + NULL
-- Confirmed: 16 regions, ~12,675-13,107 rows each, NULL 13,260
SELECT order_region_clean, COUNT(*) AS cnt
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_final`
GROUP BY order_region_clean ORDER BY cnt DESC;

-- D.3.3 Confirm market collapsed to 5 canonical values + NULL
-- Confirmed: Pacific Asia 41,614 | Europe 41,426 | LATAM 41,212
--            USCA 41,078 | Africa 41,055 | NULL 13,186
SELECT market_clean, COUNT(*) AS cnt
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_final`
GROUP BY market_clean ORDER BY cnt DESC;

-- D.3.4 Confirm order_country collapsed to exactly 7 canonical values + NULL
-- Confirmed: Mexico 29,656 | Australia 29,589 | Brazil 29,581 | Vietnam 29,555
--            Germany 29,478 | Ireland 29,321 | United States 29,306 | NULL 13,085
-- Balanced distribution across all 7 countries confirms no mis-mapping.
SELECT order_country_clean, COUNT(*) AS cnt
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_final`
GROUP BY order_country_clean ORDER BY cnt DESC;


-- -----------------------------------------------------------------------------
-- KNOWN DATA-QUALITY LIMITATIONS — Section D (documented, not further "fixed")
-- -----------------------------------------------------------------------------
-- ~6% of rows have NULL customer_segment_clean / order_region_clean /
-- market_clean / order_country_clean / order_state_clean after
-- standardization, due to intentional null-flavor placeholders in the
-- source. Flagged via is_segment_missing / is_region_missing /
-- is_market_missing / is_country_missing / is_state_missing.
--
-- This is the FINAL staging table: stg_orders_final. All four cleaning
-- sections (A: keys/IDs/dates, B: delivery/status, C: money/quantity,
-- D: segmentation) are now consolidated into one table, ready for the
-- fact/dimension layer (dim_customer, dim_product, dim_date, fact_order_item)
-- and the Module 1-4 mart views on top of it.
-- =============================================================================