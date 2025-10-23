-- ============================================================================
-- ENTITY_VALUES_INGEST TABLE (STAGING)
-- ============================================================================
-- UNLOGGED staging table for COPY operations (10K writes/sec)
-- Data is batched and flushed to entity_values_ts via stage_flush() function
-- Not crash-safe: acceptable data loss window is last batch (<1 minute)
-- ============================================================================
CREATE UNLOGGED TABLE entity_values_ingest(
    entity_id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    attribute_id bigint NOT NULL,
    value text,
    value_int bigint,
    value_decimal DECIMAL(20, 5),
    value_bool boolean,
    value_date date,
    value_timestamp timestamp with time zone,
    ingested_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================================
-- AUTOVACUUM TUNING (Aggressive: absolute threshold for high churn)
-- ============================================================================
-- WARNING: Managed services (Aurora, RDS, Cloud SQL) may ignore or override
-- autovacuum_vacuum_cost_delay and related settings. Test in your environment.
ALTER TABLE entity_values_ingest SET (autovacuum_vacuum_threshold = 50, autovacuum_vacuum_scale_factor = 0.05, autovacuum_analyze_threshold = 10000, autovacuum_vacuum_cost_delay = 0);

-- ============================================================================
-- BATCH FLUSH FUNCTION
-- ============================================================================
-- SECURITY DEFINER: Bypasses RLS to allow multi-tenant batch inserts from staging
CREATE OR REPLACE FUNCTION stage_flush(p_limit int DEFAULT 50000)
    RETURNS int
    SECURITY DEFINER
    SET search_path = public
    AS $$
DECLARE
    v_count int;
BEGIN
    SET LOCAL synchronous_commit = OFF;
    WITH moved AS (
INSERT INTO entity_values_ts(entity_id, tenant_id, attribute_id, value, value_int, value_decimal, value_bool, value_date, value_timestamp, ingested_at)
        SELECT
            entity_id,
            tenant_id,
            attribute_id,
            value,
            value_int,
            value_decimal,
            value_bool,
            value_date,
            value_timestamp,
            COALESCE(ingested_at, now())
        FROM
            entity_values_ingest
        ORDER BY
            ingested_at
        LIMIT p_limit
    RETURNING
        tenant_id,
        entity_id,
        attribute_id,
        value
)
SELECT
    COUNT(*) INTO v_count
FROM
    moved;
    DELETE FROM entity_values_ingest USING (
        SELECT
            ctid
        FROM
            entity_values_ingest
        ORDER BY
            ingested_at
        LIMIT p_limit) del
WHERE
    entity_values_ingest.ctid = del.ctid;
    RETURN v_count;
END;
$$
LANGUAGE plpgsql;

-- ============================================================================
-- STATISTICS
-- ============================================================================
ANALYZE entity_values_ingest;

