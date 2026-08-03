SELECT cohort_month, month_index, active_customers, cohort_size, retention_pct
FROM `logistic-analytics-project.logistic_analytics_dataset.mart_cohort`
WHERE cohort_month = '2024-01-01'
ORDER BY month_index;