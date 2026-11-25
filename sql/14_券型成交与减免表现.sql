-- 在项目根目录的 PowerShell 中运行：
-- $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
-- Get-Content -LiteralPath 'sql/14_券型成交与减免表现.sql' -Raw -Encoding utf8 | duckdb -no-agent -bail -csv

ATTACH '_local/meituan_analysis.duckdb' AS meituan_analysis (READ_ONLY);
SET threads = 4;
SET preserve_insertion_order = false;

CREATE TEMP MACRO coupon14_text(raw_value) AS
    CASE WHEN upper(trim(raw_value)) NOT IN ('', 'NULL') THEN raw_value END;

CREATE TEMP MACRO coupon14_amount(raw_value) AS
    CASE WHEN regexp_full_match(trim(raw_value), '[+-]?([0-9]+(\.[0-9]{1,4})?|\.[0-9]{1,4})')
         THEN try_cast(trim(raw_value) AS DECIMAL(18, 4)) END;

CREATE TEMP TABLE coupon14_tiers AS
SELECT * FROM (VALUES (1, '低门槛'), (2, '中门槛'), (3, '高门槛'), (4, '门槛缺失或无效'))
    AS tiers(tier_order, tier_name);

CREATE TEMP TABLE coupon14_reference AS
SELECT tiers.tier_order, csv."可归属记录减免的已使用券数"::BIGINT AS reference_coupon_count,
       csv."可归属记录减免合计（原表单位）"::DECIMAL(38, 4) AS reference_discount,
       csv."核销率（%）"::DECIMAL(10, 6) AS tier_redemption_pct
FROM read_csv('数据清洗/13_门槛分档核销与减免.csv', header = true, all_varchar = true) AS csv
JOIN coupon14_tiers AS tiers ON tiers.tier_name = csv."门槛档";

-- 复用第 13 步的全量已使用券、原表金额分档、全部第 11 步核验时滞、三键关联和减免归属规则。
CREATE TEMP TABLE coupon14_matched AS
WITH used_receipts AS (
    SELECT coupon14_text(User_id) AS user_key, coupon14_text(Coupon_id) AS coupon_key,
           coupon14_amount(Price_limit) AS price_floor, coupon14_amount(Coupon_amt) AS face_value
    FROM read_csv('_local/raw/06 美团业务选题-优惠券投放提效分析-数据2-user_coupon_receive.csv',
                  header = true, delim = ',', all_varchar = true, ignore_errors = false)
    WHERE coupon14_text(Coupon_status) = '2'
), verified AS (
    SELECT User_id AS user_key, Coupon_id AS coupon_key, min(Order_id) AS order_key
    FROM meituan_analysis.main.coupon_pay_lag_detail
    GROUP BY User_id, Coupon_id
    HAVING count(DISTINCT Order_id) = 1
), order_lines AS (
    SELECT coupon14_text(User_id) AS user_key, coupon14_text(Coupon_id) AS coupon_key,
           coupon14_text(Order_id) AS order_key, coupon14_amount(Reduce_amount) AS amount,
           coupon14_text(Biz_code) AS biz_code, coupon14_text(Coupon_type) AS coupon_type
    FROM read_csv('_local/raw/06 美团业务选题-优惠券投放提效分析-数据1-order_detail.csv',
                  header = true, delim = ',', all_varchar = true, ignore_errors = false)
), same_coupon AS (
    SELECT verified.user_key, verified.coupon_key, verified.order_key, count(*) AS line_count,
           count(*) FILTER (WHERE amount >= 0) AS valid_count, min(amount) AS min_amount, max(amount) AS max_amount,
           CASE WHEN count(DISTINCT biz_code) = 1 THEN min(biz_code) END AS biz_code,
           CASE WHEN count(DISTINCT coupon_type) = 1 THEN min(coupon_type) END AS coupon_type
    FROM verified JOIN order_lines USING (user_key, coupon_key, order_key)
    GROUP BY verified.user_key, verified.coupon_key, verified.order_key
)
SELECT CASE WHEN price_floor IS NULL OR price_floor < 0 THEN 4
            WHEN price_floor <= 10 THEN 1
            WHEN price_floor <= 30 THEN 2
            ELSE 3 END AS tier_order,
       same_coupon.coupon_key, same_coupon.order_key, biz_code, coupon_type,
       face_value = 500 AS is_face_500,
       CASE WHEN valid_count = line_count AND min_amount = max_amount THEN min_amount END AS recorded_discount
FROM used_receipts JOIN same_coupon USING (user_key, coupon_key);

CREATE TEMP TABLE coupon14_overview AS
WITH by_coupon AS (
    SELECT tier_order, biz_code, coupon_type, count(*) AS matched_coupons,
           count(recorded_discount) AS attributed_coupons,
           coalesce(sum(recorded_discount), 0) AS discount_sum,
           count(*) FILTER (WHERE recorded_discount = 0) AS zero_discount_coupons,
           count(*) FILTER (WHERE is_face_500) AS face_500_coupons
    FROM coupon14_matched
    GROUP BY tier_order, biz_code, coupon_type
), group_orders AS (
    SELECT DISTINCT tier_order, biz_code, coupon_type, order_key
    FROM coupon14_matched
), by_order AS (
    -- 每组每笔订单只取一次底表上已核验的实付；不同组可以包含同一订单。
    SELECT group_orders.tier_order, group_orders.biz_code, group_orders.coupon_type, count(*) AS distinct_orders,
           sum(orders.Actual_pay) AS paid_sum, count(*) - count(orders.Actual_pay) AS missing_paid_orders
    FROM group_orders LEFT JOIN meituan_analysis.main.orders_clean AS orders
        ON group_orders.order_key = orders.Order_id
    GROUP BY group_orders.tier_order, group_orders.biz_code, group_orders.coupon_type
)
SELECT by_coupon.*, by_order.distinct_orders, by_order.paid_sum, by_order.missing_paid_orders,
       discount_sum / matched_coupons AS avg_recorded_discount
FROM by_coupon JOIN by_order
    ON by_coupon.tier_order = by_order.tier_order
   AND by_coupon.biz_code IS NOT DISTINCT FROM by_order.biz_code
   AND by_coupon.coupon_type IS NOT DISTINCT FROM by_order.coupon_type;

CREATE TEMP VIEW coupon14_export AS
SELECT tiers.tier_name AS "门槛档",
       coalesce(biz_code, '（缺失）') AS "Biz_code",
       coalesce(coupon_type, '（缺失）') AS "Coupon_type",
       matched_coupons AS "已匹配已用券数", distinct_orders AS "去重关联订单数",
       paid_sum AS "关联订单实付成交额（原表单位）",
       discount_sum AS "可归属记录减免合计（原表单位）",
       round(avg_recorded_discount, 6)::DECIMAL(18, 6) AS "每张已匹配券平均记录减免（原表单位）",
       zero_discount_coupons AS "记录减免为0的券数", face_500_coupons AS "原始面额500的券数",
       reference.tier_redemption_pct AS "门槛档全量核销率（%，第13步）"
FROM coupon14_overview AS overview
JOIN coupon14_tiers AS tiers USING (tier_order)
LEFT JOIN coupon14_reference AS reference USING (tier_order)
ORDER BY overview.tier_order, matched_coupons DESC, biz_code NULLS LAST, coupon_type NULLS LAST;

-- 按档对账。第 13 步同券匹配均有可归属减免，所以其覆盖数就是同券匹配基准。
WITH actual AS (
    SELECT tier_order, sum(matched_coupons)::BIGINT AS coupons,
           sum(attributed_coupons)::BIGINT AS attributed_coupons, sum(discount_sum) AS discount_sum,
           sum(missing_paid_orders)::BIGINT AS missing_paid_orders
    FROM coupon14_overview GROUP BY tier_order
)
SELECT tiers.tier_name AS "门槛档", coalesce(actual.coupons, 0) AS "已匹配已用券数",
       coalesce(actual.coupons, 0) - reference.reference_coupon_count AS "较第13步券数差额",
       coalesce(actual.coupons - actual.attributed_coupons, 0) AS "匹配但减免无法归属的券数",
       coalesce(actual.discount_sum, 0) AS "可归属记录减免合计（原表单位）",
       coalesce(actual.discount_sum, 0) - reference.reference_discount AS "较第13步减免差额",
       coalesce(actual.missing_paid_orders, 0) AS "分组实付缺失订单数"
FROM coupon14_tiers AS tiers
JOIN coupon14_reference AS reference USING (tier_order)
LEFT JOIN actual USING (tier_order)
ORDER BY tiers.tier_order;

COPY (SELECT * FROM coupon14_export) TO '数据清洗/14_券型成交与减免表现.csv' (FORMAT CSV, HEADER true);

-- 各档券数最多的组合供人群候选筛选，完整汇总见 CSV。
SELECT tiers.tier_name AS "门槛档", biz_code AS "Biz_code", coupon_type AS "Coupon_type",
       matched_coupons AS "已匹配已用券数", distinct_orders AS "去重关联订单数",
       paid_sum AS "关联订单实付成交额", discount_sum AS "可归属记录减免合计",
       round(avg_recorded_discount, 4) AS "每张已匹配券平均记录减免",
       zero_discount_coupons AS "记录减免为0的券数", face_500_coupons AS "原始面额500的券数"
FROM coupon14_overview AS overview JOIN coupon14_tiers AS tiers USING (tier_order)
QUALIFY row_number() OVER (
    PARTITION BY overview.tier_order ORDER BY matched_coupons DESC, biz_code NULLS LAST, coupon_type NULLS LAST
) <= 5
ORDER BY overview.tier_order, matched_coupons DESC, biz_code NULLS LAST, coupon_type NULLS LAST;
