-- 在项目根目录的 PowerShell 中运行以下两行：
-- $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
-- Get-Content -LiteralPath 'sql/01_原始数据盘点.sql' -Raw -Encoding utf8 | duckdb -no-agent -bail -csv
-- 逐表扫描原始 CSV 并汇总。源文件以只读方式打开，中间结果仅保存在临时表中。
-- 日期去掉首尾空格后按 YYYY-MM-DD 解析，空值、空白和文本 NULL 计为缺失。
-- 主检查只对完整键去重，保留 ID 原始文本及前导零。组合键按元组去重。
-- 订单扩展检查允许 Coupon_id 缺失，以核实每个订单的券字段明细粒度。

SET threads = 4;
SET preserve_insertion_order = false;

SET VARIABLE order_file = '_local/raw/06 美团业务选题-优惠券投放提效分析-数据1-order_detail.csv';
SET VARIABLE coupon_file = '_local/raw/06 美团业务选题-优惠券投放提效分析-数据2-user_coupon_receive.csv';
SET VARIABLE visit_file = '_local/raw/06 美团业务选题-优惠券投放提效分析-数据3-user_visit_detail.csv';

CREATE OR REPLACE TEMP VIEW inventory_orders AS
SELECT * FROM read_csv(getvariable('order_file'), header = true, delim = ',',
                       all_varchar = true, ignore_errors = false);

CREATE OR REPLACE TEMP VIEW inventory_coupons AS
SELECT * FROM read_csv(getvariable('coupon_file'), header = true, delim = ',',
                       all_varchar = true, ignore_errors = false);

CREATE OR REPLACE TEMP VIEW inventory_visits AS
SELECT * FROM read_csv(getvariable('visit_file'), header = true, delim = ',',
                       all_varchar = true, ignore_errors = false);

CREATE OR REPLACE TEMP TABLE inventory_order_metrics AS
WITH prepared AS (
    SELECT Order_id,
           CASE WHEN NULLIF(trim(Coupon_id), '') IS NOT NULL AND upper(trim(Coupon_id)) <> 'NULL'
                THEN Coupon_id END AS order_coupon_id,
           NULLIF(trim(Order_id), '') IS NOT NULL AS has_key,
           upper(trim(Pay_date)) AS raw_date_text
    FROM inventory_orders
), parsed AS (
    SELECT * EXCLUDE (raw_date_text),
           NULLIF(NULLIF(raw_date_text, ''), 'NULL') AS date_text,
           raw_date_text = 'NULL' AS date_is_text_null
    FROM prepared
), dated AS (
    SELECT *, try_strptime(date_text, '%Y-%m-%d')::DATE AS event_date FROM parsed
)
SELECT
    count(*) AS row_count,
    min(event_date) AS first_date,
    max(event_date) AS last_date,
    count(*) FILTER (WHERE date_text IS NULL) AS missing_date_rows,
    count(*) FILTER (WHERE date_is_text_null) AS text_null_date_rows,
    count(*) FILTER (WHERE date_text IS NOT NULL AND event_date IS NULL) AS invalid_date_rows,
    count(*) FILTER (WHERE NOT has_key) AS missing_grain_key_rows,
    count(DISTINCT Order_id) FILTER (WHERE has_key) AS distinct_order_ids,
    count(DISTINCT (Order_id, order_coupon_id)) FILTER (WHERE has_key) AS distinct_order_coupon_keys,
    count(*) FILTER (WHERE order_coupon_id IS NULL) AS missing_order_coupon_rows
FROM dated;

CREATE OR REPLACE TEMP TABLE inventory_coupon_metrics AS
WITH prepared AS (
    SELECT User_id, Coupon_id,
           NULLIF(trim(User_id), '') IS NOT NULL AS has_user,
           NULLIF(trim(Coupon_id), '') IS NOT NULL AS has_coupon,
           upper(trim(Receive_date)) AS raw_date_text
    FROM inventory_coupons
), parsed AS (
    SELECT * EXCLUDE (raw_date_text),
           NULLIF(NULLIF(raw_date_text, ''), 'NULL') AS date_text,
           raw_date_text = 'NULL' AS date_is_text_null
    FROM prepared
), dated AS (
    SELECT *, try_strptime(date_text, '%Y-%m-%d')::DATE AS event_date FROM parsed
)
SELECT
    count(*) AS row_count,
    min(event_date) AS first_date,
    max(event_date) AS last_date,
    count(*) FILTER (WHERE date_text IS NULL) AS missing_date_rows,
    count(*) FILTER (WHERE date_is_text_null) AS text_null_date_rows,
    count(*) FILTER (WHERE date_text IS NOT NULL AND event_date IS NULL) AS invalid_date_rows,
    count(*) FILTER (WHERE NOT (has_user AND has_coupon)) AS missing_grain_key_rows,
    count(DISTINCT Coupon_id) FILTER (WHERE has_coupon) AS distinct_coupon_ids,
    count(DISTINCT (User_id, Coupon_id)) FILTER (WHERE has_user AND has_coupon) AS distinct_user_coupon_keys
FROM dated;

CREATE OR REPLACE TEMP TABLE inventory_visit_metrics AS
WITH prepared AS (
    SELECT User_id, Visit_date,
           NULLIF(trim(User_id), '') IS NOT NULL AS has_user,
           upper(trim(Visit_date)) AS raw_date_text
    FROM inventory_visits
), parsed AS (
    SELECT * EXCLUDE (raw_date_text),
           NULLIF(NULLIF(raw_date_text, ''), 'NULL') AS date_text,
           raw_date_text = 'NULL' AS date_is_text_null
    FROM prepared
), dated AS (
    SELECT *, try_strptime(date_text, '%Y-%m-%d')::DATE AS event_date FROM parsed
)
SELECT
    count(*) AS row_count,
    min(event_date) AS first_date,
    max(event_date) AS last_date,
    count(*) FILTER (WHERE date_text IS NULL) AS missing_date_rows,
    count(*) FILTER (WHERE date_is_text_null) AS text_null_date_rows,
    count(*) FILTER (WHERE date_text IS NOT NULL AND event_date IS NULL) AS invalid_date_rows,
    count(*) FILTER (WHERE NOT (has_user AND date_text IS NOT NULL)) AS missing_grain_key_rows,
    count(DISTINCT (User_id, Visit_date)) FILTER (WHERE has_user AND date_text IS NOT NULL)
        AS distinct_user_visit_date_keys
FROM dated;

CREATE OR REPLACE TEMP TABLE inventory_summary AS
WITH source_metadata (source_no, table_name, source_file, view_name, date_field) AS (
    VALUES
        (1, '订单表', getvariable('order_file'), 'inventory_orders', 'Pay_date'),
        (2, '领券表', getvariable('coupon_file'), 'inventory_coupons', 'Receive_date'),
        (3, '访问表', getvariable('visit_file'), 'inventory_visits', 'Visit_date')
), source_columns AS (
    SELECT table_name AS view_name, string_agg(column_name, ', ' ORDER BY column_index) AS column_names
    FROM duckdb_columns()
    WHERE database_name = 'temp' AND schema_name = 'main'
      AND table_name IN ('inventory_orders', 'inventory_coupons', 'inventory_visits')
    GROUP BY table_name
), metrics AS (
    SELECT 1 AS source_no, distinct_order_ids AS distinct_grain_keys, * FROM inventory_order_metrics
    UNION ALL BY NAME
    SELECT 2 AS source_no, distinct_user_coupon_keys AS distinct_grain_keys, * FROM inventory_coupon_metrics
    UNION ALL BY NAME
    SELECT 3 AS source_no, distinct_user_visit_date_keys AS distinct_grain_keys, * FROM inventory_visit_metrics
), association_notes (source_no, join_fields, pending_checks) AS (
    VALUES
        (1, '领券表用 User_id + Coupon_id，也可检查 Coupon_id 单键。访问表用 User_id +（Pay_date 对 Visit_date）。',
         '核实订单券字段缺失的业务含义、跨表券 ID 口径、匹配率和基数，以及同日访问与支付的覆盖和时间口径。'),
        (2, '订单表用 User_id + Coupon_id，也可检查 Coupon_id 单键。访问表用 User_id +（Receive_date 对 Visit_date）。',
         '核实券 ID 是券实例还是券批次、领券日缺失的原因，以及领券、核销和访问的匹配率、基数和时间规则。'),
        (3, '订单表用 User_id +（Visit_date 对 Pay_date）。领券表用 User_id +（Visit_date 对 Receive_date）。',
         '核实跨表 User_id 编码口径、同日连接的覆盖率和基数，以及访问表的采集与聚合规则。')
)
SELECT
    source_no,
    table_name AS "表名",
    source_file AS "实际文件名",
    column_names AS "完整字段名",
    row_count AS "数据行数",
    date_field AS "日期字段",
    first_date AS "最早日期",
    last_date AS "最晚日期",
    missing_date_rows AS "日期缺失行数",
    text_null_date_rows AS "其中日期文本NULL行数",
    invalid_date_rows AS "日期解析失败行数",
    distinct_order_ids AS "不同Order_id数",
    distinct_order_coupon_keys AS "不同Order_id+Coupon_id组合数（含缺失券ID）",
    missing_order_coupon_rows AS "订单券ID缺失行数",
    distinct_coupon_ids AS "不同Coupon_id数",
    distinct_user_coupon_keys AS "不同User_id+Coupon_id组合数",
    distinct_user_visit_date_keys AS "不同User_id+Visit_date组合数",
    missing_grain_key_rows AS "粒度键缺失行数",
    row_count - missing_grain_key_rows - distinct_grain_keys AS "粒度键重复超出行数",
    CASE
        WHEN row_count = 0 THEN '空表，记录粒度待核实。'
        WHEN source_no = 1 AND row_count = distinct_order_ids THEN '每行对应一个唯一的 Order_id，呈订单级粒度。'
        WHEN source_no = 1 AND row_count = distinct_order_coupon_keys
            THEN '每行对应一个唯一的 Order_id + Coupon_id 组合，含券 ID 缺失的记录。'
        WHEN source_no = 1 THEN 'Order_id 无法唯一标识每行，订单表的更细粒度待核实。'
        WHEN source_no = 2 AND row_count = distinct_coupon_ids THEN '每行对应一个唯一的 Coupon_id，呈券 ID 级粒度。'
        WHEN source_no = 2 AND row_count = distinct_user_coupon_keys
            THEN '每行对应一个唯一的 User_id + Coupon_id 组合，呈用户×券 ID 级粒度。'
        WHEN source_no = 2 THEN 'User_id + Coupon_id 无法唯一标识每行，领券表的更细粒度待核实。'
        WHEN row_count = distinct_user_visit_date_keys
            THEN '每行对应一个唯一的 User_id + Visit_date 组合，呈用户×访问日级粒度。'
        ELSE 'User_id + Visit_date 无法唯一标识每行，访问表的更细粒度待核实。'
    END AS "粒度判断",
    join_fields AS "待验证的候选关联字段",
    pending_checks AS "待核实项"
FROM source_metadata
JOIN source_columns USING (view_name)
JOIN metrics USING (source_no)
JOIN association_notes USING (source_no);

COPY (SELECT * EXCLUDE (source_no) FROM inventory_summary ORDER BY source_no)
    TO '数据清洗/01_原始数据盘点.csv'
    (FORMAT CSV, HEADER true);

SELECT * EXCLUDE (source_no) FROM inventory_summary ORDER BY source_no;
