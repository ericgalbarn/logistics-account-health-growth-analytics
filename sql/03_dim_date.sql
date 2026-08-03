CREATE OR REPLACE TABLE `logistic-analytics-project.logistic_analytics_dataset.dim_date` AS

WITH date_range AS (
  SELECT
    date_val AS full_date
  FROM UNNEST(
    GENERATE_DATE_ARRAY('2024-01-01', '2026-12-31', INTERVAL 1 DAY)
  ) AS date_val
)

SELECT
  CAST(FORMAT_DATE('%Y%m%d', full_date) AS INT64) AS date_key,
  full_date,
  EXTRACT(YEAR FROM full_date) AS year,
  EXTRACT(MONTH FROM full_date) AS month,
  FORMAT_DATE('%B', full_date) AS month_name,
  EXTRACT(QUARTER FROM full_date) AS quarter,
  EXTRACT(DAYOFWEEK FROM full_date) AS day_of_week,
  FORMAT_DATE('%A', full_date) AS day_name,
  CASE WHEN EXTRACT(DAYOFWEEK FROM full_date) IN (1, 7) THEN TRUE ELSE FALSE END AS is_weekend,
  DATE_TRUNC(full_date, MONTH) AS month_start
FROM date_range;
