-- ============================================================================
-- ATTRIBUTES TABLE
-- ============================================================================
-- Metadata for all possible attributes in the EAV model
-- Defines attribute names, data types, and whether they're "hot" (cached in JSONB)
-- ============================================================================

CREATE TABLE attributes (
    attribute_id bigint PRIMARY KEY,
    attribute_name varchar(255) NOT NULL,
    data_type varchar(50) NOT NULL CHECK (data_type IN ('string', 'integer', 'decimal', 'boolean', 'date', 'timestamp', 'json')),
    is_indexed boolean DEFAULT FALSE,
    is_hot boolean DEFAULT FALSE,  -- Frequently accessed attributes
    validation_regex text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================================
-- INDEXES
-- ============================================================================
CREATE INDEX idx_attributes_name ON attributes(attribute_name);

CREATE INDEX idx_attributes_hot ON attributes(attribute_id) WHERE is_hot = TRUE;


-- ============================================================================
-- STATISTICS
-- ============================================================================
ANALYZE attributes;
