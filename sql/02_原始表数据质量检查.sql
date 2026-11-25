-- 在项目根目录的 PowerShell 中运行：
-- $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
-- Get-Content -LiteralPath 'sql/02_原始表数据质量检查.sql' -Raw -Encoding utf8 | duckdb -no-agent -bail -csv
-- 全量读取三份原始 CSV，全部字段按文本读取，中间表仅在当前 DuckDB 会话中存在。

SET threads = 4;
SET preserve_insertion_order = false;

CREATE OR REPLACE TEMP VIEW quality_orders_raw AS
SELECT * FROM read_csv('_local/raw/06 美团业务选题-优惠券投放提效分析-数据1-order_detail.csv',
                       header = true, delim = ',', all_varchar = true, ignore_errors = false);

CREATE OR REPLACE TEMP VIEW quality_coupons_raw AS
SELECT * FROM read_csv('_local/raw/06 美团业务选题-优惠券投放提效分析-数据2-user_coupon_receive.csv',
                       header = true, delim = ',', all_varchar = true, ignore_errors = false);

CREATE OR REPLACE TEMP VIEW quality_visits_raw AS
SELECT * FROM read_csv('_local/raw/06 美团业务选题-优惠券投放提效分析-数据3-user_visit_detail.csv',
                       header = true, delim = ',', all_varchar = true, ignore_errors = false);

-- 空值、空白及文本 NULL 计为缺失。保留其他 ID 和状态码的原始文本。
CREATE OR REPLACE TEMP MACRO quality_missing(raw_value) AS
    coalesce(upper(trim(raw_value)) IN ('', 'NULL'), true);

CREATE OR REPLACE TEMP MACRO quality_present_text(raw_value) AS
    CASE WHEN NOT quality_missing(raw_value) THEN raw_value END;

CREATE OR REPLACE TEMP MACRO quality_date(raw_value) AS
    try_strptime(trim(quality_present_text(raw_value)), '%Y-%m-%d')::DATE;

-- 源文件金额最多有 4 位小数。检查定点格式，避免转换时悄悄舍入超出精度的输入。
CREATE OR REPLACE TEMP MACRO quality_amount(raw_value) AS
    CASE WHEN regexp_full_match(trim(raw_value), '[+-]?([0-9]+(\.[0-9]{1,4})?|\.[0-9]{1,4})')
         THEN try_cast(trim(raw_value) AS DECIMAL(18, 4)) END;

CREATE OR REPLACE TEMP TABLE quality_report (
    table_no INTEGER,
    check_no INTEGER,
    table_name VARCHAR,
    check_target VARCHAR,
    check_name VARCHAR,
    check_group VARCHAR,
    result VARCHAR,
    unit VARCHAR,
    definition VARCHAR
);

-- 订单表：按九个原始字段检查整行重复，保留原值、空值和文本 NULL 的区别。
INSERT INTO quality_report
WITH raw_row_groups AS (
    SELECT *, count(*) AS copies
    FROM quality_orders_raw
    GROUP BY ALL
), duplicate_metrics AS (
    SELECT
        coalesce(sum(copies - 1), 0) AS excess_rows,
        coalesce(sum(copies) FILTER (WHERE copies > 1), 0) AS rows_in_duplicate_groups
    FROM raw_row_groups
)
SELECT 1, check_no, '订单表', '整行', check_name, NULL, result::VARCHAR, '行', definition
FROM duplicate_metrics
CROSS JOIN LATERAL (VALUES
    (1, '完全重复的超出行数', excess_rows, '每组完全相同的行保留一行，统计其余行。'),
    (2, '完全重复组的全部行数', rows_in_duplicate_groups, '统计完全重复组中的所有行，包含每组首行。')
) AS checks(check_no, check_name, result, definition);

-- 订单表：先保留行级异常计数，再按非缺失的 Order_id 统计订单与实付金额。
CREATE OR REPLACE TEMP TABLE quality_order_metrics AS
WITH parsed AS (
    SELECT
        quality_present_text(Order_id) AS order_key,
        quality_present_text(User_id) AS user_key,
        quality_present_text(Biz_code) AS biz_value,
        quality_date(Pay_date) AS pay_day,
        quality_present_text(Coupon_id) AS coupon_key,
        quality_present_text(Coupon_type) AS coupon_type_value,
        quality_missing(Actual_pay) AS paid_missing,
        quality_amount(Actual_pay) AS paid,
        quality_missing(Reduce_amount) AS reduction_missing,
        quality_amount(Reduce_amount) AS reduction
    FROM quality_orders_raw
), by_order AS (
    SELECT
        order_key,
        count(*) AS row_count,
        min(paid) AS min_paid,
        max(paid) AS max_paid,
        sum(paid) AS detail_paid,
        count(*) FILTER (WHERE paid_missing) AS paid_missing_rows,
        count(*) FILTER (WHERE NOT paid_missing AND paid IS NULL) AS paid_failed_rows,
        count(*) FILTER (WHERE paid < 0) AS paid_negative_rows,
        min(reduction) AS min_reduction,
        max(reduction) AS max_reduction,
        count(*) FILTER (WHERE reduction_missing) AS reduction_missing_rows,
        count(*) FILTER (WHERE NOT reduction_missing AND reduction IS NULL) AS reduction_failed_rows,
        count(*) FILTER (WHERE reduction < 0) AS reduction_negative_rows,
        min(user_key) <> max(user_key) AS different_users,
        min(biz_value) <> max(biz_value) AS different_biz_codes,
        min(pay_day) <> max(pay_day) AS different_pay_days,
        count(DISTINCT coupon_key) > 1 AS multiple_coupon_ids,
        count(DISTINCT coupon_type_value) > 1 AS multiple_coupon_types,
        count(*) FILTER (WHERE coupon_key IS NULL AND reduction > 0) AS missing_coupon_positive_rows,
        count(*) FILTER (WHERE coupon_key IS NOT NULL AND reduction = 0) AS present_coupon_zero_rows
    FROM parsed
    GROUP BY order_key
)
SELECT
    count(*) FILTER (WHERE order_key IS NOT NULL) AS order_count,
    coalesce(sum(row_count) FILTER (WHERE order_key IS NULL), 0) AS missing_order_key_rows,
    count(*) FILTER (WHERE order_key IS NOT NULL AND row_count > 1) AS multi_orders,
    count(*) FILTER (WHERE order_key IS NOT NULL AND row_count > 1 AND min_paid = max_paid
                     AND paid_missing_rows = 0 AND paid_failed_rows = 0) AS same_paid_orders,
    count(*) FILTER (WHERE order_key IS NOT NULL AND row_count > 1 AND min_paid <> max_paid)
        AS different_paid_orders,
    count(*) FILTER (WHERE order_key IS NOT NULL AND row_count > 1 AND paid_missing_rows > 0)
        AS missing_paid_orders,
    count(*) FILTER (WHERE order_key IS NOT NULL AND row_count > 1 AND paid_failed_rows > 0)
        AS failed_paid_orders,
    count(*) FILTER (WHERE order_key IS NOT NULL AND row_count > 1 AND min_reduction = max_reduction
                     AND reduction_missing_rows = 0 AND reduction_failed_rows = 0) AS same_reduction_orders,
    count(*) FILTER (WHERE order_key IS NOT NULL AND row_count > 1 AND min_reduction <> max_reduction)
        AS different_reduction_orders,
    count(*) FILTER (WHERE order_key IS NOT NULL AND row_count > 1 AND reduction_missing_rows > 0)
        AS missing_reduction_orders,
    count(*) FILTER (WHERE order_key IS NOT NULL AND row_count > 1 AND reduction_failed_rows > 0)
        AS failed_reduction_orders,
    count(*) FILTER (WHERE order_key IS NOT NULL AND different_users) AS different_user_orders,
    count(*) FILTER (WHERE order_key IS NOT NULL AND different_biz_codes) AS different_biz_orders,
    count(*) FILTER (WHERE order_key IS NOT NULL AND different_pay_days) AS different_pay_day_orders,
    count(*) FILTER (WHERE order_key IS NOT NULL AND multiple_coupon_ids) AS multiple_coupon_id_orders,
    count(*) FILTER (WHERE order_key IS NOT NULL AND multiple_coupon_types) AS multiple_coupon_type_orders,
    sum(detail_paid) AS all_detail_paid,
    sum(max_paid) FILTER (WHERE order_key IS NOT NULL) AS once_per_order_paid,
    count(*) FILTER (WHERE order_key IS NOT NULL AND max_paid IS NULL) AS no_valid_paid_orders,
    coalesce(sum(missing_coupon_positive_rows), 0) AS missing_coupon_positive_rows,
    count(*) FILTER (WHERE order_key IS NOT NULL AND missing_coupon_positive_rows > 0)
        AS missing_coupon_positive_orders,
    coalesce(sum(present_coupon_zero_rows), 0) AS present_coupon_zero_rows,
    count(*) FILTER (WHERE order_key IS NOT NULL AND present_coupon_zero_rows > 0)
        AS present_coupon_zero_orders,
    coalesce(sum(paid_missing_rows), 0) AS paid_missing_rows,
    coalesce(sum(paid_failed_rows), 0) AS paid_failed_rows,
    coalesce(sum(paid_negative_rows), 0) AS paid_negative_rows,
    coalesce(sum(reduction_missing_rows), 0) AS reduction_missing_rows,
    coalesce(sum(reduction_failed_rows), 0) AS reduction_failed_rows,
    coalesce(sum(reduction_negative_rows), 0) AS reduction_negative_rows
FROM by_order;

INSERT INTO quality_report
SELECT 1, check_no, '订单表', check_target, check_name, NULL, result::VARCHAR, unit, definition
FROM quality_order_metrics
CROSS JOIN LATERAL (VALUES
    (3, 'Order_id', '不同订单', order_count, '笔订单', '按非缺失的原始 Order_id 去重。'),
    (4, 'Order_id', '缺失', missing_order_key_rows, '行', '空值、空白和文本 NULL 计为缺失。'),
    (5, 'Order_id', '多行订单', multi_orders, '笔订单', '非缺失 Order_id 在原始表中出现超过一行。'),
    (6, 'Actual_pay', '多行订单内完全相同', same_paid_orders, '笔订单', '该订单每行的实付都成功解析且金额相等。'),
    (7, 'Actual_pay', '多行订单内存在不同值', different_paid_orders, '笔订单', '该订单至少有两个不同的可解析实付金额。'),
    (8, 'Actual_pay', '多行订单内含缺失', missing_paid_orders, '笔订单', '该订单至少有一行实付缺失，可与存在不同值重叠。'),
    (9, 'Actual_pay', '多行订单内含解析失败', failed_paid_orders, '笔订单', '该订单至少有一行实付非缺失但解析失败。'),
    (10, 'Reduce_amount', '多行订单内完全相同', same_reduction_orders, '笔订单', '该订单每行的减免都成功解析且金额相等。'),
    (11, 'Reduce_amount', '多行订单内存在不同值', different_reduction_orders, '笔订单', '该订单至少有两个不同的可解析减免金额。'),
    (12, 'Reduce_amount', '多行订单内含缺失', missing_reduction_orders, '笔订单', '该订单至少有一行减免缺失，可与存在不同值重叠。'),
    (13, 'Reduce_amount', '多行订单内含解析失败', failed_reduction_orders, '笔订单', '该订单至少有一行减免非缺失但解析失败。'),
    (14, 'User_id', '同订单内存在不同值', different_user_orders, '笔订单', '该订单至少有两个不同的非缺失 User_id。'),
    (15, 'Biz_code', '同订单内存在不同值', different_biz_orders, '笔订单', '该订单至少有两个不同的非缺失 Biz_code。'),
    (16, 'Pay_date', '同订单内存在不同值', different_pay_day_orders, '笔订单', '该订单至少有两个不同的可解析支付日。'),
    (17, 'Coupon_id', '同订单内有多个不同券 ID', multiple_coupon_id_orders, '笔订单', '只比较非缺失的券 ID。'),
    (18, 'Coupon_type', '同订单内有多个不同券类型', multiple_coupon_type_orders, '笔订单', '只比较非缺失的原始券类型。'),
    (22, 'Actual_pay', '订单内无可解析实付', no_valid_paid_orders, '笔订单', '该订单所有行的实付均缺失或解析失败。'),
    (23, 'Coupon_id + Reduce_amount', '券 ID 缺失且减免大于 0', missing_coupon_positive_rows, '行', '减免金额解析成功。'),
    (24, 'Coupon_id + Reduce_amount', '券 ID 缺失且减免大于 0', missing_coupon_positive_orders, '笔订单', '对满足条件的行按非缺失 Order_id 去重。'),
    (25, 'Coupon_id + Reduce_amount', '券 ID 有值且减免等于 0', present_coupon_zero_rows, '行', '减免金额解析成功。'),
    (26, 'Coupon_id + Reduce_amount', '券 ID 有值且减免等于 0', present_coupon_zero_orders, '笔订单', '对满足条件的行按非缺失 Order_id 去重。'),
    (27, 'Actual_pay', '缺失', paid_missing_rows, '行', '空值、空白和文本 NULL 计为缺失。'),
    (28, 'Actual_pay', '解析失败', paid_failed_rows, '行', '非缺失值无法按最多 4 位小数的定点金额解析。'),
    (29, 'Actual_pay', '负值', paid_negative_rows, '行', '可解析金额小于 0。'),
    (30, 'Reduce_amount', '缺失', reduction_missing_rows, '行', '空值、空白和文本 NULL 计为缺失。'),
    (31, 'Reduce_amount', '解析失败', reduction_failed_rows, '行', '非缺失值无法按最多 4 位小数的定点金额解析。'),
    (32, 'Reduce_amount', '负值', reduction_negative_rows, '行', '可解析金额小于 0。')
) AS checks(check_no, check_target, check_name, result, unit, definition);

INSERT INTO quality_report
SELECT 1, check_no, '订单表', 'Actual_pay', check_name, NULL, result::VARCHAR, '原表金额单位', definition
FROM quality_order_metrics
CROSS JOIN LATERAL (VALUES
    (19, '按明细直接求和', all_detail_paid, '汇总每一行可解析的实付金额。'),
    (20, '每订单取一次后求和', once_per_order_paid, '按非缺失 Order_id 取 MAX(Actual_pay) 后加总。若同订单内有不同实付，MAX 仅作待验证口径。'),
    (21, '按明细求和减去每订单取一次', all_detail_paid - once_per_order_paid, '按明细直接求和和订单级加总的差额。')
) AS checks(check_no, check_name, result, definition);

-- 领券表：一次全量扫描得到各原始状态码的行数和质量计数。
CREATE OR REPLACE TEMP TABLE quality_coupon_by_status AS
WITH parsed AS (
    SELECT
        quality_present_text(Coupon_status) AS status_code,
        quality_missing(Coupon_amt) AS amount_missing,
        quality_amount(Coupon_amt) AS amount,
        quality_missing(Price_limit) AS limit_missing,
        quality_amount(Price_limit) AS price_floor,
        quality_missing(Start_date) AS start_missing,
        quality_date(Start_date) AS start_day,
        quality_missing(End_date) AS end_missing,
        quality_date(End_date) AS end_day,
        quality_missing(Receive_date) AS receive_missing,
        quality_date(Receive_date) AS receive_day
    FROM quality_coupons_raw
)
SELECT
    status_code,
    count(*) AS status_rows,
    count(*) FILTER (WHERE amount_missing) AS amount_missing_rows,
    count(*) FILTER (WHERE NOT amount_missing AND amount IS NULL) AS amount_failed_rows,
    count(*) FILTER (WHERE amount < 0) AS amount_negative_rows,
    count(*) FILTER (WHERE limit_missing) AS limit_missing_rows,
    count(*) FILTER (WHERE NOT limit_missing AND price_floor IS NULL) AS limit_failed_rows,
    count(*) FILTER (WHERE price_floor < 0) AS limit_negative_rows,
    count(*) FILTER (WHERE amount_missing AND limit_missing) AS both_amount_fields_missing_rows,
    count(*) FILTER (WHERE start_missing) AS start_missing_rows,
    count(*) FILTER (WHERE NOT start_missing AND start_day IS NULL) AS start_failed_rows,
    count(*) FILTER (WHERE end_missing) AS end_missing_rows,
    count(*) FILTER (WHERE NOT end_missing AND end_day IS NULL) AS end_failed_rows,
    count(*) FILTER (WHERE receive_missing) AS receive_missing_rows,
    count(*) FILTER (WHERE NOT receive_missing AND receive_day IS NULL) AS receive_failed_rows,
    count(*) FILTER (WHERE start_day > end_day) AS start_after_end_rows,
    count(*) FILTER (WHERE receive_day > end_day) AS receive_after_end_rows
FROM parsed
GROUP BY status_code;

INSERT INTO quality_report
WITH status_groups AS (
    SELECT status_code FROM quality_coupon_by_status WHERE status_code IS NOT NULL
    UNION ALL
    SELECT NULL
)
SELECT 2, check_no, '领券表', check_target, check_name,
       coalesce(status_groups.status_code, '（缺失）'), coalesce(result, 0)::VARCHAR, '行', definition
FROM status_groups
LEFT JOIN quality_coupon_by_status AS profile
    ON status_groups.status_code IS NOT DISTINCT FROM profile.status_code
CROSS JOIN LATERAL (VALUES
    (1, 'Coupon_status', '按原始状态码汇总', profile.status_rows, '保留非缺失状态的原始编码。'),
    (2, 'Receive_date', '按原始状态码统计领券日缺失', profile.receive_missing_rows, '空值、空白和文本 NULL 计为领券日缺失。')
) AS checks(check_no, check_target, check_name, result, definition);

INSERT INTO quality_report
WITH totals AS (
    SELECT
        sum(amount_missing_rows) AS amount_missing,
        sum(amount_failed_rows) AS amount_failed,
        sum(amount_negative_rows) AS amount_negative,
        sum(limit_missing_rows) AS limit_missing,
        sum(limit_failed_rows) AS limit_failed,
        sum(limit_negative_rows) AS limit_negative,
        sum(both_amount_fields_missing_rows) FILTER (WHERE status_code IS NULL)
            AS both_amount_fields_missing_without_status,
        sum(start_missing_rows) AS start_missing,
        sum(start_failed_rows) AS start_failed,
        sum(end_missing_rows) AS end_missing,
        sum(end_failed_rows) AS end_failed,
        sum(receive_missing_rows) AS receive_missing,
        sum(receive_failed_rows) AS receive_failed,
        sum(start_after_end_rows) AS start_after_end,
        sum(receive_after_end_rows) AS receive_after_end
    FROM quality_coupon_by_status
)
SELECT 2, check_no, '领券表', check_target, check_name, NULL,
       coalesce(result, 0)::VARCHAR, '行', definition
FROM totals
CROSS JOIN LATERAL (VALUES
    (3, 'Coupon_amt', '缺失', amount_missing, '空值、空白和文本 NULL 计为缺失。'),
    (4, 'Coupon_amt', '解析失败', amount_failed, '非缺失值无法按最多 4 位小数的定点金额解析。'),
    (5, 'Coupon_amt', '负值', amount_negative, '可解析金额小于 0。'),
    (6, 'Price_limit', '缺失', limit_missing, '空值、空白和文本 NULL 计为缺失。'),
    (7, 'Price_limit', '解析失败', limit_failed, '非缺失值无法按最多 4 位小数的定点金额解析。'),
    (8, 'Price_limit', '负值', limit_negative, '可解析金额小于 0。'),
    (9, 'Coupon_status + Coupon_amt + Price_limit', '状态与两个金额字段均缺失',
        both_amount_fields_missing_without_status, '三个字段在同一行全部缺失。'),
    (10, 'Start_date', '缺失', start_missing, '空值、空白和文本 NULL 计为缺失。'),
    (11, 'Start_date', '解析失败', start_failed, '非缺失日期无法按 YYYY-MM-DD 解析。'),
    (12, 'End_date', '缺失', end_missing, '空值、空白和文本 NULL 计为缺失。'),
    (13, 'End_date', '解析失败', end_failed, '非缺失日期无法按 YYYY-MM-DD 解析。'),
    (14, 'Receive_date', '缺失', receive_missing, '空值、空白和文本 NULL 计为缺失。'),
    (15, 'Receive_date', '解析失败', receive_failed, '非缺失日期无法按 YYYY-MM-DD 解析。'),
    (16, 'Start_date + End_date', '开始日晚于结束日', start_after_end, '只比较两个日期均成功解析的记录。'),
    (17, 'Receive_date + End_date', '领券日晚于结束日', receive_after_end, '只比较两个日期均成功解析的记录。')
) AS checks(check_no, check_target, check_name, result, definition);

INSERT INTO quality_report
SELECT 3, 1, '访问表', 'User_id', '缺失', NULL,
       (count(*) FILTER (WHERE quality_missing(User_id)))::VARCHAR, '行',
       '空值、空白和文本 NULL 计为缺失。第 01 步核实的粒度为用户与访问日。'
FROM quality_visits_raw;

CREATE OR REPLACE TEMP VIEW quality_output AS
SELECT table_name AS "表名", check_target AS "检查对象", check_name AS "检查项",
       check_group AS "分组", result AS "结果", unit AS "统计单位", definition AS "统计口径"
FROM quality_report
ORDER BY table_no, check_no, check_group;

COPY (SELECT * FROM quality_output) TO '数据清洗/02_原始表数据质量检查.csv' (FORMAT CSV, HEADER true);

SELECT * FROM quality_output;
