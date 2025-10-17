-- ============================================================================
-- REPLICATION_HEARTBEAT TABLE
-- ============================================================================
-- Replication lag monitoring: primary writes, replicas read
-- Enables heartbeat-based lag detection (more reliable than LSN-based)
-- ============================================================================
CREATE TABLE replication_heartbeat(
    id serial PRIMARY KEY,
    timestamp timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    source varchar(50) NOT NULL
);


-- ============================================================================
-- NO AUTOVACUUM TUNING (tiny table, default is fine)
-- ============================================================================
-- ============================================================================
-- STATISTICS
-- ============================================================================
ANALYZE replication_heartbeat;

