CREATE OR REPLACE TABLE `logistic-analytics-project.logistic_analytics_dataset.dim_customer` AS

SELECT
  customer_id,
  ANY_VALUE(customer_fname) AS customer_fname,
  ANY_VALUE(customer_lname) AS customer_lname,
  -- most recent non-null segment value per customer, in case it varies row to row
  ARRAY_AGG(customer_segment_clean IGNORE NULLS ORDER BY order_date_clean DESC LIMIT 1)[SAFE_OFFSET(0)] AS customer_segment,
  ANY_VALUE(customer_city) AS customer_city,
  ANY_VALUE(customer_state) AS customer_state,
  ANY_VALUE(customer_country) AS customer_country
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_final`
GROUP BY customer_id;