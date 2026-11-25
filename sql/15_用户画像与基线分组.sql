-- 在项目根目录的 PowerShell 中运行：
-- $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
-- Get-Content -LiteralPath 'sql/15_用户画像与基线分组.sql' -Raw -Encoding utf8 | duckdb -no-agent -bail -csv

ATTACH '_local/meituan_analysis.duckdb' AS meituan_analysis;
SET threads = 4;
SET preserve_insertion_order = false;
SET VARIABLE baseline_start = DATE '2023-01-01';
SET VARIABLE baseline_end = DATE '2023-03-31';

-- 沿用第 09 步的用户 ID 缺失和访问日期解析口径。
CREATE TEMP TABLE user15_visits AS
WITH parsed AS (
    SELECT CASE WHEN upper(trim(User_id)) NOT IN ('', 'NULL') THEN User_id END AS user_id,
           try_strptime(trim(Visit_date), '%Y-%m-%d')::DATE AS visit_day
    FROM read_csv('_local/raw/06 美团业务选题-优惠券投放提效分析-数据3-user_visit_detail.csv',
                  header = true, delim = ',', all_varchar = true, ignore_errors = false)
)
SELECT user_id, count(DISTINCT visit_day) AS visit_days
FROM parsed
WHERE user_id IS NOT NULL
  AND visit_day BETWEEN getvariable('baseline_start') AND getvariable('baseline_end')
GROUP BY user_id;

-- 历史支付覆盖全部业务线。orders_clean 已是一笔订单一行。
CREATE TEMP TABLE user15_payments AS
SELECT User_id AS user_id, count(*) AS order_count, sum(Actual_pay) AS paid_amount,
       count(*) FILTER (WHERE has_coupon_id) AS coupon_order_count
FROM meituan_analysis.main.orders_clean
WHERE User_id IS NOT NULL
  AND Pay_date BETWEEN getvariable('baseline_start') AND getvariable('baseline_end')
GROUP BY User_id;

CREATE TEMP TABLE user15_profiles AS
SELECT user_id, coalesce(visits.visit_days, 0) AS visit_days,
       coalesce(payments.order_count, 0) AS order_count,
       coalesce(payments.paid_amount, 0) AS paid_amount,
       coalesce(payments.coupon_order_count, 0) AS coupon_order_count,
       payments.coupon_order_count::DOUBLE / nullif(payments.order_count, 0) AS coupon_order_share
FROM user15_visits AS visits
FULL JOIN user15_payments AS payments USING (user_id);

CREATE TEMP TABLE user15_cutoff AS
SELECT median(visit_days) AS frequent_visit_cutoff
FROM user15_profiles
WHERE order_count = 0 AND visit_days > 0;

CREATE TEMP TABLE user15_group_names AS
SELECT * FROM (VALUES (1, '常访问、尚未支付'), (2, '其他未支付'),
                      (3, '仅支付一次'), (4, '已多次支付')) AS groups(group_order, baseline_group);

BEGIN TRANSACTION;

CREATE OR REPLACE TABLE meituan_analysis.main.user_profile_baseline AS
WITH assigned AS (
    SELECT profiles.*,
           CASE WHEN order_count = 0 AND visit_days >= frequent_visit_cutoff THEN 1
                WHEN order_count = 0 THEN 2
                WHEN order_count = 1 THEN 3
                ELSE 4 END AS group_order
    FROM user15_profiles AS profiles CROSS JOIN user15_cutoff
)
SELECT assigned.user_id AS User_id, visit_days, order_count, paid_amount,
       coupon_order_count, coupon_order_share, group_order, groups.baseline_group
FROM assigned JOIN user15_group_names AS groups USING (group_order);

COMMIT;

CREATE TEMP VIEW user15_overview AS
WITH typical AS (
    SELECT group_order, count(*) AS users,
           median(visit_days) AS median_visits, median(order_count) AS median_orders,
           median(paid_amount::DECIMAL(38, 5)) AS median_paid,
           median(coupon_order_share) AS median_coupon_share
    FROM meituan_analysis.main.user_profile_baseline
    GROUP BY group_order
)
SELECT groups.group_order, groups.baseline_group, coalesce(typical.users, 0) AS users,
       100.0 * coalesce(typical.users, 0) / nullif(sum(typical.users) OVER (), 0) AS user_share_pct,
       median_visits, median_orders, median_paid, median_coupon_share
FROM user15_group_names AS groups LEFT JOIN typical USING (group_order);

-- 核对每人一行、四组覆盖全部基线用户。基准在两侧的用户汇总上独立求并集。
WITH baseline_users AS (
    SELECT user_id FROM user15_visits
    UNION
    SELECT user_id FROM user15_payments
), profile_counts AS (
    SELECT count(*) AS detail_rows, count(DISTINCT User_id) AS detail_users,
           count(*) FILTER (WHERE User_id IS NULL) AS missing_ids
    FROM meituan_analysis.main.user_profile_baseline
), totals AS (
    SELECT *, (SELECT count(*) FROM baseline_users) AS union_users,
           (SELECT sum(users)::BIGINT FROM user15_overview) AS grouped_users
    FROM profile_counts
)
SELECT frequent_visit_cutoff AS "常访问门槛（天）", union_users AS "基线访问或支付去重人数",
       detail_rows AS "明细行数", detail_users AS "明细去重人数", missing_ids AS "缺失用户ID数",
       detail_rows - detail_users - missing_ids AS "重复用户超出行数",
       grouped_users AS "四组人数合计", grouped_users - union_users AS "四组合计较并集差额"
FROM totals CROSS JOIN user15_cutoff;

CREATE TEMP VIEW user15_export AS
SELECT baseline_group AS "基线分组", users AS "人数",
       round(user_share_pct, 6)::DECIMAL(10, 6) AS "人数占比（%）",
       median_visits AS "访问天数中位数", median_orders AS "订单数中位数",
       median_paid AS "实付金额中位数（原表单位）",
       round(100 * median_coupon_share, 6)::DECIMAL(10, 6) AS "有券记录订单占比中位数（%）"
FROM user15_overview
ORDER BY group_order;

COPY (SELECT * FROM user15_export) TO '数据清洗/15_用户分组概览.csv' (FORMAT CSV, HEADER true);
SELECT * FROM user15_export;
