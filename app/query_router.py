"""
Query Router for EAV Platform
Implements intelligent routing between primary, replicas, cache, and OLAP based on freshness requirements
"""

import enum
import io
import json
import time
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple

import redis
from psycopg2 import pool


class DataSource(enum.Enum):
    PRIMARY = "primary"
    REPLICA = "replica"
    REDIS = "redis"
    REDSHIFT = "redshift"


class ConsistencyLevel(enum.Enum):
    STRONG = "strong"  # Primary only, immediate
    EVENTUAL = "eventual"  # Replicas OK, <3s lag
    ANALYTICS = "analytics"  # Redshift, <5min lag


@dataclass
class QueryMetadata:
    source: DataSource
    lag_ms: int
    sampled_at: float
    consistency: ConsistencyLevel


class DatabasePool:
    """Manages connection pools to all database endpoints"""

    def __init__(self, config: Dict[str, Any]):
        self.primary_pool = pool.ThreadedConnectionPool(
            minconn=10,
            maxconn=50,
            host=config["primary_host"],
            database=config["database"],
            user=config["user"],
            password=config["password"],
        )

        self.replica_pools = [
            pool.ThreadedConnectionPool(
                minconn=5,
                maxconn=20,
                host=replica_host,
                database=config["database"],
                user=config["user"],
                password=config["password"],
            )
            for replica_host in config.get("replica_hosts", [])
        ]

        self.redis_client = redis.Redis(
            host=config["redis_host"],
            port=6379,
            decode_responses=True,
            socket_connect_timeout=1,
            socket_timeout=1,
        )

        # Track replica lag
        self._replica_lag = [0] * len(self.replica_pools)
        self._last_lag_check = [0.0] * len(self.replica_pools)

    def get_primary_conn(self):
        return self.primary_pool.getconn()

    def get_replica_conn(
        self, max_lag_ms: int = 3000
    ) -> Tuple[Any, DataSource, int, int]:
        """Get connection to least-lagged replica under threshold

        Returns: (connection, source, replica_index, lag_ms)
        """
        healthy_replicas = [
            (i, lag) for i, lag in enumerate(self._replica_lag) if lag <= max_lag_ms
        ]

        if not healthy_replicas:
            # Fall back to primary if all replicas lagging
            return self.get_primary_conn(), DataSource.PRIMARY, -1, 0

        # Pick least-lagged replica
        idx, lag = min(healthy_replicas, key=lambda x: x[1])
        return self.replica_pools[idx].getconn(), DataSource.REPLICA, idx, lag

    def check_replica_lag(self):
        """Update replica lag metrics from heartbeat table"""
        primary_conn = self.get_primary_conn()
        try:
            with primary_conn.cursor() as cur:
                cur.execute(
                    "SELECT EXTRACT(EPOCH FROM NOW() AT TIME ZONE 'UTC') * 1000"
                )
                primary_ts = cur.fetchone()[0]

            for i, replica_pool in enumerate(self.replica_pools):
                try:
                    replica_conn = replica_pool.getconn()
                    with replica_conn.cursor() as cur:
                        cur.execute("""
                            SELECT EXTRACT(EPOCH FROM timestamp AT TIME ZONE 'UTC') * 1000
                            FROM replication_heartbeat
                            WHERE source = 'primary'
                            ORDER BY timestamp DESC
                            LIMIT 1
                        """)
                        result = cur.fetchone()
                        if result:
                            replica_ts = result[0]
                            self._replica_lag[i] = int(primary_ts - replica_ts)
                    replica_pool.putconn(replica_conn)
                except Exception as e:
                    print(f"Replica {i} lag check failed: {e}")
                    self._replica_lag[i] = 999999  # Mark as unavailable
        finally:
            self.primary_pool.putconn(primary_conn)


class QueryRouter:
    """Routes queries to appropriate backend based on consistency requirements"""

    def __init__(self, db_pool: DatabasePool):
        self.db_pool = db_pool
        self._circuit_breaker_failures = 0
        self._circuit_breaker_threshold = 5

    def execute_query(
        self,
        query: str,
        params: tuple,
        consistency: ConsistencyLevel = ConsistencyLevel.EVENTUAL,
        cache_key: Optional[str] = None,
        cache_ttl: int = 60,
    ) -> tuple[List[tuple], QueryMetadata]:
        """
        Execute query with appropriate consistency level

        Args:
            query: SQL query
            params: Query parameters
            consistency: Required consistency level
            cache_key: Optional Redis cache key
            cache_ttl: Cache TTL in seconds

        Returns:
            (results, metadata)
        """
        # Try cache first for eventual reads
        if cache_key and consistency == ConsistencyLevel.EVENTUAL:
            cached = self._get_from_cache(cache_key)
            if cached is not None:
                return cached, QueryMetadata(
                    source=DataSource.REDIS,
                    lag_ms=0,
                    sampled_at=time.time(),
                    consistency=consistency,
                )

        # Route based on consistency - track replica index
        replica_idx = -1
        if consistency == ConsistencyLevel.STRONG:
            conn = self.db_pool.get_primary_conn()
            source = DataSource.PRIMARY
            lag_ms = 0

        elif consistency == ConsistencyLevel.EVENTUAL:
            # Try replica, fall back to primary if unhealthy
            conn, source, replica_idx, lag_ms = self.db_pool.get_replica_conn(
                max_lag_ms=3000
            )

        else:  # ANALYTICS
            # Would route to Redshift here
            conn = self.db_pool.get_primary_conn()
            source = DataSource.PRIMARY
            lag_ms = 0

        try:
            with conn.cursor() as cur:
                cur.execute(query, params)
                results = cur.fetchall()

            # FIXED: Reset circuit breaker on success
            self._circuit_breaker_failures = 0

            # Cache result if requested
            if cache_key and consistency == ConsistencyLevel.EVENTUAL:
                self._set_to_cache(cache_key, results, cache_ttl)

            metadata = QueryMetadata(
                source=source,
                lag_ms=lag_ms,
                sampled_at=time.time(),
                consistency=consistency,
            )

            return results, metadata

        except Exception:
            self._circuit_breaker_failures += 1
            if self._circuit_breaker_failures >= self._circuit_breaker_threshold:
                print("Circuit breaker open, routing to primary")
                # Return original connection first
                if source == DataSource.PRIMARY:
                    self.db_pool.primary_pool.putconn(conn)
                elif replica_idx >= 0:
                    self.db_pool.replica_pools[replica_idx].putconn(conn)

                # Circuit breaker: route to primary
                conn = self.db_pool.get_primary_conn()
                source = DataSource.PRIMARY
                replica_idx = -1

                with conn.cursor() as cur:
                    cur.execute(query, params)
                    results = cur.fetchall()

                # FIXED: Reset counter after successful fallback
                self._circuit_breaker_failures = 0

                metadata = QueryMetadata(
                    source=DataSource.PRIMARY,
                    lag_ms=0,
                    sampled_at=time.time(),
                    consistency=ConsistencyLevel.STRONG,
                )
                return results, metadata
            else:
                raise
        finally:
            # Return connection to correct pool
            if source == DataSource.PRIMARY:
                self.db_pool.primary_pool.putconn(conn)
            elif replica_idx >= 0:
                self.db_pool.replica_pools[replica_idx].putconn(conn)

    def _get_from_cache(self, key: str) -> Optional[List[tuple]]:
        """Retrieve from Redis cache"""
        try:
            cached = self.db_pool.redis_client.get(key)
            if cached:
                return json.loads(cached)
        except Exception as e:
            print(f"Cache get failed: {e}")
        return None

    def _set_to_cache(self, key: str, value: List[tuple], ttl: int):
        """Store in Redis cache"""
        try:
            self.db_pool.redis_client.setex(key, ttl, json.dumps(value, default=str))
        except Exception as e:
            print(f"Cache set failed: {e}")


class WriteOptimizer:
    """Optimizes writes for high throughput"""

    def __init__(self, db_pool: DatabasePool):
        self.db_pool = db_pool
        self._batch_buffer = []
        self._batch_size = 1000
        self._flush_interval = 0.1  # 100ms
        self._last_flush = time.time()

    def ingest_telemetry(self, events: List[Dict[str, Any]]):
        """
        Batch ingest telemetry events

        Uses UNLOGGED staging table + COPY for maximum throughput
        """
        conn = self.db_pool.get_primary_conn()
        try:
            # Use COPY for bulk insert
            with conn.cursor() as cur:
                # FIXED: Prepare CSV data as file-like object (io.StringIO)
                csv_lines = []
                for e in events:
                    csv_lines.append(
                        f"{e['entity_id']}\t{e['tenant_id']}\t{e['attribute_id']}\t"
                        f"{e.get('value', '')}\t{e.get('value_int', '')}\t"
                        f"{e.get('value_decimal', '')}\t{e.get('ingested_at', '')}"
                    )
                csv_data = io.StringIO("\n".join(csv_lines))

                # COPY into staging
                cur.copy_from(
                    file=csv_data,
                    table="entity_values_ingest",
                    columns=(
                        "entity_id",
                        "tenant_id",
                        "attribute_id",
                        "value",
                        "value_int",
                        "value_decimal",
                        "ingested_at",
                    ),
                )

                # Async flush from staging to partitions
                if time.time() - self._last_flush > self._flush_interval:
                    cur.execute("SELECT stage_flush(50000)")
                    self._last_flush = time.time()

            conn.commit()
        finally:
            self.db_pool.primary_pool.putconn(conn)

    def upsert_hot_attributes(
        self, tenant_id: int, entity_id: int, attributes: Dict[str, Any]
    ):
        """
        Synchronously upsert hot attributes for immediate read-after-write
        Also invalidate Redis cache
        """
        conn = self.db_pool.get_primary_conn()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT upsert_hot_attrs(%s, %s, %s)",
                    (tenant_id, entity_id, json.dumps(attributes)),
                )
            conn.commit()

            # Invalidate cache
            cache_key = f"entity:{tenant_id}:{entity_id}"
            try:
                self.db_pool.redis_client.delete(cache_key)
            except:
                pass
        finally:
            self.db_pool.primary_pool.putconn(conn)


# Example usage
if __name__ == "__main__":
    config = {
        "primary_host": "eav-prod-postgres.xyz.rds.amazonaws.com",
        "replica_hosts": [
            "eav-prod-replica-1.xyz.rds.amazonaws.com",
            "eav-prod-replica-2.xyz.rds.amazonaws.com",
        ],
        "redis_host": "eav-prod-redis.xyz.cache.amazonaws.com",
        "database": "eav_db",
        "user": "eav_admin",
        "password": "***",
    }

    db_pool = DatabasePool(config)
    router = QueryRouter(db_pool)
    writer = WriteOptimizer(db_pool)

    # Operational query (strong consistency)
    results, metadata = router.execute_query(
        """
        SELECT e.entity_id, ej.hot_attrs
        FROM entities e
        JOIN entity_jsonb ej USING (entity_id, tenant_id)
        WHERE e.tenant_id = %s
          AND ej.hot_attrs->>'status' = %s
        LIMIT 100
        """,
        (123, "active"),
        consistency=ConsistencyLevel.STRONG,
    )

    print(f"Query executed on {metadata.source.value} with {metadata.lag_ms}ms lag")

    # Ingest telemetry
    events = [
        {
            "entity_id": 1001,
            "tenant_id": 123,
            "attribute_id": 42,
            "value": "online",
            "value_int": None,
            "ingested_at": "2025-10-16 12:00:00",
        }
        # ... more events
    ]
    writer.ingest_telemetry(events)
