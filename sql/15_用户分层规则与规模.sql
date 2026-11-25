-- 在项目根目录的 PowerShell 中运行：
-- $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
-- Get-Content -LiteralPath 'sql/15_用户分层规则与规模.sql' -Raw -Encoding utf8 | duckdb -no-agent -bail -csv

ATTACH '_local/meituan_analysis.duckdb' AS meituan_analysis;

CREATE TEMP TABLE user15_segment_rules AS
SELECT * FROM (VALUES
    (1, '常访问、尚未支付', '0 笔订单，访问天数 ≥ 9'),
    (2, '其他未支付', '0 笔订单，访问天数 < 9'),
    (3, '仅支付一次', '1 笔订单'),
    (4, '已多次支付 · 较高消费 · 有券占比较高', '至少 2 笔订单，累计实付 ≥ 306.23，有券订单占比 ≥ 50%'),
    (5, '已多次支付 · 较高消费 · 有券占比较低', '至少 2 笔订单，累计实付 ≥ 306.23，有券订单占比 < 50%'),
    (6, '已多次支付 · 较低消费 · 有券占比较高', '至少 2 笔订单，累计实付 < 306.23，有券订单占比 ≥ 50%'),
    (7, '已多次支付 · 较低消费 · 有券占比较低', '至少 2 笔订单，累计实付 < 306.23，有券订单占比 < 50%')
) AS rules(segment_order, segment_name, segment_rule);

BEGIN TRANSACTION;

-- 直接保留原基线的前三组，仅对已多次支付组按第 15 步中位数交叉分层。
-- paid_amount 沿用原表单位，coupon_order_share 在底表中以 0–1 的比例存放。
CREATE OR REPLACE TABLE meituan_analysis.main.user_profile_segments AS
WITH assigned AS (
    SELECT baseline.*,
           CASE WHEN group_order IN (1, 2, 3) THEN group_order
                WHEN group_order = 4 AND paid_amount >= 306.23 AND coupon_order_share >= 0.50 THEN 4
                WHEN group_order = 4 AND paid_amount >= 306.23 AND coupon_order_share < 0.50 THEN 5
                WHEN group_order = 4 AND paid_amount < 306.23 AND coupon_order_share >= 0.50 THEN 6
                WHEN group_order = 4 AND paid_amount < 306.23 AND coupon_order_share < 0.50 THEN 7
           END AS segment_order
    FROM meituan_analysis.main.user_profile_baseline AS baseline
)
SELECT assigned.*, rules.segment_name
FROM assigned LEFT JOIN user15_segment_rules AS rules USING (segment_order);

COMMIT;

CREATE TEMP VIEW user15_segments_overview AS
WITH counts AS (
    SELECT segment_order, count(*) AS users
    FROM meituan_analysis.main.user_profile_segments
    GROUP BY segment_order
)
SELECT rules.*, coalesce(counts.users, 0) AS users,
       100.0 * coalesce(counts.users, 0) / nullif(sum(counts.users) OVER (), 0) AS user_pct
FROM user15_segment_rules AS rules LEFT JOIN counts USING (segment_order);

-- 核对分层明细的唯一性、未分组人数和七组加总。
WITH user_counts AS (
    SELECT count(*) AS detail_rows, count(DISTINCT User_id) AS distinct_users,
           count(*) FILTER (WHERE User_id IS NULL) AS missing_user_ids,
           count(*) FILTER (WHERE segment_name IS NULL) AS unassigned_users
    FROM meituan_analysis.main.user_profile_segments
), totals AS (
    SELECT *,
           (SELECT count(*) FROM meituan_analysis.main.user_profile_baseline) AS baseline_users,
           (SELECT sum(users)::BIGINT FROM user15_segments_overview) AS grouped_users
    FROM user_counts
)
SELECT baseline_users AS "基线人数", detail_rows AS "分层明细行数", distinct_users AS "分层去重人数",
       missing_user_ids AS "缺失用户ID数",
       detail_rows - missing_user_ids - distinct_users AS "重复用户超出行数",
       unassigned_users AS "未分组人数", grouped_users AS "七组人数合计",
       grouped_users - baseline_users AS "七组较基线差额", grouped_users - 46711 AS "七组较46711差额"
FROM totals;

CREATE TEMP VIEW user15_segments_export AS
SELECT segment_name AS "最终分组", segment_rule AS "2023年1至3月划分规则（实付按原表单位）",
       users AS "人数", round(user_pct, 6)::DECIMAL(10, 6) AS "人数占比（%）"
FROM user15_segments_overview
ORDER BY segment_order;

COPY (SELECT * FROM user15_segments_export) TO '数据清洗/15_用户分层规则与规模.csv' (FORMAT CSV, HEADER true);
SELECT * FROM user15_segments_export;
