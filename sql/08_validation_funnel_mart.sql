-- 1. Funnel stage counts overall (this is your headline funnel chart data)
SELECT
  COUNT(DISTINCT CASE WHEN is_placed THEN order_id END) AS orders_placed,
  COUNT(DISTINCT CASE WHEN is_shipped THEN order_id END) AS orders_shipped,
  COUNT(DISTINCT CASE WHEN is_delivered THEN order_id END) AS orders_delivered,
  COUNT(DISTINCT CASE WHEN is_delivered_on_time THEN order_id END) AS orders_delivered_on_time
FROM `logistic-analytics-project.logistic_analytics_dataset.mart_funnel`;

-- 2. Late-delivery rate by shipping mode (spot the "Mode X has 3x rate" finding)
SELECT
  shipping_mode,
  COUNT(*) AS total_rows,
  SUM(late_delivery_risk) AS late_count,
  ROUND(SUM(late_delivery_risk) / COUNT(*) * 100, 2) AS late_rate_pct
FROM `logistic-analytics-project.logistic_analytics_dataset.mart_funnel`
WHERE shipping_mode IS NOT NULL AND late_delivery_risk IS NOT NULL
GROUP BY shipping_mode
ORDER BY late_rate_pct DESC;

-- 3. Late-delivery rate by region (same idea, different dimension)
SELECT
  order_region,
  COUNT(*) AS total_rows,
  SUM(late_delivery_risk) AS late_count,
  ROUND(SUM(late_delivery_risk) / COUNT(*) * 100, 2) AS late_rate_pct
FROM `logistic-analytics-project.logistic_analytics_dataset.mart_funnel`
WHERE order_region IS NOT NULL AND late_delivery_risk IS NOT NULL
GROUP BY order_region
ORDER BY late_rate_pct DESC;