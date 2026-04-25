# Database Schema — 3e-Aria-Gatekeeper

**Project:** 3e-Aria-Gatekeeper
**Phase:** 4 — Low-Level Design
**Version:** 1.1.2
**Date:** 2026-04-25 (v1.1.2 Flyway closure); 2026-04-25 (v1.1.1 audit-pipeline closure); 2026-04-25 (v1.1 spec freeze); 2026-04-08 (v1.0 baseline)
**Author:** AI Architect + Human Oversight
**Input:** HLD.md v1.1.1
**v1.1 Driver:** PHASE_REVIEW_2026-04-25 FINDING-005 — DDL is correct and matches the Flyway migrations in `db/migration/V001..V003.sql`, but the sidecar has no Flyway runner wired (auto-bootstrap missing); see §1.2.
**v1.1.1 Driver:** §1.2 audit-pipeline status row updated — FINDING-003 closed in `aria-runtime@d487026` (`audit/AuditFlusher`, ADR-009). v0.2 fix item §2 retired.
**v1.1.2 Driver:** **FINDING-005 closed** in `aria-runtime@9bd22d5` — Flyway dependency + `spring.flyway.*` config added; V001..V003 migrations vendored into sidecar classpath. §1.2 sidecar-Flyway row flipped ❌ → ✅; v0.2 fix item §1 retired. The migration Job in the Helm chart remains for environments that pre-migrate (e.g., locked-down DBs where the sidecar lacks DDL grants).

---

## 1. Overview

3e-Aria-Gatekeeper persists data in two stores:

| Store | Purpose | Data Lifetime |
|-------|---------|--------------|
| **PostgreSQL 18.1+** | Audit trail, billing records, masking audit | 7-year retention (regulatory) |
| **Redis Cluster** | Real-time quotas, circuit breaker state, canary config, latency scores | Ephemeral (TTL-based) |

PostgreSQL holds append-only audit tables partitioned by month. The Java sidecar is **designed** to write asynchronously via a Redis audit buffer that is flushed periodically — see §1.2 for the v0.1 status of the audit pipeline.

### 1.2 Migration Pipeline Status (v0.1)

**Migration files:** `db/migration/V001__create_schema_and_enums.sql`, `V002__create_billing_and_masking_tables.sql`, `V003__create_partitions_and_maintenance.sql` — present in this repo and consistent with the DDL specified in §3 below.

**Migration execution path in v0.1.1:**
- ✅ **Sidecar (`aria-runtime`) bootstraps schema at startup via Flyway (v1.1.2 closure).** `build.gradle.kts` declares `flyway-core` + `flyway-database-postgresql` + `postgresql` (JDBC); `application.yml` configures `spring.flyway.*` to use the same `aria.postgres.*` coordinates as R2DBC. `baseline-on-migrate=true` allows fresh deploys against an already-migrated DB. Disable via `ARIA_FLYWAY_ENABLED=false` if migrations are externally managed.
- ✅ Helm chart still ships `runtime/helm/aria-gatekeeper/templates/migration-job.yaml` — useful when the DB role granted to the sidecar lacks DDL privileges (split-permission deployments where the migration Job runs as an elevated role and the sidecar runs as DML-only). For typical deployments where the sidecar has DDL grants, the Job becomes redundant and may be disabled.
- ✅ **Audit pipeline downstream of the migration is closed (v1.1.1).** `audit/AuditFlusher` Spring `@Scheduled` LPOP drain (ADR-009) consumes `aria:audit_buffer` and persists to `audit_events`. With v1.1.2's Flyway bootstrap the destination table now exists on first sidecar start.

**Migration source-of-truth (v0.1.1):**
The V001..V003 SQL files live in **two locations**: `gatekeeper/db/migration/` (used by the Helm migration Job) and `aria-runtime/src/main/resources/db/migration/` (vendored into the sidecar JAR for Flyway classpath discovery). Both copies are byte-identical; Flyway's checksum validation will surface any drift between them. v0.2 candidate consolidation: retire the gatekeeper copy + Helm migration Job entirely once split-permission deployments are confirmed unused.

**Remaining v0.2 fix items:**
1. ✅ **Done in v1.1.2** — Flyway bootstrap in sidecar (`aria-runtime@9bd22d5`).
2. ✅ **Done in v1.1.1** — `audit/AuditFlusher` Spring `@Scheduled` LPOP drain implemented per ADR-009.
3. Add a sidecar startup readiness check that verifies `audit_events` table presence; sidecar should fail readiness if the table is missing. (With v1.1.2 Flyway bootstrap this is mostly defence-in-depth — Flyway will fail loudly at startup if it cannot reach the DB or migrate, but a runtime readiness check still adds value if the DB is dropped post-startup.)
4. Consolidate the two migration source-of-truth copies (see "Migration source-of-truth" above).

### 1.1 Schema Name

```
aria_gatekeeper
```

All tables reside in the `aria_gatekeeper` schema.

---

## 2. ENUMs

```sql
-- Event types recorded across Shield and Mask modules
CREATE TYPE aria_gatekeeper.event_type AS ENUM (
    'PROMPT_BLOCKED',
    'PII_DETECTED',
    'QUOTA_EXCEEDED',
    'CONTENT_FILTERED',
    'EXFILTRATION_ATTEMPT',
    'MASK_APPLIED',
    'CANARY_ROLLBACK',
    'PROVIDER_FAILOVER'
);

-- Action the system took in response to the event
CREATE TYPE aria_gatekeeper.action_taken AS ENUM (
    'BLOCKED',
    'MASKED',
    'WARNED',
    'ALLOWED',
    'ROLLED_BACK'
);

-- Source that triggered a masking decision
CREATE TYPE aria_gatekeeper.mask_source AS ENUM (
    'explicit_rule',
    'auto_detect',
    'ner_detect'
);
```

---

## 3. Table Definitions

### 3.1 `audit_events` — Shield + Mask Security Audit Trail

Append-only. No UPDATE or DELETE permitted. Partitioned by month on `timestamp`.

```sql
CREATE TABLE aria_gatekeeper.audit_events (
    id              UUID            NOT NULL DEFAULT gen_random_uuid(),
    timestamp       TIMESTAMPTZ     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    consumer_id     VARCHAR(255)    NOT NULL,
    route_id        VARCHAR(255)    NOT NULL,
    event_type      aria_gatekeeper.event_type NOT NULL,
    action_taken    aria_gatekeeper.action_taken NOT NULL,
    payload_excerpt TEXT,
    rule_id         VARCHAR(255),
    metadata        JSONB,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (id, timestamp)
) PARTITION BY RANGE (timestamp);

COMMENT ON TABLE aria_gatekeeper.audit_events
    IS 'Append-only audit trail for Shield and Mask security events. Partitioned monthly. 7-year retention.';
COMMENT ON COLUMN aria_gatekeeper.audit_events.payload_excerpt
    IS 'Excerpt of the request/response payload with PII already masked. Never store raw PII.';
```

#### Indexes

```sql
CREATE INDEX idx_audit_events_consumer_id_timestamp
    ON aria_gatekeeper.audit_events (consumer_id, timestamp);

CREATE INDEX idx_audit_events_event_type_timestamp
    ON aria_gatekeeper.audit_events (event_type, timestamp);
```

#### Append-Only Rule

```sql
CREATE RULE rule_audit_events_no_update AS
    ON UPDATE TO aria_gatekeeper.audit_events
    DO INSTEAD NOTHING;

CREATE RULE rule_audit_events_no_delete AS
    ON DELETE TO aria_gatekeeper.audit_events
    DO INSTEAD NOTHING;
```

---

### 3.2 `billing_records` — Shield Token and Dollar Usage

Partitioned by month on `timestamp`.

```sql
CREATE TABLE aria_gatekeeper.billing_records (
    id              UUID            NOT NULL DEFAULT gen_random_uuid(),
    consumer_id     VARCHAR(255)    NOT NULL,
    route_id        VARCHAR(255)    NOT NULL,
    model           VARCHAR(255)    NOT NULL,
    provider        VARCHAR(255)    NOT NULL,
    tokens_input    INTEGER         NOT NULL,
    tokens_output   INTEGER         NOT NULL,
    cost_dollars    DECIMAL(12,6)   NOT NULL,
    request_id      UUID            NOT NULL,
    is_reconciled   BOOLEAN         NOT NULL DEFAULT false,
    timestamp       TIMESTAMPTZ     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (id, timestamp),

    CONSTRAINT chk_billing_records_positive_tokens_input
        CHECK (tokens_input >= 0),
    CONSTRAINT chk_billing_records_positive_tokens_output
        CHECK (tokens_output >= 0),
    CONSTRAINT chk_billing_records_positive_cost
        CHECK (cost_dollars >= 0)
) PARTITION BY RANGE (timestamp);

COMMENT ON TABLE aria_gatekeeper.billing_records
    IS 'Per-request token and dollar cost records for Shield billing. Partitioned monthly. 7-year retention.';
```

#### Indexes

```sql
CREATE INDEX idx_billing_records_consumer_id_timestamp
    ON aria_gatekeeper.billing_records (consumer_id, timestamp);

CREATE INDEX idx_billing_records_model_timestamp
    ON aria_gatekeeper.billing_records (model, timestamp);

CREATE INDEX idx_billing_records_is_reconciled
    ON aria_gatekeeper.billing_records (is_reconciled)
    WHERE is_reconciled = false;
```

---

### 3.3 `masking_audit` — Mask Masking Action Metadata

Append-only. No UPDATE or DELETE permitted. Partitioned by month on `timestamp`.

```sql
CREATE TABLE aria_gatekeeper.masking_audit (
    id              UUID            NOT NULL DEFAULT gen_random_uuid(),
    consumer_id     VARCHAR(255)    NOT NULL,
    consumer_role   VARCHAR(255)    NOT NULL,
    route_id        VARCHAR(255)    NOT NULL,
    request_id      UUID            NOT NULL,
    field_path      VARCHAR(1024)   NOT NULL,
    mask_strategy   VARCHAR(100)    NOT NULL,
    rule_id         VARCHAR(255),
    pii_type        VARCHAR(100)    NOT NULL,
    source          aria_gatekeeper.mask_source NOT NULL,
    timestamp       TIMESTAMPTZ     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (id, timestamp)
) PARTITION BY RANGE (timestamp);

COMMENT ON TABLE aria_gatekeeper.masking_audit
    IS 'Append-only record of every masking action taken by Mask module. Partitioned monthly. 7-year retention.';
```

#### Indexes

```sql
CREATE INDEX idx_masking_audit_consumer_id_timestamp
    ON aria_gatekeeper.masking_audit (consumer_id, timestamp);

CREATE INDEX idx_masking_audit_pii_type_timestamp
    ON aria_gatekeeper.masking_audit (pii_type, timestamp);
```

#### Append-Only Rule

```sql
CREATE RULE rule_masking_audit_no_update AS
    ON UPDATE TO aria_gatekeeper.masking_audit
    DO INSTEAD NOTHING;

CREATE RULE rule_masking_audit_no_delete AS
    ON DELETE TO aria_gatekeeper.masking_audit
    DO INSTEAD NOTHING;
```

---

## 4. Partition Management

### 4.1 First-Year Partition Creation (2026)

```sql
-- audit_events partitions
CREATE TABLE aria_gatekeeper.audit_events_2026_01 PARTITION OF aria_gatekeeper.audit_events
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE aria_gatekeeper.audit_events_2026_02 PARTITION OF aria_gatekeeper.audit_events
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE aria_gatekeeper.audit_events_2026_03 PARTITION OF aria_gatekeeper.audit_events
    FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE aria_gatekeeper.audit_events_2026_04 PARTITION OF aria_gatekeeper.audit_events
    FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE aria_gatekeeper.audit_events_2026_05 PARTITION OF aria_gatekeeper.audit_events
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE aria_gatekeeper.audit_events_2026_06 PARTITION OF aria_gatekeeper.audit_events
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE aria_gatekeeper.audit_events_2026_07 PARTITION OF aria_gatekeeper.audit_events
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE aria_gatekeeper.audit_events_2026_08 PARTITION OF aria_gatekeeper.audit_events
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE aria_gatekeeper.audit_events_2026_09 PARTITION OF aria_gatekeeper.audit_events
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE aria_gatekeeper.audit_events_2026_10 PARTITION OF aria_gatekeeper.audit_events
    FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE aria_gatekeeper.audit_events_2026_11 PARTITION OF aria_gatekeeper.audit_events
    FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE aria_gatekeeper.audit_events_2026_12 PARTITION OF aria_gatekeeper.audit_events
    FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');

-- billing_records partitions
CREATE TABLE aria_gatekeeper.billing_records_2026_01 PARTITION OF aria_gatekeeper.billing_records
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE aria_gatekeeper.billing_records_2026_02 PARTITION OF aria_gatekeeper.billing_records
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE aria_gatekeeper.billing_records_2026_03 PARTITION OF aria_gatekeeper.billing_records
    FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE aria_gatekeeper.billing_records_2026_04 PARTITION OF aria_gatekeeper.billing_records
    FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE aria_gatekeeper.billing_records_2026_05 PARTITION OF aria_gatekeeper.billing_records
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE aria_gatekeeper.billing_records_2026_06 PARTITION OF aria_gatekeeper.billing_records
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE aria_gatekeeper.billing_records_2026_07 PARTITION OF aria_gatekeeper.billing_records
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE aria_gatekeeper.billing_records_2026_08 PARTITION OF aria_gatekeeper.billing_records
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE aria_gatekeeper.billing_records_2026_09 PARTITION OF aria_gatekeeper.billing_records
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE aria_gatekeeper.billing_records_2026_10 PARTITION OF aria_gatekeeper.billing_records
    FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE aria_gatekeeper.billing_records_2026_11 PARTITION OF aria_gatekeeper.billing_records
    FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE aria_gatekeeper.billing_records_2026_12 PARTITION OF aria_gatekeeper.billing_records
    FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');

-- masking_audit partitions
CREATE TABLE aria_gatekeeper.masking_audit_2026_01 PARTITION OF aria_gatekeeper.masking_audit
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE aria_gatekeeper.masking_audit_2026_02 PARTITION OF aria_gatekeeper.masking_audit
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE aria_gatekeeper.masking_audit_2026_03 PARTITION OF aria_gatekeeper.masking_audit
    FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE aria_gatekeeper.masking_audit_2026_04 PARTITION OF aria_gatekeeper.masking_audit
    FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE aria_gatekeeper.masking_audit_2026_05 PARTITION OF aria_gatekeeper.masking_audit
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE aria_gatekeeper.masking_audit_2026_06 PARTITION OF aria_gatekeeper.masking_audit
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE aria_gatekeeper.masking_audit_2026_07 PARTITION OF aria_gatekeeper.masking_audit
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE aria_gatekeeper.masking_audit_2026_08 PARTITION OF aria_gatekeeper.masking_audit
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE aria_gatekeeper.masking_audit_2026_09 PARTITION OF aria_gatekeeper.masking_audit
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE aria_gatekeeper.masking_audit_2026_10 PARTITION OF aria_gatekeeper.masking_audit
    FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE aria_gatekeeper.masking_audit_2026_11 PARTITION OF aria_gatekeeper.masking_audit
    FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE aria_gatekeeper.masking_audit_2026_12 PARTITION OF aria_gatekeeper.masking_audit
    FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');
```

### 4.2 Partition Maintenance Function

This function creates partitions for the next N months and drops partitions older than 7 years. Schedule via `pg_cron` to run on the 1st of each month.

```sql
CREATE OR REPLACE FUNCTION aria_gatekeeper.maintain_partitions(
    p_months_ahead INTEGER DEFAULT 3,
    p_retention_months INTEGER DEFAULT 84  -- 7 years
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_table_name   TEXT;
    v_tables       TEXT[] := ARRAY['audit_events', 'billing_records', 'masking_audit'];
    v_start_date   DATE;
    v_end_date     DATE;
    v_partition     TEXT;
    v_drop_before  DATE;
    v_rec          RECORD;
BEGIN
    -- Create future partitions
    FOR i IN 0..p_months_ahead LOOP
        v_start_date := date_trunc('month', CURRENT_DATE + (i || ' months')::INTERVAL)::DATE;
        v_end_date   := (v_start_date + INTERVAL '1 month')::DATE;

        FOREACH v_table_name IN ARRAY v_tables LOOP
            v_partition := format('%s_%s', v_table_name, to_char(v_start_date, 'YYYY_MM'));

            IF NOT EXISTS (
                SELECT 1 FROM pg_class c
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = 'aria_gatekeeper'
                  AND c.relname = v_partition
            ) THEN
                EXECUTE format(
                    'CREATE TABLE aria_gatekeeper.%I PARTITION OF aria_gatekeeper.%I
                     FOR VALUES FROM (%L) TO (%L)',
                    v_partition, v_table_name, v_start_date, v_end_date
                );
                RAISE NOTICE 'Created partition: aria_gatekeeper.%', v_partition;
            END IF;
        END LOOP;
    END LOOP;

    -- Drop partitions older than retention period
    v_drop_before := date_trunc('month', CURRENT_DATE - (p_retention_months || ' months')::INTERVAL)::DATE;

    FOR v_rec IN
        SELECT c.relname, n.nspname
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_class parent ON parent.oid = i.inhparent
        WHERE n.nspname = 'aria_gatekeeper'
          AND parent.relname = ANY(v_tables)
    LOOP
        -- Extract year-month from partition name (e.g., audit_events_2026_01)
        DECLARE
            v_year  INTEGER;
            v_month INTEGER;
            v_partition_date DATE;
        BEGIN
            v_year  := substring(v_rec.relname FROM '(\d{4})_\d{2}$')::INTEGER;
            v_month := substring(v_rec.relname FROM '\d{4}_(\d{2})$')::INTEGER;
            v_partition_date := make_date(v_year, v_month, 1);

            IF v_partition_date < v_drop_before THEN
                EXECUTE format('DROP TABLE aria_gatekeeper.%I', v_rec.relname);
                RAISE NOTICE 'Dropped expired partition: aria_gatekeeper.%', v_rec.relname;
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE NOTICE 'Skipped partition % (could not parse date): %', v_rec.relname, SQLERRM;
        END;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION aria_gatekeeper.maintain_partitions
    IS 'Creates future monthly partitions and drops partitions older than retention period. Run monthly via pg_cron.';
```

#### pg_cron Schedule

```sql
-- Run on the 1st of every month at 02:00 UTC
SELECT cron.schedule(
    'aria_gatekeeper_partition_maintenance',
    '0 2 1 * *',
    $$SELECT aria_gatekeeper.maintain_partitions(3, 84)$$
);
```

---

## 5. Migration Files

### V001__create_schema_and_enums.sql

```sql
-- V001__create_schema_and_enums.sql
-- Creates the aria_gatekeeper schema and enum types.

CREATE SCHEMA IF NOT EXISTS aria_gatekeeper;

CREATE TYPE aria_gatekeeper.event_type AS ENUM (
    'PROMPT_BLOCKED',
    'PII_DETECTED',
    'QUOTA_EXCEEDED',
    'CONTENT_FILTERED',
    'EXFILTRATION_ATTEMPT',
    'MASK_APPLIED',
    'CANARY_ROLLBACK',
    'PROVIDER_FAILOVER'
);

CREATE TYPE aria_gatekeeper.action_taken AS ENUM (
    'BLOCKED',
    'MASKED',
    'WARNED',
    'ALLOWED',
    'ROLLED_BACK'
);

CREATE TYPE aria_gatekeeper.mask_source AS ENUM (
    'explicit_rule',
    'auto_detect',
    'ner_detect'
);
```

### V002__create_audit_and_billing_tables.sql

```sql
-- V002__create_audit_and_billing_tables.sql
-- Creates audit_events, billing_records, masking_audit (partitioned) with indexes and rules.

-- ============================================================
-- audit_events
-- ============================================================
CREATE TABLE aria_gatekeeper.audit_events (
    id              UUID            NOT NULL DEFAULT gen_random_uuid(),
    timestamp       TIMESTAMPTZ     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    consumer_id     VARCHAR(255)    NOT NULL,
    route_id        VARCHAR(255)    NOT NULL,
    event_type      aria_gatekeeper.event_type NOT NULL,
    action_taken    aria_gatekeeper.action_taken NOT NULL,
    payload_excerpt TEXT,
    rule_id         VARCHAR(255),
    metadata        JSONB,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id, timestamp)
) PARTITION BY RANGE (timestamp);

CREATE INDEX idx_audit_events_consumer_id_timestamp
    ON aria_gatekeeper.audit_events (consumer_id, timestamp);
CREATE INDEX idx_audit_events_event_type_timestamp
    ON aria_gatekeeper.audit_events (event_type, timestamp);

CREATE RULE rule_audit_events_no_update AS
    ON UPDATE TO aria_gatekeeper.audit_events DO INSTEAD NOTHING;
CREATE RULE rule_audit_events_no_delete AS
    ON DELETE TO aria_gatekeeper.audit_events DO INSTEAD NOTHING;

-- ============================================================
-- billing_records
-- ============================================================
CREATE TABLE aria_gatekeeper.billing_records (
    id              UUID            NOT NULL DEFAULT gen_random_uuid(),
    consumer_id     VARCHAR(255)    NOT NULL,
    route_id        VARCHAR(255)    NOT NULL,
    model           VARCHAR(255)    NOT NULL,
    provider        VARCHAR(255)    NOT NULL,
    tokens_input    INTEGER         NOT NULL,
    tokens_output   INTEGER         NOT NULL,
    cost_dollars    DECIMAL(12,6)   NOT NULL,
    request_id      UUID            NOT NULL,
    is_reconciled   BOOLEAN         NOT NULL DEFAULT false,
    timestamp       TIMESTAMPTZ     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id, timestamp),
    CONSTRAINT chk_billing_records_positive_tokens_input  CHECK (tokens_input  >= 0),
    CONSTRAINT chk_billing_records_positive_tokens_output CHECK (tokens_output >= 0),
    CONSTRAINT chk_billing_records_positive_cost          CHECK (cost_dollars  >= 0)
) PARTITION BY RANGE (timestamp);

CREATE INDEX idx_billing_records_consumer_id_timestamp
    ON aria_gatekeeper.billing_records (consumer_id, timestamp);
CREATE INDEX idx_billing_records_model_timestamp
    ON aria_gatekeeper.billing_records (model, timestamp);
CREATE INDEX idx_billing_records_is_reconciled
    ON aria_gatekeeper.billing_records (is_reconciled) WHERE is_reconciled = false;

-- ============================================================
-- masking_audit
-- ============================================================
CREATE TABLE aria_gatekeeper.masking_audit (
    id              UUID            NOT NULL DEFAULT gen_random_uuid(),
    consumer_id     VARCHAR(255)    NOT NULL,
    consumer_role   VARCHAR(255)    NOT NULL,
    route_id        VARCHAR(255)    NOT NULL,
    request_id      UUID            NOT NULL,
    field_path      VARCHAR(1024)   NOT NULL,
    mask_strategy   VARCHAR(100)    NOT NULL,
    rule_id         VARCHAR(255),
    pii_type        VARCHAR(100)    NOT NULL,
    source          aria_gatekeeper.mask_source NOT NULL,
    timestamp       TIMESTAMPTZ     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id, timestamp)
) PARTITION BY RANGE (timestamp);

CREATE INDEX idx_masking_audit_consumer_id_timestamp
    ON aria_gatekeeper.masking_audit (consumer_id, timestamp);
CREATE INDEX idx_masking_audit_pii_type_timestamp
    ON aria_gatekeeper.masking_audit (pii_type, timestamp);

CREATE RULE rule_masking_audit_no_update AS
    ON UPDATE TO aria_gatekeeper.masking_audit DO INSTEAD NOTHING;
CREATE RULE rule_masking_audit_no_delete AS
    ON DELETE TO aria_gatekeeper.masking_audit DO INSTEAD NOTHING;
```

### V003__create_initial_partitions_and_maintenance.sql

```sql
-- V003__create_initial_partitions_and_maintenance.sql
-- Creates 2026 monthly partitions for all three tables and the maintenance function.

-- ============================================================
-- audit_events 2026 partitions
-- ============================================================
CREATE TABLE aria_gatekeeper.audit_events_2026_01 PARTITION OF aria_gatekeeper.audit_events FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE aria_gatekeeper.audit_events_2026_02 PARTITION OF aria_gatekeeper.audit_events FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE aria_gatekeeper.audit_events_2026_03 PARTITION OF aria_gatekeeper.audit_events FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE aria_gatekeeper.audit_events_2026_04 PARTITION OF aria_gatekeeper.audit_events FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE aria_gatekeeper.audit_events_2026_05 PARTITION OF aria_gatekeeper.audit_events FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE aria_gatekeeper.audit_events_2026_06 PARTITION OF aria_gatekeeper.audit_events FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE aria_gatekeeper.audit_events_2026_07 PARTITION OF aria_gatekeeper.audit_events FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE aria_gatekeeper.audit_events_2026_08 PARTITION OF aria_gatekeeper.audit_events FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE aria_gatekeeper.audit_events_2026_09 PARTITION OF aria_gatekeeper.audit_events FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE aria_gatekeeper.audit_events_2026_10 PARTITION OF aria_gatekeeper.audit_events FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE aria_gatekeeper.audit_events_2026_11 PARTITION OF aria_gatekeeper.audit_events FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE aria_gatekeeper.audit_events_2026_12 PARTITION OF aria_gatekeeper.audit_events FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');

-- ============================================================
-- billing_records 2026 partitions
-- ============================================================
CREATE TABLE aria_gatekeeper.billing_records_2026_01 PARTITION OF aria_gatekeeper.billing_records FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE aria_gatekeeper.billing_records_2026_02 PARTITION OF aria_gatekeeper.billing_records FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE aria_gatekeeper.billing_records_2026_03 PARTITION OF aria_gatekeeper.billing_records FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE aria_gatekeeper.billing_records_2026_04 PARTITION OF aria_gatekeeper.billing_records FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE aria_gatekeeper.billing_records_2026_05 PARTITION OF aria_gatekeeper.billing_records FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE aria_gatekeeper.billing_records_2026_06 PARTITION OF aria_gatekeeper.billing_records FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE aria_gatekeeper.billing_records_2026_07 PARTITION OF aria_gatekeeper.billing_records FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE aria_gatekeeper.billing_records_2026_08 PARTITION OF aria_gatekeeper.billing_records FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE aria_gatekeeper.billing_records_2026_09 PARTITION OF aria_gatekeeper.billing_records FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE aria_gatekeeper.billing_records_2026_10 PARTITION OF aria_gatekeeper.billing_records FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE aria_gatekeeper.billing_records_2026_11 PARTITION OF aria_gatekeeper.billing_records FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE aria_gatekeeper.billing_records_2026_12 PARTITION OF aria_gatekeeper.billing_records FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');

-- ============================================================
-- masking_audit 2026 partitions
-- ============================================================
CREATE TABLE aria_gatekeeper.masking_audit_2026_01 PARTITION OF aria_gatekeeper.masking_audit FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE aria_gatekeeper.masking_audit_2026_02 PARTITION OF aria_gatekeeper.masking_audit FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE aria_gatekeeper.masking_audit_2026_03 PARTITION OF aria_gatekeeper.masking_audit FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE aria_gatekeeper.masking_audit_2026_04 PARTITION OF aria_gatekeeper.masking_audit FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE aria_gatekeeper.masking_audit_2026_05 PARTITION OF aria_gatekeeper.masking_audit FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE aria_gatekeeper.masking_audit_2026_06 PARTITION OF aria_gatekeeper.masking_audit FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE aria_gatekeeper.masking_audit_2026_07 PARTITION OF aria_gatekeeper.masking_audit FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE aria_gatekeeper.masking_audit_2026_08 PARTITION OF aria_gatekeeper.masking_audit FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE aria_gatekeeper.masking_audit_2026_09 PARTITION OF aria_gatekeeper.masking_audit FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');
CREATE TABLE aria_gatekeeper.masking_audit_2026_10 PARTITION OF aria_gatekeeper.masking_audit FOR VALUES FROM ('2026-10-01') TO ('2026-11-01');
CREATE TABLE aria_gatekeeper.masking_audit_2026_11 PARTITION OF aria_gatekeeper.masking_audit FOR VALUES FROM ('2026-11-01') TO ('2026-12-01');
CREATE TABLE aria_gatekeeper.masking_audit_2026_12 PARTITION OF aria_gatekeeper.masking_audit FOR VALUES FROM ('2026-12-01') TO ('2027-01-01');

-- ============================================================
-- Partition maintenance function
-- ============================================================
CREATE OR REPLACE FUNCTION aria_gatekeeper.maintain_partitions(
    p_months_ahead INTEGER DEFAULT 3,
    p_retention_months INTEGER DEFAULT 84
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_table_name   TEXT;
    v_tables       TEXT[] := ARRAY['audit_events', 'billing_records', 'masking_audit'];
    v_start_date   DATE;
    v_end_date     DATE;
    v_partition     TEXT;
    v_drop_before  DATE;
    v_rec          RECORD;
BEGIN
    FOR i IN 0..p_months_ahead LOOP
        v_start_date := date_trunc('month', CURRENT_DATE + (i || ' months')::INTERVAL)::DATE;
        v_end_date   := (v_start_date + INTERVAL '1 month')::DATE;

        FOREACH v_table_name IN ARRAY v_tables LOOP
            v_partition := format('%s_%s', v_table_name, to_char(v_start_date, 'YYYY_MM'));

            IF NOT EXISTS (
                SELECT 1 FROM pg_class c
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = 'aria_gatekeeper'
                  AND c.relname = v_partition
            ) THEN
                EXECUTE format(
                    'CREATE TABLE aria_gatekeeper.%I PARTITION OF aria_gatekeeper.%I
                     FOR VALUES FROM (%L) TO (%L)',
                    v_partition, v_table_name, v_start_date, v_end_date
                );
                RAISE NOTICE 'Created partition: aria_gatekeeper.%', v_partition;
            END IF;
        END LOOP;
    END LOOP;

    v_drop_before := date_trunc('month', CURRENT_DATE - (p_retention_months || ' months')::INTERVAL)::DATE;

    FOR v_rec IN
        SELECT c.relname, n.nspname
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_class parent ON parent.oid = i.inhparent
        WHERE n.nspname = 'aria_gatekeeper'
          AND parent.relname = ANY(v_tables)
    LOOP
        DECLARE
            v_year  INTEGER;
            v_month INTEGER;
            v_partition_date DATE;
        BEGIN
            v_year  := substring(v_rec.relname FROM '(\d{4})_\d{2}$')::INTEGER;
            v_month := substring(v_rec.relname FROM '\d{4}_(\d{2})$')::INTEGER;
            v_partition_date := make_date(v_year, v_month, 1);

            IF v_partition_date < v_drop_before THEN
                EXECUTE format('DROP TABLE aria_gatekeeper.%I', v_rec.relname);
                RAISE NOTICE 'Dropped expired partition: aria_gatekeeper.%', v_rec.relname;
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                RAISE NOTICE 'Skipped partition % (could not parse date): %', v_rec.relname, SQLERRM;
        END;
    END LOOP;
END;
$$;

-- Schedule via pg_cron (run on 1st of each month at 02:00 UTC)
-- SELECT cron.schedule('aria_gatekeeper_partition_maintenance', '0 2 1 * *',
--     $$SELECT aria_gatekeeper.maintain_partitions(3, 84)$$);
```

---

## 6. Data Retention Policy

| Rule | Value |
|------|-------|
| Retention period | 7 years (84 months) |
| Partition granularity | Monthly |
| Cleanup mechanism | `aria_gatekeeper.maintain_partitions()` via `pg_cron` |
| Cleanup schedule | 1st of every month, 02:00 UTC |
| Cleanup action | `DROP TABLE` on partitions older than 84 months |
| Backup before drop | Platform-level daily backups ensure recoverability |

The `maintain_partitions` function both creates future partitions (3 months ahead by default) and drops expired partitions in a single transaction. This ensures no partition gaps and no forgotten data.

---

## 7. Redis Key Schema

Redis serves as the real-time state store. All keys use the `aria:` namespace prefix. The Java sidecar is the sole writer and reader.

### 7.1 Key Definitions

| Key Pattern | Type | TTL | Module | Description |
|-------------|------|-----|--------|-------------|
| `aria:quota:{consumer}:daily:{date}:tokens` | STRING (int) | 48h | Shield | Daily token counter per consumer. `{date}` format: `YYYY-MM-DD`. |
| `aria:quota:{consumer}:monthly:{month}:dollars` | STRING (decimal) | 35d | Shield | Monthly dollar spend accumulator. `{month}` format: `YYYY-MM`. |
| `aria:cb:{provider}:{route}` | HASH | 10m | Shield | Circuit breaker state. Fields: `state` (CLOSED/OPEN/HALF_OPEN), `failure_count`, `last_failure_at`, `opened_at`. |
| `aria:latency:{provider}:{model}` | SORTED SET | 10m | Shield | Recent latency samples. Score = latency_ms, member = request timestamp. Used for P50/P99 calculation. |
| `aria:alert:{consumer}:{threshold}` | STRING | Budget period | Shield | Alert deduplication flag. Prevents repeated alerts for the same threshold crossing within one budget period. |
| `aria:canary:{route}` | HASH/JSON | Persistent | Canary | Active canary deployment config. Fields: `version_a`, `version_b`, `weight_b`, `strategy`, `started_at`. No TTL -- explicitly deleted on canary completion. |
| `aria:canary:errors:{route}:{version}:{window}` | STRING (int) | 2m | Canary | Error count for a specific version within a sliding window. `{window}` is the window start epoch. |
| `aria:tokenize:{token_id}` | STRING (encrypted) | Configurable | Mask | Tokenized PII value. The value is AES-256-GCM encrypted. TTL set per data classification policy. |
| `aria:audit_buffer` | LIST | 1h | All | Async buffer for audit events before PostgreSQL flush. RPUSH on write, LPOP batch on flush. TTL is a safety net; the flusher runs every 5s. |

### 7.2 Key Conventions

- **Namespace:** All keys start with `aria:` to avoid collisions in a shared Redis cluster.
- **Separator:** Colon (`:`) as hierarchical delimiter, per Redis convention.
- **TTL discipline:** Every ephemeral key has an explicit TTL. Persistent keys (canary config) are explicitly deleted by application logic.
- **No KEYS command:** Application code never uses `KEYS *`. Use `SCAN` if enumeration is needed.

### 7.3 Memory Estimation

| Key Pattern | Estimated Keys | Avg Size | Total |
|-------------|---------------|----------|-------|
| `aria:quota:*` | 2 per consumer per day | ~64 B | ~1 MB per 10k consumers |
| `aria:cb:*` | 1 per provider-route pair | ~256 B | Negligible |
| `aria:latency:*` | 1 per provider-model pair | ~4 KB (100 samples) | ~100 KB for 25 models |
| `aria:canary:*` | 1 per active canary route | ~512 B | Negligible |
| `aria:canary:errors:*` | ~30 per active route (windows) | ~32 B | Negligible |
| `aria:tokenize:*` | Proportional to masked PII volume | ~256 B | Varies |
| `aria:audit_buffer` | 1 (list) | ~500 B per entry | ~5 MB at peak (10k buffered) |

---

## 8. Performance Notes

### 8.1 PostgreSQL

- **Partition pruning:** All queries against partitioned tables should include a `timestamp` range in the `WHERE` clause. PostgreSQL automatically prunes irrelevant partitions, keeping scan costs proportional to the queried time window rather than total data volume.
- **Write pattern:** All three tables are insert-heavy with rare reads (dashboards, compliance reports). This favors fewer indexes and bulk inserts.
- **Bulk insert:** The Java sidecar drains `aria:audit_buffer` every 5 seconds and performs a batch `INSERT` using `COPY` or multi-value `INSERT`. Individual per-request inserts are avoided.
- **Connection pooling:** Use HikariCP with a pool size of 5-10 connections. The sidecar is the sole writer; connection contention is minimal.
- **Statement timeout:** Set `statement_timeout = 30000` (30s) on the application role.
- **JSONB indexing:** The `metadata` column on `audit_events` is not indexed by default. If query patterns emerge that filter on metadata fields, add a GIN index:
  ```sql
  CREATE INDEX idx_audit_events_metadata ON aria_gatekeeper.audit_events USING GIN (metadata);
  ```

### 8.2 Redis

- **Pipeline writes:** Quota increments (`INCRBY`) and audit buffer pushes (`RPUSH`) are pipelined to minimize round trips.
- **Lua scripts:** Circuit breaker state transitions use Redis Lua scripts to guarantee atomicity (read state + update + set TTL in one round trip).
- **Memory policy:** Set `maxmemory-policy allkeys-lru` as a safety net, though TTLs should keep memory bounded.
- **Cluster sharding:** Keys are distributed across slots by their prefix. The `{consumer}` portion provides natural sharding for quota keys.

---

## 9. Entity Relationship Summary

```
┌──────────────────────────────────────────────────────┐
│                    PostgreSQL                         │
│                                                      │
│  ┌────────────────┐  ┌────────────────┐              │
│  │ audit_events   │  │ masking_audit  │              │
│  │ (append-only)  │  │ (append-only)  │              │
│  │ partitioned    │  │ partitioned    │              │
│  └────────────────┘  └────────────────┘              │
│                                                      │
│  ┌────────────────┐                                  │
│  │billing_records │                                  │
│  │ partitioned    │                                  │
│  └────────────────┘                                  │
│                                                      │
│  No foreign keys between tables.                     │
│  consumer_id and route_id are external references    │
│  (APISIX consumer/route identifiers).                │
└──────────────────────────────────────────────────────┘
```

The three tables are independent -- no foreign key relationships exist between them. `consumer_id` and `route_id` reference APISIX entities managed outside this schema. This design keeps inserts lock-free and simplifies partition management.

---

## Appendix A: Guideline Compliance Matrix

| Guideline Rule | Compliance |
|---------------|------------|
| Table names: snake_case, plural | `audit_events`, `billing_records`, `masking_audit` |
| Column names: snake_case | All columns |
| PK: `id UUID DEFAULT gen_random_uuid()` | All tables (composite PK with `timestamp` for partitioning) |
| Mandatory `created_at` / `updated_at` | Present on all tables (`updated_at` omitted on append-only tables where updates are blocked) |
| FK columns: `{referenced_table_singular}_id` | No FKs (external references only) |
| Index naming: `idx_{table}_{columns}` | All indexes |
| Check constraints: `chk_{table}_{description}` | `billing_records` cost/token checks |
| Migration naming: `V{version}__{description}.sql` | V001, V002, V003 |
| Audit tables append-only | Rules block UPDATE/DELETE on `audit_events`, `masking_audit` |
| ENUM for status fields | PostgreSQL ENUM types for `event_type`, `action_taken`, `mask_source` |
| Partition by month for time-series | All three tables partitioned by month |
| 7-year retention | `maintain_partitions()` with 84-month default |
| Redis key naming: `{service}:{entity}:{id}:{field}` | `aria:{entity}:{id}:{qualifier}` pattern |

---

*Document Version: 1.1.2 | Created: 2026-04-08 | Revised: 2026-04-25 (v1.1 spec freeze, v1.1.1 audit-pipeline closure, v1.1.2 Flyway closure)*
*Change log v1.0 → v1.1: §1.2 NEW — migration pipeline status (FINDING-005); DDL itself unchanged.*
*Change log v1.1 → v1.1.1: §1.2 audit-pipeline downstream row flipped to ✅ closed (`audit/AuditFlusher`, ADR-009); v0.2 fix item §2 retired (done in v1.1.1).*
*Change log v1.1.1 → v1.1.2: §1.2 sidecar-Flyway row flipped ❌ → ✅ (closed in `aria-runtime@9bd22d5` — `flyway-core` + `flyway-database-postgresql` + `postgresql` JDBC + `spring.flyway.*` config). v0.2 fix item §1 retired. Migration source-of-truth note added (gatekeeper/db/migration + aria-runtime/src/main/resources/db/migration coexist; v0.2 candidate consolidation). Helm migration Job remains for split-permission deployments.*
*Phase: 4 — Low-Level Design*
*Status: Draft*
