-- ============================================================================
-- AtlasCo Telemetry System - Redshift Analytics Queries
--
-- Purpose: Example queries for OLAP workload on Redshift
-- Performance Target: 2-15 seconds for multi-billion row scans
-- Data Freshness: 5-minute lag from PostgreSQL
-- ============================================================================
-- ============================================================================
-- CATEGORY 1: TIME-SERIES ANALYTICS
-- ============================================================================
-- ----------------------------------------------------------------------------
-- Query 1: Average temperature by region over last 6 months
--
-- Use Case: Regional temperature trends for capacity planning
-- Expected Runtime: 5-8 seconds (scanning ~150M rows)
-- ----------------------------------------------------------------------------

SELECT
    DATE_TRUNC('day', ingested_at) AS day,
    tenant_name,
    entity_type, -- Extract region from denormalized column
    attribute_category,
    COUNT(DISTINCT entity_id) AS entity_count,
    AVG(value_decimal) AS avg_temperature,
    MIN(value_decimal) AS min_temperature,
    MAX(value_decimal) AS max_temperature,
    STDDEV(value_decimal) AS stddev_temperature,
    PERCENTILE_CONT(0.5) WITHIN GROUP (
        ORDER BY value_decimal
    ) AS median_temperature,
    PERCENTILE_CONT(0.95) WITHIN GROUP (
        ORDER BY value_decimal
    ) AS p95_temperature
FROM fact_telemetry
WHERE
    ingested_at >= DATEADD (month, -6, GETDATE ())
    AND attribute_name = 'temperature_celsius'
    AND tenant_id = 123
    AND value_decimal IS NOT NULL
GROUP BY
    1,
    2,
    3,
    4
ORDER BY day DESC, entity_count DESC;

/*
Performance Notes:
- SORTKEY(year_month, tenant_id, ingested_at) enables zone map pruning
- Columnar storage reads only: ingested_at, tenant_name, entity_type,
attribute_name, value_decimal (5 columns out of 20+)
- DISTKEY(entity_id) ensures data locality for COUNT(DISTINCT entity_id)
- Expected scan: ~150M rows (6 months × 1 attribute)
- Memory: ~2-4 GB for aggregation
*/
-- ----------------------------------------------------------------------------
-- Query 2: Hourly event rate with moving average (last 7 days)
--
-- Use Case: Traffic pattern analysis for scaling decisions
-- Expected Runtime: 3-5 seconds
-- ----------------------------------------------------------------------------
WITH
    hourly_counts AS (
        SELECT
            DATE_TRUNC('hour', ingested_at) AS hour,
            tenant_id,
            tenant_name,
            entity_type,
            COUNT(*) AS event_count,
            COUNT(DISTINCT entity_id) AS active_entities
        FROM fact_telemetry
        WHERE
            ingested_at >= DATEADD (day, -7, GETDATE ())
            AND tenant_id = 123
        GROUP BY
            1,
            2,
            3,
            4
    )
SELECT
    hour,
    tenant_name,
    entity_type,
    event_count,
    active_entities, -- Moving averages
    AVG(event_count) OVER (
        PARTITION BY
            entity_type
        ORDER BY hour ROWS BETWEEN 23 PRECEDING
            AND CURRENT ROW
    ) AS moving_avg_24h, -- Peak detection
    CASE
        WHEN event_count > AVG(event_count) OVER (
            PARTITION BY
                entity_type
            ORDER BY hour ROWS BETWEEN 23 PRECEDING
                AND CURRENT ROW
        ) * 1.5 THEN 'peak'
        WHEN event_count < AVG(event_count) OVER (
            PARTITION BY
                entity_type
            ORDER BY hour ROWS BETWEEN 23 PRECEDING
                AND CURRENT ROW
        ) * 0.5 THEN 'low'
        ELSE 'normal'
    END AS traffic_pattern
FROM hourly_counts
ORDER BY hour DESC, entity_type;

-- ----------------------------------------------------------------------------
-- Query 3: Daily attribute distribution (last 90 days)
--
-- Use Case: Understanding which attributes are being used heavily
-- Expected Runtime: 6-10 seconds
-- ----------------------------------------------------------------------------

SELECT
    ingested_date,
    attribute_name,
    attribute_category,
    COUNT(*) AS total_events,
    COUNT(DISTINCT entity_id) AS distinct_entities,
    COUNT(DISTINCT tenant_id) AS distinct_tenants, -- Data type distribution
    SUM(
        CASE
            WHEN value_int IS NOT NULL THEN 1
            ELSE 0
        END
    ) AS int_count,
    SUM(
        CASE
            WHEN value_decimal IS NOT NULL THEN 1
            ELSE 0
        END
    ) AS decimal_count,
    SUM(
        CASE
            WHEN value_bool IS NOT NULL THEN 1
            ELSE 0
        END
    ) AS bool_count,
    SUM(
        CASE
            WHEN value_timestamp IS NOT NULL THEN 1
            ELSE 0
        END
    ) AS timestamp_count,
    SUM(
        CASE
            WHEN value IS NOT NULL THEN 1
            ELSE 0
        END
    ) AS text_count
FROM fact_telemetry
WHERE
    ingested_date >= DATEADD (day, -90, GETDATE ())
GROUP BY
    1,
    2,
    3
HAVING
    total_events > 1000 -- Filter low-volume attributes
ORDER BY ingested_date DESC, total_events DESC;

-- ============================================================================
-- CATEGORY 2: ENTITY HEALTH & STATUS ANALYTICS
-- ============================================================================
-- ----------------------------------------------------------------------------
-- Query 4: Entity uptime analysis (last 30 days)
--
-- Use Case: SLA reporting and reliability metrics
-- Expected Runtime: 8-12 seconds
-- ----------------------------------------------------------------------------
WITH
    status_events AS (
        SELECT
            entity_id,
            tenant_id,
            tenant_name,
            entity_type,
            value AS status,
            ingested_at,
            LAG(value) OVER (
                PARTITION BY
                    entity_id
                ORDER BY ingested_at
            ) AS prev_status,
            LAG(ingested_at) OVER (
                PARTITION BY
                    entity_id
                ORDER BY ingested_at
            ) AS prev_timestamp
        FROM fact_telemetry
        WHERE
            attribute_name = 'status'
            AND ingested_at >= DATEADD (day, -30, GETDATE ())
            AND tenant_id = 123
    ),
    status_durations AS (
        SELECT
            entity_id,
            tenant_name,
            entity_type,
            status,
            DATEDIFF (
                second,
                prev_timestamp,
                ingested_at
            ) AS duration_seconds
        FROM status_events
        WHERE
            prev_status IS NOT NULL
    )
SELECT
    entity_id,
    tenant_name,
    entity_type, -- Total time per status
    SUM(
        CASE
            WHEN status = 'online' THEN duration_seconds
            ELSE 0
        END
    ) AS online_seconds,
    SUM(
        CASE
            WHEN status = 'offline' THEN duration_seconds
            ELSE 0
        END
    ) AS offline_seconds,
    SUM(
        CASE
            WHEN status = 'warning' THEN duration_seconds
            ELSE 0
        END
    ) AS warning_seconds,
    SUM(duration_seconds) AS total_seconds, -- Uptime percentage
    ROUND(
        (
            SUM(
                CASE
                    WHEN status = 'online' THEN duration_seconds
                    ELSE 0
                END
            )::DECIMAL / NULLIF(SUM(duration_seconds), 0)
        ) * 100,
        2
    ) AS uptime_percent, -- Downtime events
    COUNT(
        CASE
            WHEN status = 'offline' THEN 1
        END
    ) AS downtime_events
FROM status_durations
GROUP BY
    1,
    2,
    3
HAVING
    total_seconds > 0
ORDER BY uptime_percent ASC, entity_id;

/*
Business Value:
- Identify entities with <95% uptime (SLA breach)
- Count downtime events (reliability metric)
- Duration analysis (mean time to recovery)
*/
-- ----------------------------------------------------------------------------
-- Query 5: Top 100 entities by alert volume (last 24 hours)
--
-- Use Case: Incident response prioritization
-- Expected Runtime: 2-4 seconds
-- ----------------------------------------------------------------------------

SELECT
    ft.entity_id,
    ft.tenant_name,
    ft.entity_type, -- Current state from fact_current_state
    cs.status,
    cs.priority,
    cs.region,
    cs.environment, -- Alert metrics from time-series
    COUNT(*) AS total_alerts,
    COUNT(DISTINCT ft.attribute_id) AS distinct_alert_types,
    MIN(ft.ingested_at) AS first_alert_at,
    MAX(ft.ingested_at) AS latest_alert_at,
    DATEDIFF (
        minute,
        MIN(ft.ingested_at),
        MAX(ft.ingested_at)
    ) AS alert_duration_minutes
FROM
    fact_telemetry ft
    JOIN fact_current_state cs ON cs.entity_id = ft.entity_id
WHERE
    ft.attribute_name = 'alert_generated'
    AND ft.ingested_at >= DATEADD (hour, -24, GETDATE ())
    AND ft.tenant_id = 123
GROUP BY
    1,
    2,
    3,
    4,
    5,
    6,
    7
ORDER BY total_alerts DESC
LIMIT 100;

-- ----------------------------------------------------------------------------
-- Query 6: Entity health summary by region and environment
--
-- Use Case: Dashboard widget showing health distribution
-- Expected Runtime: 1-2 seconds (uses pre-aggregated table)
-- ----------------------------------------------------------------------------

SELECT
    tenant_name,
    entity_type,
    region,
    environment, -- Status distribution
    COUNT(*) AS total_entities,
    SUM(
        CASE
            WHEN status = 'online' THEN 1
            ELSE 0
        END
    ) AS online_count,
    SUM(
        CASE
            WHEN status = 'offline' THEN 1
            ELSE 0
        END
    ) AS offline_count,
    SUM(
        CASE
            WHEN status = 'warning' THEN 1
            ELSE 0
        END
    ) AS warning_count,
    SUM(
        CASE
            WHEN status = 'error' THEN 1
            ELSE 0
        END
    ) AS error_count, -- Health percentages
    ROUND(
        (
            SUM(
                CASE
                    WHEN status = 'online' THEN 1
                    ELSE 0
                END
            )::DECIMAL / COUNT(*)
        ) * 100,
        1
    ) AS online_percent, -- Alert metrics
    AVG(alert_count) AS avg_alerts_per_entity,
    MAX(alert_count) AS max_alerts, -- Uptime metrics
    AVG(uptime_percent) AS avg_uptime_percent,
    MIN(uptime_percent) AS min_uptime_percent
FROM fact_current_state
WHERE
    tenant_id = 123
GROUP BY
    1,
    2,
    3,
    4
ORDER BY total_entities DESC;

-- ============================================================================
-- CATEGORY 3: AGGREGATION & STATISTICAL ANALYSIS
-- ============================================================================
-- ----------------------------------------------------------------------------
-- Query 7: Attribute value distribution with percentiles
--
-- Use Case: Anomaly detection and baseline establishment
-- Expected Runtime: 7-12 seconds
-- ----------------------------------------------------------------------------

SELECT
    attribute_name,
    attribute_category,
    entity_type, -- Sample statistics
    COUNT(*) AS sample_count,
    COUNT(DISTINCT entity_id) AS entity_count, -- Central tendency
    AVG(value_decimal) AS mean_value,
    MEDIAN (value_decimal) AS median_value,
    MODE(value_decimal) AS mode_value, -- Spread
    STDDEV(value_decimal) AS stddev_value,
    VARIANCE(value_decimal) AS variance_value, -- Range
    MIN(value_decimal) AS min_value,
    MAX(value_decimal) AS max_value,
    MAX(value_decimal) - MIN(value_decimal) AS range_value, -- Percentiles
    PERCENTILE_CONT(0.01) WITHIN GROUP (
        ORDER BY value_decimal
    ) AS p01,
    PERCENTILE_CONT(0.05) WITHIN GROUP (
        ORDER BY value_decimal
    ) AS p05,
    PERCENTILE_CONT(0.25) WITHIN GROUP (
        ORDER BY value_decimal
    ) AS p25,
    PERCENTILE_CONT(0.50) WITHIN GROUP (
        ORDER BY value_decimal
    ) AS p50, -- median
    PERCENTILE_CONT(0.75) WITHIN GROUP (
        ORDER BY value_decimal
    ) AS p75,
    PERCENTILE_CONT(0.95) WITHIN GROUP (
        ORDER BY value_decimal
    ) AS p95,
    PERCENTILE_CONT(0.99) WITHIN GROUP (
        ORDER BY value_decimal
    ) AS p99
FROM fact_telemetry
WHERE
    ingested_at >= DATEADD (day, -7, GETDATE ())
    AND tenant_id = 123
    AND value_decimal IS NOT NULL
    AND attribute_category = 'performance' -- Focus on performance metrics
GROUP BY
    1,
    2,
    3
HAVING
    sample_count > 100
ORDER BY entity_count DESC, sample_count DESC;

/*
Anomaly Detection Use:
- Identify values > p99 (top 1% outliers)
- Alert when mean_value > (baseline_mean + 3*stddev)
- Detect distribution shifts (median_value moves significantly)
*/
-- ----------------------------------------------------------------------------
-- Query 8: Correlation analysis between attributes
--
-- Use Case: Understanding relationships between metrics
-- Expected Runtime: 10-15 seconds
-- ----------------------------------------------------------------------------
WITH
    attribute_pairs AS (
        SELECT
            a.entity_id,
            a.tenant_id,
            a.ingested_at,
            a.attribute_name AS attr1_name,
            a.value_decimal AS attr1_value,
            b.attribute_name AS attr2_name,
            b.value_decimal AS attr2_value
        FROM
            fact_telemetry a
            JOIN fact_telemetry b ON b.entity_id = a.entity_id
            AND b.tenant_id = a.tenant_id
            AND ABS(
                DATEDIFF (
                    second,
                    a.ingested_at,
                    b.ingested_at
                )
            ) < 60 -- Within 1 minute
        WHERE
            a.ingested_at >= DATEADD (day, -7, GETDATE ())
            AND a.tenant_id = 123
            AND a.attribute_name IN (
                'cpu_percent',
                'memory_percent',
                'disk_iops'
            )
            AND b.attribute_name IN (
                'cpu_percent',
                'memory_percent',
                'disk_iops'
            )
            AND a.attribute_name < b.attribute_name -- Avoid duplicate pairs
            AND a.value_decimal IS NOT NULL
            AND b.value_decimal IS NOT NULL
    )
SELECT
    attr1_name,
    attr2_name,
    COUNT(*) AS pair_count, -- Correlation coefficient (simplified Pearson)
    CORR(attr1_value, attr2_value) AS correlation, -- Covariance
    COVAR_POP(attr1_value, attr2_value) AS covariance, -- Regression (slope)
    REGR_SLOPE(attr2_value, attr1_value) AS regression_slope, -- Regression (intercept)
    REGR_INTERCEPT(attr2_value, attr1_value) AS regression_intercept, -- R-squared
    POWER(
        CORR(attr1_value, attr2_value),
        2
    ) AS r_squared
FROM attribute_pairs
GROUP BY
    1,
    2
HAVING
    pair_count > 1000
ORDER BY ABS(correlation) DESC;

/*
Interpretation:
- correlation > 0.7: Strong positive correlation (e.g., CPU and memory often move together)
- correlation < -0.7: Strong negative correlation
- correlation near 0: No linear relationship
*/
-- ----------------------------------------------------------------------------
-- Query 9: Time-series decomposition (trend + seasonality)
--
-- Use Case: Capacity planning and forecasting
-- Expected Runtime: 8-12 seconds
-- ----------------------------------------------------------------------------
WITH
    hourly_metrics AS (
        SELECT
            DATE_TRUNC('hour', ingested_at) AS hour,
            entity_id,
            entity_type,
            AVG(value_decimal) AS avg_value
        FROM fact_telemetry
        WHERE
            ingested_at >= DATEADD (day, -30, GETDATE ())
            AND tenant_id = 123
            AND attribute_name = 'cpu_percent'
            AND value_decimal IS NOT NULL
        GROUP BY
            1,
            2,
            3
    )
SELECT
    hour,
    entity_id,
    entity_type,
    avg_value AS actual_value, -- Trend (24-hour moving average)
    AVG(avg_value) OVER (
        PARTITION BY
            entity_id
        ORDER BY hour ROWS BETWEEN 23 PRECEDING
            AND CURRENT ROW
    ) AS trend_24h, -- Detrended (actual - trend)
    avg_value - AVG(avg_value) OVER (
        PARTITION BY
            entity_id
        ORDER BY hour ROWS BETWEEN 23 PRECEDING
            AND CURRENT ROW
    ) AS detrended, -- Day of week pattern
    EXTRACT(
        DOW
        FROM hour
    ) AS day_of_week,
    EXTRACT(
        HOUR
        FROM hour
    ) AS hour_of_day, -- Weekly seasonality (same hour, 7 days ago)
    LAG(avg_value, 168) OVER (
        PARTITION BY
            entity_id
        ORDER BY hour
    ) AS same_hour_last_week
FROM hourly_metrics
ORDER BY entity_id, hour DESC;

-- ============================================================================
-- CATEGORY 4: BUSINESS INTELLIGENCE QUERIES
-- ============================================================================
-- ----------------------------------------------------------------------------
-- Query 10: Tenant usage summary (last 30 days)
--
-- Use Case: Billing and capacity planning
-- Expected Runtime: 4-6 seconds
-- ----------------------------------------------------------------------------

SELECT
    tenant_id,
    tenant_name, -- Entity metrics
    COUNT(DISTINCT entity_id) AS total_entities,
    COUNT(
        DISTINCT CASE
            WHEN entity_type = 'sensor' THEN entity_id
        END
    ) AS sensor_count,
    COUNT(
        DISTINCT CASE
            WHEN entity_type = 'gateway' THEN entity_id
        END
    ) AS gateway_count, -- Event metrics
    COUNT(*) AS total_events,
    COUNT(*) / 30.0 AS avg_events_per_day,
    COUNT(*) / (30.0 * 24.0) AS avg_events_per_hour, -- Attribute usage
    COUNT(DISTINCT attribute_id) AS distinct_attributes_used, -- Data volume (estimated)
    SUM(LENGTH(value)) AS total_text_bytes,
    SUM(LENGTH(value)) / 1024.0 / 1024.0 AS total_text_mb, -- Time range
    MIN(ingested_at) AS earliest_event,
    MAX(ingested_at) AS latest_event,
    DATEDIFF (
        hour,
        MIN(ingested_at),
        MAX(ingested_at)
    ) AS active_hours
FROM fact_telemetry
WHERE
    ingested_at >= DATEADD (day, -30, GETDATE ())
GROUP BY
    1,
    2
ORDER BY total_events DESC;

-- ----------------------------------------------------------------------------
-- Query 11: Growth trends by tenant and entity type
--
-- Use Case: Sales dashboard and customer success metrics
-- Expected Runtime: 5-8 seconds
-- ----------------------------------------------------------------------------
WITH
    daily_stats AS (
        SELECT
            ingested_date,
            tenant_id,
            tenant_name,
            entity_type,
            COUNT(DISTINCT entity_id) AS active_entities,
            COUNT(*) AS daily_events
        FROM fact_telemetry
        WHERE
            ingested_at >= DATEADD (day, -90, GETDATE ())
        GROUP BY
            1,
            2,
            3,
            4
    )
SELECT
    tenant_id,
    tenant_name,
    entity_type, -- Current month
    AVG(
        CASE
            WHEN ingested_date >= DATE_TRUNC('month', GETDATE ()) THEN active_entities
        END
    ) AS current_month_avg_entities, -- Previous month
    AVG(
        CASE
            WHEN ingested_date >= DATE_TRUNC(
                'month',
                DATEADD (month, -1, GETDATE ())
            )
            AND ingested_date < DATE_TRUNC('month', GETDATE ()) THEN active_entities
        END
    ) AS prev_month_avg_entities, -- Month-over-month growth
    ROUND(
        (
            (
                AVG(
                    CASE
                        WHEN ingested_date >= DATE_TRUNC('month', GETDATE ()) THEN active_entities
                    END
                ) / NULLIF(
                    AVG(
                        CASE
                            WHEN ingested_date >= DATE_TRUNC(
                                'month',
                                DATEADD (month, -1, GETDATE ())
                            )
                            AND ingested_date < DATE_TRUNC('month', GETDATE ()) THEN active_entities
                        END
                    ),
                    0
                )
            ) - 1
        ) * 100,
        2
    ) AS mom_growth_percent, -- Event volume growth
    SUM(
        CASE
            WHEN ingested_date >= DATE_TRUNC('month', GETDATE ()) THEN daily_events
        END
    ) AS current_month_events,
    SUM(
        CASE
            WHEN ingested_date >= DATE_TRUNC(
                'month',
                DATEADD (month, -1, GETDATE ())
            )
            AND ingested_date < DATE_TRUNC('month', GETDATE ()) THEN daily_events
        END
    ) AS prev_month_events
FROM daily_stats
GROUP BY
    1,
    2,
    3
HAVING
    current_month_avg_entities IS NOT NULL
ORDER BY mom_growth_percent DESC;

-- ----------------------------------------------------------------------------
-- Query 12: Cost analysis by tenant (data storage and processing)
--
-- Use Case: Internal cost allocation and pricing optimization
-- Expected Runtime: 6-10 seconds
-- ----------------------------------------------------------------------------
WITH
    tenant_metrics AS (
        SELECT
            tenant_id,
            tenant_name,
            ingested_month,
            COUNT(*) AS event_count,
            COUNT(DISTINCT entity_id) AS entity_count,
            COUNT(DISTINCT attribute_id) AS attribute_count, -- Estimate storage (rough calculation)
            SUM(
                LENGTH(COALESCE(value, '')) + COALESCE(8, 0) + -- value_int (8 bytes if not null)
                COALESCE(8, 0) + -- value_decimal (8 bytes if not null)
                COALESCE(1, 0) -- value_bool (1 byte if not null)
            ) AS estimated_bytes
        FROM fact_telemetry
        WHERE
            ingested_at >= DATEADD (month, -3, GETDATE ())
        GROUP BY
            1,
            2,
            3
    )
SELECT
    tenant_id,
    tenant_name,
    ingested_month,
    event_count,
    entity_count,
    attribute_count, -- Storage costs
    estimated_bytes / 1024.0 / 1024.0 / 1024.0 AS storage_gb,
    (
        estimated_bytes / 1024.0 / 1024.0 / 1024.0
    ) * 0.023 AS storage_cost_usd, -- $0.023/GB Redshift
    -- Processing costs (estimated)
    event_count * 0.000001 AS processing_cost_usd, -- $1 per million events
    -- Total estimated cost
    (
        (
            estimated_bytes / 1024.0 / 1024.0 / 1024.0
        ) * 0.023
    ) + (event_count * 0.000001) AS total_cost_usd
FROM tenant_metrics
ORDER BY tenant_id, ingested_month DESC;

-- ============================================================================
-- CATEGORY 5: PRE-AGGREGATED QUERIES (Using agg_ tables)
-- ============================================================================
-- ----------------------------------------------------------------------------
-- Query 13: Daily entity statistics (fast - uses pre-aggregated table)
--
-- Use Case: Operations dashboard showing daily trends
-- Expected Runtime: <1 second
-- ----------------------------------------------------------------------------

SELECT
    date,
    entity_type,
    COUNT(DISTINCT entity_id) AS entity_count, -- Temperature metrics
    ROUND(AVG(avg_temperature), 2) AS avg_temp,
    ROUND(AVG(max_temperature), 2) AS avg_max_temp, -- CPU metrics
    ROUND(AVG(avg_cpu_percent), 2) AS avg_cpu, -- Uptime metrics
    ROUND(AVG(uptime_percent), 2) AS avg_uptime_pct,
    SUM(total_errors) AS total_errors, -- Time range
    MIN(date) AS start_date,
    MAX(date) AS end_date
FROM agg_daily_entity_stats
WHERE
    date >= DATEADD (day, -30, GETDATE ())
    AND tenant_id = 123
GROUP BY
    1,
    2
ORDER BY date DESC, entity_type;

-- ----------------------------------------------------------------------------
-- Query 14: Hourly attribute trends (fast - uses pre-aggregated table)
--
-- Use Case: Real-time monitoring dashboard
-- Expected Runtime: <1 second
-- ----------------------------------------------------------------------------

SELECT
    hour,
    attribute_name,
    sample_count,
    distinct_entities,
    ROUND(avg_value, 2) AS avg_value,
    ROUND(percentile_50, 2) AS median_value,
    ROUND(percentile_95, 2) AS p95_value,
    ROUND(stddev_value, 2) AS stddev_value, -- Anomaly detection
    CASE
        WHEN avg_value > percentile_95 * 1.2 THEN 'high_anomaly'
        WHEN avg_value < percentile_50 * 0.5 THEN 'low_anomaly'
        ELSE 'normal'
    END AS anomaly_status
FROM agg_hourly_attribute_stats
WHERE
    hour >= DATEADD (hour, -24, GETDATE ())
    AND tenant_id = 123
    AND attribute_name IN (
        'cpu_percent',
        'memory_percent',
        'temperature_celsius'
    )
ORDER BY hour DESC, attribute_name;

-- ============================================================================
-- CATEGORY 6: OPERATIONAL QUERIES
-- ============================================================================
-- ----------------------------------------------------------------------------
-- Query 15: Data freshness monitoring
--
-- Use Case: Ensure CDC pipeline is healthy
-- Expected Runtime: <1 second
-- ----------------------------------------------------------------------------

SELECT
    tenant_id,
    tenant_name,
    MAX(ingested_at) AS latest_event_time,
    DATEDIFF (
        second,
        MAX(ingested_at),
        GETDATE ()
    ) AS lag_seconds,
    DATEDIFF (
        minute,
        MAX(ingested_at),
        GETDATE ()
    ) AS lag_minutes,
    COUNT(*) AS events_last_hour,
    COUNT(DISTINCT entity_id) AS active_entities_last_hour, -- Freshness status
    CASE
        WHEN DATEDIFF (
            minute,
            MAX(ingested_at),
            GETDATE ()
        ) < 5 THEN 'healthy'
        WHEN DATEDIFF (
            minute,
            MAX(ingested_at),
            GETDATE ()
        ) < 15 THEN 'degraded'
        ELSE 'stale'
    END AS freshness_status
FROM fact_telemetry
WHERE
    ingested_at >= DATEADD (hour, -1, GETDATE ())
GROUP BY
    1,
    2
ORDER BY lag_seconds DESC;

-- ============================================================================
-- END OF QUERIES
-- ============================================================================
/*
PERFORMANCE TUNING NOTES:

1. DISTKEY Strategy:
- Use DISTKEY(entity_id) for fact tables
- Use DISTSTYLE ALL for small dimension tables
- Ensures joins are colocated (no network shuffle)

2. SORTKEY Strategy:
- Primary: Time-based (year_month, ingested_at)
- Secondary: Tenant filter (tenant_id)
- Enables zone map pruning (skip irrelevant blocks)

3. Query Optimization:
- Always filter by time first (year_month, ingested_at)
- Use EXPLAIN to check query plan
- Monitor WLM (Workload Management) queue times
- Partition large queries into smaller time windows

4. Columnar Storage Benefits:
- Only reads columns used in SELECT/WHERE
- 5-10x compression ratio
- Dramatically reduces I/O vs row-based storage

5. Monitoring:
- Check system tables: STL_QUERY, STL_SCAN, STL_EXPLAIN
- Monitor disk-based queries (should be <1%)
- Track query queue times (should be <5 seconds)
*/