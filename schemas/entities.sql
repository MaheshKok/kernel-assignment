-- ============================================================================
-- ENTITIES TABLE
-- ============================================================================
-- Base entity table, RANGE partitioned by entity_id for data locality
-- Contains core entity metadata (type, timestamps, soft delete flag)
--
-- PARTITION STRATEGY:
-- - RANGE by entity_id (not tenant_id) to support global entity ordering
-- - Each partition covers 1M entities for balanced size (~GB per partition)
-- - Alternative: HASH by tenant_id for Citus/distributed setups
-- - With RLS enabled, queries are tenant-isolated despite global partitioning
-- ============================================================================
CREATE TABLE entities(
    entity_id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    entity_type varchar(100) NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    is_deleted boolean DEFAULT FALSE,
    version integer DEFAULT 1,
    PRIMARY KEY (entity_id, tenant_id)
)
PARTITION BY RANGE (entity_id);

-- ============================================================================
-- PARTITIONS (Example: first 3 partitions for 0-3M entities)
-- ============================================================================
CREATE TABLE entities_p0 PARTITION OF entities
FOR VALUES FROM (0) TO (1000000);

CREATE TABLE entities_p1 PARTITION OF entities
FOR VALUES FROM (1000000) TO (2000000);

CREATE TABLE entities_p2 PARTITION OF entities
FOR VALUES FROM (2000000) TO (3000000);

-- Note: In production, create 200 partitions (1M entities each) or use pg_partman
-- ============================================================================
-- INDEXES
-- ============================================================================
CREATE INDEX idx_entities_tenant ON entities(tenant_id, entity_id);

CREATE INDEX idx_entities_type ON entities(entity_type, tenant_id);

CREATE INDEX idx_entities_updated ON entities(updated_at)
WHERE
    is_deleted = FALSE;

-- ============================================================================
-- ROW-LEVEL SECURITY
-- ============================================================================
ALTER TABLE entities ENABLE ROW LEVEL SECURITY;

-- Application users: must set app.current_tenant_id session variable
CREATE POLICY tenant_isolation_policy_entities ON entities
    FOR ALL
    TO PUBLIC
    USING (tenant_id = current_setting('app.current_tenant_id', true)::bigint)
    WITH CHECK (tenant_id = current_setting('app.current_tenant_id', true)::bigint);

-- Note: Background jobs/ingestion functions should use SECURITY DEFINER
-- to bypass RLS when processing multi-tenant batches

-- ============================================================================
-- AUTOVACUUM TUNING (Moderate: 5% threshold)
-- ============================================================================
-- WARNING: Managed services (Aurora, RDS, Cloud SQL) may ignore or override
-- autovacuum_vacuum_cost_delay and related settings. Test in your environment.
ALTER TABLE entities SET (autovacuum_vacuum_threshold = 1000, autovacuum_vacuum_scale_factor = 0.05, autovacuum_analyze_threshold = 1000, autovacuum_analyze_scale_factor = 0.05);

-- ============================================================================
-- TRIGGERS
-- ============================================================================
CREATE OR REPLACE FUNCTION update_updated_at()
    RETURNS TRIGGER
    AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;

CREATE TRIGGER update_entities_updated_at
    BEFORE UPDATE ON entities
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at();

-- ============================================================================
-- STATISTICS
-- ============================================================================
ANALYZE entities;

