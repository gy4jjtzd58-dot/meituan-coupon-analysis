-- 在项目根目录的 PowerShell 中运行：
-- $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
-- Get-Content -LiteralPath 'sql/20_第4至7天第二单用券分析.sql' -Raw -Encoding utf8 | duckdb -no-agent -bail -csv

ATTACH '_local/meituan_analysis.duckdb' AS meituan_analysis (READ_ONLY);
SET threads = 4;
SET preserve_insertion_order = false;

CREATE TEMP MACRO second20_text(raw_value) AS
    CASE WHEN upper(trim(raw_value)) NOT IN ('', 'NULL') THEN raw_value END;

CREATE TEMP MACRO second20_amount(raw_value) AS
    CASE WHEN regexp_full_match(trim(raw_value), '[+-]?([0-9]+(\.[0-9]{1,4})?|\.[0-9]{1,4})')
         THEN try_cast(trim(raw_value) AS DECIMAL(18, 4)) END;

-- 第 19 步的首单口径。确定第 4–7 天入组只需扫描到首单后第 7 天。
CREATE TEMP TABLE second20_cohort AS
WITH first_payments AS (
    SELECT User_id AS user_id, min(Pay_date) AS first_pay_day
    FROM meituan_analysis.main.orders_clean
    WHERE User_id IS NOT NULL AND Pay_date BETWEEN DATE '2023-01-01' AND DATE '2023-05-31'
    GROUP BY User_id
    HAVING min(Pay_date) >= DATE '2023-04-01'
), second_days AS (
    SELECT first_payments.user_id, first_pay_day,
           min(orders.Pay_date) FILTER (WHERE orders.Pay_date > first_pay_day) AS second_pay_day
    FROM first_payments JOIN meituan_analysis.main.orders_clean AS orders
        ON first_payments.user_id = orders.User_id
       AND orders.Pay_date BETWEEN first_pay_day AND first_pay_day + 7
    GROUP BY first_payments.user_id, first_pay_day
    HAVING count(orders.Order_id) FILTER (WHERE orders.Pay_date = first_pay_day) = 1
)
SELECT second_days.user_id, first_pay_day, second_pay_day,
       count(orders.Order_id) AS second_day_orders,
       CASE WHEN count(orders.Order_id) = 1 THEN min(orders.Order_id) END AS second_order_id
FROM second_days JOIN meituan_analysis.main.orders_clean AS orders
    ON second_days.user_id = orders.User_id AND second_days.second_pay_day = orders.Pay_date
WHERE second_pay_day BETWEEN first_pay_day + 4 AND first_pay_day + 7
GROUP BY second_days.user_id, first_pay_day, second_pay_day;

-- 仅对可定位的第二单取券 ID。每个同券同单键保留一次，券型保留原始编码。
CREATE TEMP TABLE second20_order_coupon_ids AS
WITH order_lines AS (
    SELECT second20_text(User_id) AS user_id, second20_text(Order_id) AS order_id,
           second20_text(Coupon_id) AS coupon_id, second20_text(Coupon_type) AS coupon_type
    FROM read_csv('_local/raw/06 美团业务选题-优惠券投放提效分析-数据1-order_detail.csv',
                  header = true, delim = ',', all_varchar = true, ignore_errors = false)
)
SELECT cohort.user_id, cohort.second_order_id AS order_id, lines.coupon_id,
       coalesce(string_agg(DISTINCT lines.coupon_type, '/' ORDER BY lines.coupon_type), '（缺失）')
           AS coupon_type
FROM second20_cohort AS cohort JOIN order_lines AS lines
    ON cohort.user_id = lines.user_id AND cohort.second_order_id = lines.order_id
WHERE lines.coupon_id IS NOT NULL
GROUP BY cohort.user_id, cohort.second_order_id, lines.coupon_id;

-- 第 11 步已核验唯一匹配订单和有效日期；第 13 步按同用户、同券、同订单核对状态 2。
-- 该会话明细也是第 21 步的直接输入，同一 DuckDB 连接内顺序执行。
CREATE TEMP TABLE second20_confirmed_coupons AS
WITH used_receipts AS (
    SELECT second20_text(User_id) AS user_id, second20_text(Coupon_id) AS coupon_id,
           try_strptime(trim(second20_text(Receive_date)), '%Y-%m-%d')::DATE AS receive_day,
           second20_amount(Price_limit) AS price_floor, second20_amount(Coupon_amt) AS face_value,
           try_strptime(trim(second20_text(Start_date)), '%Y-%m-%d')::DATE AS start_day,
           try_strptime(trim(second20_text(End_date)), '%Y-%m-%d')::DATE AS end_day
    FROM read_csv('_local/raw/06 美团业务选题-优惠券投放提效分析-数据2-user_coupon_receive.csv',
                  header = true, delim = ',', all_varchar = true, ignore_errors = false)
    WHERE second20_text(Coupon_status) = '2'
)
SELECT ids.user_id, ids.coupon_id, ids.coupon_type, ids.order_id,
       receipts.price_floor, receipts.face_value, receipts.start_day, receipts.end_day,
       CASE WHEN price_floor IS NULL OR price_floor < 0 THEN '门槛缺失或无效'
            WHEN price_floor <= 10 THEN '低门槛（含无门槛）'
            WHEN price_floor <= 30 THEN '中门槛'
            ELSE '高门槛' END AS threshold_tier,
       CASE WHEN receive_day < first_pay_day THEN 1
            WHEN receive_day = first_pay_day THEN 2
            WHEN receive_day < second_pay_day THEN 3
            WHEN receive_day = second_pay_day THEN 4 END AS receipt_period
FROM second20_order_coupon_ids AS ids
JOIN used_receipts AS receipts USING (user_id, coupon_id)
JOIN second20_cohort AS cohort USING (user_id)
SEMI JOIN meituan_analysis.main.coupon_pay_lag_detail AS detail
    ON ids.user_id = detail.User_id AND ids.order_id = detail.Order_id AND ids.coupon_id = detail.Coupon_id
   AND detail.Coupon_status = '2' AND receipts.receive_day = detail.Receive_date
   AND cohort.second_pay_day = detail.Pay_date;

CREATE TEMP TABLE second20_user_results AS
WITH coupon_presence AS (
    SELECT user_id, count(*) AS recorded_coupon_ids FROM second20_order_coupon_ids GROUP BY user_id
), confirmed AS (
    SELECT user_id, count(*) AS confirmed_coupons,
           string_agg(coupon_type || ' × ' || threshold_tier, ' + ' ORDER BY coupon_type, threshold_tier, coupon_id)
               AS coupon_combinations,
           count(*) FILTER (WHERE receipt_period = 1) AS received_before_first,
           count(*) FILTER (WHERE receipt_period = 2) AS received_on_first,
           count(*) FILTER (WHERE receipt_period = 3) AS received_between_orders,
           count(*) FILTER (WHERE receipt_period = 4) AS received_on_second
    FROM second20_confirmed_coupons
    GROUP BY user_id
)
SELECT cohort.user_id,
       CASE WHEN cohort.second_day_orders > 1 THEN 1
            WHEN presence.recorded_coupon_ids IS NULL THEN 2
            WHEN confirmed.confirmed_coupons IS NULL THEN 3
            WHEN confirmed.confirmed_coupons = 1 THEN 4
            ELSE 5 END AS category_order,
       confirmed.coupon_combinations, confirmed.confirmed_coupons,
       confirmed.received_before_first, confirmed.received_on_first,
       confirmed.received_between_orders, confirmed.received_on_second
FROM second20_cohort AS cohort
LEFT JOIN coupon_presence AS presence USING (user_id)
LEFT JOIN confirmed USING (user_id);

CREATE TEMP TABLE second20_export AS
WITH categories AS (
    SELECT * FROM (VALUES (1, '第二单当天有多笔订单，无法定位'), (2, '无券 ID 记录'),
                          (3, '有券 ID 但未能确认核销'), (4, '确认使用 1 张券'), (5, '确认使用多张券'))
        AS labels(category_order, category)
), counts AS (
    SELECT category_order, coupon_combinations, count(*) AS users,
           sum(confirmed_coupons)::BIGINT AS confirmed_coupons,
           sum(received_before_first)::BIGINT AS received_before_first,
           sum(received_on_first)::BIGINT AS received_on_first,
           sum(received_between_orders)::BIGINT AS received_between_orders,
           sum(received_on_second)::BIGINT AS received_on_second
    FROM second20_user_results
    GROUP BY category_order, coupon_combinations
), audit AS (
    SELECT (SELECT count(*) FROM second20_cohort) AS cohort_users,
           (SELECT coalesce(sum(users), 0) FROM counts) AS grouped_users,
           count(*) AS joined_rows, count(DISTINCT user_id) AS joined_users
    FROM second20_user_results
)
SELECT categories.category AS "第二单用券情况", coupon_combinations AS "Coupon_type原始编码×门槛档",
       coalesce(users, 0) AS "人数",
       round(100.0 * coalesce(users, 0) / nullif(cohort_users, 0), 6)::DECIMAL(10, 6) AS "占第4至7天入组人数比例（%）",
       confirmed_coupons AS "确认用券数",
       received_before_first AS "首单前领券数", received_on_first AS "首单同日领券数",
       received_between_orders AS "首单后至第二单前领券数", received_on_second AS "第二单同日领券数"
FROM categories LEFT JOIN counts USING (category_order)
CROSS JOIN audit
WHERE CASE WHEN cohort_users <> 589 THEN error('第 4–7 天入组人数与第 19 步 589 人不一致')
           WHEN joined_rows <> cohort_users OR joined_users <> cohort_users OR grouped_users <> cohort_users
                THEN error('关联后用户数被改变，或分类人数与入组人数不一致')
           ELSE true END
ORDER BY categories.category_order, users DESC NULLS LAST, coupon_combinations NULLS LAST;

COPY (SELECT * FROM second20_export) TO '数据清洗/20_第4至7天第二单用券分析.csv' (FORMAT CSV, HEADER true);
SELECT * FROM second20_export;

-- 结论以确认的券为单位，包含多券订单中的各张券。
SELECT coupon_type AS "券型", threshold_tier AS "门槛档", count(*) AS "确认用券数",
       count(*) FILTER (WHERE receipt_period = 1) AS "首单前",
       count(*) FILTER (WHERE receipt_period = 2) AS "首单同日",
       count(*) FILTER (WHERE receipt_period = 3) AS "两单之间",
       count(*) FILTER (WHERE receipt_period = 4) AS "第二单同日"
FROM second20_confirmed_coupons
GROUP BY coupon_type, threshold_tier
QUALIFY dense_rank() OVER (ORDER BY count(*) DESC) = 1
ORDER BY coupon_type, threshold_tier;
