-- 1. LTV by customer_segment (this is your headline Module 4 chart)
SELECT
  customer_segment,
  COUNT(*) AS customer_count,
  ROUND(AVG(historical_ltv), 2) AS avg_historical_ltv,
  ROUND(AVG(formula_based_ltv), 2) AS avg_formula_ltv
FROM `logistic-analytics-project.logistic_analytics_dataset.mart_ltv`
GROUP BY customer_segment
ORDER BY avg_historical_ltv DESC;

-- 2. LTV by dominant region (spot the "reallocation opportunity" finding)
SELECT
  dominant_region,
  COUNT(*) AS customer_count,
  ROUND(AVG(historical_ltv), 2) AS avg_historical_ltv
FROM `logistic-analytics-project.logistic_analytics_dataset.mart_ltv`
GROUP BY dominant_region
ORDER BY avg_historical_ltv DESC;

-- 3. Sanity check: historical_ltv vs formula_based_ltv should track closely
-- (they're mathematically near-identical by construction, so this mainly
-- confirms no calculation error)
SELECT
  ROUND(CORR(historical_ltv, formula_based_ltv), 4) AS correlation,
  COUNTIF(ABS(historical_ltv - formula_based_ltv) > 1) AS mismatch_count
FROM `logistic-analytics-project.logistic_analytics_dataset.mart_ltv`;