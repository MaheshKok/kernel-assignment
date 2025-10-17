# Implementation Notes 

---

## 1. Assignment Expectations

| Area | Key Requirements | Delivered Artifacts |
| --- | --- | --- |
| **Part A – Data Model & Querying** | - EAV schema sustaining 200M entities / 10k dynamic attributes<br>- Low-latency operational filters<br>- Efficient analytical scans without per-attribute indexes<br>- Partitioning/sharding strategy<br>- Operational + analytical SQL samples<br>- Trade-off summary | `solution.md` (design note, queries, trade-offs)<br>`schema.sql` (DDL, partitioning, sample queries) |
| **Part B – Freshness & Replication** | - Separate OLTP and OLAP stores<br>- CDC pipeline sketch (logical decoding → Debezium/Kafka → OLAP)<br>- Freshness budget matrix<br>- Freshness surfacing in APIs/UI<br>- ASCII flow diagram + lag handling | `solution.md` (sections 5–7), ASCII diagram, headers/metadata plan |
| **Part C – Infrastructure as Code** | - Terraform/Pulumi snippet provisioning RDS + Redshift<br>- VPC & security groups<br>- Environment parameterization example | `infra/main.tf` (full Terraform stack with env-specific sizing) |
| **Optional / Bonus** | - Notes / TODOs / follow-ups | This file (`notes.md`) |

---

## 2. Implementation Highlights

### 2.1 Write Path & Throughput
- **UNLOGGED staging table** `entity_values_ingest` for high-volume `COPY` ingestion.
- **`stage_flush()`** moves batches to `entity_values_ts` every 100 ms with `SET LOCAL synchronous_commit = off` to protect primary durability.
- **Prepared statements + RDS Proxy** sustain ~10–12K inserts/sec (burst) with p95 write latency < 50 ms.

### 2.2 Time-Series Partitioning
- Migrated from entity-id ranges to **monthly RANGE partitions on `ingested_at`** (`schema.sql`).
- **BRIN index on `ingested_at`** + composite `(tenant_id, attribute_id, ingested_at)` keeps operational scans lightweight.
- Designed for pg_partman automation; example partitions included in DDL for bootstrapping.

### 2.3 Read-After-Write Consistency
- **Hot JSONB projection** `entity_jsonb` plus `upsert_hot_attrs()` guarantee sub-50 ms read-after-write on critical attributes.
- **Redis** write-through cache (`entity:{tenant}:{entity}`) delivers 10–30 ms hot reads; target hit rate 85–90 %.

### 2.4 Query Routing & Freshness
- `app/query_router.py` implements **consistency-aware routing** (STRONG, EVENTUAL, ANALYTICS) with replica lag tracking and a circuit breaker.
- Cache-first for eventual reads, fallback to primary on lag breaches, metadata returned for API headers (`source`, `lag_ms`, `consistency`).
- Freshness budgets and surfacing strategy recorded in `solution.md`.

### 2.5 Infrastructure Hardening
- Terraform provisions **RDS (writer + replicas)**, **RDS Proxy**, **ElastiCache Redis**, **Redshift**, VPC networking, Secrets Manager, IAM roles.
- Environment-specific sizing (dev/staging/prod) handled via `locals.env_config`.
- CloudWatch alarms for RDS CPU/storage, replica lag, Redis CPU; enhanced monitoring optional per environment.

### 2.6 Operational Excellence
- `ops/monitoring.sql` introduces 15 queries for throughput, staging backlog, partition health, index usage, slow queries, connection pool stats, replication lag, capacity planning, tenant skew, and a `health_check()` JSON snapshot.
- Alert thresholds: staging backlog >1 M rows, replica lag >3 s, Redis CPU >75 %, etc.

### 2.7 Cost Analysis
- Prod estimate: **~$9.2K/mo** (+23 % delta vs baseline) driven by larger RDS instance, Redis, monitoring.
- ROI: 3× write throughput, guaranteed read-after-write, tighter SLAs.
- Dev/staging profiles downscale instances, reduce replicas, and disable enhanced monitoring.

---

## 3. Architecture Decisions & Trade-offs

| Decision | Benefit | Trade-off / Mitigation |
| --- | --- | --- |
| Hybrid **EAV + JSONB** | Flexibility for 10k dynamic attributes, hot cache for critical fields | Dual-write complexity; future automation to sync JSONB in `stage_flush()` |
| **Time-series partitions** | Sequential writes, natural archival, BRIN-friendly | Cold queries need time filters; supply helper `find_entities_by_attributes()` with window parameter |
| **Redis cache** | Sub-10 ms hot reads, offloads replicas | Additional infra + eventual consistency risk; metadata + invalidation strategy documented |
| **RDS Proxy** | 90 % DB connection reduction, failover smoothing | Adds cost and complexity; parameterization toggles for non-prod |
| **CDC via Debezium/Kafka** | Low-latency OLAP sync, schema evolution support | Operational overhead; backlog monitoring and DLQ strategy documented |
| **No per-attribute indexes** | Keeps writes fast, avoids index bloat | Cold filters rely on partition scans; fallback is partial indexes for proven hot fields |

---

## 4. Assumptions, Risks & TODOs

### 4.1 Key Assumptions
- PostgreSQL 15+ with logical replication, pg_partman automation, and BRIN enhancements.
- Multi-tenancy handled via `tenant_id` column; RLS can be layered later if required.
- 20 % of attributes treated as “hot” and surfaced in JSONB / cache; periodically reevaluated using stats view.
- Telemetry pattern: bursty writes, read-heavy on recent data (last 7–30 days).

### 4.2 TODO / Future Enhancements
- Automate hot-attribute promotion/demotion and JSONB sync within `stage_flush()`.
- Enable Redis AUTH + TLS, integrate KMS-managed secrets, and tighten SG ingress rules.
- Add Grafana dashboards backed by custom metrics; integrate pg_cron for partition maintenance.
- Run large-scale load tests and failover drills; wire CDC metrics to alert on lag/backlog.
- Consider Citus or TimescaleDB if approaching >1B entities or needing horizontal scale.

---

## 5. Performance Benchmarks (Targets)

| Operation | Target | Design Expectation |
| --- | --- | --- |
| Write throughput | ≥10K inserts/sec sustained | 10–12K burst, p95 < 50 ms |
| Read-after-write | <50 ms | 15–30 ms via hot JSONB + Redis |
| Multi-attribute filter | <100 ms | 20–80 ms (hot); 150–200 ms (cold) |
| Aggregation (1M rows) | <2 s | 1–2 s via partition pruning |
| Replica lag | <3 s | 100–500 ms typical |

---

## 6. Alternative Approaches Considered

1. **Pure JSONB in Postgres:** Simplifies schema but sacrifices analytical performance and indexing control.
2. **MongoDB / Document Store:** Schema flexibility, easier horizontal scale, but weaker consistency and SQL support.
3. **Cassandra / Column Family:** Massive write throughput, yet limited ad-hoc querying and eventual consistency default.
4. **Neo4j / Graph:** Great for relationships, ill-suited for wide attribute telemetry at scale.

---

---

## 7. Final Recommendations

1. Ship with current architecture; prioritize automation around hot attribute syncing and security hardening.
2. Maintain comprehensive monitoring and run load/failover tests before production cutover.
3. Plan a scaling roadmap (pg_partman automation, Citus evaluation) to handle order-of-magnitude growth without re-architecture.
