-- 在项目根目录的 PowerShell 中运行：
-- $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
-- Get-Content -LiteralPath 'sql/09_访问与下单关系.sql' -Raw -Encoding utf8 | duckdb -no-agent -bail -csv
-- 脚本更新两张汇总表并导出 CSV。终端另外展示与第 05 步的七项支付人数对账。

ATTACH '_local/meituan_analysis.duckdb' AS meituan_analysis;

SET threads = 4;
SET VARIABLE visit09_start = DATE '2023-01-01';
SET VARIABLE visit09_end = DATE '2023-06-30';
SET VARIABLE visit09_cutoff = getvariable('visit09_end') - 7;

-- 访问 CSV 全量按文本读入。保留非缺失用户 ID 原值，日期沿用 YYYY-MM-DD。
CREATE OR REPLACE TEMP TABLE visit09_days AS
WITH parsed AS (
    SELECT CASE WHEN upper(trim(User_id)) NOT IN ('', 'NULL') THEN User_id END AS user_id,
           try_strptime(trim(Visit_date), '%Y-%m-%d')::DATE AS visit_day
    FROM read_csv('_local/raw/06 美团业务选题-优惠券投放提效分析-数据3-user_visit_detail.csv',
                  header = true, delim = ',', all_varchar = true, ignore_errors = false)
)
SELECT user_id, visit_day
FROM parsed
WHERE user_id IS NOT NULL
  AND visit_day BETWEEN getvariable('visit09_start') AND getvariable('visit09_end');

CREATE OR REPLACE TEMP TABLE visit09_paid_days AS
SELECT DISTINCT User_id AS user_id, Pay_date AS pay_day
FROM meituan_analysis.main.orders_clean
WHERE User_id IS NOT NULL
  AND Pay_date BETWEEN getvariable('visit09_start') AND getvariable('visit09_end');

-- 先在两侧分别按用户和月份去重，再统计当月两种行为均有记录的用户。
CREATE OR REPLACE TEMP TABLE visit09_monthly_metrics AS
WITH months AS (
    SELECT month_begin::DATE AS month_start
    FROM generate_series(getvariable('visit09_start'), getvariable('visit09_end'), INTERVAL 1 MONTH)
         AS calendar(month_begin)
), visits AS (
    SELECT DISTINCT date_trunc('month', visit_day)::DATE AS month_start, user_id
    FROM visit09_days
), payments AS (
    SELECT DISTINCT date_trunc('month', pay_day)::DATE AS month_start, user_id
    FROM visit09_paid_days
), counted AS (
    SELECT month_start, count(visits.user_id) AS visiting_users,
           count(payments.user_id) AS paying_users,
           count(*) FILTER (WHERE visits.user_id IS NOT NULL AND payments.user_id IS NOT NULL) AS overlapping_users
    FROM visits
    FULL JOIN payments USING (month_start, user_id)
    GROUP BY month_start
)
SELECT months.month_start,
       coalesce(counted.visiting_users, 0) AS visiting_users,
       coalesce(counted.paying_users, 0) AS paying_users,
       coalesce(counted.overlapping_users, 0) AS overlapping_users
FROM months LEFT JOIN counted USING (month_start);

CREATE OR REPLACE TEMP TABLE visit09_period_metrics AS
WITH first_visits AS (
    SELECT user_id, min(visit_day) AS first_visit_day
    FROM visit09_days
    GROUP BY user_id
), payers AS (
    SELECT DISTINCT user_id FROM visit09_paid_days
), visits_counted AS (
    SELECT count(*) AS visiting_users,
           count(*) FILTER (WHERE first_visit_day <= getvariable('visit09_cutoff')) AS eligible_users,
           count(*) FILTER (WHERE first_visit_day > getvariable('visit09_cutoff')) AS excluded_users
    FROM first_visits
), both_counted AS (
    SELECT count(*) AS overlapping_users
    FROM first_visits SEMI JOIN payers USING (user_id)
), window_paid AS (
    -- 半连接只保留命中的访问用户。第 0 天的支付不进入第 1–7 天指标。
    SELECT count(*) AS paid_in_window
    FROM first_visits AS visit
    SEMI JOIN visit09_paid_days AS payment
        ON visit.user_id = payment.user_id
       AND payment.pay_day BETWEEN visit.first_visit_day + 1 AND visit.first_visit_day + 7
    WHERE visit.first_visit_day <= getvariable('visit09_cutoff')
)
SELECT visits_counted.*, (SELECT count(*) FROM payers) AS paying_users,
       both_counted.overlapping_users, window_paid.paid_in_window
FROM visits_counted CROSS JOIN both_counted CROSS JOIN window_paid;

BEGIN TRANSACTION;

CREATE OR REPLACE TABLE meituan_analysis.main.visit_order_monthly AS
SELECT * FROM visit09_monthly_metrics;

CREATE OR REPLACE TABLE meituan_analysis.main.visit_order_summary AS
SELECT metric_order, metric, user_count, numerator, denominator,
       numerator::DOUBLE / nullif(denominator, 0) AS rate,
       getvariable('visit09_start') AS sample_start,
       getvariable('visit09_end') AS sample_end,
       first_visit_cutoff,
       observation_window
FROM visit09_period_metrics
CROSS JOIN LATERAL (VALUES
    (1, '全期去重访问人数', visiting_users, NULL, NULL, NULL::DATE,
        '样本期内至少访问一次，按用户去重。'),
    (2, '全期去重支付人数', paying_users, NULL, NULL, NULL::DATE,
        '样本期内至少支付一次，按用户去重。'),
    (3, '全期既访问又支付的去重人数', overlapping_users, NULL, NULL, NULL::DATE,
        '样本期内两种行为均有记录，按用户去重。'),
    (4, '访问用户中同期有支付的比例', NULL, overlapping_users, visiting_users, NULL::DATE,
        '全期既访问又支付的去重人数 ÷ 全期去重访问人数。'),
    (5, '符合完整观察条件的访问人数', eligible_users, NULL, NULL, getvariable('visit09_cutoff'),
        '样本期首次访问最晚为 6 月 23 日，之后可完整观察 7 个自然日。'),
    (6, '因观察时间不足排除的人数', excluded_users, NULL, NULL, getvariable('visit09_cutoff'),
        '样本期首次访问在 6 月 24–30 日。'),
    (7, '样本期首次访问后第 1–7 天内有支付人数', paid_in_window, NULL, NULL, getvariable('visit09_cutoff'),
        '符合完整观察条件的同一用户在首次访问后第 1–7 天内至少支付一次，首尾日期均计入，每人只计一次。'),
    (8, '样本期首次访问后第 1–7 天内有支付比例', NULL, paid_in_window, eligible_users, getvariable('visit09_cutoff'),
        '第 1–7 天内有支付人数 ÷ 符合完整观察条件的访问人数。同日记第 0 天，同日先后需更细的时间信息。')
) AS rows(metric_order, metric, user_count, numerator, denominator, first_visit_cutoff, observation_window);

COMMIT;

CREATE OR REPLACE TEMP VIEW visit09_monthly_export AS
SELECT strftime(month_start, '%Y-%m') AS "月份", visiting_users AS "去重访问人数",
       paying_users AS "去重支付人数", overlapping_users AS "同月既访问又支付人数"
FROM meituan_analysis.main.visit_order_monthly
ORDER BY month_start;

CREATE OR REPLACE TEMP VIEW visit09_summary_export AS
SELECT metric AS "指标", user_count AS "人数", numerator AS "分子人数", denominator AS "分母人数",
       round(100 * rate, 6)::DECIMAL(10, 6) AS "比例（%）",
       sample_start AS "样本期起日", sample_end AS "样本期止日",
       first_visit_cutoff AS "完整观察的首次访问截止日", observation_window AS "观察窗口与口径"
FROM meituan_analysis.main.visit_order_summary
ORDER BY metric_order;

COPY (SELECT * FROM visit09_monthly_export) TO '数据清洗/09_月度访问与下单.csv' (FORMAT CSV, HEADER true);
COPY (SELECT * FROM visit09_summary_export) TO '数据清洗/09_全期访问与下单.csv' (FORMAT CSV, HEADER true);

SELECT * FROM visit09_monthly_export;
SELECT * FROM visit09_summary_export;

-- 全期基准为第 05 步从底表全期直接去重得到的 47,208 人。
WITH checks AS (
    SELECT strftime(current.month_start, '%Y-%m') AS period, current.paying_users AS actual,
           baseline.paying_user_count AS expected
    FROM meituan_analysis.main.visit_order_monthly AS current
    LEFT JOIN meituan_analysis.main.monthly_overview AS baseline USING (month_start)
    UNION ALL
    SELECT '全期', paying_users, 47208 FROM visit09_period_metrics
)
SELECT period AS "对账期间", actual AS "本步去重支付人数", expected AS "第05步去重支付人数",
       actual - expected AS "差额", CASE WHEN actual = expected THEN '通过' ELSE '差异' END AS "结果"
FROM checks
ORDER BY CASE WHEN period = '全期' THEN 1 ELSE 0 END, period;
