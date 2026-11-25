-- 在项目根目录的 PowerShell 中运行：
-- $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
-- Get-Content -LiteralPath 'sql/03_三表关联核验.sql' -Raw -Encoding utf8 | duckdb -no-agent -bail -csv
-- 全量读取原始 CSV。中间结果均为会话临时对象，唯一文件输出为关联核验汇总。

SET threads = 4;
SET preserve_insertion_order = false;

CREATE OR REPLACE TEMP MACRO relation_text(raw_value) AS
    CASE WHEN upper(trim(raw_value)) NOT IN ('', 'NULL') THEN raw_value END;

CREATE OR REPLACE TEMP MACRO relation_date(raw_value) AS
    try_strptime(trim(relation_text(raw_value)), '%Y-%m-%d')::DATE;

CREATE OR REPLACE TEMP TABLE relation_order_rows AS
SELECT relation_text(Order_id) AS order_key,
       relation_text(User_id) AS user_key,
       relation_text(Coupon_id) AS coupon_key,
       relation_date(Pay_date) AS pay_day
FROM read_csv('_local/raw/06 美团业务选题-优惠券投放提效分析-数据1-order_detail.csv',
              header = true, delim = ',', all_varchar = true, ignore_errors = false);

CREATE OR REPLACE TEMP VIEW relation_coupon_rows AS
SELECT relation_text(User_id) AS user_key,
       relation_text(Coupon_id) AS coupon_key,
       relation_text(Coupon_status) AS status_code,
       relation_text(Receive_date) IS NULL AS receive_missing,
       relation_date(Receive_date) AS receive_day,
       relation_date(Start_date) AS start_day,
       relation_date(End_date) AS end_day
FROM read_csv('_local/raw/06 美团业务选题-优惠券投放提效分析-数据2-user_coupon_receive.csv',
              header = true, delim = ',', all_varchar = true, ignore_errors = false);

-- 单内非缺失值唯一时取该值。有冲突或全部缺失时，该字段不可用于匹配。
CREATE OR REPLACE TEMP TABLE relation_orders_once AS
SELECT order_key,
       CASE WHEN min(user_key) = max(user_key) THEN min(user_key) END AS user_key,
       CASE WHEN min(pay_day) = max(pay_day) THEN min(pay_day) END AS pay_day
FROM relation_order_rows
WHERE order_key IS NOT NULL
GROUP BY order_key;

CREATE OR REPLACE TEMP TABLE relation_order_coupon_pairs AS
WITH pairs AS (
    SELECT user_key, coupon_key, count(DISTINCT order_key) AS order_count,
           min(order_key) AS first_order_key
    FROM relation_order_rows
    WHERE user_key IS NOT NULL AND coupon_key IS NOT NULL
    GROUP BY user_key, coupon_key
)
SELECT pairs.user_key, pairs.coupon_key, pairs.order_count, orders.pay_day
FROM pairs
LEFT JOIN relation_orders_once AS orders
    ON CASE WHEN pairs.order_count = 1 THEN pairs.first_order_key END = orders.order_key;

CREATE OR REPLACE TEMP TABLE relation_report (
    section_no INTEGER,
    metric_no INTEGER,
    section VARCHAR,
    metric VARCHAR,
    metric_group VARCHAR,
    numerator BIGINT,
    unit VARCHAR,
    denominator BIGINT,
    denominator_definition VARCHAR,
    criteria VARCHAR
);

-- 先找存在的券 ID，再核对用户。用组内存在性判定，分母保持为订单侧唯一组合数。
INSERT INTO relation_report
WITH receipt_ids_found AS (
    SELECT receipts.coupon_key, receipts.user_key
    FROM relation_coupon_rows AS receipts
    SEMI JOIN (SELECT DISTINCT coupon_key FROM relation_order_coupon_pairs) AS order_ids USING (coupon_key)
), classified AS (
    SELECT pairs.coupon_key, pairs.user_key,
           count(receipts.coupon_key) > 0 AS id_found,
           count(receipts.user_key) > 0 AS receipt_user_present,
           coalesce(bool_or(pairs.user_key = receipts.user_key), false) AS exact_match
    FROM relation_order_coupon_pairs AS pairs
    LEFT JOIN receipt_ids_found AS receipts ON pairs.coupon_key = receipts.coupon_key
    GROUP BY pairs.coupon_key, pairs.user_key
), totals AS (
    SELECT count(*) AS pair_count,
           count(*) FILTER (WHERE NOT id_found) AS id_not_found,
           count(*) FILTER (WHERE receipt_user_present AND NOT exact_match) AS different_user,
           count(*) FILTER (WHERE exact_match) AS matching_pairs,
           count(*) FILTER (WHERE id_found AND NOT receipt_user_present) AS missing_receipt_user
    FROM classified
)
SELECT 1, metric_no, '订单与领券匹配', metric, NULL, numerator, '组', pair_count,
       '订单侧 User_id 与 Coupon_id 均非缺失的去重组合数', criteria
FROM totals
CROSS JOIN LATERAL (VALUES
    (1, '待匹配的键完整组合', pair_count, '从订单原始明细按 User_id 与 Coupon_id 去重。'),
    (2, '券 ID 找不到', id_not_found, '领券表无相同 Coupon_id。'),
    (3, '券 ID 找到但用户不同', different_user, '领券表有相同 Coupon_id，并有非缺失用户，且没有相同 User_id。'),
    (4, '券 ID 和用户均一致', matching_pairs, '领券表存在同时相同的 User_id 与 Coupon_id。'),
    (5, '券 ID 找到但领券用户缺失', missing_receipt_user, '相同 Coupon_id 的领券记录没有可核对的 User_id。')
) AS metrics(metric_no, metric, numerator, criteria);

INSERT INTO relation_report
WITH missing_keys AS (
    SELECT count(*) AS total_rows,
           count(*) FILTER (WHERE user_key IS NULL OR coupon_key IS NULL) AS missing_either,
           count(*) FILTER (WHERE user_key IS NULL AND coupon_key IS NOT NULL) AS missing_user_only,
           count(*) FILTER (WHERE user_key IS NOT NULL AND coupon_key IS NULL) AS missing_coupon_only,
           count(*) FILTER (WHERE user_key IS NULL AND coupon_key IS NULL) AS missing_both
    FROM relation_order_rows
)
SELECT 1, metric_no, '订单与领券匹配', metric, NULL, numerator, '行', total_rows, '订单原始明细总行数',
       '任一匹配键缺失的行单列，不进入另列的键完整组合分母。'
FROM missing_keys
CROSS JOIN LATERAL (VALUES
    (6, '缺少匹配关键字段', missing_either),
    (7, '仅 User_id 缺失', missing_user_only),
    (8, '仅 Coupon_id 缺失', missing_coupon_only),
    (9, 'User_id 与 Coupon_id 均缺失', missing_both)
) AS metrics(metric_no, metric, numerator);

-- 第 01 步已验证本批领券表 Coupon_id 唯一。每张领券记录只在 ID 与用户均一致时累计不同订单。
CREATE OR REPLACE TEMP TABLE relation_coupon_metrics AS
WITH linked AS (
    SELECT receipts.status_code, receipts.receive_day, receipts.start_day, receipts.end_day,
           receipts.receive_missing, pairs.pay_day, coalesce(pairs.order_count, 0) AS order_count
    FROM relation_coupon_rows AS receipts
    LEFT JOIN relation_order_coupon_pairs AS pairs USING (user_key, coupon_key)
    WHERE receipts.coupon_key IS NOT NULL
), comparable AS (
    SELECT *,
           pay_day IS NOT NULL AND receive_day IS NOT NULL AS can_compare_receive,
           pay_day IS NOT NULL AND start_day IS NOT NULL AND end_day IS NOT NULL
               AND start_day <= end_day AS can_compare_window
    FROM linked
)
SELECT status_code,
       grouping(status_code) = 1 AS is_overall,
       count(*) AS coupon_count,
       count(*) FILTER (WHERE order_count = 0) AS zero_orders,
       count(*) FILTER (WHERE order_count = 1) AS one_order,
       count(*) FILTER (WHERE order_count > 1) AS multiple_orders,
       count(*) FILTER (WHERE order_count = 1 AND can_compare_receive AND pay_day < receive_day)
           AS paid_before_receive,
       count(*) FILTER (WHERE order_count = 1 AND can_compare_window AND pay_day BETWEEN start_day AND end_day)
           AS paid_in_window,
       count(*) FILTER (WHERE order_count = 1 AND can_compare_window AND pay_day NOT BETWEEN start_day AND end_day)
           AS paid_outside_window,
       count(*) FILTER (WHERE order_count = 1 AND (NOT can_compare_receive OR NOT can_compare_window))
           AS dates_undetermined,
       count(*) FILTER (WHERE order_count = 1 AND receive_missing) AS missing_receive_day,
       count(*) FILTER (WHERE order_count = 1 AND NOT can_compare_window) AS undetermined_window,
       count(*) FILTER (WHERE order_count = 1 AND start_day > end_day) AS inverted_window,
       count(*) FILTER (WHERE order_count = 1 AND can_compare_receive AND pay_day = receive_day) AS same_day,
       count(*) FILTER (WHERE order_count = 1 AND can_compare_receive AND can_compare_window
                        AND pay_day >= receive_day AND pay_day BETWEEN start_day AND end_day) AS timing_candidates
FROM comparable
GROUP BY GROUPING SETS ((status_code), ());

INSERT INTO relation_report
SELECT 2, metric_no, '领券侧订单基数', metric,
       CASE WHEN is_overall THEN '全部状态' ELSE coalesce(status_code, '（缺失）') END,
       numerator, '张券', coupon_count, '本分组的非缺失 Coupon_id 券数',
       '仅累计券 ID 与用户均一致的不同 Order_id。状态按原始编码分组，含义待核实。'
FROM relation_coupon_metrics
CROSS JOIN LATERAL (VALUES
    (1, '匹配 0 笔订单', zero_orders),
    (2, '匹配 1 笔订单', one_order),
    (3, '匹配多笔订单', multiple_orders)
) AS metrics(metric_no, metric, numerator);

INSERT INTO relation_report
SELECT 3, metric_no, '单订单匹配券日期核验', metric, '全部状态', numerator, '张券', one_order,
       '券 ID 和用户均一致且只匹配 1 笔订单的券数', criteria
FROM relation_coupon_metrics
CROSS JOIN LATERAL (VALUES
    (1, '支付日早于领券日', paid_before_receive, '支付日与领券日均有效，且 Pay_date < Receive_date。'),
    (2, '支付日在有效期内', paid_in_window, '支付日、生效日和结束日均有效，且 Start_date <= Pay_date <= End_date。'),
    (3, '支付日在有效期之外', paid_outside_window, '支付日和有效期可比较，且 Pay_date 早于 Start_date 或晚于 End_date。'),
    (4, '至少一项日期比较无法判断', dates_undetermined, '支付与领券先后或支付与有效期至少一项不可比较。有效期判断可与本项重叠。'),
    (5, '其中领券日缺失', missing_receive_day, '领券日原值为空、空白或文本 NULL。'),
    (6, '支付与有效期无法比较', undetermined_window, '支付日、生效日或结束日无有效值，或生效日晚于结束日。'),
    (7, '生效日晚于结束日', inverted_window, '生效日和结束日均有效，且 Start_date > End_date。'),
    (8, '领券与支付同一天', same_day, '支付日与领券日均有效，且 Pay_date = Receive_date。')
) AS metrics(metric_no, metric, numerator, criteria)
WHERE is_overall;

INSERT INTO relation_report
SELECT 3, 9, '单订单匹配券日期核验', '日级核销时滞候选',
       CASE WHEN is_overall THEN '全部状态' ELSE coalesce(status_code, '（缺失）') END,
       timing_candidates, '张券', one_order, '本分组中券 ID 和用户均一致且只匹配 1 笔订单的券数',
       '四个日期均有效，支付日不早于领券日且在有效期内（含首尾与同日）。总量按关联和日期筛选，状态码用于分组，含义待核实。'
FROM relation_coupon_metrics;

-- 访问侧先取得唯一的用户与访问日键，左连接保留无同日访问的订单和领券记录。
CREATE OR REPLACE TEMP TABLE relation_visit_days AS
WITH parsed AS (
    SELECT relation_text(User_id) AS user_key, relation_date(Visit_date) AS visit_day
    FROM read_csv('_local/raw/06 美团业务选题-优惠券投放提效分析-数据3-user_visit_detail.csv',
                  header = true, delim = ',', all_varchar = true, ignore_errors = false)
)
SELECT DISTINCT user_key, visit_day
FROM parsed
WHERE user_key IS NOT NULL AND visit_day IS NOT NULL;

INSERT INTO relation_report
WITH counts AS (
    SELECT count(*) AS after_join,
           count(DISTINCT orders.order_key) AS after_distinct_orders,
           count(visits.visit_day) AS has_visit,
           count(*) FILTER (WHERE orders.user_key IS NULL OR orders.pay_day IS NULL) AS missing_keys
    FROM relation_orders_once AS orders
    LEFT JOIN relation_visit_days AS visits
        ON orders.user_key = visits.user_key AND orders.pay_day = visits.visit_day
), source_count AS (
    SELECT count(*) AS before_join FROM relation_orders_once
)
SELECT 4, metric_no, '订单与访问', metric, NULL, numerator, unit, before_join,
       '关联前一单一条的不同非缺失 Order_id 数', criteria
FROM counts
CROSS JOIN source_count
CROSS JOIN LATERAL (VALUES
    (1, '关联前订单数', before_join, '笔订单', '按非缺失 Order_id 归并为一单一条。'),
    (2, '关联后订单数', after_distinct_orders, '笔订单', '左连接后按 Order_id 去重。'),
    (3, '关联后记录行数', after_join, '行', '左连接结果的全部行，用于检查是否增行。'),
    (4, '用户或支付日无法用于匹配', missing_keys, '笔订单', '订单归并后用户或支付日缺失、无法解析或不唯一。'),
    (5, '同日访问覆盖率', has_visit, '笔订单', 'User_id 相同且订单 Pay_date 等于 Visit_date。匹配仅反映同一用户同一天有两种行为。')
) AS metrics(metric_no, metric, numerator, unit, criteria);

INSERT INTO relation_report
WITH counts AS (
    SELECT count(*) AS joined_rows,
           count(receipts.receive_day) AS valid_receive_rows,
           count(*) FILTER (WHERE receipts.receive_missing) AS missing_receive_rows,
           count(*) FILTER (WHERE NOT receipts.receive_missing AND receipts.receive_day IS NULL)
               AS failed_receive_rows,
           count(*) FILTER (WHERE receipts.receive_day IS NOT NULL AND receipts.user_key IS NULL)
               AS missing_user_valid_receive_rows,
           count(visits.visit_day) AS has_visit
    FROM relation_coupon_rows AS receipts
    LEFT JOIN relation_visit_days AS visits
        ON receipts.user_key = visits.user_key AND receipts.receive_day = visits.visit_day
)
SELECT 5, metric_no, '领券与访问', metric, NULL, numerator, '行', denominator, denominator_definition, criteria
FROM counts
CROSS JOIN LATERAL (VALUES
    (1, '领券日有效', valid_receive_rows, joined_rows, '领券全部记录数', 'Receive_date 成功解析。'),
    (2, '领券日缺失', missing_receive_rows, joined_rows, '领券全部记录数', '领券日原值为空、空白或文本 NULL。'),
    (3, '领券日解析失败', failed_receive_rows, joined_rows, '领券全部记录数', '领券日非缺失但无法按 YYYY-MM-DD 解析。'),
    (4, '领券日有效但用户缺失', missing_user_valid_receive_rows, valid_receive_rows, '领券日有效的记录数',
        '领券日可用且 User_id 缺失，仍计入该有效日期分母。'),
    (5, '同日访问覆盖率', has_visit, valid_receive_rows, '领券日有效的记录数',
        'User_id 相同且 Receive_date 等于 Visit_date。匹配仅反映同一用户同一天有两种行为。')
) AS metrics(metric_no, metric, numerator, denominator, denominator_definition, criteria);

CREATE OR REPLACE TEMP VIEW relation_output AS
SELECT section AS "关联环节", metric AS "检查项", metric_group AS "分组",
       numerator AS "数量", unit AS "统计单位", denominator AS "分母",
       denominator_definition AS "分母口径",
       (100.0 * numerator / nullif(denominator, 0))::DECIMAL(9, 6) AS "比例（%）",
       criteria AS "筛选条件"
FROM relation_report
ORDER BY section_no, metric_no, CASE WHEN metric_group = '全部状态' THEN 0 ELSE 1 END, metric_group;

COPY (SELECT * FROM relation_output) TO '数据清洗/03_三表关联核验.csv' (FORMAT CSV, HEADER true);

SELECT * FROM relation_output;
