-- 在项目根目录的 PowerShell 中运行：
-- $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
-- Get-Content -LiteralPath 'sql/11_领券至关联支付时滞.sql' -Raw -Encoding utf8 | duckdb -no-agent -bail -csv
-- 复用第 03 步的文本 ID、缺失值、日期解析和同笔订单支付日规则。
-- 脚本更新明细表与分布表，仅导出汇总 CSV，终端输出筛选对账及关键比例。

ATTACH '_local/meituan_analysis.duckdb' AS meituan_analysis;

SET threads = 4;
SET preserve_insertion_order = false;

CREATE OR REPLACE TEMP MACRO lag11_text(raw_value) AS
    CASE WHEN upper(trim(raw_value)) NOT IN ('', 'NULL') THEN raw_value END;

CREATE OR REPLACE TEMP MACRO lag11_date(raw_value) AS
    try_strptime(trim(lag11_text(raw_value)), '%Y-%m-%d')::DATE;

CREATE OR REPLACE TEMP TABLE lag11_order_rows AS
SELECT lag11_text(Order_id) AS order_key,
       lag11_text(User_id) AS user_key,
       lag11_text(Coupon_id) AS coupon_key,
       lag11_date(Pay_date) AS pay_day
FROM read_csv('_local/raw/06 美团业务选题-优惠券投放提效分析-数据1-order_detail.csv',
              header = true, delim = ',', all_varchar = true, ignore_errors = false);

-- 订单明细可能多行。用不同订单号计数，支付日取全单唯一的非缺失有效值。
CREATE OR REPLACE TEMP TABLE lag11_single_pairs AS
WITH pairs AS (
    SELECT user_key, coupon_key, min(order_key) AS order_key
    FROM lag11_order_rows
    WHERE user_key IS NOT NULL AND coupon_key IS NOT NULL
    GROUP BY user_key, coupon_key
    HAVING count(DISTINCT order_key) = 1
), orders AS (
    SELECT order_key, CASE WHEN min(pay_day) = max(pay_day) THEN min(pay_day) END AS pay_day
    FROM lag11_order_rows
    WHERE order_key IS NOT NULL
    GROUP BY order_key
)
SELECT pairs.*, orders.pay_day
FROM pairs JOIN orders USING (order_key);

CREATE OR REPLACE TEMP TABLE lag11_screened AS
WITH receipts AS (
    SELECT lag11_text(User_id) AS user_key,
           lag11_text(Coupon_id) AS coupon_key,
           lag11_text(Coupon_status) AS status_code,
           lag11_date(Receive_date) AS receive_day,
           lag11_date(Start_date) AS start_day,
           lag11_date(End_date) AS end_day
    FROM read_csv('_local/raw/06 美团业务选题-优惠券投放提效分析-数据2-user_coupon_receive.csv',
                  header = true, delim = ',', all_varchar = true, ignore_errors = false)
)
SELECT receipts.user_key, receipts.coupon_key, pairs.order_key, receipts.status_code,
       receipts.receive_day, pairs.pay_day,
       CASE WHEN receive_day IS NULL OR pay_day IS NULL OR start_day IS NULL OR end_day IS NULL
                THEN '日期缺失或无法解析'
            WHEN pay_day < receive_day THEN '支付早于领券'
            WHEN pay_day NOT BETWEEN start_day AND end_day THEN '支付不在有效期内'
            ELSE '候选' END AS screening_result
FROM receipts JOIN lag11_single_pairs AS pairs USING (user_key, coupon_key);

BEGIN TRANSACTION;

CREATE OR REPLACE TABLE meituan_analysis.main.coupon_pay_lag_detail AS
SELECT user_key AS User_id, coupon_key AS Coupon_id, order_key AS Order_id,
       receive_day AS Receive_date, pay_day AS Pay_date, status_code AS Coupon_status,
       date_diff('day', receive_day, pay_day) AS lag_days
FROM lag11_screened
WHERE screening_result = '候选';

CREATE OR REPLACE TABLE meituan_analysis.main.coupon_pay_lag_summary AS
WITH buckets (bucket_order, lag_bucket) AS (
    VALUES (0, '第 0 天'), (1, '第 1 天'), (2, '第 2 天'), (3, '第 3 天'),
           (4, '第 4 天'), (5, '第 5 天'), (6, '第 6 天'), (7, '第 7 天'),
           (8, '第 8–14 天'), (9, '第 15 天及以上')
), bucket_counts AS (
    SELECT CASE WHEN lag_days <= 7 THEN lag_days WHEN lag_days <= 14 THEN 8 ELSE 9 END AS bucket_order,
           count(*) AS all_coupons, count(*) FILTER (WHERE Coupon_status = '2') AS status_2_coupons
    FROM meituan_analysis.main.coupon_pay_lag_detail
    GROUP BY bucket_order
), counts AS (
    SELECT buckets.*, group_order, sample_group, coalesce(coupon_count, 0) AS coupon_count
    FROM buckets LEFT JOIN bucket_counts USING (bucket_order)
    CROSS JOIN LATERAL (VALUES
        (1, '全部候选', all_coupons),
        (2, '原始状态码 = 2', status_2_coupons)
    ) AS samples(group_order, sample_group, coupon_count)
), totals AS (
    SELECT *, (sum(coupon_count) OVER (PARTITION BY group_order))::BIGINT AS sample_size
    FROM counts
)
SELECT group_order, sample_group, bucket_order, lag_bucket, coupon_count, sample_size,
       coupon_count::DOUBLE / nullif(sample_size, 0) AS coupon_share
FROM totals;

COMMIT;

CREATE OR REPLACE TEMP VIEW lag11_export AS
SELECT sample_group AS "样本组", bucket_order AS "图表排序号", lag_bucket AS "领券至关联支付时滞",
       coupon_count AS "券数", sample_size AS "本组候选券数",
       round(100 * coupon_share, 6)::DECIMAL(10, 6) AS "占本组比例（%）"
FROM meituan_analysis.main.coupon_pay_lag_summary
ORDER BY group_order, bucket_order;

COPY (SELECT * FROM lag11_export) TO '数据清洗/11_领券至关联支付时滞.csv' (FORMAT CSV, HEADER true);
SELECT * FROM lag11_export;

-- 逐级对照第 03 步的样本规模。排除原因按上述 CASE 依次归类。
WITH screened AS (
    SELECT count(*) AS single_match,
           count(*) FILTER (WHERE screening_result = '日期缺失或无法解析') AS invalid_dates,
           count(*) FILTER (WHERE screening_result = '支付早于领券') AS early_payment,
           count(*) FILTER (WHERE screening_result = '支付不在有效期内') AS outside_window
    FROM lag11_screened
), detail AS (
    SELECT count(*) AS candidates, count(*) FILTER (WHERE lag_days = 0) AS day_zero,
           count(*) FILTER (WHERE Coupon_status = '2') AS status_2,
           count(*) - count(DISTINCT Coupon_id) AS duplicate_coupons
    FROM meituan_analysis.main.coupon_pay_lag_detail
)
SELECT item AS "对账项目", actual AS "本步券数", reference AS "对账基准",
       actual - reference AS "差额", CASE WHEN actual = reference THEN '通过' ELSE '差异' END AS "结果"
FROM screened CROSS JOIN detail
CROSS JOIN LATERAL (VALUES
    (1, '仅匹配一笔订单', single_match, 592820),
    (2, '日期缺失或无法解析', invalid_dates, 7047),
    (3, '支付早于领券', early_payment, 0),
    (4, '支付不在有效期内', outside_window, 0),
    (5, '全部候选', candidates, 585773),
    (6, '第 0 天候选', day_zero, 439387),
    (7, '原始状态码 = 2 候选', status_2, 575774),
    (8, '候选明细重复券 ID 超出数', duplicate_coupons, 0)
) AS checks(sort_key, item, actual, reference)
ORDER BY sort_key;

SELECT sample_group AS "样本组", sample_size AS "本组候选券数",
       sum(coupon_count) AS "分布券数合计", sum(coupon_count) - sample_size AS "合计差额",
       sum(coupon_count) FILTER (WHERE bucket_order = 0) AS "当日券数",
       round(100 * sum(coupon_count) FILTER (WHERE bucket_order = 0) / nullif(sample_size, 0), 6) AS "当日占比（%）",
       sum(coupon_count) FILTER (WHERE bucket_order <= 7) AS "第0–7天累计券数",
       round(100 * sum(coupon_count) FILTER (WHERE bucket_order <= 7) / nullif(sample_size, 0), 6) AS "第0–7天累计占比（%）"
FROM meituan_analysis.main.coupon_pay_lag_summary
GROUP BY group_order, sample_group, sample_size
ORDER BY group_order;
