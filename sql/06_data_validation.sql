-- 1. Row counts should match: fact_order_item = stg_orders_final
SELECT
  (SELECT COUNT(*) FROM `logistic-analytics-project.logistic_analytics_dataset.stg_orders_final`) AS staging_rows,
  (SELECT COUNT(*) FROM `logistic-analytics-project.logistic_analytics_dataset.fact_order_item`) AS fact_rows;

-- 2. Referential integrity: every customer_id in fact should exist in dim_customer
SELECT COUNT(*) AS orphaned_customer_rows
FROM `logistic-analytics-project.logistic_analytics_dataset.fact_order_item` f
LEFT JOIN `logistic-analytics-project.logistic_analytics_dataset.dim_customer` c
  ON f.customer_id = c.customer_id
WHERE c.customer_id IS NULL;

-- 3. Referential integrity: every product_card_id in fact should exist in dim_product
SELECT COUNT(*) AS orphaned_product_rows
FROM `logistic-analytics-project.logistic_analytics_dataset.fact_order_item` f
LEFT JOIN `logistic-analytics-project.logistic_analytics_dataset.dim_product` p
  ON f.product_card_id = p.product_card_id
WHERE p.product_card_id IS NULL;

-- 4. Referential integrity: every non-null order_date_key should exist in dim_date
SELECT COUNT(*) AS orphaned_date_rows
FROM `logistic-analytics-project.logistic_analytics_dataset.fact_order_item` f
LEFT JOIN `logistic-analytics-project.logistic_analytics_dataset.dim_date` d
  ON f.order_date_key = d.date_key
WHERE f.order_date_key IS NOT NULL AND d.date_key IS NULL;

-- 5. dim_customer / dim_product row counts (should equal distinct counts in fact)
SELECT
  (SELECT COUNT(*) FROM `logistic-analytics-project.logistic_analytics_dataset.dim_customer`) AS dim_customer_rows,
  (SELECT COUNT(DISTINCT customer_id) FROM `logistic-analytics-project.logistic_analytics_dataset.fact_order_item`) AS distinct_customers_in_fact,
  (SELECT COUNT(*) FROM `logistic-analytics-project.logistic_analytics_dataset.dim_product`) AS dim_product_rows,
  (SELECT COUNT(DISTINCT product_card_id) FROM `logistic-analytics-project.logistic_analytics_dataset.fact_order_item`) AS distinct_products_in_fact;
