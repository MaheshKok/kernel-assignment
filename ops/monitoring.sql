-- Operational Monitoring Queries for EAV Platform
-- Run these regularly or set up as CloudWatch custom metrics

-- 1. Write Throughput Monitoring
CREATE OR REPLACE VIEW v_write_throughput AS
SELECT 
    DATE_TRUNC('minute', ingested_at) as minute,
    tenant_id,
    COUNT(*) as events_per_minute,
    COUNT(DISTINCT entity_id) as unique_entities
FROM entity_values_ts
WHERE ingested_at >= NOW() - INTERVAL '1 hour'
GROUP BY DATE_TRUNC('minute', ingested_at), tenant_id
ORDER BY minute DESC;

-- Query current write throughput
SELECT 
    minute,
    SUM(events_per_minute) as total_events,
    MAX(events_per_minute) as peak_tenant_events
FROM v_write_throughput
WHERE minute >= NOW() - INTERVAL '5 minutes'
GROUP BY minute
ORDER BY minute DESC;

-- 2. Staging Table Health
SELECT 
    COUNT(*) as pending_events,
    pg_size_pretty(pg_total_relation_size('entity_values_ingest')) as staging_size,
    MIN(ingested_at) as oldest_event,
    MAX(ingested_at) as newest_event,
    EXTRACT(EPOCH FROM (MAX(ingested_at) - MIN(ingested_at))) as age_span_seconds
FROM entity_values_ingest;

-- Alert if staging table > 1M rows (indicates flush backlog)
-- Alert if oldest event > 60 seconds old

-- 3. Partition Health & Size
SELECT 
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size,
    n_live_tup as live_rows,
    n_dead_tup as dead_rows,
    ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) as dead_pct,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze
FROM pg_stat_user_tables
WHERE tablename LIKE 'entity_values_%'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
LIMIT 20;

-- Alert if dead_pct > 20%
-- Alert if partition > 50GB (consider sub-partitioning)

-- 4. Index Usage Analysis
SELECT 
    schemaname,
    tablename,
    indexname,
    idx_scan as index_scans,
    idx_tup_read as tuples_read,
    idx_tup_fetch as tuples_fetched,
    pg_size_pretty(pg_relation_size(indexrelid)) as index_size
FROM pg_stat_user_indexes
WHERE schemaname = 'public'
AND tablename LIKE 'entity_%'
ORDER BY idx_scan ASC, pg_relation_size(indexrelid) DESC
LIMIT 20;

-- Alert if large index (>1GB) with idx_scan < 1000 (consider dropping)

-- 5. Query Performance (top slow queries)
SELECT 
    query,
    calls,
    ROUND(total_exec_time::numeric / 1000, 2) as total_seconds,
    ROUND(mean_exec_time::numeric, 2) as avg_ms,
    ROUND(stddev_exec_time::numeric, 2) as stddev_ms,
    rows as avg_rows_returned
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat%'
AND query NOT LIKE '%pg_catalog%'
ORDER BY mean_exec_time DESC
LIMIT 20;

-- Alert if avg_ms > 1000 for operational queries

-- 6. Connection Pool Health
SELECT 
    datname,
    usename,
    application_name,
    state,
    COUNT(*) as connection_count,
    MAX(EXTRACT(EPOCH FROM (NOW() - state_change))) as max_idle_seconds
FROM pg_stat_activity
WHERE datname = 'eav_db'
GROUP BY datname, usename, application_name, state
ORDER BY connection_count DESC;

-- Alert if idle connections > 100
-- Alert if active connections > 80% of max_connections

-- 7. Replication Lag Monitoring
SELECT 
    client_addr as replica_address,
    state,
    sync_state,
    EXTRACT(EPOCH FROM (NOW() - backend_start)) as connection_age_seconds,
    pg_wal_lsn_diff(pg_current_wal_lsn(), sent_lsn) / 1024 / 1024 as send_lag_mb,
    pg_wal_lsn_diff(sent_lsn, write_lsn) / 1024 / 1024 as write_lag_mb,
    pg_wal_lsn_diff(write_lsn, flush_lsn) / 1024 / 1024 as flush_lag_mb,
    pg_wal_lsn_diff(flush_lsn, replay_lsn) / 1024 / 1024 as replay_lag_mb,
    EXTRACT(EPOCH FROM (NOW() - backend_start)) as uptime_seconds
FROM pg_stat_replication;

-- Alert if any lag > 100MB or > 5 seconds

-- 8. Heartbeat-based Lag Detection
CREATE OR REPLACE FUNCTION check_replication_lag()
RETURNS TABLE(
    lag_ms INTEGER,
    status TEXT
) AS $$
DECLARE
    primary_ts TIMESTAMP WITH TIME ZONE;
    replica_ts TIMESTAMP WITH TIME ZONE;
    lag INTEGER;
BEGIN
    -- Get latest heartbeat from replica's perspective
    SELECT MAX(timestamp) INTO replica_ts
    FROM replication_heartbeat
    WHERE source = 'primary';
    
    -- Compare to current time
    lag := EXTRACT(EPOCH FROM (NOW() - replica_ts)) * 1000;
    
    IF lag IS NULL THEN
        RETURN QUERY SELECT -1, 'NO_HEARTBEAT'::TEXT;
    ELSIF lag > 5000 THEN
        RETURN QUERY SELECT lag, 'CRITICAL'::TEXT;
    ELSIF lag > 3000 THEN
        RETURN QUERY SELECT lag, 'WARNING'::TEXT;
    ELSE
        RETURN QUERY SELECT lag, 'OK'::TEXT;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Run on replicas
SELECT * FROM check_replication_lag();

-- 9. Hot Attributes Cache Hit Rate
-- (Requires application-level metrics)
-- Monitor in Redis:
-- INFO stats
-- Look for: keyspace_hits, keyspace_misses
-- Target hit rate: > 80%

-- 10. Disk Space Monitoring
SELECT 
    pg_database.datname,
    pg_size_pretty(pg_database_size(pg_database.datname)) as size
FROM pg_database
WHERE datname = 'eav_db';

-- Alert if free space < 15% of total storage

-- 11. VACUUM Progress (for large tables)
SELECT 
    p.pid,
    p.datname,
    p.relid::regclass as table_name,
    p.phase,
    p.heap_blks_total,
    p.heap_blks_scanned,
    p.heap_blks_vacuumed,
    ROUND(100.0 * p.heap_blks_scanned / NULLIF(p.heap_blks_total, 0), 2) as pct_complete
FROM pg_stat_progress_vacuum p;

-- 12. Lock Contention
SELECT 
    locktype,
    relation::regclass,
    mode,
    transactionid,
    pid,
    granted,
    COUNT(*) as lock_count
FROM pg_locks
WHERE NOT granted
GROUP BY locktype, relation, mode, transactionid, pid, granted
ORDER BY lock_count DESC;

-- Alert if ungra 13. Capacity Planning Query
WITH daily_growth AS (
    SELECT 
        DATE_TRUNC('day', ingested_at) as day,
        COUNT(*) as daily_events,
        COUNT(DISTINCT entity_id) as daily_entities,
        COUNT(DISTINCT tenant_id) as active_tenants
    FROM entity_values_ts
    WHERE ingested_at >= NOW() - INTERVAL '30 days'
    GROUP BY DATE_TRUNC('day', ingested_at)
)
SELECT 
    AVG(daily_events) as avg_daily_events,
    MAX(daily_events) as peak_daily_events,
    STDDEV(daily_events) as stddev_daily_events,
    -- Project 90 days forward
    ROUND(AVG(daily_events) * 90) as projected_90d_events,
    pg_size_pretty(
        -- Rough estimate: 200 bytes per event
        ROUND(AVG(daily_events) * 90 * 200)::BIGINT
    ) as projected_90d_storage
FROM daily_growth;

-- 14. Tenant-level Resource Usage
SELECT 
    tenant_id,
    COUNT(*) as total_events,
    COUNT(DISTINCT entity_id) as unique_entities,
    COUNT(DISTINCT attribute_id) as unique_attributes,
    pg_size_pretty(
        SUM(LENGTH(COALESCE(value, '')))::BIGINT
    ) as data_size_estimate,
    MIN(ingested_at) as first_event,
    MAX(ingested_at) as last_event
FROM entity_values_ts
WHERE ingested_at >= NOW() - INTERVAL '7 days'
GROUP BY tenant_id
ORDER BY COUNT(*) DESC
LIMIT 50;

-- Alert if single tenant > 40% of total traffic (hot tenant issue)

-- 15. Automated Health Check Function
CREATE OR REPLACE FUNCTION health_check()
RETURNS JSON AS $$
DECLARE
    result JSON;
BEGIN
    SELECT json_build_object(
        'timestamp', NOW(),
        'database_size_mb', pg_database_size(current_database()) / 1024 / 1024,
        'active_connections', (
            SELECT COUNT(*) FROM pg_stat_activity 
            WHERE state = 'active' AND datname = current_database()
        ),
        'staging_rows', (SELECT COUNT(*) FROM entity_values_ingest),
        'recent_throughput_per_sec', (
            SELECT COUNT(*) / 60 
            FROM entity_values_ts 
            WHERE ingested_at >= NOW() - INTERVAL '1 minute'
        ),
        'replica_lag_ms', (
            SELECT COALESCE(
                EXTRACT(EPOCH FROM (NOW() - MAX(timestamp))) * 1000,
                -1
            )
            FROM replication_heartbeat WHERE source = 'primary'
        ),
        'longest_transaction_seconds', (
            SELECT COALESCE(
                MAX(EXTRACT(EPOCH FROM (NOW() - xact_start))),
                0
            )
            FROM pg_stat_activity 
            WHERE state = 'active' AND xact_start IS NOT NULL
        )
    ) INTO result;
    
    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- Run health check
SELECT health_check();

-- Expected output:
-- {
--   "timestamp": "2025-10-16 14:00:00",
--   "database_size_mb": 125000,
--   "active_connections": 45,
--   "staging_rows": 50000,
--   "recent_throughput_per_sec": 8500,
--   "replica_lag_ms": 250,
--   "longest_transaction_seconds": 1.5
-- }