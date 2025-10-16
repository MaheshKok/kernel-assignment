# EAV at Scale: PostgreSQL Solution for 200M Entities (Revised)

## Executive Summary
Updated to sustain ~10k writes/sec, guarantee read-after-write for critical actions, support wide ad-hoc filters, and replicate with explicit freshness. Key changes: time-series partitioning, write-optimized ingest path, CQRS hot-projection for immediate reads, Redis cache, and infra hardening (RDS Proxy, ElastiCache, CloudWatch alarms).

## Part A: Data Model & Querying

### Logical Schema (Hybrid EAV + Hot JSONB Projection)
- entities(entity_id, tenant_id, ...): base
- attributes(attribute_id, name, data_type, ...): metadata
- entity_values_ts(..., ingested_at timestamptz): time-series EAV (append-only)
- entity_jsonb(entity_id, tenant_id, hot_attrs jsonb): latest "hot" projection for immediate reads
- entity_values_ingest: UNLOGGED staging for bursty ingest

### Partitioning & Sharding
- Time-series RANGE partitions on entity_values_ts by month (or day at extreme scale); BRIN on ingested_at
- Optional sub-shard by HASH(entity_id) if a single time partition gets hot
- Row-level multi-tenancy via tenant_id; future path: Citus for tenant sharding
- Hot/cold split: hot attributes denormalized into entity_jsonb with GIN

### Indexing (write-lean defaults)
- entity_values_ts: BRIN(ingested_at), BTREE(tenant_id, attribute_id, ingested_at)
- entity_jsonb: BTREE(tenant_id, entity_id), GIN(hot_attrs)
- Avoid per-attribute indexes; use partials only for the top-N attributes if proven hot

### Query Examples

Operational (multi-attribute, read-after-write via hot projection):
```sql
-- color='red' AND size > 100 for tenant 123 (immediate)
SELECT e.entity_id, ej.hot_attrs
FROM entities e
JOIN entity_jsonb ej USING (entity_id, tenant_id)
WHERE e.tenant_id = 123
  AND ej.hot_attrs->>'color' = 'red'
  AND (ej.hot_attrs->>'size')::int > 100
LIMIT 100;
```
Analytical (distribution over recent 30d slice):
```sql
SELECT a.attribute_name, ev.value, COUNT(DISTINCT ev.entity_id) AS entity_count
FROM entity_values_ts ev
JOIN attributes a USING (attribute_id)
WHERE ev.tenant_id = 123
  AND ev.ingested_at >= now() - interval '30 days'
  AND a.attribute_name IN ('category','status')
GROUP BY a.attribute_name, ev.value
ORDER BY entity_count DESC;
```

### Write Path (10k inserts/sec)
- UNLOGGED staging table + COPY for bulk loads
- Async commit for non-critical writes (synchronous_commit=off)
- Batched move from staging → partitions; upsert hot projection synchronously for critical attributes
- Prepared statements, connection pooling (RDS Proxy/PgBouncer)

### Trade-offs
- Pros: High write throughput, immediate reads from hot projection, partition pruning for scans
- Cons: Dual-write (TS + hot JSONB) complexity; extra RAM for Redis; BRIN less selective on small partitions
- Fallbacks: Promote a hot attribute to partial index; materialize common analytical views; scale-out with Citus

## Part B: Read Freshness & Replication

### Architecture
```
App → RDS Proxy → Postgres (writer)
               ↘ near-RT replicas (reads)
CDC: Postgres WAL → Debezium → Kafka → Stream proc → Redshift
Cache: Redis (low-latency read-after-write keys)
```

### Freshness Budget
- Critical UX reads: primary or replica with lag ≤ 50ms; Redis cached with write-through
- Search/list: near-RT replicas (≤ 3s)
- Analytics: Redshift (≤ 5 min)
- Surface via headers: X-Data-Source, X-Data-Lag-Seconds, X-Consistency-Level

### Lag Detection & Handling
- Heartbeat table + comparator; CloudWatch alarms on replica lag/CPU
- Circuit-breaker to primary if lag beyond SLO; UI banner when stale

## Part C: Infrastructure as Code (Terraform)
- Adds ElastiCache Redis, RDS Proxy, security groups, alarms
- Environment params (dev/staging/prod) size the fleet and retention

## Operational Notes
- Vacuum/Analyze tuned; partition rotation via pg_partman
- Background job: stage_flush() every 100ms during load
- Disaster recovery: snapshots + PITR; runbooks; regular drills

## Conclusion
Design now aligns with telemetry realities (time-series writes), preserves immediate UX correctness via hot projection + Redis, and keeps OLAP honest with explicit freshness and CDC.
