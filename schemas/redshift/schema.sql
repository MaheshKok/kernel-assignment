-- ============================================================================
-- AtlasCo Telemetry System - Redshift OLAP Schema
-- 
-- Purpose: Analytics warehouse for historical queries and aggregations
-- Data Flow: PostgreSQL → Debezium → Kafka → Flink → Redshift
-- Freshness: 5-minute lag (target)
-- ============================================================================

-- ============================================================================
-- DIMENSION TABLES (Slowly Changing Dimensions)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- dim_tenants: Tenant dimension (replicated from PostgreSQL tenants table)
-- ----------------------------------------------------------------------------
CREATE TABLE dim_tenants (
    tenant_id BIGINT NOT NULL,
    tenant_name VARCHAR(255) NOT NULL,
    created_at TIMESTAMP NOT NULL,
    is_active BOOLEAN DEFAULT TRUE,
    
    -- SCD Type 2 fields
    valid_from TIMESTAMP NOT NULL DEFAULT GETDATE(),
    valid_to TIMESTAMP DEFAULT '9999-12-31 23:59:59',
    is_current BOOLEAN DEFAULT TRUE,
    
    PRIMARY KEY (tenant_id, valid_from)
)
DISTSTYLE ALL  -- Small table, replicate to all nodes
SORTKEY (tenant_id);

COMMENT ON TABLE dim_tenants IS 'Tenant dimension with Slowly Changing Dimension Type 2 tracking';


-- ----------------------------------------------------------------------------
-- dim_attributes: Attribute metadata dimension
-- ----------------------------------------------------------------------------
CREATE TABLE dim_attributes (
    attribute_id BIGINT NOT NULL,
    attribute_name VARCHAR(255) NOT NULL,
    data_type VARCHAR(50) NOT NULL,
    
    -- Additional classification for analytics
    category VARCHAR(100),  -- e.g., 'performance', 'status', 'environmental', 'diagnostic'
    unit VARCHAR(50),       -- e.g., 'celsius', 'percent', 'mbps', 'count'
    is_hot BOOLEAN DEFAULT FALSE,
    
    -- SCD Type 2 fields
    valid_from TIMESTAMP NOT NULL DEFAULT GETDATE(),
    valid_to TIMESTAMP DEFAULT '9999-12-31 23:59:59',
    is_current BOOLEAN DEFAULT TRUE,
    
    PRIMARY KEY (attribute_id, valid_from)
)
DISTSTYLE ALL  -- Small table, replicate to all nodes
SORTKEY (attribute_id);

COMMENT ON TABLE dim_attributes IS 'Attribute metadata dimension with categorization for analytics';


-- ----------------------------------------------------------------------------
-- dim_entities: Entity dimension (enriched from PostgreSQL entities)
-- ----------------------------------------------------------------------------
CREATE TABLE dim_entities (
    entity_id BIGINT NOT NULL,
    tenant_id BIGINT NOT NULL,
    tenant_name VARCHAR(255),  -- Denormalized from dim_tenants
    entity_type VARCHAR(100) NOT NULL,
    
    -- Enriched from entity_jsonb hot_attrs
    region VARCHAR(50),
    environment VARCHAR(50),    -- production, staging, dev
    datacenter VARCHAR(100),
    
    created_at TIMESTAMP NOT NULL,
    
    -- SCD Type 2 fields
    valid_from TIMESTAMP NOT NULL DEFAULT GETDATE(),
    valid_to TIMESTAMP DEFAULT '9999-12-31 23:59:59',
    is_current BOOLEAN DEFAULT TRUE,
    
    PRIMARY KEY (entity_id, valid_from)
)
DISTKEY(entity_id)  -- Distribute by entity_id for joins with fact tables
SORTKEY(tenant_id, entity_type, created_at);

COMMENT ON TABLE dim_entities IS 'Entity dimension with enriched metadata from JSONB attributes';


-- ============================================================================
-- FACT TABLES (Time-Series Data)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- fact_telemetry: Main telemetry fact table (denormalized)
-- 
-- Source: PostgreSQL entity_values_ts
-- Size: ~500M rows/month at 10K writes/sec
-- Retention: 2 years (24 months) = ~12 billion rows
-- Compression: ~5-10x (columnar storage)
-- ----------------------------------------------------------------------------
CREATE TABLE fact_telemetry (
    -- Dimension keys
    entity_id BIGINT NOT NULL,
    tenant_id BIGINT NOT NULL,
    attribute_id BIGINT NOT NULL,
    
    -- Denormalized dimension attributes (avoid JOINs)
    tenant_name VARCHAR(255),
    entity_type VARCHAR(100),
    attribute_name VARCHAR(255),
    attribute_category VARCHAR(100),  -- For filtering by category
    
    -- Typed value columns (from entity_values_ts)
    value TEXT,                       -- Generic string
    value_int BIGINT,                 -- Integer values
    value_decimal DECIMAL(20,5),      -- Numeric values
    value_bool BOOLEAN,               -- Boolean flags
    value_timestamp TIMESTAMP,        -- Timestamp values
    
    -- Time dimensions (for efficient filtering and aggregation)
    ingested_at TIMESTAMP NOT NULL,
    ingested_date DATE NOT NULL,      -- Derived: DATE(ingested_at)
    ingested_hour SMALLINT NOT NULL,  -- Derived: EXTRACT(HOUR FROM ingested_at) [0-23]
    ingested_day_of_week SMALLINT NOT NULL, -- Derived: EXTRACT(DOW FROM ingested_at) [0-6]
    ingested_week DATE,               -- Derived: DATE_TRUNC('week', ingested_at)
    ingested_month DATE,              -- Derived: DATE_TRUNC('month', ingested_at)
    
    -- Partition key (for time-based partition pruning)
    year_month CHAR(7) NOT NULL       -- e.g., '2025-10'
)
DISTKEY(entity_id)  -- Distribute by entity_id to colocate with dim_entities
SORTKEY(year_month, tenant_id, ingested_at)  -- Multi-level sorting for query optimization
-- Note: Redshift doesn't support declarative partitioning like PostgreSQL,
-- but SORTKEY on year_month enables zone maps for effective partition pruning
;

COMMENT ON TABLE fact_telemetry IS 'Main telemetry fact table with denormalized dimensions and derived time columns';


-- ----------------------------------------------------------------------------
-- fact_current_state: Current state snapshot (from entity_jsonb)
-- 
-- Source: PostgreSQL entity_jsonb (flattened JSONB to columns)
-- Size: ~200M rows (one per entity)
-- Purpose: Fast current state queries without scanning time-series
-- ----------------------------------------------------------------------------
CREATE TABLE fact_current_state (
    -- Dimension keys
    entity_id BIGINT NOT NULL,
    tenant_id BIGINT NOT NULL,
    
    -- Denormalized dimensions
    tenant_name VARCHAR(255),
    entity_type VARCHAR(100),
    
    -- Hot attributes (extracted from JSONB)
    status VARCHAR(50),               -- online, offline, warning, error
    environment VARCHAR(50),          -- production, staging, dev
    priority SMALLINT,                -- 1-10 (critical to low)
    region VARCHAR(50),               -- us-west-2, us-east-1, eu-west-1
    datacenter VARCHAR(100),
    
    -- Operational metrics
    last_seen TIMESTAMP,
    alert_count INTEGER,
    error_count INTEGER,
    uptime_percent DECIMAL(5,2),
    
    -- Metadata
    updated_at TIMESTAMP NOT NULL,
    
    PRIMARY KEY (entity_id)
)
DISTKEY(entity_id)
SORTKEY(tenant_id, entity_type, status);

COMMENT ON TABLE fact_current_state IS 'Current state snapshot with flattened hot attributes for fast queries';


-- ============================================================================
-- AGGREGATE TABLES (Pre-computed for dashboards)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- agg_daily_entity_stats: Daily entity-level statistics
-- 
-- Pre-aggregated for dashboard performance
-- Refreshed: Hourly via scheduled query
-- ----------------------------------------------------------------------------
CREATE TABLE agg_daily_entity_stats (
    entity_id BIGINT NOT NULL,
    tenant_id BIGINT NOT NULL,
    entity_type VARCHAR(100),
    date DATE NOT NULL,
    
    -- Aggregated metrics
    total_events BIGINT,
    total_errors BIGINT,
    avg_temperature DECIMAL(10,2),
    max_temperature DECIMAL(10,2),
    min_temperature DECIMAL(10,2),
    avg_cpu_percent DECIMAL(5,2),
    avg_memory_percent DECIMAL(5,2),
    
    -- Uptime metrics
    uptime_minutes INTEGER,
    downtime_minutes INTEGER,
    uptime_percent DECIMAL(5,2),
    
    -- Computed at
    computed_at TIMESTAMP NOT NULL DEFAULT GETDATE(),
    
    PRIMARY KEY (entity_id, date)
)
DISTKEY(entity_id)
SORTKEY(tenant_id, date);

COMMENT ON TABLE agg_daily_entity_stats IS 'Daily pre-aggregated entity statistics for dashboard performance';


-- ----------------------------------------------------------------------------
-- agg_hourly_attribute_stats: Hourly attribute-level statistics
-- 
-- For trending and anomaly detection
-- Refreshed: Every 5 minutes via scheduled query
-- ----------------------------------------------------------------------------
CREATE TABLE agg_hourly_attribute_stats (
    tenant_id BIGINT NOT NULL,
    attribute_id BIGINT NOT NULL,
    attribute_name VARCHAR(255),
    hour TIMESTAMP NOT NULL,  -- Truncated to hour
    
    -- Statistical aggregates
    sample_count BIGINT,
    distinct_entities BIGINT,
    
    -- Numeric aggregates (if attribute is numeric)
    avg_value DECIMAL(20,5),
    min_value DECIMAL(20,5),
    max_value DECIMAL(20,5),
    stddev_value DECIMAL(20,5),
    percentile_50 DECIMAL(20,5),  -- Median
    percentile_95 DECIMAL(20,5),
    percentile_99 DECIMAL(20,5),
    
    -- Computed at
    computed_at TIMESTAMP NOT NULL DEFAULT GETDATE(),
    
    PRIMARY KEY (tenant_id, attribute_id, hour)
)
DISTKEY(tenant_id)
SORTKEY(hour, attribute_id);

COMMENT ON TABLE agg_hourly_attribute_stats IS 'Hourly attribute statistics for trending and anomaly detection';


-- ============================================================================
-- HELPER VIEWS
-- ============================================================================

-- ----------------------------------------------------------------------------
-- v_latest_telemetry: Latest value per entity/attribute (last 7 days)
-- ----------------------------------------------------------------------------
CREATE VIEW v_latest_telemetry AS
WITH ranked_values AS (
    SELECT
        entity_id,
        tenant_id,
        attribute_id,
        attribute_name,
        value,
        value_int,
        value_decimal,
        value_bool,
        ingested_at,
        ROW_NUMBER() OVER (
            PARTITION BY entity_id, attribute_id
            ORDER BY ingested_at DESC
        ) AS rn
    FROM fact_telemetry
    WHERE ingested_at >= GETDATE() - INTERVAL '7 days'
)
SELECT
    entity_id,
    tenant_id,
    attribute_id,
    attribute_name,
    value,
    value_int,
    value_decimal,
    value_bool,
    ingested_at
FROM ranked_values
WHERE rn = 1;

COMMENT ON VIEW v_latest_telemetry IS 'Latest value per entity/attribute for last 7 days';


-- ----------------------------------------------------------------------------
-- v_entity_health_summary: Current entity health snapshot
-- ----------------------------------------------------------------------------
CREATE VIEW v_entity_health_summary AS
SELECT
    e.entity_id,
    e.tenant_id,
    e.tenant_name,
    e.entity_type,
    e.region,
    e.environment,
    cs.status,
    cs.priority,
    cs.last_seen,
    cs.alert_count,
    cs.error_count,
    cs.uptime_percent,
    CASE
        WHEN cs.status = 'offline' THEN 'critical'
        WHEN cs.alert_count > 10 THEN 'warning'
        WHEN cs.error_count > 5 THEN 'warning'
        WHEN cs.uptime_percent < 95 THEN 'degraded'
        ELSE 'healthy'
    END AS health_status,
    cs.updated_at
FROM dim_entities e
JOIN fact_current_state cs ON cs.entity_id = e.entity_id
WHERE e.is_current = TRUE;

COMMENT ON VIEW v_entity_health_summary IS 'Current entity health with computed health status';


-- ============================================================================
-- DATA LOADING TABLES (Staging for CDC pipeline)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- staging_telemetry: Temporary staging for Flink-processed CDC events
-- 
-- Flink writes batches here every 30 seconds
-- ETL job loads to fact_telemetry and truncates
-- ----------------------------------------------------------------------------
CREATE TABLE staging_telemetry (
    entity_id BIGINT NOT NULL,
    tenant_id BIGINT NOT NULL,
    tenant_name VARCHAR(255),
    attribute_id BIGINT NOT NULL,
    attribute_name VARCHAR(255),
    attribute_category VARCHAR(100),
    entity_type VARCHAR(100),
    value TEXT,
    value_int BIGINT,
    value_decimal DECIMAL(20,5),
    value_bool BOOLEAN,
    value_timestamp TIMESTAMP,
    ingested_at TIMESTAMP NOT NULL,
    ingested_date DATE NOT NULL,
    ingested_hour SMALLINT NOT NULL,
    ingested_day_of_week SMALLINT NOT NULL,
    ingested_week DATE,
    ingested_month DATE,
    year_month CHAR(7) NOT NULL,
    batch_id VARCHAR(100)  -- Flink batch identifier
)
DISTSTYLE EVEN;  -- Even distribution for bulk loading

COMMENT ON TABLE staging_telemetry IS 'Staging table for CDC events before loading to fact_telemetry';


-- ============================================================================
-- STORED PROCEDURES (ETL and Maintenance)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- sp_load_telemetry_from_staging: Load data from staging to fact_telemetry
-- 
-- Called every 30 seconds by scheduled job
-- Ensures idempotency via batch_id deduplication
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_load_telemetry_from_staging()
AS $$
DECLARE
    v_rows_loaded BIGINT;
BEGIN
    -- Insert new data (deduplicate by batch_id)
    INSERT INTO fact_telemetry
    SELECT DISTINCT
        entity_id,
        tenant_id,
        attribute_id,
        tenant_name,
        entity_type,
        attribute_name,
        attribute_category,
        value,
        value_int,
        value_decimal,
        value_bool,
        value_timestamp,
        ingested_at,
        ingested_date,
        ingested_hour,
        ingested_day_of_week,
        ingested_week,
        ingested_month,
        year_month
    FROM staging_telemetry
    WHERE batch_id NOT IN (
        -- Avoid re-processing already loaded batches
        SELECT DISTINCT batch_id 
        FROM staging_telemetry_audit 
        WHERE loaded_at >= GETDATE() - INTERVAL '1 hour'
    );
    
    GET DIAGNOSTICS v_rows_loaded = ROW_COUNT;
    
    -- Audit loaded batches
    INSERT INTO staging_telemetry_audit (batch_id, loaded_at, rows_loaded)
    SELECT DISTINCT batch_id, GETDATE(), v_rows_loaded
    FROM staging_telemetry;
    
    -- Truncate staging
    TRUNCATE TABLE staging_telemetry;
    
    RAISE INFO 'Loaded % rows from staging to fact_telemetry', v_rows_loaded;
END;
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- staging_telemetry_audit: Track processed batches (idempotency)
-- ----------------------------------------------------------------------------
CREATE TABLE staging_telemetry_audit (
    batch_id VARCHAR(100) NOT NULL,
    loaded_at TIMESTAMP NOT NULL,
    rows_loaded BIGINT,
    PRIMARY KEY (batch_id)
)
DISTSTYLE EVEN;


-- ============================================================================
-- INDEXES (Redshift uses zone maps, not traditional indexes)
-- ============================================================================

-- Note: Redshift doesn't support CREATE INDEX
-- Instead, query optimization relies on:
-- 1. DISTKEY - Colocation for joins
-- 2. SORTKEY - Zone maps for filtering
-- 3. Column encoding - Compression
-- 4. Denormalization - Avoid expensive joins

-- Analyze tables to update statistics
ANALYZE dim_tenants;
ANALYZE dim_attributes;
ANALYZE dim_entities;
ANALYZE fact_telemetry;
ANALYZE fact_current_state;
ANALYZE agg_daily_entity_stats;
ANALYZE agg_hourly_attribute_stats;


-- ============================================================================
-- VACUUM (Redshift equivalent for reclaiming space)
-- ============================================================================

-- Schedule these as part of maintenance window
-- VACUUM fact_telemetry TO 95 PERCENT;
-- VACUUM fact_current_state TO 95 PERCENT;


-- ============================================================================
-- GRANTS (Example permissions for analytics users)
-- ============================================================================

-- Create analytics role
CREATE GROUP analytics_users;

-- Grant read access to all tables
GRANT SELECT ON ALL TABLES IN SCHEMA public TO GROUP analytics_users;

-- Grant read access to views
GRANT SELECT ON v_latest_telemetry TO GROUP analytics_users;
GRANT SELECT ON v_entity_health_summary TO GROUP analytics_users;

-- Deny access to staging tables (internal use only)
REVOKE ALL ON staging_telemetry FROM GROUP analytics_users;
REVOKE ALL ON staging_telemetry_audit FROM GROUP analytics_users;


-- ============================================================================
-- MONITORING VIEWS
-- ============================================================================

-- ----------------------------------------------------------------------------
-- v_table_sizes: Monitor table growth
-- ----------------------------------------------------------------------------
CREATE VIEW v_table_sizes AS
SELECT
    TRIM(pgn.nspname) AS schema_name,
    TRIM(a.name) AS table_name,
    ((b.mbytes / part.total::DECIMAL) * 100)::DECIMAL(5,2) AS pct_of_total,
    b.mbytes,
    b.rows
FROM (
    SELECT 
        db_id, 
        id, 
        name, 
        SUM(rows) AS rows
    FROM stv_tbl_perm
    GROUP BY db_id, id, name
) AS a
JOIN pg_class AS pgc ON pgc.oid = a.id
JOIN pg_namespace AS pgn ON pgn.oid = pgc.relnamespace
JOIN (
    SELECT 
        tbl,
        COUNT(*) AS mbytes,
        SUM(rows) AS rows
    FROM stv_blocklist
    GROUP BY tbl
) AS b ON a.id = b.tbl
CROSS JOIN (
    SELECT SUM(mbytes) AS total
    FROM (
        SELECT COUNT(*) AS mbytes
        FROM stv_blocklist
        GROUP BY tbl
    )
) AS part
WHERE pgn.nspname = 'public'
ORDER BY b.mbytes DESC;

COMMENT ON VIEW v_table_sizes IS 'Monitor table sizes and row counts';


-- ============================================================================
-- SCHEDULED QUERIES (To be configured in Redshift console)
-- ============================================================================

/*
Schedule 1: Load from staging (every 30 seconds)
CALL sp_load_telemetry_from_staging();

Schedule 2: Refresh daily aggregates (every hour)
INSERT INTO agg_daily_entity_stats
SELECT ... FROM fact_telemetry
WHERE ingested_date >= CURRENT_DATE - 1;

Schedule 3: Refresh hourly aggregates (every 5 minutes)
INSERT INTO agg_hourly_attribute_stats
SELECT ... FROM fact_telemetry
WHERE hour >= DATE_TRUNC('hour', GETDATE()) - INTERVAL '1 hour';

Schedule 4: Vacuum and analyze (daily at 2 AM)
VACUUM fact_telemetry TO 95 PERCENT;
ANALYZE fact_telemetry;
*/


-- ============================================================================
-- END OF SCHEMA
-- ============================================================================
