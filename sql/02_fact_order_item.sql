CREATE OR REPLACE TABLE `logistic-analytics-project.logistic_analytics_dataset.fact_order_item` AS

WITH corrected_dates AS (
  SELECT
    *,
    CASE
      WHEN order_date_clean > '2026-07-30'
       AND EXTRACT(DAY FROM order_date_clean) <= 12  -- only swappable if day could be a valid month
      THEN DATE(EXTRACT(YEAR FROM order_date_clean), EXTRACT(DAY FROM order_date_clean), EXTRACT(MONTH FROM order_date_clean))
      WHEN order_date_clean > '2026-07-30'
      THEN NULL  -- genuinely unrecoverable: day > 12, can't be a month
      ELSE order_date_clean
    END AS order_date_final,
    CASE
      WHEN shipping_date_clean > '2026-07-30'
       AND EXTRACT(DAY FROM shipping_date_clean) <= 12
      THEN DATE(EXTRACT(YEAR FROM shipping_date_clean), EXTRACT(DAY FROM shipping_date_clean), EXTRACT(MONTH FROM shipping_date_clean))
      WHEN shipping_date_clean > '2026-07-30'
      THEN NULL
      ELSE shipping_date_clean
    END AS shipping_date_final
  FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_final`
)

SELECT
  order_item_id, order_id, customer_id, product_card_id,
  CAST(FORMAT_DATE('%Y%m%d', order_date_final) AS INT64) AS order_date_key,
  CAST(FORMAT_DATE('%Y%m%d', shipping_date_final) AS INT64) AS shipping_date_key,
  order_date_final AS order_date_clean,
  shipping_date_final AS shipping_date_clean,
  order_status_clean AS order_status,
  delivery_status_clean AS delivery_status,
  shipping_mode_clean AS shipping_mode,
  order_region_clean AS order_region,
  order_state_clean AS order_state,
  order_country_clean AS order_country,
  market_clean AS market,
  real_shipping_days_clean AS real_shipping_days,
  scheduled_days_for_shipment_clean AS scheduled_days_for_shipment,
  late_delivery_risk_clean AS late_delivery_risk,
  sales_clean AS sales,
  order_item_total_clean AS order_item_total,
  order_item_product_price_clean AS order_item_product_price,
  order_item_discount_clean AS order_item_discount,
  order_item_discount_rate_clean AS order_item_discount_rate,
  order_profit_per_order_clean AS order_profit_per_order,
  benefit_per_order_clean AS benefit_per_order,
  order_item_profit_ratio_clean AS order_item_profit_ratio,
  sales_per_customer_clean AS sales_per_customer,
  order_item_quantity_clean AS order_item_quantity,
  (order_date_final IS NULL) AS is_order_date_missing,
  (shipping_date_final IS NULL) AS is_shipping_date_missing,
  CASE WHEN order_date_final IS NOT NULL AND shipping_date_final IS NOT NULL
        AND shipping_date_final < order_date_final THEN TRUE ELSE FALSE END AS is_ship_before_order_flag,
  is_shipping_mode_missing, is_order_status_missing, is_delivery_status_missing,
  is_late_risk_missing, is_real_days_missing, is_scheduled_days_missing,
  is_sales_missing, is_order_item_total_missing, is_product_price_missing,
  is_discount_missing, is_profit_per_order_missing, is_benefit_per_order_missing,
  is_sales_per_customer_missing, is_discount_rate_missing, is_profit_ratio_missing,
  is_quantity_missing, is_quantity_invalid,
  is_segment_missing, is_region_missing, is_market_missing, is_country_missing, is_state_missing
FROM corrected_dates;