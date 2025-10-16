# Follow-up Question Bank (Q&A)

Use this curated set of questions and answers to prepare for interviews, architecture reviews, or stakeholder conversations. References point to key files for deeper detail.

---

## Architecture & Data Modeling

### Why adopt a hybrid EAV + JSONB model instead of pure JSONB or wide tables?
- **Rationale:** Pure JSONB simplifies schema changes but hampers large-scale analytics—GIN indexes on massive JSONB documents remain heavy, and type fidelity is lost. A wide table explodes schema management and wastes space when thousands of attributes are sparse. The hybrid approach keeps core facts in typed EAV form (`schema.sql:86-190`) for efficient scans while denormalizing the top ~20 % “hot” fields into `entity_jsonb` for immediate filters. This balances flexibility, type safety, and query performance.

### How does the time-series partitioning scheme keep queries fast at 200M entities?
- **Mechanism:** `entity_values_ts` is partitioned by time (`ingested_at`), aligning with telemetry’s append-only pattern. BRIN indexes (`schema.sql:107`) exploit sequential inserts, and most operational queries filter on “recent” slices (last 7–30 days), so partition pruning drops 90 %+ of data early. Batch operations (archival, reindexing) become single-partition tasks.

### What guarantees read-after-write semantics for hot attributes?
- **Components:** Writes funnel through `WriteOptimizer.upsert_hot_attributes()` (`app/query_router.py:315-337`), invoking `upsert_hot_attrs()` (`schema.sql:126-140`) synchronously in the same transaction as the primary fact insert. Redis cache entries (`entity:{tenant}:{entity}`) are invalidated immediately. This gives 15–30 ms read-after-write for critical UI fields.

### How do you mitigate cold-attribute queries that fall outside the JSONB projection?
- **Approach:** Provide helper SQL (`find_entities_by_attributes`, `schema.sql:215-240`) with time windows to limit scans to recent partitions. Analytical queries use partition-pruned scans with joins to `attributes`. If a “cold” field becomes hot, either promote it into JSONB or add a partial index—documented in the trade-off plan.

### Describe the CQRS split between `entity_values_ingest`, `entity_values_ts`, and `entity_jsonb`.
- **Write Model:** High-volume telemetry lands in UNLOGGED staging (`entity_values_ingest`). `stage_flush()` batches into `entity_values_ts` partitions at 100 ms cadence.
- **Read Model:** `entity_jsonb` stores the latest hot attributes for instant reads; Redis caches aggregate results. This separation keeps OLTP writes lean while satisfying low-latency read paths.

---

## Performance & Scaling

### What is the end-to-end write path, and where are the throughput bottlenecks?
1. Application collects telemetry → `WriteOptimizer.ingest_telemetry()` builds a `COPY` payload (`app/query_router.py:271-309`).
2. Data enters `entity_values_ingest` (UNLOGGED) to avoid WAL pressure.
3. `stage_flush()` moves batches with `SET LOCAL synchronous_commit = off`, then deletes consumed staging rows (`schema.sql:142-174`).
4. Optional synchronous `upsert_hot_attrs()` keeps hot JSONB aligned.
5. Bottlenecks: network to RDS, `COPY` rate, and `stage_flush()` cadence. Monitoring (`ops/monitoring.sql`) alerts if staging backlog grows.

### How would you scale beyond 10K writes/sec or 200M entities?
- Increase flush frequency or parallelize `stage_flush()` workers.
- Partition by smaller windows (weekly/daily) and use pg_partman for automation.
- Introduce **Citus** for tenant-based sharding or **TimescaleDB** for time-series enhancements.
- Archive older partitions to cheaper storage (S3 via foreign tables).

### Which indexes are retained or dropped, and why?
- **Retained:** BRIN on `ingested_at`; composite `(tenant_id, attribute_id, ingested_at)` for fact lookups; GIN on `entity_jsonb.hot_attrs`.
- **Dropped:** Attribute-specific BTREE/partial indexes to avoid write amplification. Strategy is to add partials only for attributes proven hot over time.

### How do BRIN indexes, partition pruning, and Redis caching interact under load?
- BRIN reduces index maintenance; pruning ensures BRIN scans touch minimal blocks. Redis absorbs repetitive hot reads so replicas stay free for less cache-friendly queries. Together they balance IO, CPU, and cache pressure.

---

## Freshness, Replication, & Consistency

### Walk through the CDC pipeline from Postgres to Redshift and how lag is detected.
- WAL → logical decoding → Debezium connector → Kafka topics → stream processing (optional) → Redshift ingestion. Lag monitored via:
  - `replication_heartbeat` table comparisons (`ops/monitoring.sql`).
  - Kafka consumer offsets.
  - CloudWatch alarms on replication slots.

### What is the freshness budget for different query classes, and how is it surfaced?
- **Strong reads (critical UI):** primary DB / Redis (0–50 ms lag).
- **Eventual reads (lists/search):** replicas with ≤3 s lag.
- **Analytics:** Redshift with ≤5 min lag.
Metadata (headers `X-Data-Source`, `X-Data-Lag-Seconds`) is included in API responses (`solution.md` Part B).

### How does the circuit breaker protect against lagging replicas?
- `QueryRouter.execute_query()` tracks consecutive failures (`app/query_router.py:189-240`). After 5 replica errors, it routes to primary and resets. Lag data from heartbeat table prevents selecting replicas above the threshold.

### What reconciliation or drift-detection steps exist between OLTP and OLAP?
- Periodic queries compare counts/checksums per tenant between Postgres and Redshift.
- CDC consumers log dead-letter events; replayable via Kafka retention.
- Reconciliation jobs flagged in `notes.md` TODOs for production hardening.

---

## Reliability & Operations

### How do you monitor staging backlog, partition health, and query latency?
- `ops/monitoring.sql` provides:
  - Staging backlog counts and oldest timestamp.
  - Partition size/dead tuples (`pg_stat_user_tables`).
  - `pg_stat_statements` for slow queries.
Run via scheduled jobs or dashboards (Grafana/CloudWatch).

### What alarms exist for RDS, Redis, and replica lag? Where would you add more?
- Terraform defines CloudWatch alarms (`infra/main.tf:601-665`) for RDS CPU/storage, replica lag, Redis CPU. Next steps: add SNS notifications, alarms for stage backlog, Kafka lag, and CDC consumer failures.

### Outline the disaster recovery plan (RPO/RTO) and cross-region strategy.
- Snapshots + PITR provide RPO ≈ 1 hour, RTO ≈ 30 minutes (`notes.md` §4).
- Multi-AZ ensures local HA; cross-region read replicas + snapshot replication serve DR scenarios. Regular failover drills planned.

### How do you manage tenant isolation today, and what would RLS buy you?
- Tenant isolation enforced via `tenant_id` column and application scoping. RLS is a future enhancement to push enforcement into Postgres; TODO captured in `notes.md`.

---

## Security & Compliance

### What controls are in place for secrets management and encryption?
- Secrets stored in AWS Secrets Manager (`infra/main.tf`), TLS enabled for RDS/Redis, storage encrypted at rest. Next steps: integrate KMS for key rotation, enforce Redis AUTH.

### How do you address GDPR/PII obligations within this architecture?
- Soft delete flags + crypto-shredding approach; audit logging; region-specific deployments for data residency; potential column-level encryption for PII (documented in `notes.md` Q&A).

### What are the next security hardening steps (KMS, Redis AUTH, VPC tightening)?
- Enable Redis AUTH + TLS, adopt customer-managed KMS keys, restrict security group ingress, add RLS, integrate Vault for secret leasing. These sit in the TODO roadmap.

---

## Cost & Trade-offs

### Explain the +23 % monthly cost increase and why it is justified.
- Added Redis, RDS Proxy, larger RDS writer, enhanced monitoring—totals ≈$9.2K/month. Gains: 3× write throughput, consistent read-after-write, replica resilience. ROI justified for production SLAs.

### Where could you downshift resources in dev/staging without harming prod?
- Use smaller instance classes, reduce replica count, disable enhanced monitoring, leverage spot for stateless components. Terraform `env_config` already captures these variations.

### What are the main trade-offs of the dual-write model, and how would you de-risk it?
- Complexity: staging + hot projection syncing. Mitigations: ensure transactional upsert for critical fields, monitor for divergence, plan automation for hot JSONB updates in `stage_flush()`, add integration tests.

---

## Future Roadmap

### When do you introduce Citus or TimescaleDB, and what triggers that decision?
- If data volume nears >1B rows, tenants demand cross-partition joins, or write headroom falls below 20 %, consider Citus (tenant sharding) or TimescaleDB (hypertables) to scale horizontally.

### How would you automate promotion/demotion of hot attributes?
- Collect access stats via `pg_stat_statements`, maintain a percentile threshold, and update `attributes.is_hot`. Automation could replay changes through `upsert_hot_attrs()` or rebuild JSONB snapshots.

### What additional automation (pg_cron, Grafana dashboards) is on the TODO list?
- pg_cron for `stage_flush()`, partition maintenance, and analytics rollups; Grafana dashboards for throughput/lag; CI/CD pipeline for schema migrations; automated backup restore tests. All listed in `notes.md` §4.2.

---

Keep this Q&A alongside `notes.md` for detailed context and `solution.md` for the narrative overview. Adjust the answers with real metrics if you run load tests in your environment.
