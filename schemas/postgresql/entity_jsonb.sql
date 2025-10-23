-- ============================================================================
-- ENTITY_JSONB TABLE
-- ============================================================================
-- JSONB projection for hot/cold attributes (CQRS read model)
-- HASH partitioned by entity_id for uniform distribution (100 partitions)
-- Enables fast multi-attribute queries via GIN index
--
-- PARTITION STRATEGY:
-- - HASH by entity_id for even load distribution across partitions
-- - 100 partitions = ~2M entities per partition at 200M scale
-- - Alternative: HASH by tenant_id if tenant skew is minimal
-- ============================================================================
CREATE TABLE entity_jsonb(
    entity_id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    hot_attrs jsonb NOT NULL DEFAULT '{}',
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (entity_id, tenant_id)
)
PARTITION BY HASH (entity_id);

-- ============================================================================
-- PARTITIONS (Example: first 3 of 100 hash partitions)
-- ============================================================================
CREATE TABLE entity_jsonb_p0 PARTITION OF entity_jsonb
FOR VALUES WITH (MODULUS 100, REMAINDER 0);

CREATE TABLE entity_jsonb_p1 PARTITION OF entity_jsonb
FOR VALUES WITH (MODULUS 100, REMAINDER 1);

CREATE TABLE entity_jsonb_p2 PARTITION OF entity_jsonb
FOR VALUES WITH (MODULUS 100, REMAINDER 2);

-- Note: Generate remaining 97 partitions with:
-- DO $$
-- BEGIN
--   FOR i IN 3..99 LOOP
--     EXECUTE format('CREATE TABLE entity_jsonb_p%s PARTITION OF entity_jsonb FOR VALUES WITH (MODULUS 100, REMAINDER %s)', i, i);
--   END LOOP;
-- END $$;
-- ============================================================================
-- INDEXES
-- ============================================================================
CREATE INDEX idx_entity_jsonb_hot_attrs ON entity_jsonb USING GIN(hot_attrs);

CREATE INDEX idx_entity_jsonb_tenant ON entity_jsonb(tenant_id);

-- ============================================================================
-- ROW-LEVEL SECURITY
-- ============================================================================
ALTER TABLE entity_jsonb ENABLE ROW LEVEL SECURITY;

-- Application users: must set app.current_tenant_id session variable
CREATE POLICY tenant_isolation_policy_jsonb ON entity_jsonb
    FOR ALL TO PUBLIC
        USING (tenant_id = current_setting('app.current_tenant_id', TRUE)::bigint)
        WITH CHECK (tenant_id = current_setting('app.current_tenant_id', TRUE)::bigint);

-- Note: Background jobs/ingestion functions should use SECURITY DEFINER
-- to bypass RLS when processing multi-tenant batches
-- ============================================================================
-- AUTOVACUUM TUNING (Aggressive: 1% threshold for frequent updates)
-- ============================================================================
-- WARNING: Managed services (Aurora, RDS, Cloud SQL) may ignore or override
-- autovacuum_vacuum_cost_delay and related settings. Test in your environment.
ALTER TABLE entity_jsonb SET (autovacuum_vacuum_threshold = 100, autovacuum_vacuum_scale_factor = 0.01, autovacuum_analyze_threshold = 100, autovacuum_analyze_scale_factor = 0.01, autovacuum_vacuum_cost_delay = 2);

-- ============================================================================
-- FUNCTIONS
-- ============================================================================
-- SECURITY DEFINER: Bypasses RLS to allow multi-tenant batch updates
CREATE OR REPLACE FUNCTION upsert_hot_attrs(p_tenant_id bigint, p_entity_id bigint, p_delta jsonb)
    RETURNS VOID
    SECURITY DEFINER
    SET search_path = public
    AS $$
BEGIN
    INSERT INTO entity_jsonb(entity_id, tenant_id, hot_attrs)
        VALUES(p_entity_id, p_tenant_id, p_delta)
    ON CONFLICT(entity_id, tenant_id)
        DO UPDATE SET
            hot_attrs = entity_jsonb.hot_attrs || EXCLUDED.hot_attrs,
            updated_at = CURRENT_TIMESTAMP;
END;
$$
LANGUAGE plpgsql;

-- ============================================================================
-- STATISTICS
-- ============================================================================
ANALYZE entity_jsonb;

