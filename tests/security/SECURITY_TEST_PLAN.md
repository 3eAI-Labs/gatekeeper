# Security Test Plan — 3e-Aria-Gatekeeper

**Phase:** 5.5 — Quality Assurance
**Date:** 2026-04-08
**Source:** SECURITY_TESTING_GUIDELINE.md v3.0.0, OWASP Top 10

---

## 1. Scope

Security testing covers all components of 3e-Aria-Gatekeeper:
- **Lua plugins:** aria-shield, aria-mask, aria-canary (+ shared libs)
- **Java sidecar:** aria-runtime (gRPC handlers, Redis/Postgres clients)
- **Database:** SQL migrations, schema constraints
- **Configuration:** Plugin schemas, secrets handling

---

## 2. OWASP Top 10 Coverage Matrix

| # | Vulnerability | Applicability | Test Approach | Status |
|---|--------------|---------------|---------------|--------|
| A01 | Broken Access Control | HIGH — role-based masking, canary admin API | Verify role policy enforcement, admin API requires auth | TESTED |
| A02 | Cryptographic Failures | MEDIUM — API keys, hash salt | Verify keys never in logs/responses, TLS config | TESTED |
| A03 | Injection | HIGH — prompt content flows through system | SQL param binding, no eval/exec, input validation | TESTED |
| A04 | Insecure Design | MEDIUM — circuit breaker, quota bypass | Business logic abuse tests (negative tokens, overflow) | TESTED |
| A05 | Security Misconfiguration | MEDIUM — default configs, error messages | Verify no stack traces in responses, safe defaults | TESTED |
| A06 | Vulnerable Components | HIGH — dependencies | SCA scan (Gradle, LuaRocks) | DOCUMENTED |
| A07 | Auth Failures | LOW — delegated to APISIX | Verify Aria trusts APISIX context correctly | TESTED |
| A08 | Data Integrity Failures | MEDIUM — audit log immutability | Verify append-only rules, no UPDATE/DELETE | TESTED |
| A09 | Logging Failures | HIGH — PII in logs | Verify PII masking in log output | TESTED |
| A10 | SSRF | LOW — no user-controlled URLs in plugins | Webhook URLs are config-only, not user input | N/A |

---

## 3. Test Cases

### 3.1 Input Validation (A03: Injection)

| ID | Test | Input | Expected | Component |
|----|------|-------|----------|-----------|
| SEC-01 | SQL injection in consumer_id | `'; DROP TABLE audit_events; --` | Parameterized query prevents injection | PostgresClient |
| SEC-02 | XSS in prompt content | `<script>alert(1)</script>` | Stored masked in audit, never rendered | Shield audit |
| SEC-03 | Oversized request body | 100MB JSON body | Rejected by APISIX body size limit | Shield access |
| SEC-04 | Null bytes in model name | `gpt-4o\x00admin` | Rejected as invalid model | Shield validation |
| SEC-05 | Path traversal in JSONPath | `$/../../../etc/passwd` | JSONPath parser rejects invalid expression | Mask |
| SEC-06 | Negative token count | `{"usage": {"total_tokens": -1000}}` | Treated as 0, not negative quota | Quota update |
| SEC-07 | Integer overflow in quota | Monthly tokens = MAX_INT + 1 | JSON schema validation rejects | Shield schema |
| SEC-08 | Unicode abuse in PII patterns | Homoglyph credit card (Cyrillic digits) | Regex handles ASCII only, non-match is safe | PII scanner |

### 3.2 Access Control (A01: Broken Access Control)

| ID | Test | Input | Expected | Component |
|----|------|-------|----------|-----------|
| SEC-10 | Admin role sees full PII | Consumer role=admin, PAN field | Full value visible | Mask role policy |
| SEC-11 | Unknown role gets redacted | Consumer role=hacker | All fields [REDACTED] (failsafe) | Mask role policy |
| SEC-12 | No role defaults to redact | No aria_role in consumer metadata | All fields [REDACTED] | Mask role policy |
| SEC-13 | Canary admin API without auth | POST /promote without APISIX admin key | Rejected by APISIX admin auth | Canary admin |
| SEC-14 | Consumer cannot set own quota | Consumer sends X-Aria-Quota header | Headers are set by plugin, not from client | Shield |

### 3.3 Cryptographic Controls (A02)

| ID | Test | Input | Expected | Component |
|----|------|-------|----------|-----------|
| SEC-20 | API key not in error response | Provider returns 401 | Error response contains ARIA code, not API key | Shield |
| SEC-21 | API key not in logs | Provider auth failure | Log contains "PROVIDER_AUTH_FAILED", not key value | Shield logging |
| SEC-22 | Hash salt not exposed | Mask hash strategy applied | Salt is not in response or logs | Mask strategies |
| SEC-23 | Tokenization encrypted at rest | tokenize strategy used | Redis value is AES-256 encrypted, not plaintext | Mask tokenization |

### 3.4 Business Logic Abuse (A04: Insecure Design)

| ID | Test | Input | Expected | Component |
|----|------|-------|----------|-----------|
| SEC-30 | Quota bypass via negative tokens | Response with negative total_tokens | Clamped to 0, quota not decreased | Quota update |
| SEC-31 | Circuit breaker manipulation | Rapid 5xx responses to force failover | Circuit breaker opens as designed (not a bypass) | Shield CB |
| SEC-32 | Canary state tampering via Redis | Direct Redis write to canary state | System reads state as-is (acceptable — Redis is trusted Zone 4) | Canary |
| SEC-33 | Budget alert flood | Rapid requests crossing all thresholds | Each threshold fires exactly once (SETNX de-dup) | Quota alerts |
| SEC-34 | Concurrent quota exhaustion race | Two requests with 1 token remaining | Redis INCRBY is atomic — one succeeds, one may slightly over-count | Quota |

### 3.5 Data Integrity (A08)

| ID | Test | Input | Expected | Component |
|----|------|-------|----------|-----------|
| SEC-40 | Audit table UPDATE blocked | `UPDATE audit_events SET action_taken = 'ALLOWED'` | Rule prevents update (DO INSTEAD NOTHING) | DB migration |
| SEC-41 | Audit table DELETE blocked | `DELETE FROM audit_events WHERE id = '...'` | Rule prevents delete | DB migration |
| SEC-42 | Masking audit UPDATE blocked | `UPDATE masking_audit SET ...` | Rule prevents update | DB migration |
| SEC-43 | Billing has CHECK constraints | `INSERT ... tokens_input = -1` | CHECK constraint violation | DB migration |

### 3.6 PII Protection (A09: Logging Failures)

| ID | Test | Input | Expected | Component |
|----|------|-------|----------|-----------|
| SEC-50 | PII masked in audit payload | Blocked prompt containing credit card | audit_events.payload_excerpt has `[REDACTED_PAN]`, not raw PAN | Shield audit |
| SEC-51 | Original PII never in masking_audit | Mask applied to email field | masking_audit has field_path and strategy, not email value | Mask audit |
| SEC-52 | Provider API key not in structured log | Provider call fails | Log JSON does not contain api_key field | Core logging |
| SEC-53 | Prompt content not fully logged | Prompt injection detected | Only first 200 chars (masked) in audit excerpt | Shield audit |

---

## 4. Static Analysis (SAST)

### 4.1 Lua Analysis

| Check | Tool | Rule |
|-------|------|------|
| No `os.execute` or `io.popen` | grep/semgrep | Command injection prevention |
| No `loadstring` or `load` with user input | grep/semgrep | Code injection prevention |
| No hardcoded secrets | gitleaks | Secret detection |
| All Redis operations use parameterized commands | manual review | Injection prevention |

### 4.2 Java Analysis

| Check | Tool | Rule |
|-------|------|------|
| No SQL string concatenation | SonarQube/semgrep | SQL injection prevention |
| All DB operations use parameterized queries (R2DBC bind) | manual review | SQL injection prevention |
| No `Runtime.exec` | grep | Command injection prevention |
| No `ObjectInputStream` deserialization | grep | Deserialization attacks |
| Dependencies scanned for CVEs | Trivy / `gradle dependencyCheckAnalyze` | SCA |

---

## 5. Dependency Audit (SCA)

### 5.1 Java Dependencies

```bash
# Run with Gradle OWASP dependency check plugin
./gradlew dependencyCheckAnalyze

# Or Trivy scan on built image
trivy image aria-runtime:latest
```

### 5.2 Threshold

| Severity | Action |
|----------|--------|
| CRITICAL | BLOCKING — must fix before merge |
| HIGH | BLOCKING — must fix before merge |
| MEDIUM | REQUIRED — fix within sprint |
| LOW | RECOMMENDED — track in backlog |

---

## 6. Container Security

```bash
# Scan Dockerfile best practices
hadolint aria-runtime/Dockerfile

# Scan built image
trivy image --severity HIGH,CRITICAL aria-runtime:latest
```

### Dockerfile Security Checklist

- [x] Non-root user (`USER aria`)
- [x] Minimal base image (alpine JRE)
- [x] No secrets in image layers
- [x] Health check defined
- [x] Read-only filesystem (can be enforced at K8s level)

---

*Document Version: 1.0 | Created: 2026-04-08*
*Status: Draft — Pending Human Approval*
