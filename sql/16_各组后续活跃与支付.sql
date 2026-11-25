-- 在项目根目录的 PowerShell 中运行：
-- $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
-- Get-Content -LiteralPath 'sql/16_各组后续活跃与支付.sql' -Raw -Encoding utf8 | duckdb -no-agent -bail -csv

ATTACH '_local/meituan_analysis.duckdb' AS meituan_analysis;
SET threads = 4;
SET preserve_insertion_order = false;
SET VARIABLE followup_start = DATE '2023-04-01';
SET VARIABLE followup_end = DATE '2023-06-30';

-- 沿用第 15 步的用户 ID 和访问日期口径。两侧各自汇总至用户粒度。
CREATE TEMP TABLE user16_visits AS
WITH parsed AS (
    SELECT CASE WHEN upper(trim(User_id)) NOT IN ('', 'NULL') THEN User_id END AS user_id,
           try_strptime(trim(Visit_date), '%Y-%m-%d')::DATE AS visit_day
    FROM read_csv('_local/raw/06 美团业务选题-优惠券投放提效分析-数据3-user_visit_detail.csv',
                  header = true, delim = ',', all_varchar = true, ignore_errors = false)
)
SELECT user_id, count(DISTINCT visit_day) AS visit_days_q2
FROM parsed
WHERE user_id IS NOT NULL
  AND visit_day BETWEEN getvariable('followup_start') AND getvariable('followup_end')
GROUP BY user_id;

CREATE TEMP TABLE user16_payments AS
SELECT User_id AS user_id, count(*) AS order_count_q2, min(Pay_date) AS first_pay_date_q2
FROM meituan_analysis.main.orders_clean
WHERE User_id IS NOT NULL
  AND Pay_date BETWEEN getvariable('followup_start') AND getvariable('followup_end')
GROUP BY User_id;

BEGIN TRANSACTION;

CREATE OR REPLACE TABLE meituan_analysis.main.user_followup_2023q2 AS
SELECT baseline.User_id, baseline.group_order, baseline.baseline_group,
       coalesce(visits.visit_days_q2, 0) AS visit_days_q2,
       coalesce(payments.order_count_q2, 0) AS order_count_q2,
       payments.first_pay_date_q2
FROM meituan_analysis.main.user_profile_baseline AS baseline
LEFT JOIN user16_visits AS visits ON baseline.User_id = visits.user_id
LEFT JOIN user16_payments AS payments ON baseline.User_id = payments.user_id;

COMMIT;

CREATE TEMP VIEW user16_overview AS
WITH baseline AS (
    SELECT group_order, baseline_group, count(*) AS baseline_users
    FROM meituan_analysis.main.user_profile_baseline
    GROUP BY group_order, baseline_group
), followup AS (
    SELECT group_order, baseline_group, count(*) AS followup_users,
           count(*) FILTER (WHERE visit_days_q2 > 0) AS returned_users,
           count(*) FILTER (WHERE order_count_q2 > 0) AS paid_users
    FROM meituan_analysis.main.user_followup_2023q2
    GROUP BY group_order, baseline_group
)
SELECT baseline.*, coalesce(followup_users, 0) AS followup_users,
       coalesce(returned_users, 0) AS returned_users, coalesce(paid_users, 0) AS paid_users
FROM baseline LEFT JOIN followup USING (group_order, baseline_group);

SELECT 46711 AS "第15步基线总人数", count(*) AS "后续明细行数",
       count(DISTINCT User_id) AS "后续去重人数", count(*) - 46711 AS "行数差额",
       count(*) - count(User_id) AS "用户ID缺失数",
       count(User_id) - count(DISTINCT User_id) AS "重复用户超出行数"
FROM meituan_analysis.main.user_followup_2023q2;

SELECT baseline_group AS "基线分组", baseline_users AS "第15步分母人数",
       followup_users AS "后续明细人数", followup_users - baseline_users AS "分母差额"
FROM user16_overview
ORDER BY group_order;

CREATE TEMP VIEW user16_export AS
SELECT baseline_group AS "基线分组", baseline_users AS "基线人数",
       returned_users AS "回访人数",
       round(100.0 * returned_users / nullif(baseline_users, 0), 6)::DECIMAL(10, 6) AS "回访比例（%）",
       paid_users AS "支付人数",
       round(100.0 * paid_users / nullif(baseline_users, 0), 6)::DECIMAL(10, 6) AS "支付比例（%）"
FROM user16_overview
ORDER BY group_order;

COPY (SELECT * FROM user16_export) TO '数据清洗/16_各组后续活跃与支付.csv' (FORMAT CSV, HEADER true);
SELECT * FROM user16_export;
