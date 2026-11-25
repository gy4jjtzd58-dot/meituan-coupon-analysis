ATTACH '_local/meituan_analysis.duckdb' AS meituan_analysis (READ_ONLY);

COPY (
    WITH baselines AS (
        SELECT month_start,
               avg(paying_users) FILTER (WHERE day_type = '普通工作日') AS workday_payers,
               avg(paying_users) FILTER (WHERE day_type = '普通周末') AS weekend_payers
        FROM meituan_analysis.main.daily_activity
        GROUP BY month_start
    ), daily_holidays AS (
        SELECT activity_date, holiday_name, paying_users, workday_payers, weekend_payers
        FROM meituan_analysis.main.daily_activity
        JOIN baselines USING (month_start)
        WHERE day_type = '节假日假期'
    ), holidays AS (
        SELECT holiday_name AS holiday, min(activity_date) AS first_day, count(*) AS day_count,
               avg(paying_users) AS daily_payers,
               avg(workday_payers) AS workday_payers, avg(weekend_payers) AS weekend_payers
        FROM daily_holidays
        GROUP BY holiday_name
        UNION ALL
        SELECT '其余假期合计', DATE '2023-07-01', count(*), avg(paying_users),
               avg(workday_payers), avg(weekend_payers)
        FROM daily_holidays
        WHERE holiday_name <> '春节'
    )
    SELECT row_number() OVER (ORDER BY first_day) AS "节日顺序",
           holiday AS "节假日", day_count AS "假期天数",
           round(daily_payers, 6) AS "日均支付人数",
           round(workday_payers, 6) AS "同月工作日日均支付人数",
           round(weekend_payers, 6) AS "同月周末日均支付人数",
           round(100 * (daily_payers / nullif(workday_payers, 0) - 1), 6) AS "较同月工作日变化（%）",
           round(100 * (daily_payers / nullif(weekend_payers, 0) - 1), 6) AS "较同月周末变化（%）"
    FROM holidays
    ORDER BY first_day
) TO '数据清洗/18_节假日同月支付对比.csv' (FORMAT CSV, HEADER true);
