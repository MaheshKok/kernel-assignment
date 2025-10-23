# AtlasCo Database Design - Complete Deep Dive

## Executive Summary

Your database architecture uses a sophisticated hybrid approach:
- **8 tables** (7 regular + 1 materialized view)
- **3 partitioning strategies** (RANGE by time, RANGE by ID, HASH)
- **4 index types** (B-tree, BRIN, GIN, Partial)
- **3 replication flows** (Physical, Logical CDC, Redis)
- **Redis caching layer** (hot attributes, metadata, aggregations)

Let me explain **every single table** in detail, plus exactly where replication, partitioning, indexing, sharding, and Redis fit.

---

## Table-by-Table Complete Analysis

### Table 1: `tenants` (10K rows, <1MB)

**Purpose:** Multi-tenancy root - every query filters by tenant_id

**Schema:**
```sql
CREATE TABLE tenants(
    tenant_id bigint PRIMARY KEY,
    tenant_name varchar(255) NOT NULL,
    created_at timestamptz DEFAULT CURRENT_TIMESTAMP,
    is_active boolean DEFAULT TRUE
);
```

**WHERE IT LIVES:**
- **Partitioning:** ❌ None (too small)
- **Indexing:** ✅ B-tree on PRIMARY KEY
- **Replication:** ✅ Physical (to replicas), ❌ Not in Redis (too small)
- **Sharding:** ❌ Never shard (shared lookup table)

**Why no partitioning?** 10K rows × 100 bytes = 1MB → fits in memory

---

### Table 2: `attributes` (10K rows, ~5MB)

**Purpose:** EAV attribute metadata - defines what each attribute_id means

**Schema:**
```sql
CREATE TABLE attributes (
    attribute_id bigint PRIMARY KEY,
    attribute_name varchar(255) NOT NULL,
    data_type varchar(50) CHECK (data_type IN (...)),
    is_indexed boolean DEFAULT FALSE,
    is_hot boolean DEFAULT FALSE,  -- ⭐ CONTROLS JSONB PROJECTION
    validation_regex text,
    created_at timestamptz,
    updated_at timestamptz
);
```

**WHERE IT LIVES:**
- **Partitioning:** ❌ None (small metadata table)
- **Indexing:** 
  - ✅ B-tree on PRIMARY KEY (attribute_id)
  - ✅ B-tree on attribute_name (for "temperature" → 77 lookups)
  - ✅ Partial index on is_hot = TRUE
- **Replication:** ✅ Physical (to replicas) + ✅ Redis (entire table cached)
- **Sharding:** ❌ Never shard (global lookup)

**THE CRITICAL FIELD: `is_hot`**

This boolean determines the entire read path:

```sql
-- Hot attribute (is_hot = true)
attribute_name = 'status', 'priority', 'region'
    │
    ├─> Write: Goes to BOTH entity_values_ts AND entity_jsonb
    ├─> Read:  Served from entity_jsonb (15-30ms via GIN index)
    └─> Cache: Redis caches the JSONB row

-- Cold attribute (is_hot = false)  
attribute_name = 'temperature', 'firmware_version'
    │
    ├─> Write: Only goes to entity_values_ts
    ├─> Read:  Served from entity_values_ts (100-500ms via BRIN)
    └─> Cache: Not cached (too much data)
```

**Redis Caching:**
```python
# Cache entire attributes table on startup
redis.hset("attribute:name_to_id", "temperature", "77")
redis.hset("attribute:name_to_id", "status", "1")
redis.expire("attribute:name_to_id", 3600)  # 1 hour TTL
```

---

### Table 3: `entities` (200M rows, ~20GB)

**Purpose:** Base entity registry - represents physical devices/assets

**Schema:**
```sql
CREATE TABLE entities(
    entity_id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    entity_type varchar(100) NOT NULL,
    created_at timestamptz DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamptz DEFAULT CURRENT_TIMESTAMP,
    is_deleted boolean DEFAULT FALSE,
    version integer DEFAULT 1,
    PRIMARY KEY (entity_id, tenant_id)
)
PARTITION BY RANGE (entity_id);  -- ⭐ PARTITIONED
```

**WHERE IT LIVES:**

#### Partitioning: ✅ RANGE by entity_id
```sql
-- 200 partitions, 1M entities each
CREATE TABLE entities_p0 PARTITION OF entities
FOR VALUES FROM (0) TO (1000000);

CREATE TABLE entities_p1 PARTITION OF entities
FOR VALUES FROM (1000000) TO (2000000);

-- ... up to entities_p199
```

**Why entity_id instead of tenant_id?**
- Sequential writes (new entities get sequential IDs)
- Global ordering (entity 1, 2, 3...)
- Efficient batch exports

**Partition Pruning:**
```sql
-- GOOD: Includes entity_id
SELECT * FROM entities WHERE entity_id = 5500000;
-- Scans: 1 partition (entities_p5)
-- Speed: 0.05ms

-- BAD: Only tenant_id
SELECT * FROM entities WHERE tenant_id = 123;
-- Scans: ALL 200 partitions!
-- Speed: 500ms
```

#### Indexing:
```sql
-- Primary Key (B-tree per partition)
PRIMARY KEY (entity_id, tenant_id)

-- Secondary indexes
CREATE INDEX idx_entities_tenant ON entities(tenant_id, entity_id);
CREATE INDEX idx_entities_type ON entities(entity_type, tenant_id);
CREATE INDEX idx_entities_updated ON entities(updated_at) 
WHERE is_deleted = FALSE;  -- ⭐ PARTIAL INDEX
```

#### Replication:
- ✅ Physical (to 3 read replicas, 1-3s lag)
- ✅ Logical CDC (to Redshift, 5min lag)
- ⚠️ Redis (selective - hot entities only, NOT entire table)

**Redis Strategy:**
```python
# Don't cache entire table (20GB is too large)
# Only cache hot entities
redis.setex(
    f"entity:{tenant_id}:{entity_id}",
    3600,  # 1 hour
    json.dumps(entity_data)
)
```

#### Sharding: ❌ Not yet (sufficient for 200M entities)
**Future:** When >1B entities → Citus with tenant_id distribution key

---

### Table 4: `entity_values_ts` (25.9B rows/month, ~780GB/month)

**Purpose:** Time-series EAV - THE HEART OF THE SYSTEM

**Schema:**
```sql
CREATE TABLE entity_values_ts(
    entity_id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    attribute_id bigint NOT NULL,
    value text,              -- Generic string
    value_int bigint,        -- Typed: integers
    value_decimal DECIMAL(20,5),  -- Typed: decimals
    value_bool boolean,      -- Typed: booleans
    value_date date,         -- Typed: dates
    value_timestamp timestamptz,  -- Typed: timestamps
    ingested_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_at timestamptz DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, entity_id, attribute_id, ingested_at)
)
PARTITION BY RANGE (ingested_at);  -- ⭐ TIME PARTITIONING
```

**WHY MULTIPLE VALUE COLUMNS?**
```sql
-- BAD: Everything as text
value text  -- "75.5", "true", "2025-01-01"
WHERE value::decimal > 100  -- ❌ Slow conversion

-- GOOD: Typed columns
value_decimal DECIMAL(20,5)  -- 75.50000
WHERE value_decimal > 100  -- ✅ Fast numeric comparison
```

**WHERE IT LIVES:**

#### Partitioning: ✅ RANGE by ingested_at (monthly)
```sql
-- Current month
CREATE TABLE entity_values_2025_10 PARTITION OF entity_values_ts
FOR VALUES FROM ('2025-10-01') TO ('2025-11-01');

-- Next month (pre-created)
CREATE TABLE entity_values_2025_11 PARTITION OF entity_values_ts
FOR VALUES FROM ('2025-11-01') TO ('2025-12-01');

-- Automated with pg_partman
SELECT partman.create_parent(
    'public.entity_values_ts',
    'ingested_at',
    'native',
    'monthly',
    p_premake := 2
);
```

**Size Calculation:**
```
10K writes/sec × 86400 sec/day × 30 days = 25.9 billion rows/month
25.9B rows × 150 bytes/row = 3.9 TB/month (raw)
With compression (80%): ~780 GB/month
```

**Partition Pruning:**
```sql
-- EXCELLENT: Time filter (partition pruning works)
WHERE ingested_at >= '2025-10-20' AND ingested_at < '2025-10-25'
-- Scans: 1 partition (entity_values_2025_10)

-- TERRIBLE: No time filter
WHERE tenant_id = 123 AND attribute_id = 77
-- Scans: ALL partitions (TBs of data!)
-- FIX: ALWAYS include time filter!
```

#### Indexing:

**Index 1: BRIN (Block Range Index)**
```sql
CREATE INDEX idx_entity_values_ts_brin 
ON entity_values_ts USING BRIN(ingested_at);
```

**What is BRIN?**
- Stores min/max per block range (128 pages = 1MB)
- 1/1000th the size of B-tree!
- Perfect for time-series (naturally ordered data)

```
Block 1: [2025-10-01 00:00, 2025-10-01 01:23]
Block 2: [2025-10-01 01:24, 2025-10-01 02:45]
Block 3: [2025-10-01 02:46, 2025-10-01 04:10]

Query: WHERE ingested_at >= '2025-10-01 02:00'
BRIN: Skip Block 1, scan Block 2 & 3 only
```

**Comparison:**
```
200M rows in partition

B-tree index: ~8 GB (40 bytes/row)
BRIN index:   ~8 MB (1000x smaller!)
```

**Index 2: Composite B-tree**
```sql
CREATE INDEX idx_entity_values_ts_attr_time 
ON entity_values_ts(tenant_id, attribute_id, ingested_at);
```

**Use case:**
```sql
-- Get latest temperature for device
SELECT value_decimal, ingested_at
FROM entity_values_ts
WHERE tenant_id = 456
  AND attribute_id = 77  -- temperature
  AND ingested_at >= NOW() - INTERVAL '7 days'
ORDER BY ingested_at DESC
LIMIT 1;

-- Uses: idx_entity_values_ts_attr_time
-- Speed: 0.1ms (index-only scan)
```

#### Replication:
- ✅ Physical (to 3 replicas, 1-3s lag)
- ✅ Logical CDC (Debezium → Kafka → Redshift, 5min lag)
- ❌ Redis (too large - 780GB/month growth!)

#### Sharding: ❌ Not yet
**Future:** Citus with hash(tenant_id) when >1B entities

#### Row-Level Security (RLS):
```sql
ALTER TABLE entity_values_ts ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON entity_values_ts
    FOR ALL TO PUBLIC
    USING (tenant_id = current_setting('app.current_tenant_id')::bigint);
```

**How it works:**
```sql
-- App sets tenant context
SET LOCAL app.current_tenant_id = 123;

-- Query automatically filtered
SELECT * FROM entity_values_ts WHERE attribute_id = 77;

-- PostgreSQL rewrites to:
SELECT * FROM entity_values_ts 
WHERE attribute_id = 77 AND tenant_id = 123;  -- ✅ RLS adds this
```

---

### Table 5: `entity_values_ingest` (0-1M rows, 0-150MB)

**Purpose:** UNLOGGED staging table for 10K writes/sec throughput

**Schema:**
```sql
CREATE UNLOGGED TABLE entity_values_ingest(
    entity_id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    attribute_id bigint NOT NULL,
    value text,
    value_int bigint,
    value_decimal DECIMAL(20, 5),
    value_bool boolean,
    value_date date,
    value_timestamp timestamptz,
    ingested_at timestamptz DEFAULT CURRENT_TIMESTAMP
);
```

**WHAT IS UNLOGGED?**

```
Normal table:
┌────────┐ → ┌─────┐ → ┌──────────┐
│ INSERT │   │ WAL │   │ Data     │
└────────┘   └─────┘   └──────────┘
             (5ms fsync overhead)

UNLOGGED table:
┌────────┐ → ┌──────────┐
│ INSERT │   │ Data     │
└────────┘   └──────────┘
(0.5ms - 10x faster!)

Trade-off:
✅ 10x faster writes
❌ Crash = data loss (table truncated)
✅ Mitigation: Kafka/SQS can replay
```

**WHERE IT LIVES:**
- **Partitioning:** ❌ None (temporary staging)
- **Indexing:** ❌ None (no indexes for max speed)
- **Replication:** ❌ None (not replicated)
- **Sharding:** ❌ N/A

**Write Flow:**
```
Telemetry Event
    │
    ├─> COPY to entity_values_ingest (UNLOGGED) ← 0.5ms
    │
    ├─> stage_flush() every 100ms
    │       │
    │       ├─> Batch INSERT to entity_values_ts ← 50ms
    │       ├─> DELETE from staging
    │       └─> upsert_hot_attrs() if hot
    │
    └─> ACK to app

Loss window: <1 minute
```

**Batch Flush Function:**
```sql
CREATE FUNCTION stage_flush(p_limit int DEFAULT 50000)
    RETURNS int
    SECURITY DEFINER  -- Bypasses RLS
    SET search_path = public
AS $$
BEGIN
    SET LOCAL synchronous_commit = OFF;  -- ⭐ Async WAL
    
    INSERT INTO entity_values_ts(...)
    SELECT ... FROM entity_values_ingest
    ORDER BY ingested_at
    LIMIT p_limit;
    
    DELETE FROM entity_values_ingest ...;
    
    RETURN row_count;
END;
$$;
```

**Monitoring:**
```sql
-- Alert if backlog > 1M rows
SELECT COUNT(*) FROM entity_values_ingest;

-- Alert if oldest event > 60 seconds
SELECT EXTRACT(EPOCH FROM (NOW() - MIN(ingested_at)))
FROM entity_values_ingest;
```

---

### Table 6: `entity_jsonb` (200M rows, ~200GB)

**Purpose:** Hot attributes JSONB projection - sub-50ms queries

**Schema:**
```sql
CREATE TABLE entity_jsonb(
    entity_id bigint NOT NULL,
    tenant_id bigint NOT NULL,
    hot_attrs jsonb NOT NULL DEFAULT '{}',
    cold_attrs jsonb DEFAULT '{}',
    updated_at timestamptz DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (entity_id, tenant_id)
)
PARTITION BY HASH (entity_id);  -- ⭐ HASH PARTITIONING
```

**JSONB Example:**
```json
{
  "status": "online",
  "environment": "production",
  "priority": 8,
  "region": "us-west-2",
  "last_seen": "2025-10-23T14:30:00Z",
  "alert_count": 3,
  "tags": ["critical", "database", "primary"]
}
```

**WHY JSONB?**
- Dynamic schema (hot attributes change over time)
- GIN indexing (fast `@>` containment queries)
- Atomic updates (JSON merge `||` operator)
- No ALTER TABLE needed

**WHERE IT LIVES:**

#### Partitioning: ✅ HASH by entity_id (100 partitions)
```sql
CREATE TABLE entity_jsonb_p0 PARTITION OF entity_jsonb
FOR VALUES WITH (MODULUS 100, REMAINDER 0);

-- ... up to p99
CREATE TABLE entity_jsonb_p99 PARTITION OF entity_jsonb
FOR VALUES WITH (MODULUS 100, REMAINDER 99);
```

**How HASH works:**
```python
partition_number = hash(entity_id) % 100

# entity_id = 123456 → partition 42
```

**Distribution:**
```
200M entities ÷ 100 partitions = 2M per partition
2M rows × 1 KB/row = 2 GB per partition
Total: 200 GB
```

**Query Patterns:**
```sql
-- BEST: Single entity (1 partition)
SELECT hot_attrs FROM entity_jsonb
WHERE entity_id = 123456 AND tenant_id = 789;
-- Scans: 1 partition (entity_jsonb_p42)
-- Speed: 1-5ms

-- SLOW: Tenant only (all partitions)
SELECT entity_id FROM entity_jsonb
WHERE tenant_id = 789;
-- Scans: 100 partitions!
-- Speed: 500ms - 2s

-- MEDIUM: JSONB filter (GIN helps)
SELECT entity_id FROM entity_jsonb
WHERE tenant_id = 789
  AND hot_attrs @> '{"environment": "production"}'::jsonb;
-- Scans: 100 partitions (parallel)
-- Uses: GIN index
-- Speed: 100-500ms
```

#### Indexing:

**Index 1: Primary Key (B-tree per partition)**
```sql
PRIMARY KEY (entity_id, tenant_id)
-- Creates: entity_jsonb_p0_pkey, ..., entity_jsonb_p99_pkey
```

**Index 2: GIN on JSONB**
```sql
CREATE INDEX idx_entity_jsonb_hot_attrs 
ON entity_jsonb USING GIN(hot_attrs);
```

**What is GIN (Generalized Inverted Index)?**
```
JSONB: {"status": "online", "priority": 8}

GIN entries:
"status" → "online" → [entity_1, entity_2, ...]
"priority" → 8 → [entity_3, entity_4, ...]

Query: WHERE hot_attrs @> '{"status": "online"}'
GIN: Lookup "status" → "online" → return [entity_1, entity_2]
```

**Supported operators:**
```sql
-- Containment (@>)
WHERE hot_attrs @> '{"status": "online"}'  -- ✅ Uses GIN

-- Key exists (?)
WHERE hot_attrs ? 'priority'  -- ✅ Uses GIN

-- Any of (|)
WHERE hot_attrs ?| array['status', 'priority']  -- ✅ Uses GIN

-- All of (&)
WHERE hot_attrs ?& array['status', 'priority']  -- ✅ Uses GIN

-- Extract (->>, not GIN-optimized)
WHERE (hot_attrs->>'priority')::int > 7  -- ❌ Full scan
```

**Index 3: Tenant lookup**
```sql
CREATE INDEX idx_entity_jsonb_tenant ON entity_jsonb(tenant_id);
-- For tenant-scoped queries (but still scans all partitions)
```

#### Replication:
- ✅ Physical (to 3 replicas, 1-3s lag)
- ✅ Logical CDC (to Redshift, 5min lag)
- ✅ Redis (hot entities cached)

**Upsert Function:**
```sql
CREATE FUNCTION upsert_hot_attrs(
    p_tenant_id bigint,
    p_entity_id bigint,
    p_delta jsonb
) RETURNS VOID
SECURITY DEFINER
AS $$
BEGIN
    INSERT INTO entity_jsonb(entity_id, tenant_id, hot_attrs)
        VALUES(p_entity_id, p_tenant_id, p_delta)
    ON CONFLICT(entity_id, tenant_id) DO UPDATE SET
        hot_attrs = entity_jsonb.hot_attrs || EXCLUDED.hot_attrs,  -- ⭐ JSON merge
        updated_at = CURRENT_TIMESTAMP;
END;
$$;
```

**JSON Merge (`||`):**
```sql
-- Existing
hot_attrs = '{"status": "online", "priority": 5}'

-- Delta
p_delta = '{"priority": 8, "alert_count": 3}'

-- Result
hot_attrs = '{"status": "online", "priority": 8, "alert_count": 3}'
```

#### Sharding: ❌ Not yet

---

### Table 7: `replication_heartbeat` (~17K rows/day, <10MB)

**Purpose:** Measure replication lag (heartbeat method)

**Schema:**
```sql
CREATE TABLE replication_heartbeat(
    id serial PRIMARY KEY,
    timestamp timestamptz DEFAULT CURRENT_TIMESTAMP,
    source varchar(50) NOT NULL
);
```

**HOW IT WORKS:**

**On Primary (every 5 seconds):**
```sql
INSERT INTO replication_heartbeat (source) VALUES ('primary');
```

**On Replica (measure lag):**
```sql
SELECT 
    EXTRACT(EPOCH FROM (NOW() - MAX(timestamp))) AS lag_seconds
FROM replication_heartbeat
WHERE source = 'primary';
-- Returns: 2.3 (seconds)
```

**WHY BETTER than pg_stat_replication?**
- End-to-end lag (what users actually see)
- Works across PostgreSQL versions
- Application-level visibility

**WHERE IT LIVES:**
- **Partitioning:** ❌ None
- **Indexing:** ✅ PRIMARY KEY only
- **Replication:** ✅ Physical (that's the point!)
- **Redis:** ❌ No

**Retention:**
```sql
-- Keep last 24 hours only
DELETE FROM replication_heartbeat
WHERE timestamp < NOW() - INTERVAL '24 hours';
```

---

### Table 8: `mv_entity_attribute_stats` (Materialized View)

**Purpose:** Pre-aggregated attribute usage statistics

**Definition:**
```sql
CREATE MATERIALIZED VIEW mv_entity_attribute_stats AS
SELECT
    ev.tenant_id,
    ev.attribute_id,
    a.attribute_name,
    COUNT(DISTINCT ev.entity_id) AS distinct_entities,
    COUNT(*) AS total_values,
    MIN(ev.ingested_at) AS oldest,
    MAX(ev.ingested_at) AS newest
FROM entity_values_ts ev
JOIN attributes a ON ev.attribute_id = a.attribute_id
GROUP BY ev.tenant_id, ev.attribute_id, a.attribute_name;

CREATE INDEX idx_mv_stats_tenant ON mv_entity_attribute_stats(tenant_id);
```

**REFRESH STRATEGY:**
```sql
-- Manual
REFRESH MATERIALIZED VIEW mv_entity_attribute_stats;

-- Automated (pg_cron, every hour)
SELECT cron.schedule(
    'refresh-mv-stats',
    '0 * * * *',
    'REFRESH MATERIALIZED VIEW CONCURRENTLY mv_entity_attribute_stats'
);
```

**WHY CONCURRENTLY?**
```
REFRESH: Locks view (blocks reads)
REFRESH CONCURRENTLY: No locks (requires unique index)
```

**Use Case:**
```sql
-- Which attributes are most popular?
SELECT attribute_name, total_values
FROM mv_entity_attribute_stats
WHERE tenant_id = 123
ORDER BY total_values DESC
LIMIT 10;

-- Speed: <10ms (reading materialized view)
-- vs. 30-60s (scanning entity_values_ts)
```

**WHERE IT LIVES:**
- **Partitioning:** ❌ No (materialized view)
- **Indexing:** ✅ B-tree on tenant_id
- **Replication:** ✅ Physical
- **Redis:** ❌ No

---

## Replication Strategy

### 1. Physical Replication (PostgreSQL → Replicas)

```
┌──────────────┐
│   PRIMARY    │
│  (Writer)    │
└──────┬───────┘
       │ WAL Stream
       ├─────────┬─────────┬─────────┐
       ▼         ▼         ▼         ▼
   ┌────────┐┌────────┐┌────────┐┌────────┐
   │Replica ││Replica ││Replica ││Standby │
   │   1    ││   2    ││   3    ││(Multi  │
   │(AZ-a)  ││(AZ-b)  ││(AZ-c)  ││-AZ)    │
   └────────┘└────────┘└────────┘└────────┘
   Read       Read      Read      Failover
```

**Configuration:**
```sql
-- Primary
ALTER SYSTEM SET wal_level = 'replica';
ALTER SYSTEM SET max_wal_senders = 10;
ALTER SYSTEM SET max_replication_slots = 10;

-- Replica
primary_conninfo = 'host=primary.rds.amazonaws.com ...'
primary_slot_name = 'replica_1_slot'
hot_standby = on
```

**Lag Monitoring:**
```sql
-- On primary
SELECT client_addr, replay_lag FROM pg_stat_replication;

-- On replica (using heartbeat)
SELECT EXTRACT(EPOCH FROM (NOW() - MAX(timestamp))) AS lag_seconds
FROM replication_heartbeat WHERE source = 'primary';
```

**Lag Budgets:**
```
STRONG (primary):    0ms
EVENTUAL (replica): <3s (circuit break at 5s)
ANALYTICS:          <5min
```

### 2. Logical Replication (PostgreSQL → Redshift via CDC)

```
PostgreSQL
    │ WAL → wal2json
    ▼
Debezium
    │ Change events
    ▼
Kafka (MSK)
    │ 3 brokers, 3 AZs
    ▼
Flink (KDA)
    │ Enrich, dedupe, batch (30s)
    ▼
Redshift
```

**PostgreSQL Setup:**
```sql
ALTER SYSTEM SET wal_level = 'logical';

CREATE PUBLICATION eav_cdc FOR TABLE
    entities,
    entity_values_ts,
    entity_jsonb,
    attributes;

SELECT pg_create_logical_replication_slot('debezium_slot', 'wal2json');
```

**Debezium Config:**
```json
{
  "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
  "slot.name": "debezium_slot",
  "publication.name": "eav_cdc",
  "heartbeat.interval.ms": "10000",
  "snapshot.mode": "initial"
}
```

### 3. Redis Replication

```
┌────────────────┐
│ Redis Primary  │
│  (us-east-1a)  │
└────────┬───────┘
         │ Async replication
         ├────────┬────────┐
         ▼        ▼        │
    ┌────────┐┌────────┐  │
    │Replica ││Replica │  │
    │   1    ││   2    │  │
    │(AZ-b)  ││(AZ-c)  │  │
    └────────┘└────────┘  │
                          │
                          ▼
                    Auto-failover
```

**Configuration:**
```properties
# Primary
bind 0.0.0.0
protected-mode yes

# Replica
replicaof primary-redis-host 6379
replica-read-only yes
```

---

## Redis Cache Layer - Complete Strategy

### WHERE REDIS SITS:
```
Application
    │
    ├─> Redis (Layer 0: 5-30ms)
    │       │ Cache HIT → Return
    │       │ Cache MISS ↓
    │
    └─> PostgreSQL (Layer 1: 15-100ms)
            └─> Populate Redis
```

### WHAT GETS CACHED:

```
┌─────────────────────────────┬─────┬────────┬──────────┐
│ Data                        │Cache│  TTL   │ Why?     │
├─────────────────────────────┼─────┼────────┼──────────┤
│ Hot entity attributes       │ ✅  │ 300s   │ Dashboard│
│ (entity_jsonb rows)         │     │ (5min) │ queries  │
├─────────────────────────────┼─────┼────────┼──────────┤
│ Attribute metadata          │ ✅  │ 3600s  │ Frequent │
│ (attributes table)          │     │ (1hr)  │ lookups  │
├─────────────────────────────┼─────┼────────┼──────────┤
│ Entity lists by tenant      │ ✅  │ 60s    │ Listings │
├─────────────────────────────┼─────┼────────┼──────────┤
│ Aggregations (pre-computed) │ ✅  │ 60s    │ Expensive│
├─────────────────────────────┼─────┼────────┼──────────┤
│ Time-series data            │ ❌  │ N/A    │ Too large│
│ (entity_values_ts)          │     │        │          │
└─────────────────────────────┴─────┴────────┴──────────┘
```

### CACHE KEY PATTERNS:

**Pattern 1: Hot Entity**
```python
key = f"entity:{tenant_id}:{entity_id}"
value = {"status": "online", "priority": 8, ...}
redis.setex(key, 300, json.dumps(value))
```

**Pattern 2: Attribute Lookup (Hash)**
```python
redis.hset("attribute:name_to_id", "temperature", "77")
redis.expire("attribute:name_to_id", 3600)
```

**Pattern 3: Entity Lists (Set)**
```python
key = f"entity:list:{tenant_id}:{entity_type}"
redis.sadd(key, "123456", "123457", "123458")
redis.expire(key, 60)
```

**Pattern 4: Aggregations**
```python
key = f"agg:alert_count:{tenant_id}:last_hour"
redis.setex(key, 60, json.dumps({"count": 42}))
```

### CACHE INVALIDATION:

**On Write:**
```python
def write_hot_attribute(tenant_id, entity_id, attribute_id, value):
    # Write to PostgreSQL
    pg.execute("SELECT upsert_hot_attrs(%s, %s, %s)", ...)
    
    # Invalidate Redis
    redis.delete(f"entity:{tenant_id}:{entity_id}")
```

### REDIS CONFIGURATION:

```properties
maxmemory 16gb
maxmemory-policy allkeys-lru  # Least Recently Used
save ""  # No persistence (cache can be rebuilt)
appendonly no
```

**Why no persistence?**
- Cache data is in PostgreSQL (source of truth)
- No persistence = faster writes
- Crash = cache miss → rebuild from DB

### MONITORING:

```python
def get_cache_stats():
    info = redis.info('stats')
    hits = info['keyspace_hits']
    misses = info['keyspace_misses']
    hit_rate = hits / (hits + misses)
    return hit_rate  # Target: >90%
```

---

## Summary Table: Where Everything Lives

```
┌────────────────────┬──────────────────────────────────────────────────┐
│ Technique          │ Implementation                                   │
├────────────────────┼──────────────────────────────────────────────────┤
│ REPLICATION        │                                                  │
│  - Physical        │ PostgreSQL Primary → 3 Replicas (WAL, 1-3s lag) │
│  - Logical (CDC)   │ PostgreSQL → Debezium → Kafka → Redshift (5min) │
│  - Redis           │ Primary → 2 Replicas (async, auto-failover)     │
├────────────────────┼──────────────────────────────────────────────────┤
│ PARTITIONING       │                                                  │
│  - RANGE (time)    │ entity_values_ts (by ingested_at, monthly)      │
│  - RANGE (ID)      │ entities (by entity_id, 1M per partition)       │
│  - HASH            │ entity_jsonb (by entity_id, 100 partitions)     │
├────────────────────┼──────────────────────────────────────────────────┤
│ INDEXING           │                                                  │
│  - BRIN            │ entity_values_ts (ingested_at) - 1/1000 B-tree  │
│  - GIN             │ entity_jsonb (hot_attrs) - JSONB queries        │
│  - B-tree          │ All PKs, tenant_id, attribute lookups           │
│  - Partial         │ entities (is_deleted = FALSE)                   │
├────────────────────┼──────────────────────────────────────────────────┤
│ SHARDING           │                                                  │
│  - Current         │ ❌ None (200M entities fit in single cluster)   │
│  - Future (>1B)    │ Citus: hash(tenant_id) distribution             │
├────────────────────┼──────────────────────────────────────────────────┤
│ CACHING (Redis)    │                                                  │
│  - Hot attributes  │ entity_jsonb rows (5min TTL)                    │
│  - Metadata        │ attributes table (1hr TTL)                      │
│  - Lists           │ Entity IDs by tenant (1min TTL)                 │
│  - Aggregations    │ Pre-computed metrics (1min TTL)                 │
└────────────────────┴──────────────────────────────────────────────────┘
```

This completes the comprehensive database design deep dive!
