-- 在项目根目录的 PowerShell 中运行以下两行：
-- $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
-- Get-Content -LiteralPath 'sql/05_月度经营表现.sql' -Raw -Encoding utf8 | duckdb -no-agent -bail -csv
-- 脚本更新 monthly_overview、导出月度 CSV，并在终端单独输出对账、缺失影响、
-- 未取整的成交额还原校验和环比变化最大的月份。

ATTACH '_local/meituan_analysis.duckdb' AS meituan_analysis;

SET VARIABLE period_start = DATE '2023-01-01';
SET VARIABLE period_end = DATE '2023-07-01';

CREATE OR REPLACE TEMP VIEW month05_orders AS
SELECT *
FROM meituan_analysis.main.orders_clean
WHERE Pay_date >= getvariable('period_start') AND Pay_date < getvariable('period_end');

BEGIN TRANSACTION;

CREATE OR REPLACE TABLE meituan_analysis.main.monthly_overview (
    month_start DATE PRIMARY KEY,
    calendar_days INTEGER NOT NULL,
    order_count BIGINT NOT NULL,
    paying_user_count BIGINT NOT NULL,
    paid_gmv DECIMAL(38, 4),
    orders_per_paying_user DOUBLE,
    average_order_value DOUBLE,
    recorded_discount_sum DECIMAL(38, 4),
    coupon_order_count BIGINT NOT NULL,
    coupon_order_share DOUBLE,
    positive_discount_order_count BIGINT NOT NULL,
    positive_discount_order_share DOUBLE,
    paid_gmv_mom DOUBLE,
    average_daily_paid_gmv DOUBLE
);

INSERT INTO meituan_analysis.main.monthly_overview
WITH calendar AS (
    SELECT month_start::DATE AS month_start, day(last_day(month_start)) AS calendar_days
    FROM generate_series(
        getvariable('period_start'),
        getvariable('period_end') - INTERVAL 1 MONTH,
        INTERVAL 1 MONTH
    ) AS months(month_start)
), aggregated AS (
    SELECT
        date_trunc('month', Pay_date)::DATE AS month_start,
        count(*) AS order_count,
        count(DISTINCT User_id) AS paying_user_count,
        sum(Actual_pay) AS paid_gmv,
        sum(recorded_discount_sum) AS recorded_discount_sum,
        count(*) FILTER (WHERE has_coupon_id) AS coupon_order_count,
        count(*) FILTER (WHERE has_positive_discount) AS positive_discount_order_count
    FROM month05_orders
    GROUP BY month_start
), monthly AS (
    SELECT
        calendar.month_start,
        calendar.calendar_days,
        coalesce(aggregated.order_count, 0) AS order_count,
        coalesce(aggregated.paying_user_count, 0) AS paying_user_count,
        CASE WHEN aggregated.order_count IS NULL THEN 0 ELSE aggregated.paid_gmv END AS paid_gmv,
        CASE WHEN aggregated.order_count IS NULL THEN 0 ELSE aggregated.recorded_discount_sum END
            AS recorded_discount_sum,
        coalesce(aggregated.coupon_order_count, 0) AS coupon_order_count,
        coalesce(aggregated.positive_discount_order_count, 0) AS positive_discount_order_count
    FROM calendar
    LEFT JOIN aggregated USING (month_start)
)
SELECT
    month_start,
    calendar_days,
    order_count,
    paying_user_count,
    paid_gmv,
    order_count::DOUBLE / nullif(paying_user_count, 0) AS orders_per_paying_user,
    paid_gmv / nullif(order_count, 0) AS average_order_value,
    recorded_discount_sum,
    coupon_order_count,
    coupon_order_count::DOUBLE / nullif(order_count, 0) AS coupon_order_share,
    positive_discount_order_count,
    positive_discount_order_count::DOUBLE / nullif(order_count, 0) AS positive_discount_order_share,
    paid_gmv / nullif(lag(paid_gmv) OVER (ORDER BY month_start), 0) - 1 AS paid_gmv_mom,
    paid_gmv / calendar_days AS average_daily_paid_gmv
FROM monthly
ORDER BY month_start;

COMMIT;

-- 数据库保留未取整的派生指标，比例为小数。CSV 的比例按百分比数值导出。
CREATE OR REPLACE TEMP VIEW month05_export AS
SELECT
    strftime(month_start, '%Y-%m') AS "月份",
    calendar_days AS "自然日天数",
    order_count AS "订单数",
    paying_user_count AS "去重支付人数",
    paid_gmv AS "实付成交额",
    round(orders_per_paying_user, 6)::DECIMAL(24, 6) AS "人均订单数",
    round(average_order_value, 6)::DECIMAL(24, 6) AS "客单价",
    recorded_discount_sum AS "记录的减免明细合计",
    coupon_order_count AS "有券记录订单数",
    round(100 * coupon_order_share, 6)::DECIMAL(16, 6) AS "有券记录订单占比（%）",
    positive_discount_order_count AS "正减免订单数",
    round(100 * positive_discount_order_share, 6)::DECIMAL(16, 6) AS "正减免订单占比（%）",
    round(100 * paid_gmv_mom, 6)::DECIMAL(16, 6) AS "实付成交额环比（%）",
    round(average_daily_paid_gmv, 6)::DECIMAL(24, 6) AS "日均实付成交额"
FROM meituan_analysis.main.monthly_overview
ORDER BY month_start;

COPY (SELECT * FROM month05_export) TO '数据清洗/05_月度经营表现.csv' (FORMAT CSV, HEADER true);

SELECT * FROM month05_export;

-- 六个月合计对照第 04 步，金额差额以定点小数计算。
WITH totals AS (
    SELECT count(*) AS months,
           sum(order_count) AS orders,
           sum(paid_gmv) AS paid,
           sum(recorded_discount_sum) AS discount
    FROM meituan_analysis.main.monthly_overview
)
SELECT
    item AS "对账项",
    CASE WHEN unit = '原表金额单位' THEN actual::VARCHAR ELSE actual::BIGINT::VARCHAR END AS "实际值",
    CASE WHEN unit = '原表金额单位' THEN baseline::VARCHAR ELSE baseline::BIGINT::VARCHAR END AS "对账基准",
    CASE WHEN unit = '原表金额单位' THEN (actual - baseline)::VARCHAR
         ELSE (actual - baseline)::BIGINT::VARCHAR END AS "差额",
    unit AS "统计单位",
    CASE WHEN actual IS NULL THEN '无法对账' WHEN actual = baseline THEN '通过' ELSE '差异' END AS "结果"
FROM totals
CROSS JOIN LATERAL (VALUES
    (1, '月份数', months, 6, '个月'),
    (2, '订单数合计', orders, 973363, '笔订单'),
    (3, '实付成交额合计', paid, 39389606.4200::DECIMAL(38, 4), '原表金额单位'),
    (4, '记录的减免明细合计', discount, 2228200.0106::DECIMAL(38, 4), '原表金额单位')
) AS checks(check_no, item, actual, baseline, unit)
ORDER BY check_no;

SELECT count(DISTINCT User_id) AS "2023年1至6月全期去重支付人数"
FROM month05_orders;

-- 日期缺失的订单无法归月。期间内用户缺失的订单保留于订单和金额指标，支付人数只统计可识别的用户。
WITH gaps AS (
    SELECT
        Pay_date IS NULL AS missing_pay_date,
        User_id IS NULL AS missing_user_id,
        Pay_date >= getvariable('period_start') AND Pay_date < getvariable('period_end') AS in_period,
        Actual_pay, recorded_discount_sum
    FROM meituan_analysis.main.orders_clean
)
SELECT
    category AS "缺失或范围检查",
    count(*) FILTER (WHERE affected) AS "订单数",
    coalesce(sum(Actual_pay) FILTER (WHERE affected), 0) AS "涉及的实付成交额",
    coalesce(sum(recorded_discount_sum) FILTER (WHERE affected), 0) AS "涉及的记录减免明细合计",
    impact AS "指标影响"
FROM gaps
CROSS JOIN LATERAL (VALUES
    (1, '支付日缺失', missing_pay_date, '无法归月，涉及订单和金额单列。'),
    (2, '用户 ID 缺失（全部底表）', missing_user_id, '无法识别支付用户，其中可归入本期的订单单列。'),
    (3, '用户 ID 缺失（期间内）', in_period AND missing_user_id, '计入当月订单和金额，支付人数只统计可识别的用户。'),
    (4, '支付日有效但在期间外', NOT missing_pay_date AND NOT in_period, '归属期间之外，订单和金额单列。')
) AS flags(check_no, category, affected, impact)
GROUP BY check_no, category, impact
ORDER BY check_no;

-- 汇总金额保留四位小数。派生比率以未四舍五入的 DOUBLE 参与乘法，并容许 0.00000001 的浮点误差。
WITH rebuilt AS (
    SELECT month_start, paid_gmv,
           paying_user_count * orders_per_paying_user * average_order_value AS rebuilt_paid_gmv
    FROM meituan_analysis.main.monthly_overview
)
SELECT month_start AS "月份",
       paid_gmv AS "实付成交额",
       rebuilt_paid_gmv AS "按三项指标还原的实付成交额",
       rebuilt_paid_gmv - paid_gmv::DOUBLE AS "还原差额",
       CASE WHEN rebuilt_paid_gmv IS NULL OR paid_gmv IS NULL THEN '无法校验'
            WHEN abs(rebuilt_paid_gmv - paid_gmv::DOUBLE) <= 0.00000001 THEN '通过'
            ELSE '差异' END AS "结果"
FROM rebuilt
ORDER BY month_start;

-- 选取环比绝对变化最大的月份，比较该月与上一自然月。
WITH comparison AS (
    SELECT *,
           lag(month_start) OVER months AS prior_month,
           lag(paying_user_count) OVER months AS prior_users,
           lag(orders_per_paying_user) OVER months AS prior_orders_per_user,
           lag(average_order_value) OVER months AS prior_average_order_value,
           lag(average_daily_paid_gmv) OVER months AS prior_daily_paid_gmv
    FROM meituan_analysis.main.monthly_overview
    WINDOW months AS (ORDER BY month_start)
)
SELECT
    prior_month AS "上月",
    month_start AS "选中月份",
    100 * paid_gmv_mom AS "实付成交额环比（%）",
    prior_users AS "上月支付人数",
    paying_user_count AS "当月支付人数",
    100 * (paying_user_count::DOUBLE / nullif(prior_users, 0) - 1) AS "支付人数环比（%）",
    prior_orders_per_user AS "上月人均订单数",
    orders_per_paying_user AS "当月人均订单数",
    100 * (orders_per_paying_user / nullif(prior_orders_per_user, 0) - 1) AS "人均订单数环比（%）",
    prior_average_order_value AS "上月客单价",
    average_order_value AS "当月客单价",
    100 * (average_order_value / nullif(prior_average_order_value, 0) - 1) AS "客单价环比（%）",
    prior_daily_paid_gmv AS "上月日均实付",
    average_daily_paid_gmv AS "当月日均实付",
    100 * (average_daily_paid_gmv / nullif(prior_daily_paid_gmv, 0) - 1) AS "日均实付环比（%）"
FROM comparison
WHERE paid_gmv_mom IS NOT NULL
ORDER BY abs(paid_gmv_mom) DESC, month_start
LIMIT 1;
