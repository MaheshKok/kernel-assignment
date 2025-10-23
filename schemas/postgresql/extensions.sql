-- ============================================================================
-- EXTENSIONS
-- ============================================================================
-- PostgreSQL extensions required for EAV schema
-- Run this first before creating any tables
-- ============================================================================
CREATE EXTENSION IF NOT EXISTS pg_partman;

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

CREATE EXTENSION IF NOT EXISTS btree_gin;

