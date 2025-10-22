# Architecture Decisions – Comprehensive Q&A

This guide captures the rationale behind every major decision made while designing the AtlasCo telemetry platform. Use it to internalize the architecture, justify trade-offs, and answer deep-dive questions with confidence.

---

## 1. Data Model & Schema

### Q1. Why did we choose an EAV schema instead of a traditional wide table?
**A:** Each asset can expose up to 10,000 attributes that change frequently. A fixed wide table would be sparse, require constant DDL, and break backwards compatibility. The EAV model keeps the core facts lean (`entity_values_ts` with typed columns) and supports dynamic attribute addition without schema churn.

### Q2. Why store “hot” attributes separately in `entity_jsonb`?
**A:** Critical UI actions need sub-50 ms reads. Fetching dozens of attributes by joining EAV rows is expensive. `entity_jsonb` denormalizes the latest values for the hottest 20 % fields so we can answer filters like “status=online” instantly while keeping the flexible EAV backend for the long tail.

### Q3. Why partition `entity_values_ts` by `ingested_at` rather than `entity_id`?
**A:** Writes are append-only and time-correlated. Time partitions give sequential inserts, natural pruning (e.g., “last 7 days”), simpler archival, and BRIN-friendly indexes. Entity-based ranges spread writes across partitions, causing random I/O and complicated retention policies.

### Q4. How do we keep type safety if values are stored as EAV rows?
**A:** `entity_values_ts` includes typed columns (`value_int`, `value_decimal`, etc.). Only one is populated per row, preserving type fidelity. The `attributes` table holds metadata (`data_type`, validation regex) so application layers can validate inputs before writes.

### Q5. Why not rely solely on JSONB with GIN indexes?
**A:** GIN indexes on very large JSON documents incur heavy maintenance and storage costs, especially with high write throughput. JSONB also loses type information. By limiting JSONB to hot fields and keeping the rest in EAV, we maintain performance and type correctness.

---

## 2. Write Path & Throughput

### Q6. How does the write pipeline achieve ~10K inserts/sec?
**A:** Writes enter the UNLOGGED staging table via `COPY` (`WriteOptimizer.ingest_telemetry`). `stage_flush()` batches rows into the partitioned table every 100 ms with `SET LOCAL synchronous_commit = off` to reduce WAL pressure. Prepared statements and RDS Proxy minimise connection overhead. This pipeline keeps log writes sequential and amortizes flush cost.

### Q7. Why is the staging table UNLOGGED, and how do we handle crashes?
**A:** UNLOGGED tables skip WAL, dramatically increasing ingest throughput. In a crash we lose in-flight staging data, but telemetry sources can replay via Kafka/SQS buffers. Monitoring alerts if staging backlog grows so we can react before exceeding SLA.

### Q8. How are hot attributes synchronized during writes?
**A:** For critical fields, the same transaction calls `upsert_hot_attrs()` to update `entity_jsonb`. Redis cache entries are invalidated immediately. This ensures write-after-read consistency without waiting for asynchronous jobs.

### Q9. What happens if `stage_flush()` can’t keep up?
**A:** The staging health query (ops/monitoring.sql) monitors backlog size and oldest event age. Alerts trigger scaling actions: increase flush frequency, parallelize flush workers, or scale the DB instance. Because staging is UNLOGGED, it can temporarily buffer spikes without backpressure on the primary table.

---

## 3. Read Path & Freshness

### Q10. How are consistency levels enforced for reads?
**A:** `QueryRouter.execute_query` accepts `STRONG`, `EVENTUAL`, or `ANALYTICS`. STRONG hits the primary (or Redis if already populated). EVENTUAL picks the least-lagged replica under 3 s; if all replicas exceed the threshold, it falls back to primary via a circuit breaker. ANALYTICS routes to Redshift (placeholder for the demo). Metadata (`source`, `lag_ms`, `consistency`) returns with each query to power API headers and telemetry.

### Q11. How do we guarantee read-after-write for critical actions?
**A:** The combo of synchronous JSONB upserts and Redis invalidation ensures that once the write transaction commits, hot fields are immediately visible via primary/Redis. STRONG reads (critical UI) are wired to the primary, bypassing laggy replicas.

### Q12. What controls prevent stale replica reads?
**A:** Replica lag is tracked via the `replication_heartbeat` table. `QueryRouter.get_replica_conn` only returns replicas whose lag is under the threshold. Circuit breaker logic reroutes to primary after five consecutive errors, preventing persistent stale reads.

---

## 4. Caching & Hot/Cold Strategy

### Q13. Why bring in Redis at all?
**A:** Hot attribute reads dominate traffic (dashboards, status checks). Redis caches hot entities (`entity:{tenant}:{entity}`) for sub-10 ms access, offloading both primaries and replicas. Without Redis, replicas would bear all dashboard load, risking lag spikes.

### Q14. How are cache entries invalidated?
**A:** `upsert_hot_attributes()` deletes the relevant Redis key after updating Postgres. For derived aggregates, TTL-based invalidation (60 s for lists, 300 s for entity lookups) balances freshness with cache churn.

### Q15. How do we handle attributes that move between hot and cold classifications?
**A:** Monitoring views record attribute access frequency. Operators can toggle the `attributes.is_hot` flag and update JSONB projections. Future automation (TODO) will promote/demote attributes based on rolling percentiles.

---

## 5. Replication & Analytics

### Q16. What replication pattern feeds Redshift?
**A:** Logical decoding streams WAL changes into Debezium, then Kafka topics. Stream processors (Flink/Spark) can enrich data before loading into Redshift. This design supports near real-time analytics with schema evolution and replay capabilities.

### Q17. How is lag surfaced and handled?
**A:** Freshness budgets define acceptable lag per workload (primary ≈0 ms, replica ≤3 s, Redshift ≤5 min). API responses include `X-Data-Lag-Seconds` and `X-Data-Source`. When lag exceeds thresholds, circuit breakers reroute traffic, UI banners warn users, and CloudWatch alarms page operators.

### Q18. How do we reconcile data between OLTP and OLAP?
**A:** Scheduled jobs compare counts/checksums per tenant. CDC consumers write to Dead Letter Queues on failure. Reconciliation jobs reprocess DLQs and report discrepancies so OLAP copies track OLTP with explicit SLAs.

---

## 6. Infrastructure & Environment Strategy

### Q19. Why go all-in on Terraform?
**A:** Infrastructure is part of the deliverable. Terraform codifies VPC, subnets, RDS, Redis, Redshift, IAM roles, Secrets Manager, and CloudWatch alarms—ensuring reproducible environments. Environment-specific sizing (dev/staging/prod) lives in `locals.env_config`.

### Q20. Why provision RDS Proxy and ElastiCache (vs. simpler stacks)?
**A:** AtlasCo expects thousands of concurrent clients. RDS Proxy reduces direct connections by ~90 %, smoothing failovers. ElastiCache is essential for sub-10 ms reads and decoupling read workloads from Postgres. Both upgrades were needed to hit performance targets.

### Q21. How do we handle secrets and encryption?
**A:** DB credentials live in Secrets Manager; RDS/Redshift/Redis are encrypted at rest and in transit. Future hardening (TODO) includes customer-managed KMS keys, Redis AUTH, and Vault integration for short-lived credentials.

### Q22. What’s the elasticity story?
**A:** Terraform parameterizes instance classes and replica counts. Auto-scaling hooks (e.g., read replicas) can be added later. Partitioning strategy and staging buffers absorb short-term spikes; horizontal scale (Citus, Timescale) is the roadmap if growth outpaces a single cluster.

---

## 7. Monitoring, Operations & Reliability

### Q23. How do we monitor write health and staging backlog?
**A:** `ops/monitoring.sql` exposes staging row counts, oldest event age, and table size. CloudWatch alarms trigger when backlog >1 M rows or when lag >3 s. Operators can add Grafana dashboards atop these queries.

### Q24. What is the disaster recovery plan?
**A:** RPO ≈1 hour via automated snapshots, RTO ≈30 minutes with Multi-AZ failover. Cross-region snapshots and read replicas support regional DR. Runbooks outline failover steps and restoration drills.

### Q25. How are tenant isolation and security enforced?
**A:** Tenant scoping uses `tenant_id` at every layer. Application logic ensures per-tenant filters; future enhancement is enabling Postgres RLS for defense in depth. All data flows through VPC-private subnets with restricted security groups.

---

## 8. Cost & Trade-offs

### Q26. What drove the 23 % cost increase, and why is it acceptable?
**A:** Larger RDS writer instance, additional replicas, RDS Proxy, Redis, and enhanced monitoring add ~$1.7K/month (prod). In return we get 3× write throughput, consistent read-after-write, and better observability—critical for AtlasCo’s SLOs.

### Q27. Where can we trim costs in lower environments?
**A:** Dev/staging use smaller instance classes, fewer replicas, and disabled enhanced monitoring. Read replicas and Redis clusters can scale down, or be replaced with spot instances for ephemeral testing.

### Q28. What are the biggest trade-offs of this design?
**A:** Dual-write complexity (EAV + JSONB) and operational overhead (CDC, Redis) increase maintenance. These are mitigated with clear runbooks, monitoring, and future automation. Cold attribute queries are slower but acceptable given business priorities; partial indexes are a fallback.

---

## 9. Roadmap & Future Enhancements

### Q29. When should we consider Citus or TimescaleDB?
**A:** If entity counts exceed ~1B or per-tenant data exceeds single-node limits, Citus enables tenant sharding and distributed parallelism. TimescaleDB is an option if time-series analytics become dominant. Early planning prevents painful retrofits.

### Q30. What automation is planned next?
**A:** Automate partition maintenance (pg_partman + pg_cron), build Grafana dashboards, automate hot attribute promotion, add load/failover tests to CI/CD, and incorporate RLS & Vault for security. These tasks are tracked in `notes.md`.

### Q31. How do we keep the architecture adaptable?
**A:** By treating “hot vs. cold” as a sliding scale, using metadata-driven toggles, and building on Postgres extensions, we avoid lock-in. Clear documentation (`solution.md`, `notes.md`, this Q&A) ensures new team members can evolve the system without guesswork.

---

### Final Note
Use this document alongside `notes.md`, `solution.md`, and `assignment.md` when preparing for interviews or deep dives. It ties implementation choices to business requirements and highlights where further investment yields the biggest payoff. Good luck! 🛠️📈
