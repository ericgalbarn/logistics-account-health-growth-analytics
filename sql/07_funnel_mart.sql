CREATE OR REPLACE VIEW `logistic-analytics-project.logistic_analytics_dataset.mart_funnel` AS

SELECT
  f.order_item_id,
  f.order_id,
  f.customer_id,
  f.order_status,
  f.delivery_status,
  f.shipping_mode,
  f.order_region,
  f.order_country,
  f.market,
  f.late_delivery_risk,
  f.real_shipping_days,
  f.scheduled_days_for_shipment,
  f.order_date_clean,
  d.year AS order_year,
  d.month AS order_month,
  d.month_name AS order_month_name,

  -- Funnel stage flags
  TRUE AS is_placed,
  CASE WHEN f.order_status NOT IN ('CANCELED', 'SUSPECTED_FRAUD') THEN TRUE ELSE FALSE END AS is_shipped,
  CASE WHEN f.order_status IN ('COMPLETE', 'CLOSED') THEN TRUE ELSE FALSE END AS is_delivered,
  CASE
    WHEN f.order_status IN ('COMPLETE', 'CLOSED') AND f.late_delivery_risk = 0 THEN TRUE
    ELSE FALSE
  END AS is_delivered_on_time

FROM `logistic-analytics-project.logistic_analytics_dataset.fact_order_item` f
LEFT JOIN `logistic-analytics-project.logistic_analytics_dataset.dim_date` d
  ON f.order_date_key = d.date_key
WHERE f.order_status IS NOT NULL;