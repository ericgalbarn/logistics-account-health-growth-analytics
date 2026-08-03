-- 1. Segment distribution — check it's not wildly lopsided
SELECT segment, COUNT(*) AS customer_count, ROUND(AVG(monetary),2) AS avg_monetary
FROM `logistic-analytics-project.logistic_analytics_dataset.mart_churn_rfm`
GROUP BY segment
ORDER BY avg_monetary DESC;

-- 2. Cross-check: does the RFM-based segment broadly agree with the simple 90-day churn flag?
SELECT segment, is_churned, COUNT(*) AS cnt
FROM `logistic-analytics-project.logistic_analytics_dataset.mart_churn_rfm`
GROUP BY segment, is_churned
ORDER BY segment, is_churned;