-- 在项目根目录的 PowerShell 中运行：
-- $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
-- Get-Content -LiteralPath 'sql/10_日活与日期类型分析.sql' -Raw -Encoding utf8 | duckdb -no-agent -bail -csv
-- 脚本更新两张分析表、导出两份 CSV，并在终端单列日期与领券对账。
-- 节假日来源：国办发明电〔2022〕16 号
-- https://app.www.gov.cn/govdata/gov/202212/08/495070/article.html

ATTACH '_local/meituan_analysis.duckdb' AS meituan_analysis;

SET threads = 4;
SET VARIABLE day10_start = DATE '2023-01-01';
SET VARIABLE day10_end = DATE '2023-06-30';

CREATE OR REPLACE TEMP TABLE day10_calendar AS
WITH days AS (
    SELECT day_value::DATE AS activity_date,
           isodow(day_value) AS weekday_number,
           date_trunc('week', day_value)::DATE AS week_start
    FROM generate_series(getvariable('day10_start'), getvariable('day10_end'), INTERVAL 1 DAY) AS series(day_value)
), holidays (first_day, last_day, holiday_name) AS (
    VALUES (DATE '2023-01-01', DATE '2023-01-02', '元旦'),
           (DATE '2023-01-21', DATE '2023-01-27', '春节'),
           (DATE '2023-04-05', DATE '2023-04-05', '清明节'),
           (DATE '2023-04-29', DATE '2023-05-03', '劳动节'),
           (DATE '2023-06-22', DATE '2023-06-24', '端午节')
), makeup (work_day, holiday_name) AS (
    VALUES (DATE '2023-01-28', '春节'), (DATE '2023-01-29', '春节'),
           (DATE '2023-04-23', '劳动节'), (DATE '2023-05-06', '劳动节'),
           (DATE '2023-06-25', '端午节')
)
SELECT days.activity_date,
       date_trunc('month', days.activity_date)::DATE AS month_start,
       days.weekday_number,
       list_extract(['周一', '周二', '周三', '周四', '周五', '周六', '周日'], days.weekday_number) AS weekday_name,
       days.week_start,
       1 + date_diff('week', date_trunc('week', getvariable('day10_start')), days.week_start) AS sample_week_number,
       CASE WHEN holidays.holiday_name IS NOT NULL THEN '节假日假期'
            WHEN makeup.holiday_name IS NOT NULL THEN '调休上班日'
            WHEN days.weekday_number IN (6, 7) THEN '普通周末'
            ELSE '普通工作日' END AS day_type,
       coalesce(holidays.holiday_name, makeup.holiday_name) AS holiday_name
FROM days
LEFT JOIN holidays ON days.activity_date BETWEEN holidays.first_day AND holidays.last_day
LEFT JOIN makeup ON days.activity_date = makeup.work_day;

CREATE OR REPLACE TEMP TABLE day10_visit_counts AS
WITH parsed AS (
    SELECT CASE WHEN upper(trim(User_id)) NOT IN ('', 'NULL') THEN User_id END AS user_id,
           try_strptime(trim(Visit_date), '%Y-%m-%d')::DATE AS visit_day
    FROM read_csv('_local/raw/06 美团业务选题-优惠券投放提效分析-数据3-user_visit_detail.csv',
                  header = true, delim = ',', all_varchar = true, ignore_errors = false)
)
SELECT visit_day AS activity_date, count(DISTINCT user_id) AS visiting_users
FROM parsed
WHERE visit_day BETWEEN getvariable('day10_start') AND getvariable('day10_end')
GROUP BY visit_day;

-- 单次扫描同时保留有效日期分组、缺失和解析失败记录，供逐日汇总及对账。
CREATE OR REPLACE TEMP TABLE day10_coupon_counts AS
WITH normalized AS (
    SELECT nullif(nullif(upper(trim(Receive_date)), ''), 'NULL') AS date_text
    FROM read_csv('_local/raw/06 美团业务选题-优惠券投放提效分析-数据2-user_coupon_receive.csv',
                  header = true, delim = ',', all_varchar = true, ignore_errors = false)
), parsed AS (
    SELECT date_text, try_strptime(date_text, '%Y-%m-%d')::DATE AS receive_day
    FROM normalized
)
SELECT receive_day AS activity_date, count(*) AS coupon_count,
       count(*) FILTER (WHERE date_text IS NULL) AS missing_date,
       count(*) FILTER (WHERE date_text IS NOT NULL AND receive_day IS NULL) AS failed_date
FROM parsed
GROUP BY receive_day;

CREATE OR REPLACE TEMP TABLE day10_paid_counts AS
SELECT Pay_date AS activity_date, count(DISTINCT User_id) AS paying_users
FROM meituan_analysis.main.orders_clean
WHERE Pay_date BETWEEN getvariable('day10_start') AND getvariable('day10_end')
GROUP BY Pay_date;

BEGIN TRANSACTION;

CREATE OR REPLACE TABLE meituan_analysis.main.daily_activity AS
WITH daily AS (
    SELECT calendar.*, coalesce(visits.visiting_users, 0) AS visiting_users,
           coalesce(coupons.coupon_count, 0) AS coupon_receive_count,
           coalesce(payments.paying_users, 0) AS paying_users
    FROM day10_calendar AS calendar
    LEFT JOIN day10_visit_counts AS visits USING (activity_date)
    LEFT JOIN day10_coupon_counts AS coupons USING (activity_date)
    LEFT JOIN day10_paid_counts AS payments USING (activity_date)
)
SELECT *,
       CASE WHEN count(*) OVER last_seven = 7 THEN avg(visiting_users) OVER last_seven END AS visiting_users_7d_average
FROM daily
WINDOW last_seven AS (ORDER BY activity_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW);

CREATE OR REPLACE TABLE meituan_analysis.main.day_type_overview AS
SELECT day_type, count(*) AS day_count,
       sum(visiting_users)::BIGINT AS visiting_user_days, sum(coupon_receive_count)::BIGINT AS coupon_receive_count,
       sum(paying_users)::BIGINT AS paying_user_days,
       avg(visiting_users) AS avg_daily_visiting_users, avg(coupon_receive_count) AS avg_daily_coupon_receives,
       avg(paying_users) AS avg_daily_paying_users
FROM meituan_analysis.main.daily_activity
GROUP BY day_type;

COMMIT;

COPY (
    SELECT activity_date AS "日期", strftime(month_start, '%Y-%m') AS "月份",
           weekday_number AS "星期序号", weekday_name AS "星期几", week_start AS "周起始日期",
           sample_week_number AS "样本周次", day_type AS "日期类型", holiday_name AS "节假日名称",
           visiting_users AS "去重访问人数", coupon_receive_count AS "领券量", paying_users AS "去重支付人数",
           round(visiting_users_7d_average, 6)::DECIMAL(16, 6) AS "访问人数7日移动平均"
    FROM meituan_analysis.main.daily_activity
    ORDER BY activity_date
) TO '数据清洗/10_日活与日期类型分析.csv' (FORMAT CSV, HEADER true);

CREATE OR REPLACE TEMP VIEW day10_type_export AS
SELECT day_type AS "日期类型", day_count AS "天数",
       round(avg_daily_visiting_users, 6)::DECIMAL(16, 6) AS "日均访问人数",
       round(avg_daily_coupon_receives, 6)::DECIMAL(16, 6) AS "日均领券量",
       round(avg_daily_paying_users, 6)::DECIMAL(16, 6) AS "日均支付人数",
       visiting_user_days AS "访问人日", coupon_receive_count AS "领券量合计", paying_user_days AS "支付人日"
FROM meituan_analysis.main.day_type_overview
ORDER BY CASE day_type WHEN '普通工作日' THEN 1 WHEN '普通周末' THEN 2 WHEN '节假日假期' THEN 3 ELSE 4 END;

COPY (SELECT * FROM day10_type_export) TO '数据清洗/10_日期类型对比.csv' (FORMAT CSV, HEADER true);
SELECT * FROM day10_type_export;

SELECT round(100 * (weekend.avg_daily_visiting_users / nullif(workday.avg_daily_visiting_users, 0) - 1), 6)
           AS "普通周末相对普通工作日日均访问变化（%）",
       round(100 * (weekend.avg_daily_coupon_receives / nullif(workday.avg_daily_coupon_receives, 0) - 1), 6)
           AS "普通周末相对普通工作日日均领券变化（%）",
       round(100 * (weekend.avg_daily_paying_users / nullif(workday.avg_daily_paying_users, 0) - 1), 6)
           AS "普通周末相对普通工作日日均支付变化（%）"
FROM meituan_analysis.main.day_type_overview AS weekend
CROSS JOIN meituan_analysis.main.day_type_overview AS workday
WHERE weekend.day_type = '普通周末' AND workday.day_type = '普通工作日';

SELECT activity_date AS "节假日假期访问人数最低日", holiday_name AS "节假日名称",
       visiting_users AS "去重访问人数", coupon_receive_count AS "领券量", paying_users AS "去重支付人数"
FROM meituan_analysis.main.daily_activity
WHERE day_type = '节假日假期'
ORDER BY visiting_users, activity_date
LIMIT 1;

SELECT count(*) AS "日期行数", count(DISTINCT activity_date) AS "不同日期数",
       (SELECT sum(day_count) FROM meituan_analysis.main.day_type_overview) AS "四类日期天数合计",
       sum(coupon_receive_count) AS "逐日领券量合计", 12406240 AS "第03步领券日有效记录数",
       sum(coupon_receive_count) - 12406240 AS "领券量对账差额",
       sum(visiting_users) AS "全期访问人日", sum(paying_users) AS "全期支付人日",
       count(*) FILTER (WHERE visiting_users_7d_average IS NULL) AS "移动平均留空天数"
FROM meituan_analysis.main.daily_activity;

SELECT coalesce(sum(missing_date), 0) AS "领券日缺失记录数",
       coalesce(sum(failed_date), 0) AS "领券日解析失败记录数",
       coalesce(sum(coupon_count) FILTER (
           WHERE activity_date NOT BETWEEN getvariable('day10_start') AND getvariable('day10_end')
       ), 0) AS "日期有效但在样本期外的领券记录数"
FROM day10_coupon_counts;
