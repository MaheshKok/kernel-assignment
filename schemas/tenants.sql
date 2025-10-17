-- ============================================================================
-- TENANTS TABLE
-- ============================================================================
-- Multi-tenant isolation table
-- Each tenant gets isolated data across all other tables
-- ============================================================================
CREATE TABLE tenants(
    tenant_id bigint PRIMARY KEY,
    tenant_name varchar(255) NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    is_active boolean DEFAULT TRUE
);

-- Statistics
ANALYZE tenants;

