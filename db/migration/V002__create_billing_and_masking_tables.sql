-- V002: Create billing_records and masking_audit tables
-- Business Rules: BR-SH-006 (token reconciliation), BR-SH-007 (dollar budget)
-- Business Rules: BR-MK-005 (masking audit metadata)

SET search_path TO aria, public;

-- ────────────────────────────────────────────────────────────────────────────
-- billing_records — Token and dollar usage per request
-- Partitioned by month on timestamp
-- ────────────────────────────────────────────────────────────────────────────

CREATE TABLE billing_records (
    id              UUID NOT NULL DEFAULT gen_random_uuid(),
    consumer_id     VARCHAR(255) NOT NULL,
    route_id        VARCHAR(255) NOT NULL,
    model           VARCHAR(255) NOT NULL,
    provider        VARCHAR(100) NOT NULL,
    tokens_input    INTEGER NOT NULL DEFAULT 0 CHECK (tokens_input >= 0),
    tokens_output   INTEGER NOT NULL DEFAULT 0 CHECK (tokens_output >= 0),
    cost_dollars    DECIMAL(12, 6) NOT NULL DEFAULT 0 CHECK (cost_dollars >= 0),
    request_id      VARCHAR(255) DEFAULT '',
    is_reconciled   BOOLEAN NOT NULL DEFAULT false,
    timestamp       TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id, timestamp)
) PARTITION BY RANGE (timestamp);

-- Indexes
CREATE INDEX idx_billing_consumer_ts ON billing_records (consumer_id, timestamp);
CREATE INDEX idx_billing_model_ts ON billing_records (model, timestamp);
CREATE INDEX idx_billing_unreconciled ON billing_records (created_at)
    WHERE is_reconciled = false;

COMMENT ON TABLE billing_records IS 'Per-request token and dollar usage. 7-year retention for tax/audit.';

-- ────────────────────────────────────────────────────────────────────────────
-- masking_audit — Masking action metadata (no original values)
-- Partitioned by month on timestamp
-- ────────────────────────────────────────────────────────────────────────────

CREATE TABLE masking_audit (
    id              UUID NOT NULL DEFAULT gen_random_uuid(),
    consumer_id     VARCHAR(255) NOT NULL,
    consumer_role   VARCHAR(100) NOT NULL DEFAULT 'unknown',
    route_id        VARCHAR(255) NOT NULL,
    request_id      VARCHAR(255) DEFAULT '',
    field_path      VARCHAR(500) NOT NULL,
    mask_strategy   VARCHAR(100) NOT NULL,
    rule_id         VARCHAR(255) NOT NULL,
    pii_type        VARCHAR(100) NOT NULL,
    source          mask_source NOT NULL DEFAULT 'explicit_rule',
    timestamp       TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id, timestamp)
) PARTITION BY RANGE (timestamp);

-- Append-only
CREATE RULE masking_audit_no_update AS ON UPDATE TO masking_audit DO INSTEAD NOTHING;
CREATE RULE masking_audit_no_delete AS ON DELETE TO masking_audit DO INSTEAD NOTHING;

-- Indexes
CREATE INDEX idx_masking_consumer_ts ON masking_audit (consumer_id, timestamp);
CREATE INDEX idx_masking_pii_type_ts ON masking_audit (pii_type, timestamp);

COMMENT ON TABLE masking_audit IS 'Masking action metadata only. Original PII values are NEVER stored.';
