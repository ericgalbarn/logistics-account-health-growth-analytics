CREATE OR REPLACE VIEW `logistic-analytics-project.logistic_analytics_dataset.mart_cohort` AS

WITH customer_orders AS (
  SELECT
    f.customer_id,
    f.order_id,
    f.order_date_clean,
    MIN(f.order_date_clean) OVER (PARTITION BY f.customer_id) AS cohort_month_raw
  FROM `logistic-analytics-project.logistic_analytics_dataset.fact_order_item` f
  WHERE f.order_date_clean IS NOT NULL
),

with_cohort AS (
  SELECT
    customer_id,
    order_id,
    DATE_TRUNC(cohort_month_raw, MONTH) AS cohort_month,
    DATE_TRUNC(order_date_clean, MONTH) AS order_month
  FROM customer_orders
),

with_month_index AS (
  SELECT
    customer_id,
    cohort_month,
    DATE_DIFF(order_month, cohort_month, MONTH) AS month_index
  FROM with_cohort
),

cohort_activity AS (
  SELECT
    cohort_month,
    month_index,
    COUNT(DISTINCT customer_id) AS active_customers
  FROM with_month_index
  GROUP BY cohort_month, month_index
),

cohort_sizes AS (
  SELECT cohort_month, active_customers AS cohort_size
  FROM cohort_activity
  WHERE month_index = 0
)

SELECT
  a.cohort_month,
  a.month_index,
  a.active_customers,
  s.cohort_size,
  ROUND(a.active_customers / s.cohort_size * 100, 2) AS retention_pct
FROM cohort_activity a
JOIN cohort_sizes s
  ON a.cohort_month = s.cohort_month
WHERE DATE_ADD(a.cohort_month, INTERVAL a.month_index MONTH) <= DATE_SUB('2026-07-30', INTERVAL 1 MONTH)
ORDER BY a.cohort_month, a.month_index;