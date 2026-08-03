CREATE OR REPLACE VIEW `logistic-analytics-project.logistic_analytics_dataset.mart_ltv` AS

WITH customer_region_counts AS (
  -- Count orders per customer per region, to find their dominant region
  SELECT
    customer_id,
    order_region,
    COUNT(DISTINCT order_id) AS region_order_count,
    MAX(order_date_clean) AS latest_order_in_region
  FROM `logistic-analytics-project.logistic_analytics_dataset.fact_order_item`
  WHERE order_region IS NOT NULL AND order_date_clean IS NOT NULL
  GROUP BY customer_id, order_region
),

customer_dominant_region AS (
  -- Pick the region with the most orders per customer; ties broken by most recent
  SELECT customer_id, order_region AS dominant_region
  FROM (
    SELECT
      customer_id,
      order_region,
      ROW_NUMBER() OVER (
        PARTITION BY customer_id
        ORDER BY region_order_count DESC, latest_order_in_region DESC
      ) AS rn
    FROM customer_region_counts
  )
  WHERE rn = 1
),

customer_market AS (
  -- Same "most common" logic for market
  SELECT customer_id, market AS dominant_market
  FROM (
    SELECT
      customer_id,
      market,
      COUNT(DISTINCT order_id) AS market_order_count,
      MAX(order_date_clean) AS latest_order_in_market,
      ROW_NUMBER() OVER (
        PARTITION BY customer_id
        ORDER BY COUNT(DISTINCT order_id) DESC, MAX(order_date_clean) DESC
      ) AS rn
    FROM `logistic-analytics-project.logistic_analytics_dataset.fact_order_item`
    WHERE market IS NOT NULL AND order_date_clean IS NOT NULL
    GROUP BY customer_id, market
  )
  WHERE rn = 1
),

customer_ltv_base AS (
  SELECT
    f.customer_id,
    SUM(f.sales) AS historical_ltv,
    COUNT(DISTINCT f.order_id) AS total_orders,
    MIN(f.order_date_clean) AS first_order_date,
    MAX(f.order_date_clean) AS last_order_date,
    -- Customer lifespan in months (minimum 1, to avoid divide-by-zero for single-month customers)
    GREATEST(DATE_DIFF(MAX(f.order_date_clean), MIN(f.order_date_clean), MONTH) + 1, 1) AS lifespan_months
  FROM `logistic-analytics-project.logistic_analytics_dataset.fact_order_item` f
  WHERE f.order_date_clean IS NOT NULL
    AND NOT f.is_quantity_invalid
  GROUP BY f.customer_id
),

formula_ltv AS (
  SELECT
    *,
    ROUND(historical_ltv / total_orders, 2) AS avg_order_value,
    ROUND(total_orders / lifespan_months, 3) AS purchase_frequency_per_month,
    ROUND((historical_ltv / total_orders) * (total_orders / lifespan_months) * lifespan_months, 2) AS formula_based_ltv
  FROM customer_ltv_base
)

SELECT
  l.customer_id,
  c.customer_segment,
  r.dominant_region,
  m.dominant_market,
  l.historical_ltv,
  l.formula_based_ltv,
  l.avg_order_value,
  l.total_orders,
  l.lifespan_months,
  l.first_order_date,
  l.last_order_date
FROM formula_ltv l
LEFT JOIN `logistic-analytics-project.logistic_analytics_dataset.dim_customer` c
  ON l.customer_id = c.customer_id
LEFT JOIN customer_dominant_region r
  ON l.customer_id = r.customer_id
LEFT JOIN customer_market m
  ON l.customer_id = m.customer_id;