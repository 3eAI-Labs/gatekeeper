-- Security Test: SQL Safety Validation
-- Tests SEC-40 through SEC-43 from SECURITY_TEST_PLAN.md
-- Run against a test database with V001-V003 migrations applied

SET search_path TO aria, public;

-- ────────────────────────────────────────────────────────────────────────────
-- SEC-40: audit_events UPDATE must be blocked
-- ────────────────────────────────────────────────────────────────────────────

-- Insert a test record
INSERT INTO audit_events (consumer_id, route_id, event_type, action_taken, timestamp)
VALUES ('test-consumer', 'test-route', 'PROMPT_BLOCKED', 'BLOCKED', '2026-04-08 12:00:00+00');

-- Attempt UPDATE (should be silently ignored by the rule)
UPDATE audit_events SET action_taken = 'ALLOWED'
WHERE consumer_id = 'test-consumer' AND event_type = 'PROMPT_BLOCKED';

-- Verify: action_taken should still be 'BLOCKED'
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM audit_events
        WHERE consumer_id = 'test-consumer'
          AND action_taken = 'ALLOWED'
    ) THEN
        RAISE EXCEPTION 'SEC-40 FAILED: audit_events UPDATE was not blocked';
    ELSE
        RAISE NOTICE 'SEC-40 PASSED: audit_events UPDATE correctly blocked';
    END IF;
END $$;


-- ────────────────────────────────────────────────────────────────────────────
-- SEC-41: audit_events DELETE must be blocked
-- ────────────────────────────────────────────────────────────────────────────

-- Attempt DELETE (should be silently ignored by the rule)
DELETE FROM audit_events WHERE consumer_id = 'test-consumer';

-- Verify: record should still exist
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM audit_events WHERE consumer_id = 'test-consumer'
    ) THEN
        RAISE EXCEPTION 'SEC-41 FAILED: audit_events DELETE was not blocked';
    ELSE
        RAISE NOTICE 'SEC-41 PASSED: audit_events DELETE correctly blocked';
    END IF;
END $$;


-- ────────────────────────────────────────────────────────────────────────────
-- SEC-42: masking_audit UPDATE must be blocked
-- ────────────────────────────────────────────────────────────────────────────

INSERT INTO masking_audit (consumer_id, route_id, field_path, mask_strategy, rule_id, pii_type, timestamp)
VALUES ('test-consumer', 'test-route', '$.email', 'mask:email', 'rule-1', 'email', '2026-04-08 12:00:00+00');

UPDATE masking_audit SET mask_strategy = 'full'
WHERE consumer_id = 'test-consumer' AND field_path = '$.email';

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM masking_audit
        WHERE consumer_id = 'test-consumer' AND mask_strategy = 'full'
    ) THEN
        RAISE EXCEPTION 'SEC-42 FAILED: masking_audit UPDATE was not blocked';
    ELSE
        RAISE NOTICE 'SEC-42 PASSED: masking_audit UPDATE correctly blocked';
    END IF;
END $$;


-- ────────────────────────────────────────────────────────────────────────────
-- SEC-43: billing_records CHECK constraints enforce non-negative values
-- ────────────────────────────────────────────────────────────────────────────

-- Attempt negative tokens_input (should fail)
DO $$
BEGIN
    INSERT INTO billing_records (consumer_id, route_id, model, provider, tokens_input, tokens_output, cost_dollars, timestamp)
    VALUES ('test-consumer', 'test-route', 'gpt-4o', 'openai', -100, 50, 0.01, '2026-04-08 12:00:00+00');

    RAISE EXCEPTION 'SEC-43a FAILED: negative tokens_input was accepted';
EXCEPTION
    WHEN check_violation THEN
        RAISE NOTICE 'SEC-43a PASSED: negative tokens_input correctly rejected';
END $$;

-- Attempt negative cost_dollars (should fail)
DO $$
BEGIN
    INSERT INTO billing_records (consumer_id, route_id, model, provider, tokens_input, tokens_output, cost_dollars, timestamp)
    VALUES ('test-consumer', 'test-route', 'gpt-4o', 'openai', 100, 50, -0.01, '2026-04-08 12:00:00+00');

    RAISE EXCEPTION 'SEC-43b FAILED: negative cost_dollars was accepted';
EXCEPTION
    WHEN check_violation THEN
        RAISE NOTICE 'SEC-43b PASSED: negative cost_dollars correctly rejected';
END $$;

-- Valid insert should succeed
INSERT INTO billing_records (consumer_id, route_id, model, provider, tokens_input, tokens_output, cost_dollars, timestamp)
VALUES ('test-consumer', 'test-route', 'gpt-4o', 'openai', 100, 50, 0.0125, '2026-04-08 12:00:00+00');

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM billing_records
        WHERE consumer_id = 'test-consumer' AND tokens_input = 100
    ) THEN
        RAISE NOTICE 'SEC-43c PASSED: valid billing record accepted';
    ELSE
        RAISE EXCEPTION 'SEC-43c FAILED: valid billing record was rejected';
    END IF;
END $$;


-- ────────────────────────────────────────────────────────────────────────────
-- Cleanup test data
-- Note: audit_events and masking_audit have DELETE rules (DO INSTEAD NOTHING),
-- so cleanup requires TRUNCATE or partition drop. Use TRUNCATE for test DB only.
-- ────────────────────────────────────────────────────────────────────────────
-- TRUNCATE audit_events, masking_audit, billing_records;  -- Only in test environment!

SELECT 'All SQL security tests completed successfully' AS result;
