-- 在项目根目录的 PowerShell 中运行：
-- $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
-- Get-Content -LiteralPath 'sql/13_门槛分档核销与减免.sql' -Raw -Encoding utf8 | duckdb -no-agent -bail -csv

ATTACH '_local/meituan_analysis.duckdb' AS meituan_analysis (READ_ONLY);
SET threads = 4;
SET preserve_insertion_order = false;

CREATE TEMP MACRO coupon13_text(raw_value) AS
    CASE WHEN upper(trim(raw_value)) NOT IN ('', 'NULL') THEN raw_value END;

CREATE TEMP MACRO coupon13_amount(raw_value) AS
    CASE WHEN regexp_full_match(trim(raw_value), '[+-]?([0-9]+(\.[0-9]{1,4})?|\.[0-9]{1,4})')
         THEN try_cast(trim(raw_value) AS DECIMAL(18, 4)) END;

CREATE TEMP TABLE coupon13_receipts AS
WITH parsed AS (
    SELECT coupon13_text(Coupon_status) AS status_code, Coupon_id, User_id,
           coupon13_amount(Price_limit) AS price_floor, coupon13_amount(Coupon_amt) AS face_value
    FROM read_csv('_local/raw/06 美团业务选题-优惠券投放提效分析-数据2-user_coupon_receive.csv',
                  header = true, delim = ',', all_varchar = true, ignore_errors = false)
)
SELECT CASE WHEN price_floor IS NULL OR price_floor < 0 THEN 4
            WHEN price_floor <= 10 THEN 1
            WHEN price_floor <= 30 THEN 2
            ELSE 3 END AS tier_order,
       status_code, coalesce(face_value = 500, false) AS is_face_500,
       CASE WHEN status_code = '2' THEN coupon13_text(User_id) END AS user_key,
       CASE WHEN status_code = '2' THEN coupon13_text(Coupon_id) END AS coupon_key
FROM parsed;

-- 使用第 11 步全部核验时滞。每个用户和券的组合只接受一个已核验订单。
-- 只读三键都一致的订单明细。同键多行金额均有效且一致时取一次，有冲突或无有效金额时留空。
CREATE TEMP TABLE coupon13_discounts AS
WITH verified AS (
    SELECT User_id AS user_key, Coupon_id AS coupon_key, min(Order_id) AS order_key
    FROM meituan_analysis.main.coupon_pay_lag_detail
    GROUP BY User_id, Coupon_id
    HAVING count(DISTINCT Order_id) = 1
), order_lines AS (
    SELECT coupon13_text(User_id) AS user_key, coupon13_text(Coupon_id) AS coupon_key,
           coupon13_text(Order_id) AS order_key, coupon13_amount(Reduce_amount) AS amount
    FROM read_csv('_local/raw/06 美团业务选题-优惠券投放提效分析-数据1-order_detail.csv',
                  header = true, delim = ',', all_varchar = true, ignore_errors = false)
), same_coupon AS (
    SELECT verified.user_key, verified.coupon_key, count(*) AS line_count,
           count(*) FILTER (WHERE amount >= 0) AS valid_count,
           min(amount) AS min_amount, max(amount) AS max_amount
    FROM verified JOIN order_lines USING (user_key, coupon_key, order_key)
    GROUP BY verified.user_key, verified.coupon_key
)
SELECT user_key, coupon_key, line_count,
       CASE WHEN valid_count = line_count AND min_amount = max_amount THEN min_amount END AS recorded_discount
FROM same_coupon;

-- 第 01 步已核验原始领券的 Coupon_id 唯一。左连接保留全量领券。
CREATE TEMP TABLE coupon13_counts AS
SELECT tier_order, is_face_500, count(*) AS receipts,
       count(*) FILTER (WHERE status_code = '1') AS unused,
       count(*) FILTER (WHERE status_code = '2') AS used,
       count(*) FILTER (WHERE status_code = '3') AS other_status,
       count(*) FILTER (WHERE status_code IS NULL) AS missing_status,
       count(recorded_discount) AS discount_covered,
       coalesce(sum(recorded_discount), 0) AS discount_amount
FROM coupon13_receipts
LEFT JOIN coupon13_discounts USING (user_key, coupon_key)
GROUP BY tier_order, is_face_500;

CREATE TEMP TABLE coupon13_metrics AS
WITH amounts AS (
    SELECT include_face_500, tier_order, sum(receipts)::BIGINT AS receipts, sum(unused)::BIGINT AS unused,
           sum(used)::BIGINT AS used, sum(other_status)::BIGINT AS other_status,
           sum(missing_status)::BIGINT AS missing_status, sum(discount_covered)::BIGINT AS discount_covered,
           sum(discount_amount) AS discount_amount
    FROM coupon13_counts CROSS JOIN (VALUES (true), (false)) AS scenario(include_face_500)
    WHERE include_face_500 OR NOT is_face_500
    GROUP BY include_face_500, tier_order
), tier_names AS (
    SELECT * FROM (VALUES (1, '低门槛', '[0, 10]'), (2, '中门槛', '(10, 30]'), (3, '高门槛', '(30, +∞)'),
                          (4, '门槛缺失或无效', NULL))
        AS tiers(tier_order, tier_name, tier_range)
)
SELECT amounts.*, tier_names.tier_name, tier_names.tier_range,
       CASE WHEN amounts.tier_order <= 3 THEN 100.0 * receipts / nullif(
           sum(receipts) FILTER (WHERE amounts.tier_order <= 3) OVER (PARTITION BY include_face_500), 0
       ) END AS tier_share,
       100.0 * used / nullif(receipts, 0) AS redemption_pct,
       100.0 * discount_amount / nullif(receipts, 0) AS discount_per_100,
       100.0 * discount_covered / nullif(used, 0) AS discount_coverage_pct
FROM amounts JOIN tier_names USING (tier_order);

-- 最小对账：全量领券和已使用券按第 12 步状态汇总表核对。
WITH actual AS (
    SELECT sum(receipts)::BIGINT AS receipts, sum(used)::BIGINT AS used FROM coupon13_counts
), baseline AS (
    SELECT sum(coupon_count)::BIGINT AS receipts,
           sum(coupon_count) FILTER (WHERE status_code = '2')::BIGINT AS used
    FROM meituan_analysis.main.coupon_status_overview
)
SELECT actual.receipts AS "全量领券数", actual.receipts - baseline.receipts AS "较第12步全量差额",
       actual.used AS "全量已使用券数", actual.used - baseline.used AS "较第12步已使用差额"
FROM actual CROSS JOIN baseline;

-- 仅核对已使用券的金额归属，零值属于覆盖，重复同券同单明细最多归属一次。
SELECT count(recorded_discount) AS "有可归属记录减免的已使用券数",
       count(recorded_discount) - count(DISTINCT coupon_key) FILTER (WHERE recorded_discount IS NOT NULL)
           AS "归属减免重复计券数",
       count(*) FILTER (WHERE line_count > 1) AS "同券同单匹配多行的已使用券数",
       count(*) FILTER (WHERE line_count IS NOT NULL AND recorded_discount IS NULL)
           AS "匹配明细但金额无法归属的已使用券数",
       count(*) FILTER (WHERE recorded_discount = 0) AS "减免为0且计入覆盖的券数",
       count(*) FILTER (WHERE recorded_discount IS NULL) AS "未能归属减免的已使用券数"
FROM coupon13_receipts LEFT JOIN coupon13_discounts USING (user_key, coupon_key)
WHERE status_code = '2';

SELECT sum(receipts)::BIGINT AS "原始面额500的领券数", sum(used)::BIGINT AS "原始面额500的已使用券数"
FROM coupon13_counts WHERE is_face_500;

SELECT CASE WHEN include_face_500 THEN '含面额500' ELSE '剔除面额500' END AS "核对范围",
       string_agg(tier_name, ' > ' ORDER BY redemption_pct DESC, tier_order) AS "核销率从高到低",
       string_agg(tier_name, ' > ' ORDER BY discount_per_100 DESC, tier_order) AS "每领100张可归属记录减免从高到低"
FROM coupon13_metrics
WHERE tier_order <= 3
GROUP BY include_face_500
ORDER BY include_face_500 DESC;

CREATE TEMP VIEW coupon13_export AS
SELECT tier_name AS "门槛档", tier_range AS "Price_limit区间（原表单位）",
       receipts AS "领券数", round(tier_share, 6)::DECIMAL(10, 6) AS "占已分档券的比例（%）",
       unused AS "未使用（状态1）券数", used AS "已使用（状态2）券数",
       other_status AS "其他（状态3）券数", missing_status AS "状态缺失券数",
       round(redemption_pct, 6)::DECIMAL(10, 6) AS "核销率（%）",
       discount_covered AS "可归属记录减免的已使用券数",
       used - discount_covered AS "无法归属记录减免的已使用券数",
       round(discount_coverage_pct, 6)::DECIMAL(10, 6) AS "可归属记录减免覆盖率（%）",
       discount_amount AS "可归属记录减免合计（原表单位）",
       round(discount_per_100, 6)::DECIMAL(18, 6) AS "每领100张可归属记录减免（原表单位）"
FROM coupon13_metrics
WHERE include_face_500
ORDER BY tier_order;

COPY (SELECT * FROM coupon13_export) TO '数据清洗/13_门槛分档核销与减免.csv' (FORMAT CSV, HEADER true);
SELECT * FROM coupon13_export;
