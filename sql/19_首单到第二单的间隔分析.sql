-- 在项目根目录的 PowerShell 中运行：
-- $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
-- Get-Content -LiteralPath 'sql/19_首单到第二单的间隔分析.sql' -Raw -Encoding utf8 | duckdb -no-agent -bail -csv

ATTACH '_local/meituan_analysis.duckdb' AS meituan_analysis (READ_ONLY);
SET threads = 4;

-- 1–5 月的最早支付日落在 4–5 月，等价于一季度无订单且 4–5 月有订单。
CREATE TEMP TABLE repeat19_cohort AS
SELECT User_id, min(Pay_date) AS first_pay_day
FROM meituan_analysis.main.orders_clean
WHERE User_id IS NOT NULL AND Pay_date BETWEEN DATE '2023-01-01' AND DATE '2023-05-31'
GROUP BY User_id
HAVING min(Pay_date) >= DATE '2023-04-01';

CREATE TEMP TABLE repeat19_buckets AS
WITH second_payment AS (
    SELECT cohort.User_id,
           CASE WHEN count(orders.Order_id) FILTER (WHERE orders.Pay_date = cohort.first_pay_day) >= 2 THEN 0
                ELSE date_diff('day', cohort.first_pay_day,
                    min(orders.Pay_date) FILTER (WHERE orders.Pay_date > cohort.first_pay_day))
           END AS lag_days
    FROM repeat19_cohort AS cohort
    LEFT JOIN meituan_analysis.main.orders_clean AS orders
        ON cohort.User_id = orders.User_id
       AND orders.Pay_date BETWEEN cohort.first_pay_day AND cohort.first_pay_day + 30
    GROUP BY cohort.User_id, cohort.first_pay_day
)
SELECT User_id,
       CASE WHEN lag_days = 0 THEN 1
            WHEN lag_days BETWEEN 1 AND 3 THEN 2
            WHEN lag_days BETWEEN 4 AND 7 THEN 3
            WHEN lag_days BETWEEN 8 AND 14 THEN 4
            WHEN lag_days BETWEEN 15 AND 30 THEN 5
            ELSE 6 END AS bucket_order
FROM second_payment;

CREATE TEMP TABLE repeat19_export AS
WITH labels AS (
    SELECT * FROM (VALUES (1, '同日'), (2, '1–3 天'), (3, '4–7 天'), (4, '8–14 天'),
                          (5, '15–30 天'), (6, '30 天内未再支付')) AS ranges(bucket_order, bucket_name)
), bucket_counts AS (
    SELECT bucket_order, count(*) AS users
    FROM repeat19_buckets
    GROUP BY bucket_order
), distribution AS (
    SELECT labels.*, coalesce(bucket_counts.users, 0) AS users
    FROM labels LEFT JOIN bucket_counts USING (bucket_order)
), cumulative AS (
    SELECT *, sum(users) OVER () AS grouped_users,
           sum(users) OVER (ORDER BY bucket_order ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
               AS cumulative_users
    FROM distribution
), audit AS (
    SELECT (SELECT count(*) FROM repeat19_cohort) AS cohort_users,
           count(*) AS assigned_rows, count(DISTINCT User_id) AS assigned_users
    FROM repeat19_buckets
)
SELECT bucket_name AS "首单至第二单间隔", users AS "人数",
       round(100.0 * users / nullif(cohort_users, 0), 6)::DECIMAL(10, 6) AS "占全部入组用户比例（%）",
       CASE WHEN bucket_order < 6 THEN
           round(100.0 * cumulative_users / nullif(cohort_users, 0), 6)::DECIMAL(10, 6)
       END AS "截至区间末日累计再次支付比例（%）"
FROM cumulative CROSS JOIN audit
-- 仅核对本步区间归类。
WHERE CASE WHEN assigned_rows <> assigned_users THEN error('用户重复分入区间或用户 ID 缺失')
           WHEN assigned_users <> cohort_users OR grouped_users <> cohort_users
                THEN error('六组人数与入组人数不一致')
           ELSE true END
ORDER BY bucket_order;

COPY (SELECT * FROM repeat19_export) TO '数据清洗/19_首单到第二单的间隔分布.csv' (FORMAT CSV, HEADER true);
SELECT * FROM repeat19_export;
