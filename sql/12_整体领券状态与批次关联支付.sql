-- 在项目根目录的 PowerShell 中运行：
-- $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
-- Get-Content -LiteralPath 'sql/12_整体领券状态与批次关联支付.sql' -Raw -Encoding utf8 | duckdb -no-agent -bail -csv
-- 全量状态保留非缺失原始编码。SQL 另行输出筛选排除、样本闭合和连接对账。

ATTACH '_local/meituan_analysis.duckdb' AS meituan_analysis;

SET threads = 4;
SET preserve_insertion_order = false;
SET VARIABLE coupon12_start = DATE '2023-01-01';
SET VARIABLE coupon12_end = DATE '2023-06-30';
SET VARIABLE coupon12_cutoff = getvariable('coupon12_end') - 7;

CREATE OR REPLACE TEMP MACRO coupon12_text(raw_value) AS
    CASE WHEN upper(trim(raw_value)) NOT IN ('', 'NULL') THEN raw_value END;

CREATE OR REPLACE TEMP TABLE coupon12_receipts AS
WITH cleaned AS (
    SELECT coupon12_text(User_id) AS user_key,
           coupon12_text(Coupon_id) AS coupon_key,
           coupon12_text(Coupon_status) AS status_code,
           coupon12_text(Receive_date) AS receive_text,
           coupon12_text(End_date) AS end_text
    FROM read_csv('_local/raw/06 美团业务选题-优惠券投放提效分析-数据2-user_coupon_receive.csv',
                  header = true, delim = ',', all_varchar = true, ignore_errors = false)
), parsed AS (
    SELECT *, try_strptime(trim(receive_text), '%Y-%m-%d')::DATE AS receive_day,
              try_strptime(trim(end_text), '%Y-%m-%d')::DATE AS end_day
    FROM cleaned
)
SELECT user_key, coupon_key, status_code, date_trunc('month', receive_day)::DATE AS month_start,
       CASE WHEN receive_text IS NULL OR end_text IS NULL THEN '缺日期'
            WHEN receive_day IS NULL OR end_day IS NULL OR receive_day > end_day
              OR receive_day NOT BETWEEN getvariable('coupon12_start') AND getvariable('coupon12_end')
                THEN '日期异常'
            WHEN receive_day > getvariable('coupon12_cutoff') THEN '观察时间不足'
            ELSE '符合观察条件' END AS eligibility
FROM parsed;

CREATE OR REPLACE TEMP TABLE coupon12_cohort_checks AS
WITH eligible AS MATERIALIZED (
    SELECT month_start, user_key, coupon_key
    FROM coupon12_receipts
    WHERE eligibility = '符合观察条件'
), before_join AS (
    SELECT month_start, count(*) AS eligible_coupons, count(DISTINCT coupon_key) AS distinct_eligible_coupons
    FROM eligible
    GROUP BY month_start
), after_join AS (
    SELECT receipts.month_start, count(*) AS joined_rows,
           count(DISTINCT receipts.coupon_key) FILTER (WHERE detail.lag_days BETWEEN 0 AND 7)
               AS verified_payment_coupons
    FROM eligible AS receipts
    LEFT JOIN meituan_analysis.main.coupon_pay_lag_detail AS detail
        ON receipts.user_key = detail.User_id AND receipts.coupon_key = detail.Coupon_id
    GROUP BY receipts.month_start
), months AS (
    SELECT d::DATE AS month_start
    FROM generate_series(getvariable('coupon12_start'), getvariable('coupon12_end'), INTERVAL 1 MONTH) AS m(d)
)
SELECT months.month_start, coalesce(before_join.eligible_coupons, 0) AS eligible_coupons,
       coalesce(before_join.distinct_eligible_coupons, 0) AS distinct_eligible_coupons,
       coalesce(after_join.joined_rows, 0) AS joined_rows,
       coalesce(after_join.verified_payment_coupons, 0) AS verified_payment_coupons
FROM months LEFT JOIN before_join USING (month_start) LEFT JOIN after_join USING (month_start);

BEGIN TRANSACTION;

CREATE OR REPLACE TABLE meituan_analysis.main.coupon_status_overview AS
WITH grouped AS (
    SELECT status_code, count(*) AS coupon_count
    FROM coupon12_receipts
    GROUP BY status_code
), totals AS (
    SELECT *, (sum(coupon_count) OVER ())::BIGINT AS total_coupons
    FROM grouped
)
SELECT *, coupon_count::DOUBLE / nullif(total_coupons, 0) AS status_share
FROM totals;

CREATE OR REPLACE TABLE meituan_analysis.main.coupon_receive_cohort_monthly AS
SELECT month_start, least(last_day(month_start), getvariable('coupon12_cutoff')) AS receive_window_end,
       eligible_coupons, verified_payment_coupons,
       verified_payment_coupons::DOUBLE / nullif(eligible_coupons, 0) AS verified_payment_share_0_7
FROM coupon12_cohort_checks;

COMMIT;

CREATE OR REPLACE TEMP VIEW coupon12_status_export AS
SELECT coalesce(status_code, '（缺失）') AS "原始状态码", coupon_count AS "券数",
       total_coupons AS "全量领券数",
       round(100 * status_share, 6)::DECIMAL(10, 6) AS "占全量比例（%）"
FROM meituan_analysis.main.coupon_status_overview
ORDER BY status_code NULLS LAST;

CREATE OR REPLACE TEMP VIEW coupon12_cohort_export AS
SELECT strftime(month_start, '%Y-%m') AS "领券月份",
       month_start AS "领券窗口起日", receive_window_end AS "领券窗口止日",
       eligible_coupons AS "符合观察条件的领券数",
       verified_payment_coupons AS "领券当天至第 7 天可核验关联支付券数",
       round(100 * verified_payment_share_0_7, 6)::DECIMAL(10, 6)
           AS "领券当天至第 7 天可核验关联支付占比（%）"
FROM meituan_analysis.main.coupon_receive_cohort_monthly
ORDER BY month_start;

COPY (SELECT * FROM coupon12_status_export) TO '数据清洗/12_整体领券状态.csv' (FORMAT CSV, HEADER true);
COPY (SELECT * FROM coupon12_cohort_export) TO '数据清洗/12_领券批次关联支付.csv' (FORMAT CSV, HEADER true);

SELECT * FROM coupon12_status_export;
SELECT * FROM coupon12_cohort_export;

-- 互斥判定顺序：必需日期缺失、日期异常、观察时间不足。
WITH grouped AS (
    SELECT eligibility, count(*) AS coupon_count
    FROM coupon12_receipts
    GROUP BY eligibility
)
SELECT reasons.reason AS "样本筛选结果", coalesce(grouped.coupon_count, 0) AS "券数"
FROM (VALUES (1, '缺日期'), (2, '日期异常'), (3, '观察时间不足'), (4, '符合观察条件')) AS reasons(sort_key, reason)
LEFT JOIN grouped ON reasons.reason = grouped.eligibility
ORDER BY reasons.sort_key;

SELECT strftime(month_start, '%Y-%m') AS "领券月份",
       eligible_coupons AS "连接前券数", distinct_eligible_coupons AS "连接前去重券数", joined_rows AS "连接后行数",
       joined_rows - eligible_coupons AS "连接差额", eligible_coupons - distinct_eligible_coupons AS "非唯一券数差额"
FROM coupon12_cohort_checks
ORDER BY month_start;

SELECT (SELECT sum(coupon_count) FROM meituan_analysis.main.coupon_status_overview) AS "状态分组合计",
       (SELECT sum(coupon_count) FROM meituan_analysis.main.coupon_status_overview) - 12693100 AS "状态对账差额",
       sum(eligible_coupons) AS "连接前券数", sum(joined_rows) AS "连接后行数",
       sum(verified_payment_coupons) AS "第0–7天可核验关联支付券数"
FROM coupon12_cohort_checks;
