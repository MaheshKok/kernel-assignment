# EAV at Scale: PostgreSQL Solution for 200M Entities

## Executive Summary
This document outlines a scalable Entity-Attribute-Value (EAV) schema design for PostgreSQL capable of handling 200M entities with ~10,000 dynamic attribute types, supporting both operational and analytical workloads.

## Part A: Data Model & Querying

### Logical Schema Design

The core schema uses a hybrid EAV approach with JSONB for optimization:

**Core Tables:**
1. **entities** - Base entity table with tenant isolation
2. **attributes** - Attribute metadata with type information
3. **entity_values** - Main EAV storage with optimized indexing
4. **entity_jsonb** - JSONB storage for hot attributes (frequently accessed)

### Partitioning Strategy

**Hybrid Partitioning Approach:**
- **Range partitioning** on entity_id (200 partitions, 1M entities each)
- **List partitioning** on tenant_id for multi-tenancy
- **Hot/Cold separation** using JSONB for top 20% most-queried attributes

```
entities_p0 (entity_id 0-1M, tenant_1)
entities_p1 (entity_id 0-1M, tenant_2)
...
entities_p200 (entity_id 199M-200M, tenant_n)
```

### Indexing Strategy

1. **Composite B-tree indexes** on (tenant_id, entity_id, attribute_id)
2. **GIN indexes** on JSONB columns for hot attributes
3. **BRIN indexes** on timestamp columns for time-series queries
4. **Partial indexes** on frequently filtered attribute_id values

### Query Examples

**Operational Query (Multi-attribute filter):**
```sql
-- Find entities with color='red' AND size > 100
WITH filtered_entities AS (
    SELECT e.entity_id 
    FROM entity_jsonb e
    WHERE e.tenant_id = 123
    AND e.hot_attrs->>'color' = 'red'
    AND (e.hot_attrs->>'size')::int > 100
)
SELECT e.*, ev.attribute_id, ev.value
FROM entities e
JOIN entity_values ev ON e.entity_id = ev.entity_id
WHERE e.entity_id IN (SELECT entity_id FROM filtered_entities)
AND e.tenant_id = 123;
```

**Analytical Query (Aggregation):**
```sql
-- Distribution of attribute values across entities
SELECT 
    a.attribute_name,
    ev.value,
    COUNT(DISTINCT ev.entity_id) as entity_count,
    COUNT(*) as total_occurrences
FROM entity_values ev
JOIN attributes a ON ev.attribute_id = a.attribute_id
WHERE ev.tenant_id = 123
AND a.attribute_name IN ('category', 'status')
GROUP BY a.attribute_name, ev.value
HAVING COUNT(DISTINCT ev.entity_id) > 100
ORDER BY entity_count DESC;
```

### Trade-offs Analysis

**Where this design excels:**
- Flexible schema evolution without DDL changes
- Efficient tenant isolation
- Good performance for known hot attributes via JSONB
- Scales horizontally with partitioning

**Where it degrades:**
- Complex queries joining multiple attributes (N-way joins)
- Full table scans on cold attributes
- Storage overhead (3-5x compared to traditional schema)
- VACUUM and maintenance overhead at scale

**Fallback approaches:**
- Materialized views for frequent query patterns
- Read replicas for analytical workload separation
- Migration to Citus for true horizontal sharding
- Consider PostgreSQL 16+ with improved partitioning

## Part B: Read Freshness & Replication

### Replication Architecture

```
┌─────────────┐      ┌──────────────┐      ┌─────────────┐
│   Primary   │      │   Kafka      │      │  Redshift   │
│  PostgreSQL │─────▶│   Topics     │─────▶│   (OLAP)    │
│   (OLTP)    │ CDC  │              │      │             │
└─────────────┘      └──────────────┘      └─────────────┘
       │                    │                      ▲
       │                    │                      │
       ▼                    ▼                      │
┌─────────────┐      ┌──────────────┐              │
│  Read       │      │  Debezium    │──────────────┘
│  Replicas   │      │  Connector   │ Transform
│  (Near RT)  │      │              │ & Load
└─────────────┘      └──────────────┘
```

**Components:**
- **Logical Replication** via pg_logical for read replicas
- **Debezium** for CDC to Kafka (WAL-based change capture)
- **Kafka** as event backbone with compacted topics
- **Spark/Flink** for stream processing and transformations
- **Redshift** for analytical workloads

### Freshness Budget Matrix

| Query Type | Target | Actual Lag | Destination | Consistency |
|------------|--------|------------|-------------|-------------|
| Transactional Writes | 0ms | 0ms | Primary | Strong |
| Entity Lookups | <10ms | 0-5ms | Primary | Strong |
| Recent Changes | <1s | 100-500ms | Read Replica | Eventual |
| List/Search | <5s | 1-3s | Read Replica | Eventual |
| Analytics/Reports | <5min | 2-5min | Redshift | Eventual |
| Historical Analysis | <1hr | 15-30min | Redshift | Eventual |

### Freshness Surfacing in Application

**API Response Headers:**
```http
X-Data-Source: primary|replica|analytics
X-Data-Lag-Seconds: 0|3|180
X-Data-Timestamp: 2024-01-10T14:30:00Z
X-Consistency-Level: strong|eventual|stale
```

**API Response Body:**
```json
{
  "data": {...},
  "metadata": {
    "source": "replica-us-east-1",
    "lag_ms": 1200,
    "sampled_at": "2024-01-10T14:30:00Z",
    "consistency": "eventual"
  }
}
```

### Lag Detection & Handling

1. **Heartbeat Table**: Write timestamp every second to primary, compare on replicas
2. **Replication Slot Monitoring**: Monitor pg_replication_slots.lag_bytes
3. **Circuit Breaker**: Route to primary if lag > threshold
4. **User Notification**: Display banner for stale data in UI

## Part C: Infrastructure as Code

See `infra/main.tf` for complete Terraform configuration.

Key parameterization example:
```hcl
variable "environment" {
  description = "Environment name (dev/staging/prod)"
  type        = string
}

locals {
  instance_class = {
    dev     = "db.t3.large"
    staging = "db.r6g.xlarge"
    prod    = "db.r6g.4xlarge"
  }
}
```

## Cost Optimization Strategies

1. **Storage Tiering**: Archive old data to S3 via pg_partman
2. **Reserved Instances**: 40-60% cost savings for predictable workloads
3. **Auto-scaling**: Scale read replicas based on load
4. **Compression**: TOAST compression for large text values
5. **Vacuum Optimization**: Scheduled during off-peak hours

## Operational Considerations

### Monitoring & Observability
- PostgreSQL: pg_stat_statements, pgBadger
- Application: OpenTelemetry, Datadog APM
- Infrastructure: CloudWatch, Prometheus
- CDC Pipeline: Kafka lag monitoring, Debezium metrics

### Failure Modes
1. **Primary failure**: Automatic failover to standby (RTO: 30s)
2. **Replica lag**: Circuit breaker redirects to primary
3. **Kafka failure**: Buffer in PostgreSQL, retry with backoff
4. **Redshift failure**: Queries fall back to read replicas

### Maintenance Windows
- **VACUUM**: Daily during 2-4 AM UTC
- **REINDEX**: Weekly on Sundays
- **Partition maintenance**: Monthly, automated via pg_partman
- **Statistics update**: Continuous with auto-analyze

## Conclusion

This solution balances flexibility with performance at scale, leveraging PostgreSQL's native features while acknowledging its limitations. The hybrid EAV+JSONB approach provides a pragmatic path forward, with clear upgrade paths as requirements evolve.