-- EAV Schema for 200M Entities at Scale
-- PostgreSQL 15+ recommended for optimal partitioning performance

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS pg_partman;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS btree_gin;

-- Tenant table for multi-tenancy
CREATE TABLE tenants (
    tenant_id BIGINT PRIMARY KEY,
    tenant_name VARCHAR(255) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    is_active BOOLEAN DEFAULT true
);

-- Attributes metadata table
CREATE TABLE attributes (
    attribute_id BIGINT PRIMARY KEY,
    attribute_name VARCHAR(255) NOT NULL,
    data_type VARCHAR(50) NOT NULL CHECK (data_type IN ('string', 'integer', 'decimal', 'boolean', 'date', 'timestamp', 'json')),
    is_indexed BOOLEAN DEFAULT false,
    is_hot BOOLEAN DEFAULT false, -- Frequently accessed attributes
    validation_regex TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create index on attribute lookups
CREATE INDEX idx_attributes_name ON attributes(attribute_name);
CREATE INDEX idx_attributes_hot ON attributes(attribute_id) WHERE is_hot = true;

-- Main entities table (partitioned by entity_id range and tenant_id)
CREATE TABLE entities (
    entity_id BIGINT NOT NULL,
    tenant_id BIGINT NOT NULL,
    entity_type VARCHAR(100) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    is_deleted BOOLEAN DEFAULT false,
    version INTEGER DEFAULT 1,
    PRIMARY KEY (entity_id, tenant_id)
) PARTITION BY RANGE (entity_id);

-- Create partitions for entities (example for first 10M)
CREATE TABLE entities_p0 PARTITION OF entities
    FOR VALUES FROM (0) TO (1000000);
    
CREATE TABLE entities_p1 PARTITION OF entities
    FOR VALUES FROM (1000000) TO (2000000);

CREATE TABLE entities_p2 PARTITION OF entities
    FOR VALUES FROM (2000000) TO (3000000);

-- ... continue creating partitions up to 200M
-- In production, use pg_partman for automatic partition management

-- Create indexes on entity partitions
CREATE INDEX idx_entities_tenant ON entities(tenant_id, entity_id);
CREATE INDEX idx_entities_type ON entities(entity_type, tenant_id);
CREATE INDEX idx_entities_updated ON entities(updated_at) WHERE is_deleted = false;

-- JSONB table for hot attributes (frequently accessed)
CREATE TABLE entity_jsonb (
    entity_id BIGINT NOT NULL,
    tenant_id BIGINT NOT NULL,
    hot_attrs JSONB NOT NULL DEFAULT '{}',
    cold_attrs JSONB DEFAULT '{}',
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (entity_id, tenant_id)
) PARTITION BY HASH (entity_id);

-- Create hash partitions for entity_jsonb
CREATE TABLE entity_jsonb_p0 PARTITION OF entity_jsonb
    FOR VALUES WITH (MODULUS 100, REMAINDER 0);
    
CREATE TABLE entity_jsonb_p1 PARTITION OF entity_jsonb
    FOR VALUES WITH (MODULUS 100, REMAINDER 1);

-- ... continue for all 100 partitions

-- GIN indexes for JSONB queries
CREATE INDEX idx_entity_jsonb_hot_attrs ON entity_jsonb USING GIN (hot_attrs);
CREATE INDEX idx_entity_jsonb_tenant ON entity_jsonb(tenant_id);

-- Main EAV values table (TIME-SERIES, partitioned by ingested_at)
CREATE TABLE entity_values_ts (
    entity_id BIGINT NOT NULL,
    tenant_id BIGINT NOT NULL,
    attribute_id BIGINT NOT NULL,
    value TEXT,
    value_int BIGINT,
    value_decimal DECIMAL(20,5),
    value_bool BOOLEAN,
    value_date DATE,
    value_timestamp TIMESTAMP WITH TIME ZONE,
    ingested_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, entity_id, attribute_id, ingested_at)
) PARTITION BY RANGE (ingested_at);

-- Create example time partitions (monthly); automate via pg_partman in prod
CREATE TABLE entity_values_2025_10 PARTITION OF entity_values_ts
  FOR VALUES FROM ('2025-10-01') TO ('2025-11-01');

-- BRIN index for partition pruning + fast scans
CREATE INDEX idx_entity_values_ts_brin ON entity_values_ts USING BRIN (ingested_at);

-- Minimal write-lean indexes
CREATE INDEX idx_entity_values_ts_attr_time ON entity_values_ts(tenant_id, attribute_id, ingested_at);

-- UNLOGGED staging table for bursty ingest (COPY target)
CREATE UNLOGGED TABLE entity_values_ingest (
    entity_id BIGINT NOT NULL,
    tenant_id BIGINT NOT NULL,
    attribute_id BIGINT NOT NULL,
    value TEXT,
    value_int BIGINT,
    value_decimal DECIMAL(20,5),
    value_bool BOOLEAN,
    value_date DATE,
    value_timestamp TIMESTAMP WITH TIME ZONE,
    ingested_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Hot projection upsert (immediate read-after-write)
CREATE OR REPLACE FUNCTION upsert_hot_attrs(
    p_tenant_id BIGINT,
    p_entity_id BIGINT,
    p_delta JSONB
) RETURNS VOID AS $$
BEGIN
  INSERT INTO entity_jsonb(entity_id, tenant_id, hot_attrs)
  VALUES (p_entity_id, p_tenant_id, p_delta)
  ON CONFLICT (entity_id, tenant_id)
  DO UPDATE SET 
    hot_attrs = entity_jsonb.hot_attrs || EXCLUDED.hot_attrs,
    updated_at = CURRENT_TIMESTAMP;
END;$$ LANGUAGE plpgsql;

-- Batch flush from staging into time-series table (write-optimized)
CREATE OR REPLACE FUNCTION stage_flush(p_limit INT DEFAULT 50000)
RETURNS INT AS $$
DECLARE
  v_count INT;
BEGIN
  SET LOCAL synchronous_commit = off;
  WITH moved AS (
    INSERT INTO entity_values_ts (
      entity_id, tenant_id, attribute_id, value, value_int, value_decimal,
      value_bool, value_date, value_timestamp, ingested_at
    )
    SELECT entity_id, tenant_id, attribute_id, value, value_int, value_decimal,
           value_bool, value_date, value_timestamp, COALESCE(ingested_at, now())
    FROM entity_values_ingest
    ORDER BY ingested_at
    LIMIT p_limit
    RETURNING tenant_id, entity_id, attribute_id, value
  )
  SELECT COUNT(*) INTO v_count FROM moved;

  -- Optionally upsert hot attributes for a subset of keys here
  -- PERFORM upsert_hot_attrs(...);

  DELETE FROM entity_values_ingest
  USING (
    SELECT ctid FROM entity_values_ingest
    ORDER BY ingested_at
    LIMIT p_limit
  ) del
  WHERE entity_values_ingest.ctid = del.ctid;

  RETURN v_count;
END;$$ LANGUAGE plpgsql;

-- Materialized view for common aggregations
CREATE MATERIALIZED VIEW mv_entity_attribute_stats AS
SELECT 
    ev.tenant_id,
    ev.attribute_id,
    a.attribute_name,
    COUNT(DISTINCT ev.entity_id) as distinct_entities,
    COUNT(*) as total_values,
    MIN(ev.ingested_at) as oldest,
    MAX(ev.ingested_at) as newest
FROM entity_values_ts ev
JOIN attributes a ON ev.attribute_id = a.attribute_id
GROUP BY ev.tenant_id, ev.attribute_id, a.attribute_name;

CREATE INDEX idx_mv_stats_tenant ON mv_entity_attribute_stats(tenant_id);

-- Heartbeat table for replication monitoring
CREATE TABLE replication_heartbeat (
    id SERIAL PRIMARY KEY,
    timestamp TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    source VARCHAR(50) NOT NULL
);

-- Function to update timestamps
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Triggers for timestamp updates
CREATE TRIGGER update_entities_updated_at BEFORE UPDATE ON entities
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- Note: entity_values_ts is append-only, no UPDATE trigger needed

-- Function for efficient multi-attribute queries
CREATE OR REPLACE FUNCTION find_entities_by_attributes(
    p_tenant_id BIGINT,
    p_filters JSONB,
    p_recent_days INT DEFAULT 7
) RETURNS TABLE(entity_id BIGINT) AS $$
BEGIN
    RETURN QUERY
    WITH attribute_filters AS (
        SELECT 
            (attr->>'attribute_id')::BIGINT as attr_id,
            attr->>'value' as attr_value,
            attr->>'operator' as op
        FROM jsonb_array_elements(p_filters) as attr
    )
    SELECT DISTINCT ev.entity_id
    FROM entity_values_ts ev
    JOIN attribute_filters af ON ev.attribute_id = af.attr_id
    WHERE ev.tenant_id = p_tenant_id
    AND ev.ingested_at >= NOW() - make_interval(days => p_recent_days)
    AND (
        (af.op = '=' AND ev.value = af.attr_value) OR
        (af.op = '>' AND ev.value_int > af.attr_value::BIGINT) OR
        (af.op = '<' AND ev.value_int < af.attr_value::BIGINT)
    )
    GROUP BY ev.entity_id
    HAVING COUNT(DISTINCT ev.attribute_id) = (SELECT COUNT(*) FROM attribute_filters);
END;
$$ LANGUAGE plpgsql;

-- Statistics and maintenance
ANALYZE entities;
ANALYZE entity_values_ts;
ANALYZE entity_jsonb;

-- Example Queries

-- 1. OPERATIONAL QUERY: Find entities with hot attribute filters
-- Find all entities for tenant 123 where color='red' AND size > 100
SELECT 
    e.entity_id,
    e.entity_type,
    e.created_at,
    ej.hot_attrs
FROM entities e
JOIN entity_jsonb ej ON e.entity_id = ej.entity_id AND e.tenant_id = ej.tenant_id
WHERE e.tenant_id = 123
  AND ej.hot_attrs @> '{"color": "red"}'::jsonb
  AND (ej.hot_attrs->>'size')::int > 100
  AND e.is_deleted = false
LIMIT 100;

-- 1b. COLD ATTRIBUTE QUERY: Find entities by non-hot attributes
-- Find entities with specific firmware version (cold attribute)
WITH firmware_entities AS (
    SELECT DISTINCT entity_id, tenant_id
    FROM entity_values_ts
    WHERE tenant_id = 123
      AND attribute_id = 42  -- firmware_version
      AND value = 'v2.3.1'
      AND ingested_at >= NOW() - INTERVAL '7 days'  -- Partition pruning
)
SELECT 
    e.entity_id,
    e.entity_type,
    ej.hot_attrs,
    ev_latest.value as firmware_version
FROM firmware_entities fe
JOIN entities e USING (entity_id, tenant_id)
JOIN entity_jsonb ej USING (entity_id, tenant_id)
JOIN LATERAL (
    SELECT value
    FROM entity_values_ts
    WHERE entity_id = fe.entity_id
      AND tenant_id = fe.tenant_id
      AND attribute_id = 42
    ORDER BY ingested_at DESC
    LIMIT 1
) ev_latest ON true
LIMIT 100;

-- 2. ANALYTICAL QUERY: Distribution of attribute values over time
-- Analyze category distribution and numeric aggregates (last 30 days)
WITH category_entities AS (
    SELECT 
        ev.entity_id,
        ev.value as category
    FROM entity_values_ts ev
    WHERE ev.tenant_id = 123
      AND ev.attribute_id = 2  -- category attribute
      AND ev.ingested_at >= CURRENT_DATE - INTERVAL '30 days'
),
numeric_aggregates AS (
    SELECT 
        ce.category,
        a.attribute_name,
        AVG(ev.value_decimal) as avg_value,
        MIN(ev.value_decimal) as min_value,
        MAX(ev.value_decimal) as max_value,
        COUNT(*) as sample_count
    FROM category_entities ce
    JOIN entity_values_ts ev ON ce.entity_id = ev.entity_id AND ce.tenant_id = ev.tenant_id
    JOIN attributes a ON ev.attribute_id = a.attribute_id
    WHERE ev.tenant_id = 123
      AND ev.value_decimal IS NOT NULL
      AND a.data_type = 'decimal'
      AND ev.ingested_at >= CURRENT_DATE - INTERVAL '30 days'
    GROUP BY ce.category, a.attribute_name
)
SELECT 
    category,
    attribute_name,
    ROUND(avg_value, 2) as average,
    min_value as minimum,
    max_value as maximum,
    sample_count
FROM numeric_aggregates
WHERE sample_count > 100
ORDER BY category, attribute_name;

-- 3. Performance monitoring query
SELECT 
    schemaname,
    tablename,
    n_live_tup as live_tuples,
    n_dead_tup as dead_tuples,
    last_autovacuum,
    last_autoanalyze
FROM pg_stat_user_tables
WHERE schemaname = 'public'
ORDER BY n_live_tup DESC;

-- 4. Partition size monitoring
SELECT 
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size
FROM pg_tables
WHERE tablename LIKE 'entity_%'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
LIMIT 20;