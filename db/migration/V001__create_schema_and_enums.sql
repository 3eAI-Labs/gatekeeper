-- V001: Create aria schema, ENUM types, and audit_events table
-- Business Rules: BR-SH-015 (security audit), BR-MK-005 (masking audit)
-- Data Classification: L2-L3 (payload_excerpt contains masked PII fragments)

CREATE SCHEMA IF NOT EXISTS aria;
SET search_path TO aria, public;

-- Event type enum
CREATE TYPE event_type AS ENUM (
    'PROMPT_BLOCKED',
    'PII_DETECTED',
    'QUOTA_EXCEEDED',
    'CONTENT_FILTERED',
    'EXFILTRATION_ATTEMPT',
    'MASK_APPLIED',
    'CANARY_ROLLBACK',
    'PROVIDER_FAILOVER'
);

-- Action taken enum
CREATE TYPE action_taken AS ENUM (
    'BLOCKED',
    'MASKED',
    'WARNED',
    'ALLOWED',
    'ROLLED_BACK'
);

-- Mask source enum (for masking_audit table)
CREATE TYPE mask_source AS ENUM (
    'explicit_rule',
    'auto_detect',
    'ner_detect'
);

-- ────────────────────────────────────────────────────────────────────────────
-- audit_events — Append-only security audit trail
-- Partitioned by month on timestamp for 7-year retention management
-- ────────────────────────────────────────────────────────────────────────────

CREATE TABLE audit_events (
    id              UUID NOT NULL DEFAULT gen_random_uuid(),
    consumer_id     VARCHAR(255) NOT NULL,
    route_id        VARCHAR(255) NOT NULL,
    event_type      event_type NOT NULL,
    action_taken    action_taken NOT NULL,
    payload_excerpt TEXT DEFAULT '',          -- Masked PII (L3), never raw
    rule_id         VARCHAR(255) DEFAULT '',
    metadata        JSONB DEFAULT '{}'::jsonb,
    request_id      VARCHAR(255) DEFAULT '',
    timestamp       TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id, timestamp)
) PARTITION BY RANGE (timestamp);

-- Append-only: prevent UPDATE and DELETE
CREATE RULE audit_events_no_update AS ON UPDATE TO audit_events DO INSTEAD NOTHING;
CREATE RULE audit_events_no_delete AS ON DELETE TO audit_events DO INSTEAD NOTHING;

-- Indexes
CREATE INDEX idx_audit_events_consumer_ts ON audit_events (consumer_id, timestamp);
CREATE INDEX idx_audit_events_event_type_ts ON audit_events (event_type, timestamp);
CREATE INDEX idx_audit_events_request_id ON audit_events (request_id) WHERE request_id != '';

COMMENT ON TABLE audit_events IS 'Immutable security and compliance audit trail. 7-year retention.';
COMMENT ON COLUMN audit_events.payload_excerpt IS 'Masked excerpt of blocked/flagged content. PII is masked BEFORE storage (L3).';
