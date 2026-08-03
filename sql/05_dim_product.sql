CREATE OR REPLACE TABLE `logistic-analytics-project.logistic_analytics_dataset.dim_product` AS

SELECT
  product_card_id,
  ANY_VALUE(category_id) AS category_id,
  ANY_VALUE(category_name) AS category_name,
  ANY_VALUE(department_id) AS department_id,
  ANY_VALUE(department_name) AS department_name,
  ANY_VALUE(product_name) AS product_name,
  ANY_VALUE(product_price) AS product_price,
  ANY_VALUE(product_status) AS product_status
FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_final`
GROUP BY product_card_id;