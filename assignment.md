# AtlasCo Telemetry Architecture Assignment

## 1. Context
- AtlasCo ingests millions of telemetry events for enterprise customers.
- Each asset can expose up to 10,000 dynamic attributes (firmware flags, counters, tags).
- Users expect immediate read-after-write for critical UI actions; analytics jobs run on a separate OLAP stack.
- You have 2 hours to craft a pragmatic solution. Favor clear trade-offs and call out explicit TODOs where you trim scope.

## 2. Objectives
Design an approach that can:
- Sustain ~10k OLTP inserts per second.
- Serve immediate reads for user-visible flows.
- Support ad-hoc filtering across thousands of attributes.
- Replicate data into an analytics warehouse with clear freshness guarantees.
- Capture the core in Infrastructure as Code (Terraform or Pulumi).

## 3. Timebox & Recommended Split
| Phase | Focus | Suggested Time |
| --- | --- | --- |
| Part A | EAV data model & querying in Postgres | 55–65 min |
| Part B | Freshness, replication, and lag handling | 30–35 min |
| Part C | Terraform/Pulumi snippet | 20–25 min |
| Buffer | Polish & packaging | 5–10 min |

## 4. What to Build

### Part A — Data Model & Querying (Postgres, EAV at Scale)
Design an Entity–Attribute–Value schema that can support:
- 200M entities.
- ~10,000 dynamic attribute types (not known upfront).

**Constraints**
- Operational queries must filter on arbitrary attributes with low latency.
- Analytical queries must aggregate/scan large slices efficiently.
- No per-attribute indexes created in advance.
- Stay within Postgres and its ecosystem (extensions are fine).

**Deliverables**
Create a short design note (~1 page) that covers:
1. Logical schema (core tables, keys, data types).
2. Partitioning and/or sharding approach and how it keeps queries fast at 200M entities.
3. Two example SQL queries:
   - Operational: multi-attribute filter.
   - Analytical: aggregation or distribution.
4. Trade-offs: where the design excels, where it degrades, and fallback options if scale breaks.

### Part B — Read Freshness & Replication
- Separate OLTP (Postgres) from OLAP (e.g., Redshift, ClickHouse).
- Sketch the replication flow (logical decoding → Debezium/Kafka → OLAP or equivalent).
- Provide a freshness budget matrix that maps read paths (writer, near-zero-lag replica, OLAP) to tolerable lag.
- Explain how the application surfaces freshness (headers, metadata, UI messaging).
- Include a small ASCII diagram showing the flow and how lag is detected/handled.

### Part C — Infrastructure as Code (Terraform or Pulumi)
Author a concise snippet that:
- Provisions AWS Postgres (RDS or Aurora).
- Provisions a Redshift cluster.
- Creates a VPC plus security groups that allow connectivity between them.
- Demonstrates environment parameterization (e.g., dev vs. prod instance sizes). Pseudocode for module imports is acceptable.

## 5. Deliverables Checklist
- `solution.md` (or PDF): design narrative, diagrams, trade-offs, freshness matrix.
- `schema.sql`: Postgres DDL and example queries.
- `infra/` directory with `main.tf` or Pulumi file.
- Optional: `notes.md` for TODOs, assumptions, follow-ups.

## 6. Constraints & Hints
- Multi-tenancy is required—justify your isolation strategy (schema-per-tenant, row-level key, shard key, etc.).
- Differentiate hot vs. cold attributes in your approach.
- Consider index cardinality plus VACUUM/REINDEX costs at this scale.
- For OLAP, specify where eventual consistency is acceptable and how you avoid confusing users.
- Keep IaC readable; prove structure and parameterization without enumerating every AWS knob.

## 7. Evaluation Criteria
- **Pragmatism:** Will it run in production and evolve sanely?
- **Depth:** Mastery of Postgres internals, indexing, replication, queueing.
- **Communication:** Clear trade-offs, diagrams, explicit limits.
- **Operational Thinking:** Observability, failure modes, cost awareness.
- **IaC Discipline:** Reusable, parameterized, auditable patterns.

## 8. Submission
Share either a GitHub/GitLab repository link or a ZIP that includes all required files.
