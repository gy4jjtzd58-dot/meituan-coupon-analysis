-- 在项目根目录的 PowerShell 中运行：
-- $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
-- Get-Content -LiteralPath 'sql/16_分层后续表现.sql' -Raw -Encoding utf8 | duckdb -no-agent -bail -csv

ATTACH '_local/meituan_analysis.duckdb' AS meituan_analysis (READ_ONLY);
SET threads = 4;
SET preserve_insertion_order = false;
SET VARIABLE followup_start = DATE '2023-04-01';
SET VARIABLE followup_end = DATE '2023-06-30';

CREATE TEMP VIEW segment16_users AS
SELECT User_id AS user_id, segment_order, segment_name
FROM meituan_analysis.main.user_profile_segments;

-- 限定为七组基线用户，先各自汇总订单与领券至每人一行。
-- 半连接只限制样本范围，汇总前每笔订单和每张券仍只出现一次。
CREATE TEMP TABLE segment16_user_orders AS
SELECT orders.User_id AS user_id, count(*) AS order_count,
       sum(orders.Actual_pay) AS paid_amount, sum(orders.recorded_discount_sum) AS recorded_discount
FROM meituan_analysis.main.orders_clean AS orders
SEMI JOIN segment16_users AS users ON orders.User_id = users.user_id
WHERE orders.Pay_date BETWEEN getvariable('followup_start') AND getvariable('followup_end')
GROUP BY orders.User_id;

CREATE TEMP MACRO segment16_text(raw_value) AS
    CASE WHEN upper(trim(raw_value)) NOT IN ('', 'NULL') THEN raw_value END;

CREATE TEMP TABLE segment16_user_receipts AS
WITH parsed AS (
    SELECT segment16_text(User_id) AS user_id, segment16_text(Coupon_status) AS status_code,
           try_strptime(trim(segment16_text(Receive_date)), '%Y-%m-%d')::DATE AS receive_day
    FROM read_csv('_local/raw/06 美团业务选题-优惠券投放提效分析-数据2-user_coupon_receive.csv',
                  header = true, delim = ',', all_varchar = true, ignore_errors = false)
)
SELECT receipts.user_id, count(*) AS received_coupons,
       count(*) FILTER (WHERE receipts.status_code = '2') AS used_coupons
FROM parsed AS receipts SEMI JOIN segment16_users USING (user_id)
-- 按有效领券日统计整个二季度，保留短有效期券。
WHERE receive_day BETWEEN getvariable('followup_start') AND getvariable('followup_end')
GROUP BY receipts.user_id;

CREATE TEMP TABLE segment16_overview AS
WITH baseline AS (
    SELECT users.segment_order, users.segment_name, count(*) AS baseline_users,
           count(*) FILTER (WHERE followup.order_count_q2 > 0) AS ordering_users
    FROM segment16_users AS users
    LEFT JOIN meituan_analysis.main.user_followup_2023q2 AS followup
        ON users.user_id = followup.User_id
    GROUP BY users.segment_order, users.segment_name
), orders_by_segment AS (
    SELECT users.segment_order, sum(orders.order_count)::BIGINT AS order_count,
           sum(orders.paid_amount) AS paid_amount, sum(orders.recorded_discount) AS recorded_discount
    FROM segment16_user_orders AS orders JOIN segment16_users AS users USING (user_id)
    GROUP BY users.segment_order
), receipts_by_segment AS (
    SELECT users.segment_order, sum(receipts.received_coupons)::BIGINT AS received_coupons,
           sum(receipts.used_coupons)::BIGINT AS used_coupons
    FROM segment16_user_receipts AS receipts JOIN segment16_users AS users USING (user_id)
    GROUP BY users.segment_order
)
SELECT baseline.*, coalesce(orders_by_segment.order_count, 0) AS order_count,
       orders_by_segment.paid_amount, orders_by_segment.recorded_discount,
       coalesce(receipts_by_segment.received_coupons, 0) AS received_coupons,
       coalesce(receipts_by_segment.used_coupons, 0) AS used_coupons
FROM baseline LEFT JOIN orders_by_segment USING (segment_order)
LEFT JOIN receipts_by_segment USING (segment_order);

-- 在分组关联前的人级汇总和输出之间对账。
WITH result AS (
    SELECT count(*) AS segment_count, sum(baseline_users)::BIGINT AS users,
           sum(order_count)::BIGINT AS orders, sum(received_coupons)::BIGINT AS receipts,
           sum(used_coupons)::BIGINT AS used
    FROM segment16_overview
), sources AS (
    SELECT (SELECT coalesce(sum(order_count), 0)::BIGINT FROM segment16_user_orders) AS orders,
           (SELECT coalesce(sum(received_coupons), 0)::BIGINT FROM segment16_user_receipts) AS receipts,
           (SELECT coalesce(sum(used_coupons), 0)::BIGINT FROM segment16_user_receipts) AS used
)
SELECT result.segment_count AS "分组数", result.users AS "基线人数合计", result.users - 46711 AS "人数差额",
       result.orders AS "订单数合计", result.orders - sources.orders AS "订单数关联差额",
       result.receipts AS "领券数合计", result.receipts - sources.receipts AS "领券数关联差额",
       result.used AS "已用券数合计", result.used - sources.used AS "已用券数关联差额"
FROM result CROSS JOIN sources;

CREATE TEMP VIEW segment16_export AS
SELECT segment_name AS "最终分组", baseline_users AS "基线人数", ordering_users AS "下单人数",
       round(100.0 * ordering_users / nullif(baseline_users, 0), 6)::DECIMAL(10, 6) AS "下单比例（%）",
       order_count AS "订单数",
       round(paid_amount / nullif(order_count, 0), 6)::DECIMAL(18, 6) AS "客单价（原表单位）",
       received_coupons AS "领券数", used_coupons AS "已用券数",
       round(100.0 * used_coupons / nullif(received_coupons, 0), 6)::DECIMAL(10, 6) AS "核销率（%）",
       round(recorded_discount / nullif(order_count, 0), 6)::DECIMAL(18, 6) AS "单均记录减免（原表单位）"
FROM segment16_overview
ORDER BY segment_order;

COPY (SELECT * FROM segment16_export) TO '数据清洗/16_分层后续表现.csv' (FORMAT CSV, HEADER true);
SELECT * FROM segment16_export;
