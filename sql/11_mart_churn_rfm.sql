CREATE OR REPLACE VIEW `logistic-analytics-project.logistic_analytics_dataset.mart_churn_rfm` AS

WITH customer_rfm_raw AS (
  SELECT
    f.customer_id,
    DATE_DIFF(DATE('2026-07-30'), MAX(f.order_date_clean), DAY) AS recency_days,
    COUNT(DISTINCT f.order_id) AS frequency,
    SUM(f.sales) AS monetary,
    AVG(f.real_shipping_days - f.scheduled_days_for_shipment) AS avg_delivery_delay
  FROM `logistic-analytics-project.logistic_analytics_dataset.fact_order_item` f
  WHERE f.order_date_clean IS NOT NULL
    AND NOT f.is_quantity_invalid
  GROUP BY f.customer_id
),

scored AS (
  SELECT
    *,
    NTILE(5) OVER (ORDER BY recency_days DESC) AS r_score,  -- lower recency = more recent = higher score
    NTILE(5) OVER (ORDER BY frequency ASC) AS f_score,
    NTILE(5) OVER (ORDER BY monetary ASC) AS m_score
  FROM customer_rfm_raw
),

final AS (
  SELECT
    *,
    (r_score + f_score + m_score) AS rfm_score,
    CASE WHEN recency_days > 90 THEN TRUE ELSE FALSE END AS is_churned
  FROM scored
)

SELECT
  customer_id,
  recency_days,
  frequency,
  monetary,
  avg_delivery_delay,
  r_score, f_score, m_score, rfm_score,
  is_churned,
  CASE
    WHEN rfm_score >= 12 THEN 'Growing'
    WHEN rfm_score >= 9  THEN 'Stable'
    WHEN rfm_score >= 6  THEN 'At Risk'
    ELSE 'Lapsed'
  END AS segment
FROM final;