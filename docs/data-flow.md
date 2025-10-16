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
│  │  - Lag target: <3s  │       │  - Retained WAL: 10GB     │               │
│  │  - Max lag alarm:   │       │  - Heartbeat: 10s         │               │
│  │    5s → route to    │       └───────────┬───────────────┘               │
│  │    primary          │                   │                                │
│  └─────────────────────┘                   │                                │
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

## 2. Freshness Budget Matrix

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

## 9. Future Enhancements

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
