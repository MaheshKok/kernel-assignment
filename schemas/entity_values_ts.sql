-- ============================================================================
-- ENTITY_VALUES_TS TABLE
-- ============================================================================
-- Main time-series EAV table (append-only)
-- RANGE partitioned by ingested_at (monthly partitions)
-- Supports multiple data types via type-specific columns
--
-- PARTITION STRATEGY:
-- - RANGE by ingested_at (timestamp) for time-series workloads
-- - Monthly partitions enable efficient archival and partition pruning
-- - Automate with pg_partman: partman.create_parent('entity_values_ts', 'ingested_at', 'native', 'monthly')
-- - Alternative: For distributed setups, consider Citus with hash distribution
-- ============================================================================
CREATE TABLE entity_values_ts(
    entity_id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    attribute_id bigint NOT NULL,
    value text,
    value_int bigint,
    value_decimal DECIMAL(20, 5),
    value_bool boolean,
    value_date date,
    value_timestamp timestamp with time zone,
    ingested_at timestamp with time zone NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, entity_id, attribute_id, ingested_at)
)
PARTITION BY RANGE (ingested_at);

-- ============================================================================
-- PARTITIONS (Monthly example)
-- ============================================================================
CREATE TABLE entity_values_2025_10 PARTITION OF entity_values_ts
FOR VALUES FROM ('2025-10-01') TO ('2025-11-01');

-- Note: Automate partition management with pg_partman:
-- SELECT partman.create_parent('public.entity_values_ts', 'ingested_at', 'native', 'monthly');
-- ============================================================================
-- INDEXES
-- ============================================================================
-- BRIN index: 1/1000th the size of B-tree, perfect for time-series
CREATE INDEX idx_entity_values_ts_brin ON entity_values_ts USING BRIN(ingested_at);

-- Composite index: tenant + attribute + time (most common query pattern)
CREATE INDEX idx_entity_values_ts_attr_time ON entity_values_ts(tenant_id, attribute_id, ingested_at);

-- ============================================================================
-- ROW-LEVEL SECURITY
-- ============================================================================
ALTER TABLE entity_values_ts ENABLE ROW LEVEL SECURITY;

-- Application users: must set app.current_tenant_id session variable
CREATE POLICY tenant_isolation_policy_values ON entity_values_ts
    FOR ALL
    TO PUBLIC
    USING (tenant_id = current_setting('app.current_tenant_id', true)::bigint)
    WITH CHECK (tenant_id = current_setting('app.current_tenant_id', true)::bigint);

-- Note: Background jobs/ingestion functions should use SECURITY DEFINER
-- to bypass RLS when processing multi-tenant batches

-- ============================================================================
-- AUTOVACUUM TUNING (Lazy: 10% threshold for append-only workload)
-- ============================================================================
-- WARNING: Managed services (Aurora, RDS, Cloud SQL) may ignore or override
-- autovacuum settings. Test in your environment.
ALTER TABLE entity_values_ts SET (autovacuum_vacuum_threshold = 50000, autovacuum_vacuum_scale_factor = 0.1, autovacuum_analyze_threshold = 10000, autovacuum_analyze_scale_factor = 0.05);

-- ============================================================================
-- FUNCTIONS (Multi-attribute query helper)
-- ============================================================================
CREATE OR REPLACE FUNCTION find_entities_by_attributes(p_tenant_id bigint, p_filters jsonb, p_recent_days int DEFAULT 7)
    RETURNS TABLE(
        entity_id bigint
    )
    AS $$
BEGIN
    RETURN QUERY WITH attribute_filters AS(
        SELECT
(attr ->> 'attribute_id')::bigint AS attr_id,
            attr ->> 'value' AS attr_value,
            attr ->> 'operator' AS op
        FROM
            jsonb_array_elements(p_filters) AS attr
)
    SELECT DISTINCT
        ev.entity_id
    FROM
        entity_values_ts ev
        JOIN attribute_filters af ON ev.attribute_id = af.attr_id
    WHERE
        ev.tenant_id = p_tenant_id
        AND ev.ingested_at >= NOW() - make_interval(days => p_recent_days)
        AND((af.op = '='
                AND ev.value = af.attr_value)
            OR(af.op = '>'
                AND ev.value_int > af.attr_value::bigint)
            OR(af.op = '<'
                AND ev.value_int < af.attr_value::bigint))
    GROUP BY
        ev.entity_id
    HAVING
        COUNT(DISTINCT ev.attribute_id) =(
            SELECT
                COUNT(*)
            FROM
                attribute_filters);
END;
$$
LANGUAGE plpgsql;

-- ============================================================================
-- STATISTICS
-- ============================================================================
ANALYZE entity_values_ts;

