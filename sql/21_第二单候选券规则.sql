-- 在项目根目录的 PowerShell 中按顺序执行两步，使用同一个 DuckDB 连接：
-- $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
-- Get-Content -LiteralPath @('sql/20_第4至7天第二单用券分析.sql', 'sql/21_第二单候选券规则.sql') -Encoding utf8 | duckdb -no-agent -bail -csv
-- 本脚本直接读取新版第 20 步生成的临时核验明细 second20_confirmed_coupons。

CREATE TEMP TABLE rules21_scenarios AS
SELECT * FROM (VALUES (1, 2, '中门槛', '首单同日领 · 券型 1 × 中门槛'),
                      (2, 4, '低门槛（含无门槛）', '第二单同日领 · 券型 1 × 低门槛'))
    AS labels(scenario_order, receipt_period, threshold_tier, scenario_name);

-- 逐券筛选，保留多券订单中所有符合任一场景的券。
CREATE TEMP TABLE rules21_candidates AS
SELECT scenarios.scenario_order, coupons.user_id, coupons.coupon_id, coupons.order_id,
       coupons.price_floor, coupons.face_value,
       date_diff('day', coupons.start_day, coupons.end_day) + 1 AS valid_days
FROM second20_confirmed_coupons AS coupons
JOIN rules21_scenarios AS scenarios USING (receipt_period, threshold_tier)
WHERE coupons.coupon_type = '1';

CREATE TEMP TABLE rules21_enriched AS
SELECT candidates.*, orders.Biz_code AS use_biz_code
FROM rules21_candidates AS candidates LEFT JOIN meituan_analysis.main.orders_clean AS orders
    ON candidates.order_id = orders.Order_id AND candidates.user_id = orders.User_id;

-- 仅核对补入规则属性后每张券仍只计一次。
WITH before_rules AS (
    SELECT scenario_order, count(*) AS coupon_rows
    FROM rules21_candidates GROUP BY scenario_order
), after_rules AS (
    SELECT scenario_order, count(*) AS coupon_rows, count(DISTINCT coupon_id) AS distinct_coupons
    FROM rules21_enriched GROUP BY scenario_order
)
SELECT scenarios.scenario_name AS "场景", coalesce(before_rules.coupon_rows, 0) AS "补入业务线前确认券数",
       coalesce(after_rules.coupon_rows, 0) AS "补入业务线后行数",
       coalesce(after_rules.distinct_coupons, 0) AS "去重券数",
       coalesce(after_rules.coupon_rows - after_rules.distinct_coupons, 0) AS "重复计券数"
FROM rules21_scenarios AS scenarios
LEFT JOIN before_rules USING (scenario_order)
LEFT JOIN after_rules USING (scenario_order)
ORDER BY scenarios.scenario_order;

CREATE TEMP TABLE rules21_export AS
WITH grouped AS (
    SELECT scenario_order, use_biz_code, price_floor, face_value, valid_days,
           count(*) AS coupons, count(DISTINCT user_id) AS users
    FROM rules21_enriched
    GROUP BY scenario_order, use_biz_code, price_floor, face_value, valid_days
), ranked AS (
    SELECT *, sum(coupons) OVER (PARTITION BY scenario_order)::BIGINT AS scenario_coupons,
           row_number() OVER (
               PARTITION BY scenario_order
               ORDER BY coupons DESC, users DESC, use_biz_code NULLS LAST,
                        price_floor NULLS LAST, face_value NULLS LAST, valid_days NULLS LAST
           ) AS rule_rank
    FROM grouped
)
SELECT scenarios.scenario_name AS "场景", rule_rank AS "场景内排名",
       coalesce(use_biz_code, '（缺失）') AS "使用业务线",
       price_floor AS "实际门槛（原表单位）", face_value AS "原始面额（原表单位）",
       valid_days AS "有效期天数（含首尾）",
       coupons AS "券数", users AS "去重用户数", scenario_coupons AS "场景确认用券数",
       round(100.0 * coupons / nullif(scenario_coupons, 0), 6)::DECIMAL(10, 6) AS "占场景确认用券比例（%）"
FROM ranked JOIN rules21_scenarios AS scenarios USING (scenario_order)
ORDER BY ranked.scenario_order, rule_rank;

COPY (SELECT * FROM rules21_export) TO '数据清洗/21_第二单候选券规则.csv' (FORMAT CSV, HEADER true);
SELECT * FROM rules21_export WHERE "场景内排名" <= 3;
