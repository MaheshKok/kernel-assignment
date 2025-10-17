# Part B: Read Freshness & Replication Architecture

## Overview
This document details the complete replication flow from OLTP (PostgreSQL) to OLAP (Redshift), freshness guarantees, lag detection mechanisms, and how the application surfaces data consistency to users.

---

## 1. Replication Flow & Architecture

### High-Level Data Flow
```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         WRITE PATH (10K ops/sec)                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     ▼
        ┌────────────────────────────────────────────────────┐
        │           Application Layer (ECS/EKS)              │
        │  - Connection pooling (PgBouncer internal)         │
        │  - Write batching & retry logic                    │
        │  - Hot attribute caching (Redis write-through)     │
        └──────────────────┬─────────────────────────────────┘
                           │
                           ▼
        ┌─────────────────────────────────────────────────────┐
        │         RDS Proxy (Connection Multiplexing)         │
        │  - 20K max connections → 200 DB connections         │
        │  - Pinning for transactions                         │
        │  - Failover handling (30-60s)                       │
        └──────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                      OLTP LAYER (PostgreSQL RDS)                             │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                               │
│  ┌────────────────────────────────────────────────────────────────┐          │
│  │                    PRIMARY (Writer)                             │          │
│  │  - db.r6g.4xlarge (128GB RAM, 8K IOPS provisioned)             │          │
│  │  - Multi-AZ deployment (sync standby in AZ-B)                  │          │
│  │  - WAL archiving to S3 (5-min PITR)                            │          │
│  │                                                                 │          │
│  │  Tables:                                                        │          │
│  │  • entities (base records)                                     │          │
│  │  • entity_values_ts (time-series, partitioned by month)        │          │
│  │  • entity_jsonb (hot projection, ~10-20 attributes/entity)     │          │
│  │  • entity_values_ingest (UNLOGGED staging buffer)              │          │
│  │  • _heartbeat (lag detection table)                            │          │
│  └────────┬───────────────────────────────┬──────────────────────┘          │
│           │                               │                                  │
│           │ Streaming Replication         │ Logical Decoding (WAL)          │
│           │ (Physical, <50ms lag)         │ (via wal2json plugin)           │
│           ▼                               ▼                                  │
│  ┌─────────────────────┐       ┌───────────────────────────┐               │
│  │  Read Replica #1    │       │  Logical Replication      │               │
│  │  (Near-RT queries)  │       │  Slot: debezium_slot      │               │
│  │  - Lag target: <3s  │       │  - Plugin: wal2json       │               │
│  │  - Max lag alarm:   │       │  - Retained WAL: 10GB     │               │
│  │    5s → route to    │       │  - Heartbeat: 10s         │               │
│  │    primary          │       │  - Publication: eav_cdc   │               │
│  └─────────────────────┘       └───────────┬───────────────┘               │
│                                             │                                │
│                                             │ Debezium Connector             │
│                                             │ (Kafka Connect)                │
│                                            │                                │
└────────────────────────────────────────────┼────────────────────────────────┘
                                             │
                                             │ CDC Stream (Postgres → Kafka)
                                             ▼
        ┌─────────────────────────────────────────────────────┐
        │              MSK (Managed Kafka)                    │
        │  - 3 brokers across 3 AZs                           │
        │  - Topics:                                          │
        │    • postgres.eav.entities (retention: 7d)          │
        │    • postgres.eav.entity_values_ts (retention: 7d)  │
        │    • postgres.eav.entity_jsonb (retention: 3d)      │
        │  - Compression: snappy                              │
        │  - Replication factor: 3                            │
        └──────────────────┬──────────────────────────────────┘
                           │
                           │ Consumer Groups:
                           │  1. Redshift loader (batch 10K msgs)
                           │  2. Search indexer (Elasticsearch)
                           │  3. Analytics pre-aggregator
                           ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                    STREAM PROCESSING LAYER                                    │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                               │
│  ┌─────────────────────────────────────────────────────────────────┐         │
│  │              Flink/Kinesis Data Analytics                        │         │
│  │  - Micro-batching (30s windows)                                  │         │
│  │  - Deduplication (by entity_id + version)                        │         │
│  │  - Schema evolution handling                                     │         │
│  │  - Enrichment (join with dimension tables)                       │         │
│  │  - Output: Parquet files → S3 staging                            │         │
│  └──────────────────────────┬───────────────────────────────────────┘         │
│                             │                                                 │
└─────────────────────────────┼─────────────────────────────────────────────────┘
                              │
                              ▼
        ┌─────────────────────────────────────────────────────┐
        │               S3 Staging Area                       │
        │  - Path: s3://eav-olap/staging/YYYY/MM/DD/HH/       │
        │  - Format: Parquet (Snappy compression)             │
        │  - Lifecycle: Delete after 7 days                   │
        │  - Events: Trigger Redshift COPY on new file        │
        └──────────────────┬──────────────────────────────────┘
                           │
                           │ COPY command (batched, every 5 min)
                           ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                        OLAP LAYER (Redshift)                                 │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                               │
│  ┌─────────────────────────────────────────────────────────────────┐         │
│  │                  Redshift Cluster                                │         │
│  │  - Node type: ra3.4xlarge (12 vCPU, 96GB RAM)                   │         │
│  │  - Nodes: 4 (total 48 vCPU, 384GB RAM)                          │         │
│  │  - Storage: Managed S3 (auto-scaling)                            │         │
│  │  - Concurrency scaling: Enabled (up to 10 clusters)              │         │
│  │                                                                  │         │
│  │  Tables (star schema denormalization):                           │         │
│  │  • fact_entity_values (dist key: entity_id, sort: timestamp)    │         │
│  │  • dim_entities (dist: ALL)                                      │         │
│  │  • dim_attributes (dist: ALL)                                    │         │
│  │  • agg_daily_metrics (pre-aggregated, sort: date)               │         │
│  │                                                                  │         │
│  │  Freshness guarantees:                                           │         │
│  │  - Target lag: 5 minutes                                         │         │
│  │  - Max acceptable lag: 15 minutes                                │         │
│  │  - SLA: 99.5% of queries see data < 5 min old                   │         │
│  └─────────────────────────────────────────────────────────────────┘         │
│                                                                               │
└───────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     ▼
        ┌─────────────────────────────────────────────────────┐
        │          Analytics/BI Tools                         │
        │  - Tableau, Looker, custom dashboards               │
        │  - Freshness indicator: "Data as of 17:42 UTC"      │
        │  - Lag warning: "Analytics delayed by 8 minutes"    │
        └─────────────────────────────────────────────────────┘


┌──────────────────────────────────────────────────────────────────────────────┐
│                      CACHING LAYER (Low-Latency Reads)                       │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                               │
│  ┌─────────────────────────────────────────────────────────────────┐         │
│  │              ElastiCache Redis (Cluster Mode)                    │         │
│  │  - Node type: cache.r6g.xlarge (26GB RAM)                        │         │
│  │  - Shards: 3 (with replica for HA)                               │         │
│  │  - Total capacity: 78GB usable                                   │         │
│  │                                                                  │         │
│  │  Cache strategy:                                                 │         │
│  │  • Write-through for hot attributes (TTL: 1 hour)               │         │
│  │  • Cache key: tenant:{tenant_id}:entity:{entity_id}:hot         │         │
│  │  • Eviction: LRU                                                 │         │
│  │  • Hit rate target: >90%                                         │         │
│  │                                                                  │         │
│  │  Freshness:                                                      │         │
│  │  • Cache invalidation on writes (pub/sub)                       │         │
│  │  • Lag: 0ms (immediate consistency)                             │         │
│  └─────────────────────────────────────────────────────────────────┘         │
│                                                                               │
└───────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Debezium CDC Configuration

### PostgreSQL Logical Replication Setup

**Step 1: Enable Logical Replication (RDS Parameter Group)**
```sql
-- In RDS parameter group
wal_level = logical
max_replication_slots = 5
max_wal_senders = 5
wal_sender_timeout = 60000  -- 60 seconds
```

**Step 2: Create Publication (on Primary DB)**
```sql
-- Create publication for tables we want to replicate
CREATE PUBLICATION eav_cdc FOR TABLE 
    entities,
    entity_values_ts,
    entity_jsonb
WITH (publish = 'insert,update,delete');

-- Verify publication
SELECT * FROM pg_publication WHERE pubname = 'eav_cdc';
```

**Step 3: Create Replication Slot**
```sql
-- Create logical replication slot for Debezium
SELECT pg_create_logical_replication_slot('debezium_slot', 'wal2json');

-- Monitor slot status
SELECT 
    slot_name,
    plugin,
    slot_type,
    database,
    active,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots
WHERE slot_name = 'debezium_slot';
```

### Debezium Connector Configuration

**Kafka Connect Deployment (ECS Task)**
```json
{
  "name": "eav-postgres-source",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "database.hostname": "eav-db-primary.123456.us-west-2.rds.amazonaws.com",
    "database.port": "5432",
    "database.user": "debezium_user",
    "database.password": "${secret:debezium-password}",
    "database.dbname": "eav_db",
    "database.server.name": "postgres",
    "plugin.name": "wal2json",
    "slot.name": "debezium_slot",
    "publication.name": "eav_cdc",
    
    "table.include.list": "public.entities,public.entity_values_ts,public.entity_jsonb",
    
    "snapshot.mode": "initial",
    "snapshot.locking.mode": "none",
    
    "heartbeat.interval.ms": "10000",
    "heartbeat.action.query": "INSERT INTO _heartbeat (node_id, node_type, last_heartbeat, write_sequence) VALUES ('debezium', 'cdc', now(), nextval('heartbeat_seq')) ON CONFLICT (node_id) DO UPDATE SET last_heartbeat = EXCLUDED.last_heartbeat, write_sequence = EXCLUDED.write_sequence",
    
    "transforms": "unwrap,addTenantIdHeader",
    "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
    "transforms.unwrap.drop.tombstones": "false",
    "transforms.addTenantIdHeader.type": "org.apache.kafka.connect.transforms.InsertField$Value",
    "transforms.addTenantIdHeader.static.field": "tenant_id",
    
    "topic.prefix": "postgres.eav",
    "key.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "key.converter.schemas.enable": "false",
    "value.converter.schemas.enable": "true",
    
    "max.batch.size": "2048",
    "max.queue.size": "8192",
    "poll.interval.ms": "1000",
    
    "errors.tolerance": "all",
    "errors.log.enable": "true",
    "errors.log.include.messages": "true"
  }
}
```

**Key Configuration Choices:**

| Parameter | Value | Rationale |
|-----------|-------|----------|
| `snapshot.mode` | `initial` | Take initial snapshot, then stream changes |
| `snapshot.locking.mode` | `none` | Don't lock tables (use for large tables) |
| `heartbeat.interval.ms` | `10000` | Detect lag every 10 seconds |
| `max.batch.size` | `2048` | Balance throughput vs. lag (2K events/poll) |
| `errors.tolerance` | `all` | Continue on errors (log + skip bad records) |
| `transforms.unwrap` | Yes | Flatten Debezium envelope (easier consumption) |

### Kafka Topic Schema

**Before Unwrap (Debezium Envelope):**
```json
{
  "schema": { ... },
  "payload": {
    "before": null,
    "after": {
      "entity_id": 12345,
      "tenant_id": 123,
      "status": "active"
    },
    "source": {
      "version": "2.4.0",
      "connector": "postgresql",
      "name": "postgres",
      "ts_ms": 1697472000000,
      "snapshot": "false",
      "db": "eav_db",
      "schema": "public",
      "table": "entities",
      "txId": 12345678,
      "lsn": 987654321,
      "xmin": null
    },
    "op": "c",  // c=create, u=update, d=delete
    "ts_ms": 1697472000100
  }
}
```

**After Unwrap (Simplified):**
```json
{
  "entity_id": 12345,
  "tenant_id": 123,
  "status": "active",
  "__op": "c",
  "__ts_ms": 1697472000100,
  "__lsn": 987654321
}
```

### Monitoring Debezium

**Kafka Connect Metrics (Prometheus)**
```yaml
# Connector status
debezium_connector_status{name="eav-postgres-source"} = 1  # 1=running, 0=stopped

# Events per second
rate(debezium_events_total[1m])

# Lag (milliseconds)
debezium_lag_ms{table="entities"}
debezium_lag_ms{table="entity_values_ts"}

# Error count
sum(rate(debezium_errors_total[5m]))
```

**CloudWatch Dashboard Query:**
```sql
-- Check if Debezium is keeping up
SELECT 
    topic,
    partition,
    "offset" AS current_offset,
    log_end_offset - "offset" AS lag_messages,
    ROUND((log_end_offset - "offset") / 10000.0, 2) AS lag_seconds  -- Assuming 10K writes/sec
FROM kafka_consumer_offsets
WHERE consumer_group = 'debezium-connector'
  AND topic LIKE 'postgres.eav.%'
ORDER BY lag_messages DESC;
```

---

## 3. Freshness Budget Matrix

This matrix defines acceptable staleness for different read paths and use cases.

| Read Path | Consumer | Use Case | Target Lag | Max Acceptable Lag | Consistency Level | Fallback Strategy |
|-----------|----------|----------|------------|-------------------|-------------------|-------------------|
| **Redis Cache** | Web UI (critical UX) | Entity detail page, dashboard widgets | 0ms | 100ms | Strong (write-through) | Read from primary if cache miss |
| **Primary DB** | API (write + read) | Edit forms, configuration changes | 0ms | 50ms | Strong (immediate) | Multi-AZ failover (30-60s) |
| **Read Replica** | API (bulk queries) | Search, list views, filters | 1-3s | 5s | Eventual (async replication) | Route to primary if lag > 5s |
| **Near-RT Replica** | Background jobs | Reports, exports, notifications | 3-10s | 30s | Eventual | Abort job, retry in 1 min |
| **Kafka Stream** | Search indexer | Full-text search (Elasticsearch) | 10-30s | 2 min | Eventual | Partial results + freshness warning |
| **Redshift (OLAP)** | BI dashboards | Analytics, trends, aggregations | 5 min | 15 min | Eventual | Display "Data as of [timestamp]" |
| **Redshift (historical)** | Data science | ML training, historical analysis | 1-24 hours | 48 hours | Eventual | Accept stale data (not time-critical) |

### Consistency Levels Explained

**Strong Consistency (Lag: 0ms)**
- Reads always reflect the most recent write
- Use cases: User editing their own data, critical transactions
- Trade-off: Higher latency, limited read scalability

**Bounded Staleness (Lag: <5s)**
- Reads may lag by a bounded time window
- Use cases: List views, search results, non-critical UX
- Trade-off: Slightly stale data, better read throughput

**Eventual Consistency (Lag: minutes to hours)**
- Reads will eventually reflect writes, but no guarantees on timing
- Use cases: Analytics, reports, background processing
- Trade-off: Much higher staleness, massive read scalability

---

## 3. Lag Detection & Monitoring

### Heartbeat Mechanism

**Table Schema:**
```sql
CREATE TABLE _heartbeat (
    node_id text PRIMARY KEY,
    node_type text,  -- 'primary', 'replica-01', 'replica-02'
    last_heartbeat timestamptz NOT NULL,
    write_sequence bigint
);

-- Writer updates every 10 seconds
INSERT INTO _heartbeat (node_id, node_type, last_heartbeat, write_sequence)
VALUES ('primary', 'primary', now(), nextval('heartbeat_seq'))
ON CONFLICT (node_id) DO UPDATE 
SET last_heartbeat = EXCLUDED.last_heartbeat,
    write_sequence = EXCLUDED.write_sequence;
```

**Replica Lag Query (runs on each replica):**
```sql
-- Compare replica's view of heartbeat to expected current time
SELECT 
    node_id,
    node_type,
    EXTRACT(EPOCH FROM (now() - last_heartbeat)) AS lag_seconds,
    write_sequence,
    (SELECT write_sequence FROM _heartbeat WHERE node_id = 'primary') - write_sequence AS sequence_lag
FROM _heartbeat
WHERE node_id = current_setting('cluster.node_id');
```

### CloudWatch Metrics

**Key Metrics:**
1. **DatabaseConnections** (RDS)
   - Alert: > 80% of max connections
   - Action: Scale RDS Proxy, check for connection leaks

2. **ReplicaLag** (RDS)
   - Alert: > 5 seconds (warning), > 30 seconds (critical)
   - Action: Route reads to primary, investigate replication bottleneck

3. **CPUUtilization** (RDS)
   - Alert: > 80% for 10 minutes
   - Action: Scale instance size, optimize queries

4. **KafkaConsumerLag** (MSK)
   - Alert: > 100K messages behind (warning), > 500K (critical)
   - Action: Scale consumer group, check Redshift load performance

5. **RedshiftQueryDuration** (Redshift)
   - Alert: p95 > 30 seconds
   - Action: Review query plans, add distribution keys

6. **RedisCacheHitRate** (ElastiCache)
   - Alert: < 85% (warning), < 75% (critical)
   - Action: Review TTL strategy, increase cache size

### Alerting Rules (CloudWatch Alarms)

```hcl
# Example alarm configuration (Terraform snippet)
resource "aws_cloudwatch_metric_alarm" "replica_lag_critical" {
  alarm_name          = "${var.environment}-rds-replica-lag-critical"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "ReplicaLag"
  namespace           = "AWS/RDS"
  period              = "60"
  statistic           = "Average"
  threshold           = "30"  # 30 seconds
  alarm_description   = "Replica lag exceeds 30 seconds"
  alarm_actions       = [aws_sns_topic.ops_alerts.arn]
  
  dimensions = {
    DBInstanceIdentifier = aws_db_instance.replica.id
  }
}

resource "aws_cloudwatch_metric_alarm" "kafka_consumer_lag" {
  alarm_name          = "${var.environment}-kafka-consumer-lag"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "3"
  metric_name         = "SumOffsetLag"
  namespace           = "AWS/Kafka"
  period              = "300"
  statistic           = "Maximum"
  threshold           = "500000"  # 500K messages
  alarm_description   = "Kafka consumer falling behind"
  alarm_actions       = [aws_sns_topic.ops_alerts.arn]
}
```

---

## 4. Application-Level Freshness Surfacing

### HTTP Response Headers

Every API response includes freshness metadata:

```http
HTTP/1.1 200 OK
Content-Type: application/json
X-Data-Source: replica-01
X-Data-Lag-Seconds: 2.3
X-Data-Timestamp: 2025-10-16T16:45:32Z
X-Consistency-Level: eventual
X-Cache-Hit: true
X-Cache-TTL-Remaining: 3421

{
  "entity_id": "device-12345",
  "attributes": {
    "color": "red",
    "size": 150
  },
  "_metadata": {
    "source": "replica-01",
    "lag_seconds": 2.3,
    "consistency": "eventual",
    "last_updated": "2025-10-16T16:45:30Z"
  }
}
```

### UI Indicators

**Freshness Badge (Web Dashboard):**
```
┌────────────────────────────────────────┐
│  Device Dashboard                      │
│  ┌────────────────────────────────┐    │
│  │ 🟢 Real-time (0s lag)          │    │  ← Green: <1s lag (primary/cache)
│  │ 🟡 Near real-time (3s lag)     │    │  ← Yellow: 1-10s lag (replica)
│  │ 🟠 Delayed (5 min lag)         │    │  ← Orange: >10s lag (analytics)
│  │ 🔴 Stale (replication paused)  │    │  ← Red: > max acceptable lag
│  └────────────────────────────────┘    │
└────────────────────────────────────────┘
```

**Banner Warning (When Lag Exceeds SLA):**
```
┌─────────────────────────────────────────────────────────────────┐
│  ⚠️  Analytics data is currently delayed by 12 minutes.         │
│      Recent changes may not be reflected. [Learn more]          │
└─────────────────────────────────────────────────────────────────┘
```

### API Client SDK (Pseudo-code)

```python
from eav_client import EntityClient

client = EntityClient(
    endpoint="https://api.atlasco.com",
    consistency_preference="strong"  # or "bounded", "eventual"
)

# Read with automatic routing based on freshness preference
entity = client.get_entity(
    entity_id="device-12345",
    tenant_id=123,
    consistency="strong"  # Forces read from primary
)

# Check freshness
if entity.metadata.lag_seconds > 5:
    print(f"Warning: Data is {entity.metadata.lag_seconds}s old")
    
# For analytics queries, accept eventual consistency
results = client.query(
    filters={"category": "router"},
    consistency="eventual",  # Can use replica or OLAP
    max_lag_seconds=300      # Reject if lag > 5 min
)
```

---

## 5. Failure Modes & Circuit Breaker Logic

### Scenario 1: Replica Lag Spike

**Trigger:** Replica lag exceeds 5 seconds  
**Detection:** CloudWatch alarm + heartbeat query  
**Action:**
1. Application routes reads to primary (automatically via routing logic)
2. SNS alert to on-call engineer
3. CloudWatch dashboard shows spike in primary read load
4. Auto-remediation: If lag persists > 5 min, consider:
   - Scaling replica instance size
   - Analyzing slow queries on replica (pg_stat_statements)
   - Checking for long-running transactions blocking WAL apply

**Recovery:** Once lag drops below 3 seconds for 2 consecutive minutes, resume routing reads to replica.

---

### Scenario 2: Kafka Consumer Lag

**Trigger:** Kafka consumer lag > 500K messages (= ~5 min of writes at 10K/sec)  
**Detection:** MSK metrics + consumer group monitoring  
**Action:**
1. Redshift dashboards show "Data delayed by 8 minutes" banner
2. Scale consumer group (add more Flink tasks or Kinesis shards)
3. Check for Redshift bottlenecks (COPY command duration, disk I/O)
4. Temporary: Increase COPY batch size to 50K messages

**Fallback:** If lag continues to grow, pause non-critical consumers (e.g., search indexer) to prioritize analytics ingestion.

---

### Scenario 3: Primary Failover

**Trigger:** Primary DB becomes unavailable (hardware failure, AZ outage)  
**Detection:** RDS Multi-AZ automatic failover (30-60 seconds)  
**Impact:**
- Write unavailability: 30-60s
- Read unavailability: 0s (reads continue on replicas)
- Cache: Remains valid (no invalidation needed)

**Application Behavior:**
```python
# Connection pool handles failover transparently via RDS Proxy
# Application sees connection errors, retries automatically

try:
    entity = client.get_entity(entity_id="device-123", consistency="strong")
except ConnectionError:
    # Exponential backoff retry (3 attempts over 5 seconds)
    time.sleep(2 ** attempt)
    entity = client.get_entity(entity_id="device-123", consistency="strong")
```

**Recovery:** Once new primary is promoted, WAL streaming resumes to replicas within 1-2 minutes.

---

## 6. Replication Topology Decision Tree

```
User Query
    │
    ├─ Write? ──────────────────────────────────────┐
    │   YES                                          │
    │   └─→ Route to PRIMARY via RDS Proxy          │
    │       └─→ Write-through to Redis (hot attrs)  │
    │           └─→ Return 201 Created              │
    │                                                │
    ├─ Read-after-write? ────────────────────────┐  │
    │   YES (user editing their own data)         │  │
    │   └─→ Check Redis cache                     │  │
    │       ├─ Cache HIT ──→ Return (lag: 0ms)    │  │
    │       └─ Cache MISS ──→ Read from PRIMARY   │  │
    │                          └─→ Cache result   │  │
    │                                              │  │
    ├─ Critical UX? ────────────────────────────┐ │  │
    │   YES (dashboard, device detail page)     │ │  │
    │   └─→ Read from PRIMARY or REDIS          │ │  │
    │       └─→ SLA: <50ms lag                  │ │  │
    │                                            │ │  │
    ├─ Bulk query? ───────────────────────────┐ │ │  │
    │   YES (search, list, filters)           │ │ │  │
    │   └─→ Check replica lag                 │ │ │  │
    │       ├─ Lag <5s ──→ Route to REPLICA   │ │ │  │
    │       └─ Lag ≥5s ──→ Route to PRIMARY   │ │ │  │
    │                                          │ │ │  │
    └─ Analytics? ──────────────────────────┐  │ │ │  │
        YES (reports, dashboards, trends)   │  │ │ │  │
        └─→ Check Redshift freshness        │  │ │ │  │
            ├─ Lag <15min ──→ Query OLAP    │  │ │ │  │
            │   └─→ Display timestamp       │  │ │ │  │
            └─ Lag ≥15min ──→ Show banner   │  │ │ │  │
                "Data delayed"              │  │ │ │  │
                                            │  │ │ │  │
                                            ▼  ▼ ▼ ▼  ▼
                                       [Query Execution]
```

---

## 7. Cost-Performance Trade-offs

| Component | Monthly Cost (Prod) | Performance Impact | Cost Optimization Strategy |
|-----------|---------------------|--------------------|-----------------------------|
| **RDS Primary** | $3,500 (r6g.4xlarge Multi-AZ) | Critical (all writes) | Right-size based on write throughput; consider Aurora if >10K writes/sec |
| **RDS Replicas** | $1,750 × 2 = $3,500 | High (offload 80% of reads) | Scale horizontally based on read load; auto-scaling groups |
| **RDS Proxy** | $150 (connection pooling) | Medium (reduces connection overhead) | Essential for 10K concurrent connections |
| **ElastiCache Redis** | $400 (r6g.xlarge × 3 shards) | High (90% cache hit = 10x faster) | Tune TTL and eviction policy; scale based on hit rate |
| **MSK (Kafka)** | $700 (3 brokers, m5.large) | Medium (CDC pipeline) | Use Kinesis Data Streams if <10MB/s throughput |
| **Redshift** | $2,800 (ra3.4xlarge × 4 nodes) | High (complex analytics) | Use Redshift Spectrum for cold data; concurrency scaling |
| **Data Transfer** | $500 (inter-AZ, S3, Kafka) | Low | Minimize cross-region replication |
| **CloudWatch** | $200 (metrics, logs, alarms) | Low | Aggregate low-value metrics; retain logs 7 days |
| **Total** | **~$12,000/month** | | |

**Cost per 1M writes:** ~$0.40  
**Cost per 1M reads (replica):** ~$0.05  
**Cost per 1M reads (cache):** ~$0.01  

---

## 8. Operational Runbook

### Daily Operations
- [ ] Check replica lag dashboard (target: <3s average)
- [ ] Review Kafka consumer lag (target: <50K messages)
- [ ] Monitor Redshift load duration (target: <5 min end-to-end)
- [ ] Verify cache hit rate (target: >90%)

### Weekly Operations
- [ ] Review slow query log (queries >5s)
- [ ] Analyze table bloat (VACUUM candidates)
- [ ] Check partition creation (pg_partman logs)
- [ ] Review CloudWatch costs and optimize

### Monthly Operations
- [ ] Load test to validate 10K writes/sec capacity
- [ ] Disaster recovery drill (failover + PITR restore)
- [ ] Review and archive old Redshift partitions
- [ ] Capacity planning (project 6-month growth)

### Incident Response

**P1: Primary DB unavailable**
1. Verify RDS failover in progress (30-60s)
2. Check application retry logic handling errors gracefully
3. Monitor replica promotion to new primary
4. Post-incident: Review RDS events, adjust alarms

**P2: Replica lag >30 seconds**
1. Route all reads to primary (manual override if needed)
2. Investigate: Long-running transactions? High write volume?
3. Scale replica instance if CPU >80%
4. Consider adding another replica for read capacity

**P3: Kafka consumer lag >15 minutes**
1. Alert analytics team: "Data delayed by X minutes"
2. Scale Flink cluster or add Kinesis shards
3. Check Redshift for locked tables or slow COPY
4. Temporary: Pause low-priority consumers

---

## 9. OLAP Platform Comparison: Redshift vs. ClickHouse

### Decision Matrix

This project uses **Redshift** for OLAP, but **ClickHouse** is a strong alternative for real-time analytics.

| Factor | Redshift | ClickHouse | Winner |
|--------|----------|------------|--------|
| **Ingestion Latency** | 5-15 min (batch COPY) | <1 second (streaming INSERT) | ✅ ClickHouse |
| **Query Latency (cold)** | 2-10s (complex aggregates) | 500ms-2s (pre-aggregated tables) | ✅ ClickHouse |
| **Query Latency (warm)** | 1-3s (result caching) | 100-500ms (native caching) | ✅ ClickHouse |
| **Compression Ratio** | 3-5x (columnar + Snappy) | 10-20x (aggressive columnar) | ✅ ClickHouse |
| **Storage Cost** | $23/TB/month (managed S3) | $10/TB/month (EBS + S3 tiering) | ✅ ClickHouse |
| **Concurrency** | 50-500 concurrent queries | 100-1000+ concurrent queries | ✅ ClickHouse |
| **SQL Compatibility** | Full ANSI SQL + window fns | 90% SQL (some PostgreSQL extensions missing) | ✅ Redshift |
| **Managed Service** | Fully managed (AWS) | Self-hosted or Altinity Cloud | ✅ Redshift |
| **Operational Complexity** | Low (push-button scaling) | Medium (requires tuning, sharding) | ✅ Redshift |
| **BI Tool Integration** | Excellent (native Tableau, Looker) | Good (JDBC/ODBC, some BI tools) | ✅ Redshift |
| **Data Deduplication** | Manual (MERGE, staging tables) | Automatic (ReplacingMergeTree) | ✅ ClickHouse |
| **Time-Series Optimization** | Requires sort keys + partitions | Native (TTL, rollups, materialized views) | ✅ ClickHouse |
| **Total Cost (4-node cluster)** | $2,800/month (ra3.4xlarge × 4) | $1,200/month (c6i.4xlarge × 4 on EC2) | ✅ ClickHouse |

**Overall Winner:** ClickHouse for **real-time analytics** (<1 second lag), Redshift for **operational simplicity**

---

### When to Use Redshift

✅ **Choose Redshift if:**
1. You need **fully managed** service (no infrastructure management)
2. Your BI tools (Tableau, Looker) have native Redshift connectors
3. You're already in AWS ecosystem (tight integration with S3, Glue, QuickSight)
4. Your analytics workload is **batch-oriented** (hourly/daily reports)
5. You need **concurrency scaling** for unpredictable query spikes
6. Your team is **familiar with PostgreSQL** (Redshift is PostgreSQL-based)

**Example Use Case:**
- Monthly executive dashboards
- Ad-hoc SQL queries by business analysts
- Integration with existing AWS data lake (S3 + Athena)

---

### When to Use ClickHouse

✅ **Choose ClickHouse if:**
1. You need **sub-second query latency** for real-time dashboards
2. Your data is **time-series heavy** (logs, metrics, events)
3. You have **high write throughput** (>100K inserts/sec)
4. You want **lower costs** (50-70% cheaper than Redshift)
5. You need **automatic deduplication** (ReplacingMergeTree, SummingMergeTree)
6. You're okay with **self-hosting** (or using Altinity Cloud, ClickHouse Cloud)

**Example Use Case:**
- Real-time operational dashboards (device health, alerts)
- High-frequency analytics (per-minute aggregations)
- Log analytics (APM, security events)

---

### Architecture Comparison

**Current (Redshift):**
```
Postgres → Kafka → Flink (30s batch) → S3 Parquet → Redshift COPY (5 min)
                                                    │
                                                    └─→ End-to-end lag: 5-8 min
```

**Alternative (ClickHouse):**
```
Postgres → Kafka → ClickHouse Kafka Engine (streaming) → ClickHouse MergeTree
                                                          │
                                                          └─→ End-to-end lag: <10 sec
```

---

### ClickHouse Implementation Details

**Table Engine: ReplacingMergeTree (Automatic Deduplication)**
```sql
CREATE TABLE entity_values_clickhouse (
    tenant_id UInt64,
    entity_id UInt64,
    attribute_id UInt64,
    value String,
    value_int Nullable(Int64),
    value_decimal Nullable(Decimal(20, 5)),
    ingested_at DateTime64(3),
    version UInt64  -- For deduplication (higher = newer)
)
ENGINE = ReplacingMergeTree(version)
PARTITION BY toYYYYMM(ingested_at)
ORDER BY (tenant_id, entity_id, attribute_id, ingested_at)
TTL ingested_at + INTERVAL 90 DAY;  -- Auto-delete after 90 days
```

**Kafka Ingestion (Real-Time)**
```sql
-- Create Kafka table (reads from Kafka topic)
CREATE TABLE entity_values_kafka (
    tenant_id UInt64,
    entity_id UInt64,
    attribute_id UInt64,
    value String,
    value_int Nullable(Int64),
    value_decimal Nullable(Decimal(20, 5)),
    ingested_at DateTime64(3),
    version UInt64
)
ENGINE = Kafka
SETTINGS 
    kafka_broker_list = 'kafka-broker-1:9092,kafka-broker-2:9092',
    kafka_topic_list = 'postgres.eav.entity_values_ts',
    kafka_group_name = 'clickhouse_consumer',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 3;

-- Materialized view: Auto-insert from Kafka to MergeTree
CREATE MATERIALIZED VIEW entity_values_kafka_mv TO entity_values_clickhouse AS
SELECT *
FROM entity_values_kafka;
```

**Pre-Aggregation (Materialized View)**
```sql
-- Aggregate metrics per hour (automatic rollup)
CREATE MATERIALIZED VIEW agg_hourly_metrics
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(hour)
ORDER BY (tenant_id, attribute_id, hour)
AS SELECT
    tenant_id,
    attribute_id,
    toStartOfHour(ingested_at) AS hour,
    count() AS sample_count,
    avg(value_decimal) AS avg_value,
    min(value_decimal) AS min_value,
    max(value_decimal) AS max_value
FROM entity_values_clickhouse
WHERE value_decimal IS NOT NULL
GROUP BY tenant_id, attribute_id, hour;

-- Query: Get hourly averages (instant response)
SELECT 
    hour,
    attribute_id,
    avg_value
FROM agg_hourly_metrics
WHERE tenant_id = 123
  AND hour >= now() - INTERVAL 7 DAY
ORDER BY hour DESC;
```

**Query Performance Comparison**

| Query Type | Redshift | ClickHouse | Improvement |
|------------|----------|------------|-------------|
| Simple aggregate (1 day) | 2-5s | 200-500ms | 4-10x faster |
| Complex joins (7 days) | 10-30s | 1-3s | 10x faster |
| Full scan (90 days) | 60-180s | 5-15s | 12x faster |
| Pre-aggregated query | 1-2s | 50-100ms | 20x faster |

---

### Cost Analysis: 4-Node Cluster

**Redshift:**
- Instance: ra3.4xlarge × 4 nodes
- Compute: 48 vCPU, 384GB RAM
- Storage: Managed S3 (10TB = $230/month)
- Total: **$2,800/month**

**ClickHouse (Self-Hosted on EC2):**
- Instance: c6i.4xlarge × 4 nodes (EBS gp3 + S3 tiering)
- Compute: 64 vCPU, 128GB RAM
- Storage: 2TB EBS (hot) + 10TB S3 (cold) = $400/month
- Total: **$1,200/month** (57% cheaper)

**ClickHouse Cloud (Managed):**
- Similar to EC2 but with auto-scaling, backups, monitoring
- Total: **$1,800/month** (36% cheaper than Redshift)

---

### Recommendation

**For this EAV project:**

**Phase 1 (Current): Use Redshift**
- Faster to implement (managed service)
- Team familiarity with SQL/PostgreSQL
- Good enough for 5-15 min lag SLA

**Phase 2 (12 months): Evaluate ClickHouse**
- When real-time dashboards become critical (<10s lag)
- When query costs grow (>$5K/month on Redshift)
- When write throughput exceeds 20K/sec

**Hybrid Approach:**
```
Postgres → Kafka → ┬─→ ClickHouse (real-time dashboards, <10s lag)
                   │
                   └─→ Redshift (historical reports, <15 min lag)
```

---

## 10. Future Enhancements

**Short-term (3-6 months):**
- [ ] Implement read-your-writes guarantee via sticky sessions
- [ ] Add Elasticsearch for full-text search on attributes
- [ ] Optimize hot attribute selection with ML-based access patterns
- [ ] Implement query result caching (Redis) for common analytical queries

**Long-term (12+ months):**
- [ ] Migrate to Aurora for better write scalability (100K IOPS)
- [ ] Implement Citus for horizontal sharding by tenant_id
- [ ] Add ClickHouse for real-time analytics (replace batch Redshift loads)
- [ ] Implement federated queries (Trino) across Postgres + Redshift + S3

---

## Conclusion

This architecture balances:
- **Write throughput:** 10K inserts/sec via staging tables, COPY, and async commits
- **Read latency:** <50ms for critical UX (Redis + primary), <200ms for bulk queries (replicas)
- **Analytics freshness:** 5-minute lag (acceptable for BI dashboards)
- **Operational simplicity:** Managed services (RDS, MSK, Redshift, ElastiCache)
- **Cost efficiency:** ~$12K/month for production-grade deployment

Key innovation: **Hot/cold attribute split** with JSONB projection enables immediate read-after-write for critical UX flows while keeping the time-series EAV design for analytical queries.
