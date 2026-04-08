-- V003: Create monthly partitions for 2026 and maintenance function
-- Partition management: auto-create future, auto-drop after 84 months (7 years)

SET search_path TO aria, public;

-- ────────────────────────────────────────────────────────────────────────────
-- Create 2026 partitions (12 months × 3 tables = 36 partitions)
-- ────────────────────────────────────────────────────────────────────────────

DO $$
DECLARE
    month_start DATE;
    month_end DATE;
    partition_name TEXT;
    tables TEXT[] := ARRAY['audit_events', 'billing_records', 'masking_audit'];
    tbl TEXT;
BEGIN
    FOREACH tbl IN ARRAY tables LOOP
        FOR m IN 1..12 LOOP
            month_start := make_date(2026, m, 1);
            month_end := month_start + INTERVAL '1 month';
            partition_name := tbl || '_y2026m' || LPAD(m::TEXT, 2, '0');

            EXECUTE format(
                'CREATE TABLE IF NOT EXISTS aria.%I PARTITION OF aria.%I '
                'FOR VALUES FROM (%L) TO (%L)',
                partition_name, tbl, month_start, month_end
            );
        END LOOP;
    END LOOP;
END $$;

-- ────────────────────────────────────────────────────────────────────────────
-- Partition maintenance function
-- Creates partitions for the next 3 months (future-proofing)
-- Drops partitions older than 84 months (7 years)
-- ────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION aria.maintain_partitions()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    month_start DATE;
    month_end DATE;
    partition_name TEXT;
    year_month TEXT;
    drop_before DATE;
    tables TEXT[] := ARRAY['audit_events', 'billing_records', 'masking_audit'];
    tbl TEXT;
    rec RECORD;
BEGIN
    -- Create partitions for next 3 months
    FOREACH tbl IN ARRAY tables LOOP
        FOR i IN 0..2 LOOP
            month_start := date_trunc('month', CURRENT_DATE + (i || ' months')::INTERVAL)::DATE;
            month_end := month_start + INTERVAL '1 month';
            year_month := 'y' || to_char(month_start, 'YYYY') || 'm' || to_char(month_start, 'MM');
            partition_name := tbl || '_' || year_month;

            BEGIN
                EXECUTE format(
                    'CREATE TABLE IF NOT EXISTS aria.%I PARTITION OF aria.%I '
                    'FOR VALUES FROM (%L) TO (%L)',
                    partition_name, tbl, month_start, month_end
                );
                RAISE NOTICE 'Created partition: %', partition_name;
            EXCEPTION WHEN duplicate_table THEN
                -- Partition already exists
                NULL;
            END;
        END LOOP;
    END LOOP;

    -- Drop partitions older than 84 months (7 years)
    drop_before := date_trunc('month', CURRENT_DATE - INTERVAL '84 months')::DATE;

    FOR rec IN
        SELECT inhrelid::regclass::text AS child_table
        FROM pg_catalog.pg_inherits
        WHERE inhparent = ANY(ARRAY[
            'aria.audit_events'::regclass,
            'aria.billing_records'::regclass,
            'aria.masking_audit'::regclass
        ])
    LOOP
        -- Extract year/month from partition name (e.g., *_y2019m04)
        DECLARE
            parts TEXT[];
            part_year INT;
            part_month INT;
            part_date DATE;
        BEGIN
            parts := regexp_matches(rec.child_table, '_y(\d{4})m(\d{2})$');
            IF parts IS NOT NULL THEN
                part_year := parts[1]::INT;
                part_month := parts[2]::INT;
                part_date := make_date(part_year, part_month, 1);

                IF part_date < drop_before THEN
                    EXECUTE format('DROP TABLE IF EXISTS %s', rec.child_table);
                    RAISE NOTICE 'Dropped old partition: %', rec.child_table;
                END IF;
            END IF;
        END;
    END LOOP;
END $$;

COMMENT ON FUNCTION aria.maintain_partitions IS
    'Monthly partition maintenance: creates future partitions (3 months ahead), drops partitions older than 7 years. Schedule via pg_cron: SELECT cron.schedule(''aria-partitions'', ''0 2 1 * *'', ''SELECT aria.maintain_partitions()'');';
