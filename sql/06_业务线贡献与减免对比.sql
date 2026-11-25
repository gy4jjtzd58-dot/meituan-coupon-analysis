-- 在项目根目录的 PowerShell 中运行以下两行：
-- $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
-- Get-Content -LiteralPath 'sql/06_业务线贡献与减免对比.sql' -Raw -Encoding utf8 | duckdb -no-agent -bail -csv
-- 脚本更新 biz_overview、导出业务线 CSV，并单独输出全期合计和对账结果。

ATTACH '_local/meituan_analysis.duckdb' AS meituan_analysis;

SET VARIABLE period_start = DATE '2023-01-01';
SET VARIABLE period_end = DATE '2023-07-01';

-- 沿用订单底表中的原始业务线编码。真实缺失分组与合计由 GROUPING 明确区分。
CREATE OR REPLACE TEMP TABLE biz06_metrics AS
WITH grouped AS (
    SELECT
        Biz_code,
        grouping(Biz_code) = 1 AS is_total,
        count(*) AS order_count,
        sum(Actual_pay) AS paid_gmv,
        sum(recorded_discount_sum) AS recorded_discount_sum,
        count(*) FILTER (WHERE has_coupon_id) AS coupon_order_count,
        count(*) FILTER (WHERE has_positive_discount) AS positive_discount_order_count
    FROM meituan_analysis.main.orders_clean
    WHERE Pay_date >= getvariable('period_start') AND Pay_date < getvariable('period_end')
    GROUP BY GROUPING SETS ((Biz_code), ())
), total_amounts AS (
    SELECT paid_gmv AS total_paid, recorded_discount_sum AS total_discount
    FROM grouped
    WHERE is_total
), ratios AS (
    SELECT
        grouped.*,
        paid_gmv / nullif(order_count, 0) AS average_order_value,
        coupon_order_count::DOUBLE / nullif(order_count, 0) AS coupon_order_share,
        positive_discount_order_count::DOUBLE / nullif(order_count, 0) AS positive_discount_order_share,
        paid_gmv / nullif(total_paid, 0) AS paid_gmv_share,
        recorded_discount_sum / nullif(total_discount, 0) AS recorded_discount_share,
        recorded_discount_sum / nullif(positive_discount_order_count, 0) AS recorded_discount_per_positive_order,
        recorded_discount_sum / nullif(paid_gmv, 0) AS recorded_discount_to_paid_ratio
    FROM grouped
    CROSS JOIN total_amounts
)
SELECT
    is_total, Biz_code, order_count, paid_gmv, average_order_value, recorded_discount_sum,
    coupon_order_count, coupon_order_share, positive_discount_order_count, positive_discount_order_share,
    paid_gmv_share, recorded_discount_share,
    100 * (recorded_discount_share - paid_gmv_share) AS share_gap_pp,
    recorded_discount_per_positive_order, recorded_discount_to_paid_ratio
FROM ratios;

BEGIN TRANSACTION;

CREATE OR REPLACE TABLE meituan_analysis.main.biz_overview AS
SELECT * EXCLUDE (is_total)
FROM biz06_metrics
WHERE NOT is_total;

COMMIT;

-- 数据库的占比和份额为小数，share_gap_pp 为百分点。CSV 的占比和份额按百分比数值导出。
CREATE OR REPLACE TEMP VIEW biz06_display AS
SELECT
    is_total,
    CASE WHEN is_total THEN '合计' ELSE coalesce(Biz_code, '（缺失）') END AS "业务线原始编码",
    order_count AS "订单数",
    paid_gmv AS "实付成交额",
    round(average_order_value, 6)::DECIMAL(24, 6) AS "客单价",
    recorded_discount_sum AS "记录的减免明细合计",
    coupon_order_count AS "有券记录订单数",
    round(100 * coupon_order_share, 6)::DECIMAL(16, 6) AS "有券记录订单占比（%）",
    positive_discount_order_count AS "正减免订单数",
    round(100 * positive_discount_order_share, 6)::DECIMAL(16, 6) AS "正减免订单占比（%）",
    round(100 * paid_gmv_share, 6)::DECIMAL(16, 6) AS "成交份额（%）",
    round(100 * recorded_discount_share, 6)::DECIMAL(16, 6) AS "减免份额（%）",
    round(share_gap_pp, 6)::DECIMAL(16, 6) AS "份额差（百分点）",
    round(recorded_discount_per_positive_order, 6)::DECIMAL(24, 6) AS "正减免订单单均记录减免",
    round(100 * recorded_discount_to_paid_ratio, 6)::DECIMAL(16, 6) AS "记录减免占实付比例（%）"
FROM (
    SELECT false AS is_total, * FROM meituan_analysis.main.biz_overview
    UNION ALL
    SELECT * FROM biz06_metrics WHERE is_total
) AS all_rows;

CREATE OR REPLACE TEMP VIEW biz06_export AS
SELECT * EXCLUDE (is_total)
FROM biz06_display
WHERE NOT is_total
ORDER BY "实付成交额" DESC NULLS LAST, "业务线原始编码";

COPY (SELECT * FROM biz06_export) TO '数据清洗/06_业务线贡献与减免对比.csv' (FORMAT CSV, HEADER true);

SELECT * FROM biz06_export;

SELECT * EXCLUDE (is_total) FROM biz06_display WHERE is_total;

-- 对照第 05 步同期月表。两种金额都用定点小数进行对账。
WITH biz_totals AS (
    SELECT sum(order_count) AS orders, sum(paid_gmv) AS paid, sum(recorded_discount_sum) AS discount
    FROM meituan_analysis.main.biz_overview
), month_totals AS (
    SELECT sum(order_count) AS orders, sum(paid_gmv) AS paid, sum(recorded_discount_sum) AS discount
    FROM meituan_analysis.main.monthly_overview
    WHERE month_start >= getvariable('period_start') AND month_start < getvariable('period_end')
)
SELECT
    check_name AS "对账项",
    CASE WHEN unit = '笔订单' THEN actual::BIGINT::VARCHAR ELSE actual::VARCHAR END AS "业务线合计",
    CASE WHEN unit = '笔订单' THEN baseline::BIGINT::VARCHAR ELSE baseline::VARCHAR END AS "第05步全期",
    CASE WHEN unit = '笔订单' THEN (actual - baseline)::BIGINT::VARCHAR
         ELSE (actual - baseline)::VARCHAR END AS "差额",
    unit AS "统计单位",
    CASE WHEN actual IS NULL OR baseline IS NULL THEN '无法对账'
         WHEN actual = baseline THEN '通过' ELSE '差异' END AS "结果"
FROM biz_totals AS biz
CROSS JOIN month_totals AS months
CROSS JOIN LATERAL (VALUES
    (1, '订单数', biz.orders, months.orders, '笔订单'),
    (2, '实付成交额', biz.paid, months.paid, '原表金额单位'),
    (3, '记录的减免明细合计', biz.discount, months.discount, '原表金额单位')
) AS checks(check_no, check_name, actual, baseline, unit)
ORDER BY check_no;

-- 份额使用数据库中的未取整值求和，允许百分数计算中的微小浮点误差。
WITH totals AS (
    SELECT sum(paid_gmv_share) AS total_paid_share, sum(recorded_discount_share) AS total_discount_share
    FROM meituan_analysis.main.biz_overview
)
SELECT check_name AS "份额对账项",
       100 * total_share AS "份额合计（%）",
       100.0 AS "基准（%）",
       100 * (total_share - 1) AS "差额（百分点）",
       CASE WHEN total_share IS NULL THEN '无法对账'
            WHEN abs(total_share - 1) <= 0.000000000001 THEN '通过' ELSE '差异' END AS "结果"
FROM totals
CROSS JOIN LATERAL (VALUES
    (1, '成交份额', total_paid_share),
    (2, '减免份额', total_discount_share)
) AS checks(check_no, check_name, total_share)
ORDER BY check_no;

SELECT coalesce(sum(order_count) FILTER (WHERE Biz_code IS NULL), 0) AS "缺失业务线编码的订单数"
FROM meituan_analysis.main.biz_overview;

SELECT Biz_code AS "成交份额最高的业务线", paid_gmv AS "实付成交额", 100 * paid_gmv_share AS "成交份额（%）"
FROM meituan_analysis.main.biz_overview
WHERE paid_gmv_share IS NOT NULL
ORDER BY paid_gmv_share DESC, Biz_code NULLS LAST
LIMIT 1;

-- 比较绝对份额差最大的业务线与全期订单。减免指标反映本期记录的明细金额。
WITH largest_gap AS (
    SELECT *
    FROM meituan_analysis.main.biz_overview
    WHERE share_gap_pp IS NOT NULL
    ORDER BY abs(share_gap_pp) DESC, order_count DESC, Biz_code NULLS LAST
    LIMIT 1
)
SELECT
    coalesce(line.Biz_code, '（缺失）') AS "比较业务线",
    line.order_count AS "订单数",
    100 * line.order_count::DOUBLE / nullif(totals.order_count, 0) AS "占全体订单（%）",
    line.share_gap_pp AS "份额差（百分点）",
    100 * line.positive_discount_order_share AS "该线正减免订单占比（%）",
    100 * totals.positive_discount_order_share AS "全体正减免订单占比（%）",
    line.recorded_discount_per_positive_order AS "该线正减免订单单均记录减免",
    totals.recorded_discount_per_positive_order AS "全体正减免订单单均记录减免",
    line.average_order_value AS "该线客单价",
    totals.average_order_value AS "全体客单价"
FROM largest_gap AS line
CROSS JOIN biz06_metrics AS totals
WHERE totals.is_total;
