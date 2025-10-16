# Implementation Notes & Follow-up Questions

## Implementation Assumptions

1. **PostgreSQL Version**: Assumed PostgreSQL 15+ for optimal partitioning performance
2. **Multi-tenancy**: Implemented row-level tenant isolation for flexibility
3. **Hot/Cold Data**: Assumed 20% of attributes are "hot" (frequently accessed)
4. **Replication**: Used logical replication for flexibility over physical streaming
5. **AWS Region**: Default us-east-1, but configurable via Terraform variables
6. **Security**: Assumed VPC isolation with private subnets for databases

## TODOs with More Time

1. **Performance Optimizations**
   - Implement pg_cron for automated partition maintenance
   - Add columnar storage extension (cstore_fdw) for cold data
   - Implement query result caching with Redis

2. **Monitoring & Observability**
   - Add Datadog/New Relic APM integration
   - Create Grafana dashboards for key metrics
   - Implement custom PostgreSQL exporter for Prometheus

3. **Security Enhancements**
   - Implement row-level security (RLS) policies
   - Add HashiCorp Vault for secrets management
   - Enable AWS KMS for encryption key rotation

4. **Automation**
   - CI/CD pipeline for schema migrations (Flyway/Liquibase)
   - Automated backup testing and restoration drills
   - Blue/green deployment for zero-downtime upgrades

## Potential Follow-up Questions & Answers

### 1. **Why did you choose EAV over JSONB-only approach?**
**Answer**: Hybrid approach balances flexibility with performance. Pure JSONB would be simpler but lacks:
- Efficient indexing on individual attributes
- Type safety and validation
- Optimal storage for sparse data
- Query performance at scale

The EAV+JSONB hybrid gives us the best of both worlds.

### 2. **How would you handle attribute type changes?**
**Answer**: 
- Store multiple typed columns (value_int, value_decimal, etc.)
- Use a migration strategy with versioning
- Keep old values temporarily during transition
- Implement a type coercion layer in the application
- Log all type changes for audit trail

### 3. **What's your partitioning strategy and why range over hash?**
**Answer**: Range partitioning on entity_id provides:
- Predictable data distribution
- Efficient bulk operations (DELETE old partitions)
- Better cache locality for sequential entity IDs
- Easier partition maintenance

Hash would give more even distribution but complicates maintenance.

### 4. **How do you prevent the N+1 query problem in EAV?**
**Answer**:
- Batch fetch entities with their attributes
- Use CTEs to aggregate attributes per entity
- Implement application-level caching
- Denormalize hot attributes into JSONB
- Use materialized views for common access patterns

### 5. **How would you scale beyond 200M entities?**
**Answer**:
- **Horizontal sharding** with Citus extension
- **Federation** by tenant or entity type
- **Archive strategy** for old data to S3/Glacier
- **Read replicas** across regions
- Consider migration to specialized databases (Cassandra for write-heavy)

### 6. **Explain your CDC (Change Data Capture) choice**
**Answer**: Debezium provides:
- Low-latency streaming (sub-second)
- Exactly-once semantics with Kafka
- Schema evolution support
- Wide ecosystem integration
- Battle-tested at scale

Alternatives considered: AWS DMS (vendor lock-in), custom triggers (performance overhead)

### 7. **How do you handle schema evolution?**
**Answer**:
- Attributes table allows dynamic addition
- Backward-compatible changes only
- Version field in entities table
- Blue/green deployments for breaking changes
- Event sourcing pattern for full history

### 8. **What about GDPR/data privacy compliance?**
**Answer**:
- Implement logical deletion with is_deleted flag
- Crypto-shredding for permanent deletion
- Audit logs for all data access
- Data residency via region-specific deployments
- PII encryption at column level

### 9. **Cost optimization strategies?**
**Answer**:
- Reserved Instances (40-60% savings)
- Spot instances for dev/test
- S3 archival for cold data
- Compression (TOAST, gzip)
- Right-sizing based on CloudWatch metrics
- Partition pruning to reduce scan costs

### 10. **How do you ensure consistency between OLTP and OLAP?**
**Answer**:
- Eventual consistency with documented SLAs
- Heartbeat monitoring for lag detection
- Reconciliation jobs for critical data
- Idempotent CDC processing
- Dead letter queues for failed events

### 11. **What's your disaster recovery plan?**
**Answer**:
- **RPO**: 1 hour (hourly snapshots)
- **RTO**: 30 minutes (automated failover)
- Cross-region backups
- Point-in-time recovery capability
- Runbook documentation
- Regular DR drills

### 12. **How do you handle hot partitions?**
**Answer**:
- Monitor with pg_stat_user_tables
- Sub-partitioning for hot partitions
- Application-level sharding key
- Caching layer (Redis) for hot data
- Read replica routing for hot queries

### 13. **Query optimization techniques for EAV?**
**Answer**:
- Covering indexes for common queries
- Parallel query execution (max_parallel_workers)
- JIT compilation for complex queries
- Statistics optimization (increase default_statistics_target)
- Query rewriting with CTEs

### 14. **Why PostgreSQL over other databases?**
**Answer**:
- Native partitioning support
- JSONB for semi-structured data
- Robust extension ecosystem
- ACID compliance
- Logical replication
- Cost-effective at scale
- Strong community support

### 15. **How would you implement full-text search?**
**Answer**:
- PostgreSQL native FTS for simple cases
- Elasticsearch sidecar for advanced search
- Sync via CDC pipeline
- Denormalized search indices
- Consider pg_search or ZomboDB extensions

## Performance Benchmarks (Expected)

| Operation | Target Latency | At Scale (200M) |
|-----------|---------------|-----------------|
| Single entity lookup | <10ms | <20ms |
| Multi-attribute filter | <100ms | <200ms |
| Aggregation (1M rows) | <1s | <2s |
| Bulk insert (1000 rows) | <100ms | <150ms |
| Replication lag | <1s | <3s |

## Alternative Approaches Considered

1. **Document Store (MongoDB)**
   - Pros: Flexible schema, horizontal scaling
   - Cons: Weaker consistency, limited SQL support

2. **Column Family (Cassandra)**
   - Pros: Linear scalability, high write throughput
   - Cons: Limited query flexibility, eventual consistency

3. **Graph Database (Neo4j)**
   - Pros: Rich relationship queries
   - Cons: Not optimized for EAV pattern, expensive at scale

4. **Pure JSONB in PostgreSQL**
   - Pros: Simpler implementation
   - Cons: Poor performance for analytical queries

## Final Recommendations

1. Start with the proposed solution and iterate
2. Implement comprehensive monitoring from day 1
3. Plan for 3x growth in data volume
4. Regular performance testing with production-like data
5. Consider Citus or migration path early if expecting >1B entities