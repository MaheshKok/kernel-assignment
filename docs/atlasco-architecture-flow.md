# AtlasCo Telemetry Architecture - Complete Flow Diagrams

## 1. High-Level System Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         TELEMETRY SOURCES                               │
│  IoT Devices │ Sensors │ Applications │ Edge Gateways                   │
└─────────────┬───────────────────────────────────────────────────────────┘
              │
              │ 10K events/sec
              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      KAFKA / SQS (Message Queue)                        │
│  - Buffer for replay capability                                         │
│  - Retention: 7 days                                                    │
└─────────────┬───────────────────────────────────────────────────────────┘
              │
              │
              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    INGESTION SERVICE (Write Path)                       │
│  - Batch writes (COPY protocol)                                         │
│  - Deduplication logic                                                  │
└─────────────┬───────────────────────────────────────────────────────────┘
              │
              ├──────────────────────────┬─────────────────────────────────┐
              │                          │                                 │
              ▼                          ▼                                 ▼
    ┌──────────────────┐      ┌──────────────────┐           ┌──────────────────┐
    │   UNLOGGED       │      │  Hot Attributes  │           │  Redis Cache     │
    │   STAGING        │      │  (entity_jsonb)  │           │  Invalidation    │
    │ entity_values_   │      │  - Dual write    │           │  - TTL: 60-300s  │
    │   ingest         │      │  - Sub-50ms read │           │                  │
    └────────┬─────────┘      └──────────────────┘           └──────────────────┘
             │
             │ stage_flush() every 100ms
             │
             ▼
    ┌──────────────────────────────────────────────────────────────────────┐
    │                    OLTP DATABASE (PostgreSQL)                        │
    │  ┌────────────────────────────────────────────────────────────────┐  │
    │  │ Primary Writer (db.r6g.4xlarge)                                │  │
    │  │  - entity_values_ts (partitioned by time)                      │  │
    │  │  - entities                                                    │  │
    │  │  - entity_jsonb (partitioned by entity_id)                     │  │
    │  │  - attributes                                                  │  │
    │  └────────────────────────────────────────────────────────────────┘  │
    │                                                                      │
    │  ┌────────────────────────────────────────────────────────────────┐  │
    │  │ Read Replicas (×2)                          Lag: <3s           │  │
    │  │  - Handles 80% of read traffic                                 │  │
    │  │  - Circuit breaker if lag > 5s                                 │  │
    │  └────────────────────────────────────────────────────────────────┘  │
    │                                                                      │
    │  ┌────────────────────────────────────────────────────────────────┐  │
    │  │ RDS Proxy                                                      │  │
    │  │  - Connection pooling (20K → 200 connections)                  │  │
    │  └────────────────────────────────────────────────────────────────┘  │
    └───────────────────────┬──────────────────────────────────────────────┘
                            │
                            │ WAL (Write-Ahead Log)
                            │ Logical Replication
                            ▼
    ┌──────────────────────────────────────────────────────────────────────┐
    │                  CDC Pipeline (Change Data Capture)                  │
    │  ┌────────────────────────────────────────────────────────────────┐  │
    │  │ Debezium Connector (Kafka Connect)                             │  │
    │  │  - Plugin: wal2json                                            │  │
    │  │  - Slot: debezium_slot                                         │  │
    │  │  - Heartbeat: 10s                                              │  │
    │  └───────────────────────────┬────────────────────────────────────┘  │
    │                              │                                       │
    │                              ▼                                       │
    │  ┌────────────────────────────────────────────────────────────────┐  │
    │  │ Kafka Topics (MSK - 3 brokers, 3 AZs)                          │  │
    │  │  - postgres.eav.entities                                       │  │
    │  │  - postgres.eav.entity_values_ts                               │  │
    │  │  - postgres.eav.entity_jsonb                                   │  │
    │  │  - Retention: 7 days                                           │  │
    │  └───────────────────────────┬────────────────────────────────────┘  │
    │                              │                                       │
    │                              ▼                                       │
    │  ┌────────────────────────────────────────────────────────────────┐  │
    │  │ Stream Processor (Flink / Kinesis Data Analytics)              │  │
    │  │  - Enrichment                                                  │  │
    │  │  - Deduplication                                               │  │
    │  │  - 30s batching                                                │  │
    │  └───────────────────────────┬────────────────────────────────────┘  │
    └──────────────────────────────┼───────────────────────────────────────┘
                                   │
                                   │ Lag: 5 min target
                                   ▼
    ┌──────────────────────────────────────────────────────────────────────┐
    │                     OLAP DATABASE (Redshift)                         │
    │  - 4-node cluster (ra3.4xlarge)                                      │
    │  - Columnar storage                                                  │
    │  - Optimized for analytics                                           │
    └──────────────────────────────────────────────────────────────────────┘
                                   │
                                   │
                                   ▼
    ┌──────────────────────────────────────────────────────────────────────┐
    │                        APPLICATION LAYER                             │
    │  ┌────────────────────────────────────────────────────────────────┐  │
    │  │ Query Router (app/query_router.py)                             │  │
    │  │  - Routes based on consistency level                           │  │
    │  │  - STRONG    → Primary DB                                      │  │
    │  │  - EVENTUAL  → Read Replica (circuit breaker)                  │  │
    │  │  - ANALYTICS → Redshift                                        │  │
    │  └────────────────────────────────────────────────────────────────┘  │
    └──────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
    ┌──────────────────────────────────────────────────────────────────────┐
    │                            END USERS                                 │
    │  - Dashboard UI (real-time monitoring)                               │
    │  - Analytics UI (reports, trends)                                    │
    │  - Mobile Apps                                                       │
    │  - API Clients                                                       │
    └──────────────────────────────────────────────────────────────────────┘
```

---

## 2. Write Path - Detailed Flow

```
Telemetry Event
     │
     │ {"entity_id": 123, "tenant_id": 456, 
     │  "temperature": 75.5, "status": "active"}
     ▼
┌──────────────────────────────────────────┐
│  Ingestion Service                       │
│  - Validates schema                      │
│  - Extracts tenant context               │
│  - Batches events (10K/batch)           │
└──────────────┬───────────────────────────┘
               │
               │ COPY protocol (fast bulk insert)
               ▼
┌──────────────────────────────────────────┐
│  entity_values_ingest (UNLOGGED)         │
│  ┌────────────────────────────────────┐  │
│  │ entity_id: 123                     │  │
│  │ tenant_id: 456                     │  │
│  │ attribute_id: 77 (temperature)     │  │
│  │ value_decimal: 75.5                │  │
│  │ ingested_at: 2025-10-23 14:30:00   │  │
│  └────────────────────────────────────┘  │
│  - No WAL (fast writes)                  │
│  - No indexes                            │
│  - Loss window: <1 minute                │
└──────────────┬───────────────────────────┘
               │
               │ Triggered every 100ms
               │ OR when batch size > 50K
               ▼
┌──────────────────────────────────────────┐
│  stage_flush() Function                  │
│  SET LOCAL synchronous_commit = off;     │
│  ┌────────────────────────────────────┐  │
│  │ 1. SELECT from staging             │  │
│  │ 2. INSERT into entity_values_ts    │  │
│  │ 3. DELETE from staging             │  │
│  │ 4. Check if attribute is "hot"     │  │
│  │ 5. If hot → upsert_hot_attrs()     │  │
│  └────────────────────────────────────┘  │
└──────────────┬───────────────┬───────────┘
               │               │
               │               │ Hot attribute?
               │               │ (is_hot = true)
               │               ▼
               │     ┌─────────────────────────┐
               │     │ upsert_hot_attrs()      │
               │     │ - Merges JSONB          │
               │     │ - Invalidates Redis     │
               │     └─────────────────────────┘
               │               │
               ▼               ▼
┌─────────────────────────────────────────────────┐
│  entity_values_ts (Partitioned by time)         │
│  Partition: entity_values_2025_10               │
│  ┌───────────────────────────────────────────┐  │
│  │ Primary Key: (tenant, entity, attr, time) │  │
│  │ Indexes: BRIN(ingested_at)                │  │
│  │          B-tree(tenant, attr, time)       │  │
│  └───────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
               │
               │ WAL streaming
               ▼
┌─────────────────────────────────────────────────┐
│  Read Replicas                                  │
│  - Async replication                            │
│  - Lag monitoring via replication_heartbeat     │
└─────────────────────────────────────────────────┘
```

---

## 3. Read Path - Query Routing Decision Tree

```
                           API Request
                                │
                                │ GET /entities/123?attr=temperature
                                ▼
                   ┌────────────────────────────┐
                   │   Query Router             │
                   │   - Extract consistency    │
                   │   - Check cache first      │
                   └────────────┬───────────────┘
                                │
                                │ What consistency level?
                                │
                ┌───────────────┼───────────────┐
                │               │               │
                ▼               ▼               ▼
           STRONG          EVENTUAL        ANALYTICS
          (Critical)      (Bulk reads)    (Reports)
                │               │               │
                │               │               │
                ▼               ▼               ▼
       ┌─────────────┐  ┌─────────────┐  ┌─────────────┐
       │ Try Redis   │  │ Try Redis   │  │ Route to    │
       │ Cache       │  │ Cache       │  │ Redshift    │
       └──────┬──────┘  └──────┬──────┘  │             │
              │                │         │ - Historical│
              │ Cache miss?    │ Cache   │   trends    │
              │                │ miss?   │ - Complex   │
              ▼                ▼         │   aggregates│
       ┌─────────────┐  ┌─────────────┐ │ - Cross-     │
       │ Read from   │  │ Check       │ │   tenant     │
       │ PRIMARY     │  │ Replica Lag │ │   analytics  │
       │             │  └──────┬──────┘ │              │
       │ - Latest    │         │        │ Lag: 5 min   │
       │   data      │         │        │              │
       │ - No lag    │         │        │ Returns:     │
       │             │         ▼        │ - Metadata   │
       │ Latency:    │    ┌─────────┐   │ - Timestamp  │
       │ 15-50ms     │    │ Lag OK? │   └──────────────┘
       └──────┬──────┘    │ (<3s)   │
              │           └────┬────┘
              │                │
              │           ┌────┴─────┐
              │           │          │
              │          YES         NO
              │           │          │
              │           ▼          ▼
              │    ┌─────────────┐ ┌──────────────┐
              │    │ Read from   │ │ Circuit      │
              │    │ REPLICA     │ │ Breaker:     │
              │    │             │ │ Fallback to  │
              │    │ - Acceptable│ │ PRIMARY      │
              │    │   staleness │ │              │
              │    │             │ │ After 5      │
              │    │ Latency:    │ │ consecutive  │
              │    │ 20-100ms    │ │ failures,    │
              │    │             │ │ stop trying  │
              │    │             │ │ replicas for │
              │    │             │ │ 60 seconds   │
              │    └──────┬──────┘ └──────┬───────┘
              │           │               │
              │           └────────┬──────┘
              │                    │
              └────────────────────┘
                                   │
                                   ▼
                          ┌─────────────────┐
                          │ Return Response │
                          │                 │
                          │ Headers:        │
                          │ ─────────────── │
                          │ X-Data-Source:  │
                          │   replica-01    │
                          │                 │
                          │ X-Data-Lag-     │
                          │   Seconds: 2.3  │
                          │                 │
                          │ X-Consistency-  │
                          │   Level:        │
                          │   eventual      │
                          │                 │
                          │ X-Cache-Status: │
                          │   miss          │
                          └─────────────────┘
```

---


## 4. Timeline: When Data Moves Between Systems

```
T=0s          Telemetry event occurs
  │
  ├─> T=0.1s   Arrives in Kafka/SQS buffer
  │
  ├─> T=0.2s   Ingestion service writes to entity_values_ingest (UNLOGGED)
  │
  ├─> T=0.3s   stage_flush() moves to entity_values_ts (WAL enabled)
  │             └─> If hot attribute: Updated in entity_jsonb + Redis invalidated
  │
  ├─> T=0.5s   Data committed in PostgreSQL primary
  │
  ├─> T=1-3s   Data replicated to read replicas
  │             └─> Available for EVENTUAL consistency reads
  │
  ├─> T=10s    Debezium captures change from WAL
  │             └─> Publishes to Kafka topic
  │
  ├─> T=40s    Flink processes stream (30s batch window)
  │             └─> Enrichment, deduplication
  │
  ├─> T=5min   Batch loaded into Redshift
  │             └─> Available for ANALYTICS queries
  │
  └─> T=1hr    Materialized views refreshed in Redshift
                └─> Dashboards show updated aggregates


FRESHNESS BY USE CASE:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Use Case                          | Acceptable Lag | System
──────────────────────────────────┼────────────────┼─────────
Critical alerts/monitoring        | 0ms            | Primary DB
Dashboard status checks           | 0-100ms        | Redis/Primary
Search/filtering (non-critical)   | 1-3s           | Read Replica
Report generation                 | 5-15 min       | Redshift
Historical trend analysis         | Hours          | Redshift
Executive monthly reports         | Days           | Redshift
```

---

## 5. Summary: The Complete Picture

| Component | Purpose | Latency | Data Age | Use Case |
|-----------|---------|---------|----------|----------|
| **Redis** | Hot cache | 5-30ms | Real-time (0s lag) | Critical UX (device status, alerts) |
| **PostgreSQL Primary** | Source of truth | 15-50ms | Real-time (0s lag) | Write-after-read, operational queries |
| **PostgreSQL Replicas** | Read scaling | 20-100ms | Near real-time (1-3s lag) | Search, filtering, bulk reads |
| **Redshift** | Analytics warehouse | 2-30s | Eventually consistent (5min lag) | Reports, trends, BI, ML, compliance |

**Key Insight:** 
- **OLTP (PostgreSQL)** = "What's happening NOW?"
- **OLAP (Redshift)** = "What PATTERNS exist in our history?"

You need BOTH because:
1. OLTP can't handle large analytical queries without dying
2. OLAP shouldn't handle real-time operational queries (too slow)
3. Mixing them = worst of both worlds

This architecture gives you **fast operations** AND **powerful analytics** without compromise.
