-- 在项目根目录的 PowerShell 中运行：
-- $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
-- Get-Content -LiteralPath 'sql/17_人群门槛核销对比.sql' -Raw -Encoding utf8 | duckdb -no-agent -bail -csv

ATTACH '_local/meituan_analysis.duckdb' AS meituan_analysis (READ_ONLY);
SET threads = 4;
SET preserve_insertion_order = false;
SET VARIABLE followup_start = DATE '2023-04-01';
SET VARIABLE followup_end = DATE '2023-06-30';

CREATE TEMP MACRO segment17_text(raw_value) AS
    CASE WHEN upper(trim(raw_value)) NOT IN ('', 'NULL') THEN raw_value END;

-- 沿用第 13 步的金额解析和对应门槛。原表金额单位保持不变。
CREATE TEMP MACRO segment17_amount(raw_value) AS
    CASE WHEN regexp_full_match(trim(raw_value), '[+-]?([0-9]+(\.[0-9]{1,4})?|\.[0-9]{1,4})')
         THEN try_cast(trim(raw_value) AS DECIMAL(18, 4)) END;

CREATE TEMP VIEW segment17_users AS
SELECT User_id AS user_id, segment_order, segment_name
FROM meituan_analysis.main.user_profile_segments;

CREATE TEMP TABLE segment17_counts AS
WITH parsed AS (
    SELECT segment17_text(User_id) AS user_id, segment17_text(Coupon_status) AS status_code,
           try_strptime(trim(segment17_text(Receive_date)), '%Y-%m-%d')::DATE AS receive_day,
           segment17_amount(Price_limit) AS price_floor
    FROM read_csv('_local/raw/06 美团业务选题-优惠券投放提效分析-数据2-user_coupon_receive.csv',
                  header = true, delim = ',', all_varchar = true, ignore_errors = false)
), classified AS (
    SELECT users.segment_order, receipts.status_code,
           CASE WHEN price_floor IS NULL OR price_floor < 0 THEN 4
                WHEN price_floor <= 10 THEN 1
                WHEN price_floor <= 30 THEN 2
                ELSE 3 END AS tier_order
    FROM parsed AS receipts JOIN segment17_users AS users USING (user_id)
    -- 与 6.2 一致，按有效领券日归入整个二季度，保留短有效期券。
    WHERE receive_day BETWEEN getvariable('followup_start') AND getvariable('followup_end')
)
SELECT segment_order, tier_order, count(*) AS receipts, count(*) FILTER (WHERE status_code = '2') AS used
FROM classified
GROUP BY segment_order, tier_order;

CREATE TEMP VIEW segment17_groups AS
SELECT DISTINCT segment_order, segment_name FROM segment17_users;

-- 四档只在这里一并对账；门槛缺失或无效行不进入热力图。
WITH from_tiers AS (
    SELECT groups.segment_order, groups.segment_name,
           coalesce(sum(counts.receipts), 0)::BIGINT AS total_receipts,
           coalesce(sum(counts.used), 0)::BIGINT AS total_used,
           coalesce(sum(counts.receipts) FILTER (WHERE tier_order = 4), 0)::BIGINT AS invalid_receipts,
           coalesce(sum(counts.used) FILTER (WHERE tier_order = 4), 0)::BIGINT AS invalid_used
    FROM segment17_groups AS groups LEFT JOIN segment17_counts AS counts USING (segment_order)
    GROUP BY groups.segment_order, groups.segment_name
), reference AS (
    SELECT "最终分组" AS segment_name, "领券数"::BIGINT AS receipts, "已用券数"::BIGINT AS used
    FROM read_csv('数据清洗/16_分层后续表现.csv', header = true, all_varchar = true)
)
SELECT segment_name AS "最终分组", total_receipts - invalid_receipts AS "三档领券数",
       invalid_receipts AS "门槛缺失或无效领券数", reference.receipts AS "6.2领券数",
       total_receipts - reference.receipts AS "领券数差额",
       total_used - invalid_used AS "三档已用券数", invalid_used AS "门槛缺失或无效已用券数",
       reference.used AS "6.2已用券数", total_used - reference.used AS "已用券数差额"
FROM from_tiers FULL JOIN reference USING (segment_name)
ORDER BY segment_order NULLS LAST;

CREATE TEMP VIEW segment17_export AS
WITH tiers AS (
    SELECT * FROM (VALUES (1, '低门槛（含无门槛）'), (2, '中门槛'), (3, '高门槛'))
        AS labels(tier_order, tier_name)
)
SELECT groups.segment_order AS "分组顺序", groups.segment_name AS "最终分组",
       tiers.tier_order AS "门槛顺序", tiers.tier_name AS "门槛档",
       coalesce(counts.receipts, 0) AS "领券数", coalesce(counts.used, 0) AS "已用券数",
       round(100.0 * counts.used / nullif(counts.receipts, 0), 6)::DECIMAL(10, 6) AS "核销率（%）"
FROM segment17_groups AS groups CROSS JOIN tiers
LEFT JOIN segment17_counts AS counts
    ON groups.segment_order = counts.segment_order AND tiers.tier_order = counts.tier_order
ORDER BY groups.segment_order, tiers.tier_order;

COPY (SELECT * FROM segment17_export) TO '数据清洗/17_人群门槛核销对比.csv' (FORMAT CSV, HEADER true);
SELECT * FROM segment17_export;
