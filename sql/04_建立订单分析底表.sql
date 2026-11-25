-- 在项目根目录的 PowerShell 中运行以下两行：
-- $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
-- Get-Content -LiteralPath 'sql/04_建立订单分析底表.sql' -Raw -Encoding utf8 | duckdb -no-agent -bail -csv
-- 复跑在事务内替换数据库中的 orders_clean，并重新导出校验 CSV。

SET threads = 4;
SET preserve_insertion_order = false;

-- 保留非缺失 ID 的原始文本及前导零。空值、空白和文本 NULL 视为缺失。
CREATE OR REPLACE TEMP MACRO order04_text(raw_value) AS
    CASE WHEN upper(trim(raw_value)) NOT IN ('', 'NULL') THEN raw_value END;

CREATE OR REPLACE TEMP MACRO order04_date(raw_value) AS
    try_strptime(trim(order04_text(raw_value)), '%Y-%m-%d')::DATE;

-- 沿用第 02 步的四位定点金额规则。格式不符及精度超限由校验单独统计。
CREATE OR REPLACE TEMP MACRO order04_amount(raw_value) AS
    CASE WHEN regexp_full_match(trim(raw_value), '[+-]?([0-9]+(\.[0-9]{1,4})?|\.[0-9]{1,4})')
         THEN try_cast(trim(raw_value) AS DECIMAL(18, 4)) END;

CREATE OR REPLACE TEMP TABLE order04_rows AS
SELECT
    order04_text(Order_id) AS order_key,
    order04_text(User_id) AS user_key,
    order04_date(Pay_date) AS pay_day,
    order04_text(Biz_code) AS biz_code,
    order04_text(Shop_id) AS shop_key,
    order04_text(Coupon_id) AS coupon_key,
    order04_text(Pay_date) IS NULL AS pay_day_missing,
    order04_text(Actual_pay) IS NULL AS paid_missing,
    order04_text(Reduce_amount) IS NULL AS discount_missing,
    order04_amount(Actual_pay) AS paid,
    order04_amount(Reduce_amount) AS discount
FROM read_csv('_local/raw/06 美团业务选题-优惠券投放提效分析-数据1-order_detail.csv',
              header = true, delim = ',', all_varchar = true, ignore_errors = false);

-- 直接从订单原始明细计算对账基准。缺失订单号的源行无法归入一笔订单。
CREATE OR REPLACE TEMP TABLE order04_source_metrics AS
SELECT
    count(DISTINCT order_key) AS source_orders,
    count(*) FILTER (WHERE order_key IS NULL) AS rows_without_order_id,
    count(*) FILTER (WHERE pay_day_missing) AS pay_day_missing_rows,
    count(*) FILTER (WHERE NOT pay_day_missing AND pay_day IS NULL) AS pay_day_failed_rows,
    count(*) FILTER (WHERE paid_missing) AS paid_missing_rows,
    count(*) FILTER (WHERE NOT paid_missing AND paid IS NULL) AS paid_failed_rows,
    count(*) FILTER (WHERE discount_missing) AS discount_missing_rows,
    count(*) FILTER (WHERE NOT discount_missing AND discount IS NULL) AS discount_failed_rows,
    sum(discount) AS raw_discount_total,
    coalesce(sum(discount) FILTER (WHERE order_key IS NULL), 0::DECIMAL(38, 4))
        AS discount_on_rows_without_order_id
FROM order04_rows;

-- 每单统计字段的最小值与最大值，再从唯一的非缺失值中取值。
CREATE OR REPLACE TEMP TABLE order04_profile AS
SELECT
    order_key,
    min(user_key) AS min_user, max(user_key) AS max_user,
    min(pay_day) AS min_day, max(pay_day) AS max_day,
    min(biz_code) AS min_biz, max(biz_code) AS max_biz,
    min(shop_key) AS min_shop, max(shop_key) AS max_shop,
    count(*) FILTER (WHERE shop_key IS NULL) AS missing_shop_rows,
    min(paid) AS min_paid, max(paid) AS max_paid,
    count(*) FILTER (WHERE paid IS NULL) AS unparsed_paid_rows,
    sum(discount) AS recorded_discount_sum,
    bool_or(discount > 0) IS TRUE AS has_positive_discount,
    count(DISTINCT coupon_key) AS coupon_count
FROM order04_rows
WHERE order_key IS NOT NULL
GROUP BY order_key;

CREATE OR REPLACE TEMP TABLE order04_field_metrics AS
SELECT
    count(*) FILTER (WHERE min_user <> max_user) AS user_conflicts,
    count(*) FILTER (WHERE min_day <> max_day) AS day_conflicts,
    count(*) FILTER (WHERE min_biz <> max_biz) AS biz_conflicts,
    count(*) FILTER (WHERE min_shop <> max_shop) AS shop_conflicts,
    count(*) FILTER (WHERE min_shop IS NULL) AS shop_missing_orders,
    count(*) FILTER (WHERE min_shop = max_shop AND missing_shop_rows > 0) AS partial_shop_missing_orders,
    count(*) FILTER (WHERE min_paid <> max_paid) AS paid_conflicts,
    count(*) FILTER (WHERE unparsed_paid_rows > 0 OR min_paid <> max_paid) AS unconfirmed_paid_orders
FROM order04_profile;

ATTACH '_local/meituan_analysis.duckdb' AS meituan_analysis;

BEGIN TRANSACTION;

CREATE OR REPLACE TABLE meituan_analysis.main.orders_clean (
    Order_id VARCHAR PRIMARY KEY,
    User_id VARCHAR,
    Pay_date DATE,
    Biz_code VARCHAR,
    Shop_id VARCHAR,
    Actual_pay DECIMAL(18, 4),
    recorded_discount_sum DECIMAL(38, 4),
    has_coupon_id BOOLEAN NOT NULL,
    has_positive_discount BOOLEAN NOT NULL,
    coupon_count BIGINT NOT NULL
);

INSERT INTO meituan_analysis.main.orders_clean
SELECT
    order_key,
    CASE WHEN min_user = max_user THEN min_user END,
    CASE WHEN min_day = max_day THEN min_day END,
    CASE WHEN min_biz = max_biz THEN min_biz END,
    CASE WHEN min_shop = max_shop THEN min_shop END,
    CASE WHEN unparsed_paid_rows = 0 AND min_paid = max_paid THEN max_paid END,
    recorded_discount_sum,
    coupon_count > 0,
    has_positive_discount,
    coupon_count
FROM order04_profile;

COMMIT;

-- 对实际写入的底表对账。本批历史基准来自第 03 步订单数和第 02 步实付合计。
CREATE OR REPLACE TEMP VIEW order04_audit AS
WITH clean AS (
    SELECT
        count(*) AS clean_rows,
        count(*) FILTER (WHERE order04_text(Order_id) IS NULL) AS clean_missing_orders,
        count(order04_text(Order_id)) - count(DISTINCT order04_text(Order_id)) AS clean_duplicates,
        sum(Actual_pay) AS clean_paid_sum,
        sum(recorded_discount_sum) AS clean_discount_sum,
        count(*) FILTER (WHERE has_coupon_id AND has_positive_discount) AS coupon_positive,
        count(*) FILTER (WHERE has_coupon_id AND NOT has_positive_discount) AS coupon_nonpositive,
        count(*) FILTER (WHERE NOT has_coupon_id AND has_positive_discount) AS no_coupon_positive,
        count(*) FILTER (WHERE NOT has_coupon_id AND NOT has_positive_discount) AS no_coupon_nonpositive,
        count(*) FILTER (WHERE Shop_id IS NULL) AS clean_shop_missing_orders
    FROM meituan_analysis.main.orders_clean
), previous_steps AS (
    SELECT 973363::BIGINT AS previous_order_count,
           39389606.4200::DECIMAL(38, 4) AS previous_paid_total
), checks AS (
    SELECT checks.*
    FROM clean
    CROSS JOIN order04_source_metrics
    CROSS JOIN order04_field_metrics
    CROSS JOIN previous_steps
    CROSS JOIN LATERAL (VALUES
        (1, '底表行数与原始订单号去重数', clean_rows, source_orders, '笔订单', '原始 CSV 非缺失 Order_id 去重',
            '按原始文本识别订单号，底表每个非缺失订单号一行。'),
        (2, '底表行数与第 03 步订单数', clean_rows, previous_order_count, '笔订单', '第 03 步关联前一单一条订单数',
            CASE WHEN source_orders <> previous_order_count THEN
                '本次源文件的订单号去重数与第 03 步基准不同，见上一项。'
            ELSE '将写入行数与第 03 步订单数对账。' END),
        (3, '底表 Order_id 缺失', clean_missing_orders, 0, '行', '应为 0',
            '检查空值、空白和文本 NULL。'),
        (4, '底表 Order_id 重复超出行数', clean_duplicates, 0, '行', '应为 0',
            '以非缺失订单号行数减去不同非缺失订单号数量。'),
        (5, '实付合计', clean_paid_sum, previous_paid_total, '原表金额单位', '第 02 步每笔订单仅取一次实付金额后加总',
            CASE WHEN unconfirmed_paid_orders > 0 THEN
                '含缺失、解析失败或实付冲突的订单未能确认实付，底表对应金额留空，订单数见单列。'
            WHEN clean_paid_sum IS DISTINCT FROM previous_paid_total THEN
                '本次每单实付均可确认，本次合计与第 02 步基准不同，需回查源数据与历史金额。'
            ELSE '同一订单每行实付均成功解析且相同，取该金额一次。' END),
        (6, '记录的减免明细合计', clean_discount_sum, raw_discount_total, '原表金额单位', '原始 CSV 可解析减免逐行求和',
            '记录的减免明细合计。减免能否叠加以及由谁承担待核实。缺少订单号的明细减免见单列。'),
        (7, '有券 ID 且有正减免', coupon_positive, NULL, '笔订单', NULL,
            '至少一行有券 ID，且至少一行的减免大于 0。两项可出现在不同行。'),
        (8, '有券 ID 且无正减免', coupon_nonpositive, NULL, '笔订单', NULL,
            '至少一行有券 ID，且没有明细减免大于 0。'),
        (9, '无券 ID 且有正减免', no_coupon_positive, NULL, '笔订单', NULL,
            '各行的券 ID 都缺失，且至少一行的减免大于 0。'),
        (10, '无券 ID 且无正减免', no_coupon_nonpositive, NULL, '笔订单', NULL,
            '各行的券 ID 都缺失，且没有明细减免大于 0。'),
        (11, '四类订单合计', coupon_positive + coupon_nonpositive + no_coupon_positive + no_coupon_nonpositive,
            clean_rows, '笔订单', '底表行数', '四类订单各计一次，对照底表全部订单。'),
        (12, '商户缺失订单', shop_missing_orders, NULL, '笔订单', NULL,
            '订单内每行 Shop_id 都缺失，保留该订单，Shop_id 记为空。'),
        (13, '商户冲突订单', shop_conflicts, NULL, '笔订单', NULL,
            '同单有多个不同的非缺失 Shop_id 时，保留订单并将 Shop_id 记为空。'),
        (14, '部分明细缺商户但商户唯一的订单', partial_shop_missing_orders, NULL, '笔订单', NULL,
            '同单存在缺失明细，但其余明细只有一个 Shop_id，底表使用该值。'),
        (15, '底表 Shop_id 为空的订单', clean_shop_missing_orders, shop_missing_orders + shop_conflicts,
            '笔订单', '源明细商户全缺失或商户冲突的订单数', '核对商户字段留空规则与实际底表。'),
        (16, '同单 User_id 冲突', user_conflicts, NULL, '笔订单', NULL,
            '同单有多个非缺失的 User_id 时，底表 User_id 记为空。'),
        (17, '同单 Pay_date 冲突', day_conflicts, NULL, '笔订单', NULL,
            '同单有多个不同的可解析支付日时，底表 Pay_date 记为空。'),
        (18, '同单 Biz_code 冲突', biz_conflicts, NULL, '笔订单', NULL,
            '同单有多个非缺失的 Biz_code 时，底表 Biz_code 记为空。'),
        (19, '同单 Actual_pay 冲突', paid_conflicts, 0, '笔订单', '同单实付金额应一致',
            '同单有多个不同的可解析实付金额时，底表 Actual_pay 记为空。'),
        (20, '实付无法确认的订单', unconfirmed_paid_orders, 0, '笔订单', '底表实付须由全部明细确认',
            '至少一行实付缺失、解析失败或存在同单金额冲突，底表 Actual_pay 记为空。'),
        (21, '原始订单号缺失', rows_without_order_id, 0, '行', '每条订单明细需可归单',
            'Order_id 缺失的行无法归入不同订单号，单列统计。'),
        (22, '原始订单号缺失的明细减免', discount_on_rows_without_order_id, NULL, '原表金额单位', NULL,
            '仅累计 Order_id 缺失且 Reduce_amount 可解析的明细，供回查分组加总差额。'),
        (23, '原始 Pay_date 缺失', pay_day_missing_rows, NULL, '行', NULL,
            '空值、空白和文本 NULL 计为缺失。'),
        (24, '原始 Pay_date 解析失败', pay_day_failed_rows, NULL, '行', NULL,
            'Pay_date 非缺失但无法按 YYYY-MM-DD 解析。'),
        (25, '原始 Actual_pay 缺失', paid_missing_rows, NULL, '行', NULL,
            '空值、空白和文本 NULL 计为缺失。'),
        (26, '原始 Actual_pay 解析失败', paid_failed_rows, NULL, '行', NULL,
            'Actual_pay 非缺失但无法按四位定点小数规则解析。'),
        (27, '原始 Reduce_amount 缺失', discount_missing_rows, NULL, '行', NULL,
            '缺失值不参与减免加总。订单没有可用减免时，其合计为空。'),
        (28, '原始 Reduce_amount 解析失败', discount_failed_rows, NULL, '行', NULL,
            'Reduce_amount 非缺失但无法按四位定点小数规则解析，不参与减免加总。')
    ) AS checks(check_no, check_name, actual_value, baseline, unit, baseline_definition, note)
)
SELECT check_name AS "检查项",
       CASE WHEN unit = '原表金额单位' THEN actual_value::VARCHAR ELSE actual_value::BIGINT::VARCHAR END AS "实际值",
       CASE WHEN unit = '原表金额单位' THEN baseline::VARCHAR ELSE baseline::BIGINT::VARCHAR END AS "对账基准",
       CASE WHEN unit = '原表金额单位' THEN (actual_value - baseline)::VARCHAR
            ELSE (actual_value - baseline)::BIGINT::VARCHAR END AS "差额",
       unit AS "统计单位",
       CASE WHEN baseline_definition IS NULL THEN '统计'
            WHEN actual_value IS NULL OR baseline IS NULL THEN '无法对账'
            WHEN actual_value = baseline THEN '通过' ELSE '差异' END AS "结果",
       baseline_definition AS "基准来源",
       note AS "说明"
FROM checks
ORDER BY check_no;

COPY (SELECT * FROM order04_audit) TO '数据清洗/04_订单分析底表校验.csv' (FORMAT CSV, HEADER true);

SELECT * FROM order04_audit;
