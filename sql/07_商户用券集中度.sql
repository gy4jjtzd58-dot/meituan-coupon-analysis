-- 在项目根目录的 PowerShell 中运行以下两行：
-- $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
-- Get-Content -LiteralPath 'sql/07_商户用券集中度.sql' -Raw -Encoding utf8 | duckdb -no-agent -bail -csv
-- 脚本更新 merchant_overview，导出前十名和覆盖校验，并单独输出第一名和前十名的份额。

ATTACH '_local/meituan_analysis.duckdb' AS meituan_analysis;

SET VARIABLE period_start = DATE '2023-01-01';
SET VARIABLE period_end = DATE '2023-07-01';

CREATE OR REPLACE TEMP VIEW merchant07_period AS
SELECT Shop_id, Biz_code, Actual_pay, has_coupon_id
FROM meituan_analysis.main.orders_clean
WHERE Pay_date >= getvariable('period_start') AND Pay_date < getvariable('period_end');

CREATE OR REPLACE TEMP TABLE merchant07_presence AS
WITH by_presence AS (
    SELECT Shop_id IS NOT NULL AS has_shop, count(*) AS order_count, sum(Actual_pay) AS paid_gmv,
           count(*) FILTER (WHERE has_coupon_id) AS coupon_order_count
    FROM merchant07_period
    GROUP BY has_shop
)
SELECT groups.has_shop,
       coalesce(by_presence.order_count, 0) AS order_count,
       CASE WHEN by_presence.order_count IS NULL THEN 0 ELSE by_presence.paid_gmv END AS paid_gmv,
       coalesce(by_presence.coupon_order_count, 0) AS coupon_order_count
FROM (VALUES (true), (false)) AS groups(has_shop)
LEFT JOIN by_presence USING (has_shop);

BEGIN TRANSACTION;

CREATE OR REPLACE TABLE meituan_analysis.main.merchant_overview AS
WITH by_merchant AS (
    SELECT Shop_id, count(*) AS order_count, sum(Actual_pay) AS paid_gmv,
           count(*) FILTER (WHERE has_coupon_id) AS coupon_order_count
    FROM merchant07_period
    WHERE Shop_id IS NOT NULL
    GROUP BY Shop_id
), shares AS (
    SELECT
        shop.*,
        shop.coupon_order_count::DOUBLE / nullif(covered.coupon_order_count, 0) AS coupon_order_share,
        shop.order_count::DOUBLE / nullif(covered.order_count, 0) AS all_order_share
    FROM by_merchant AS shop
    CROSS JOIN merchant07_presence AS covered
    WHERE covered.has_shop
)
SELECT Shop_id,
       row_number() OVER (ORDER BY coupon_order_count DESC, Shop_id) AS coupon_order_rank,
       order_count, paid_gmv, coupon_order_count, coupon_order_share, all_order_share,
       100 * (coupon_order_share - all_order_share) AS share_gap_pp
FROM shares;

COMMIT;

-- 同一有券记录订单数下，按原始文本 Shop_id 升序定序。两个份额均以有商户 ID 的订单为范围。
CREATE OR REPLACE TEMP VIEW merchant07_top_export AS
SELECT coupon_order_rank AS "有券记录订单排名",
       Shop_id,
       order_count AS "全部订单数",
       paid_gmv AS "实付成交额",
       coupon_order_count AS "有券记录订单数",
       round(100 * coupon_order_share, 6)::DECIMAL(16, 6) AS "有券记录订单份额（%）",
       round(100 * all_order_share, 6)::DECIMAL(16, 6) AS "全部订单份额（%）",
       round(share_gap_pp, 6)::DECIMAL(16, 6) AS "份额差（百分点）"
FROM meituan_analysis.main.merchant_overview
WHERE coupon_order_rank <= 10
ORDER BY coupon_order_rank;

COPY (SELECT * FROM merchant07_top_export) TO '数据清洗/07_商户用券集中度.csv' (FORMAT CSV, HEADER true);

-- 覆盖组与业务线分组来自底表，对账同时检查商户表聚合后仍保留有商户 ID 组的全部指标。
CREATE OR REPLACE TEMP VIEW merchant07_audit AS
WITH period_totals AS (
    SELECT count(*) AS order_count, sum(Actual_pay) AS paid_gmv,
           count(*) FILTER (WHERE has_coupon_id) AS coupon_order_count
    FROM merchant07_period
), presence_totals AS (
    SELECT sum(order_count) AS order_count, sum(paid_gmv) AS paid_gmv,
           sum(coupon_order_count) AS coupon_order_count
    FROM merchant07_presence
), biz_coverage AS (
    SELECT Biz_code, count(*) AS order_count, count(Shop_id) AS with_shop,
           count(*) FILTER (WHERE Shop_id IS NULL) AS without_shop
    FROM merchant07_period
    GROUP BY Biz_code
), merchant_totals AS (
    SELECT count(*) AS merchants, coalesce(sum(order_count), 0) AS order_count,
           CASE WHEN count(*) = 0 THEN 0 ELSE sum(paid_gmv) END AS paid_gmv,
           coalesce(sum(coupon_order_count), 0) AS coupon_order_count
    FROM meituan_analysis.main.merchant_overview
), checks AS (
    SELECT 1 AS section_no, CASE WHEN presence.has_shop THEN 1 ELSE 2 END AS group_no,
           item_no, '总体商户覆盖' AS section,
           CASE WHEN presence.has_shop THEN '有商户 ID' ELSE '缺商户 ID' END AS metric_group,
           item, actual, unit, denominator, NULL::DECIMAL(38, 4) AS baseline,
           denominator_definition AS note
    FROM merchant07_presence AS presence
    CROSS JOIN period_totals AS totals
    CROSS JOIN LATERAL (VALUES
        (1, '订单数', presence.order_count, '笔订单', totals.order_count, '比例分母为同期底表订单数。'),
        (2, '实付成交额', presence.paid_gmv, '原表金额单位', totals.paid_gmv, '比例分母为同期底表实付成交额。'),
        (3, '有券记录订单数', presence.coupon_order_count, '笔订单', totals.coupon_order_count,
            '比例分母为同期底表有券记录订单数，按 has_coupon_id 每单计一次。')
    ) AS metrics(item_no, item, actual, unit, denominator, denominator_definition)

    UNION ALL

    SELECT 1, 1, 4, '总体商户覆盖', '有商户 ID', '统计范围内的商户数',
           merchants, '家', NULL, NULL, '不同非缺失 Shop_id 的数量。'
    FROM merchant_totals

    UNION ALL

    SELECT 2, 1, item_no, '业务线商户覆盖', coalesce(Biz_code, '（缺失）'),
           item, actual, '笔订单', order_count, NULL, '比例分母为该业务线全部订单数。'
    FROM biz_coverage
    CROSS JOIN LATERAL (VALUES
        (1, '全部订单数', order_count),
        (2, '有商户 ID 的订单数', with_shop),
        (3, '缺商户 ID 的订单数', without_shop)
    ) AS metrics(item_no, item, actual)

    UNION ALL

    SELECT 3, 1, item_no, '对账', '覆盖两组加总比底表', item, actual, unit, NULL, baseline,
           '基准为同期订单底表的独立汇总。'
    FROM presence_totals AS combined
    CROSS JOIN period_totals AS totals
    CROSS JOIN LATERAL (VALUES
        (1, '订单数', combined.order_count, totals.order_count, '笔订单'),
        (2, '实付成交额', combined.paid_gmv, totals.paid_gmv, '原表金额单位'),
        (3, '有券记录订单数', combined.coupon_order_count, totals.coupon_order_count, '笔订单')
    ) AS metrics(item_no, item, actual, baseline, unit)

    UNION ALL

    SELECT 3, 2, item_no, '对账', '商户表汇总比有商户 ID 组', item, actual, unit, NULL, baseline,
           '基准为同期底表中有商户 ID 的订单汇总。'
    FROM merchant_totals AS merchants
    CROSS JOIN merchant07_presence AS covered
    CROSS JOIN LATERAL (VALUES
        (1, '订单数', merchants.order_count, covered.order_count, '笔订单'),
        (2, '实付成交额', merchants.paid_gmv, covered.paid_gmv, '原表金额单位'),
        (3, '有券记录订单数', merchants.coupon_order_count, covered.coupon_order_count, '笔订单')
    ) AS metrics(item_no, item, actual, baseline, unit)
    WHERE covered.has_shop
)
SELECT section AS "检查范围", metric_group AS "分组", item AS "指标",
       CASE WHEN unit = '原表金额单位' THEN actual::VARCHAR ELSE actual::BIGINT::VARCHAR END AS "统计值",
       unit AS "统计单位",
       CASE WHEN unit = '原表金额单位' THEN denominator::VARCHAR ELSE denominator::BIGINT::VARCHAR END AS "分母",
       round(100 * actual / nullif(denominator, 0), 6)::DECIMAL(16, 6) AS "比例（%）",
       CASE WHEN unit = '原表金额单位' THEN baseline::VARCHAR ELSE baseline::BIGINT::VARCHAR END AS "对账基准",
       CASE WHEN unit = '原表金额单位' THEN (actual - baseline)::VARCHAR
            ELSE (actual - baseline)::BIGINT::VARCHAR END AS "对账差额",
       CASE WHEN section_no <> 3 THEN NULL WHEN baseline IS NULL OR actual IS NULL THEN '无法对账'
            WHEN actual = baseline THEN '通过' ELSE '差异' END AS "对账结果",
       note AS "说明"
FROM checks
ORDER BY section_no, group_no, metric_group, item_no;

COPY (SELECT * FROM merchant07_audit) TO '数据清洗/07_商户覆盖校验.csv' (FORMAT CSV, HEADER true);

SELECT * FROM merchant07_audit;

SELECT * EXCLUDE (Shop_id) FROM merchant07_top_export;

-- 两项集中度都由同一份排名取得分子。各行的两个分母与单家商户份额一致。
WITH top_totals AS (
    SELECT sizes.top_size, count(shop.Shop_id) AS merchants,
           coalesce(sum(shop.order_count), 0) AS order_count,
           coalesce(sum(shop.coupon_order_count), 0) AS coupon_order_count
    FROM (VALUES (1), (10)) AS sizes(top_size)
    LEFT JOIN meituan_analysis.main.merchant_overview AS shop ON shop.coupon_order_rank <= sizes.top_size
    GROUP BY sizes.top_size
), total_merchants AS (
    SELECT count(*) AS merchants FROM meituan_analysis.main.merchant_overview
)
SELECT CASE WHEN top_size = 1 THEN '第一名' ELSE '前 10 家合计' END AS "按有券记录订单数取排名",
       top.merchants AS "所选商户数",
       scope.merchants AS "范围内商户总数",
       top.coupon_order_count AS "有券记录订单数",
       covered.coupon_order_count AS "有券记录订单份额分母",
       100 * top.coupon_order_count / nullif(covered.coupon_order_count, 0) AS "有券记录订单份额（%）",
       top.order_count AS "全部订单数",
       covered.order_count AS "全部订单份额分母",
       100 * top.order_count / nullif(covered.order_count, 0) AS "全部订单份额（%）",
       100 * (top.coupon_order_count / nullif(covered.coupon_order_count, 0)
            - top.order_count / nullif(covered.order_count, 0)) AS "份额差（百分点）"
FROM top_totals AS top
CROSS JOIN total_merchants AS scope
CROSS JOIN merchant07_presence AS covered
WHERE covered.has_shop
ORDER BY top_size;
