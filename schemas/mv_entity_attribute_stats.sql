-- ============================================================================
-- MV_ENTITY_ATTRIBUTE_STATS (MATERIALIZED VIEW)
-- ============================================================================
-- Pre-aggregated attribute usage statistics
-- Refresh hourly via cron or pg_cron
-- ============================================================================
CREATE MATERIALIZED VIEW mv_entity_attribute_stats AS
SELECT
    ev.tenant_id,
    ev.attribute_id,
    a.attribute_name,
    COUNT(DISTINCT ev.entity_id) AS distinct_entities,
    COUNT(*) AS total_values,
    MIN(ev.ingested_at) AS oldest,
    MAX(ev.ingested_at) AS newest
FROM
    entity_values_ts ev
    JOIN attributes a ON ev.attribute_id = a.attribute_id
GROUP BY
    ev.tenant_id,
    ev.attribute_id,
    a.attribute_name;

-- ============================================================================
-- INDEXES
-- ============================================================================
CREATE INDEX idx_mv_stats_tenant ON mv_entity_attribute_stats(tenant_id);


-- ============================================================================
-- REFRESH (run hourly via pg_cron)
-- ============================================================================
-- SELECT cron.schedule('refresh-mv-stats', '0 * * * *',
--   'REFRESH MATERIALIZED VIEW CONCURRENTLY mv_entity_attribute_stats');
-- Initial refresh
REFRESH MATERIALIZED VIEW mv_entity_attribute_stats;

