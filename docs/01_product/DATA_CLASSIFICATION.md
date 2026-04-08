# Data Classification Record — 3e-Aria-Gatekeeper

**Project:** 3e-Aria-Gatekeeper
**Phase:** 1 — Requirements
**Version:** 1.0
**Date:** 2026-04-08
**Classified By:** Levent Sezgin Genc (3EAI Labs Ltd)
**Source:** VISION.md v1.0, DATA_GOVERNANCE_GUIDELINE.md v3.0.0

---

## 1. Classification Levels Reference

| Level | Label | Storage | Access | Logging |
|-------|-------|---------|--------|---------|
| **L4** | Highly Sensitive | Encrypted at rest (AES-256), HSM for keys | Need-to-know, MFA required | Full audit trail, no payload in logs |
| **L3** | Sensitive (PII) | Encrypted at rest, masked in non-prod | Role-based, approval required | Masked in logs, audit trail |
| **L2** | Confidential | Standard encryption | Role-based | Standard logging |
| **L1** | Public | No special requirement | Open | Standard logging |

**Default Rule:** All data is L2 until explicitly classified otherwise.
**Upward Inheritance:** If a dataset contains even one L4 field, the entire dataset is treated as L4.

---

## 2. Stored Data (Persistent)

Data that 3e-Aria-Gatekeeper writes to Redis, PostgreSQL, or filesystem.

### 2.1 Redis (Real-Time State)

| Field Name | Data Type | Classification | Justification | Masking Rule | Retention |
|------------|-----------|---------------|---------------|--------------|-----------|
| `aria:quota:{consumer_id}:tokens_used` | INTEGER | L2 (Business) | Token consumption counter | No masking | TTL per budget period (daily/monthly) |
| `aria:quota:{consumer_id}:budget_used` | DECIMAL | L2 (Business) | Dollar spend counter | No masking | TTL per budget period |
| `aria:quota:{consumer_id}:config` | JSON | L2 (Business) | Quota/budget configuration | No masking | Persistent |
| `aria:circuit_breaker:{provider}` | JSON | L1 (Operational) | Circuit breaker state | No masking | TTL 5 min |
| `aria:latency:{provider}:{model}` | SORTED SET | L1 (Operational) | P95 latency sliding window | No masking | TTL 10 min |
| `aria:audit_buffer:*` | JSON | L3 (Contains masked PII) | Buffered audit events (Postgres failover) | PII pre-masked before buffering | TTL 1 hour, flush to Postgres |
| `aria:tokenize:{token_id}` | STRING | L4 (Reversible PII) | Tokenization mapping (original value -> token) | Full encryption at rest | Configurable TTL |
| `aria:alert_sent:{consumer}:{threshold}` | STRING | L1 (Operational) | De-duplication flag for budget alerts | No masking | TTL per budget period |

### 2.2 PostgreSQL (Audit & Billing)

| Field Name | Data Type | Classification | Justification | Masking Rule | Retention |
|------------|-----------|---------------|---------------|--------------|-----------|
| `audit_events.id` | UUID | L2 (Business) | Primary key | No masking | 7 years |
| `audit_events.timestamp` | TIMESTAMPTZ | L2 (Business) | Event time | No masking | 7 years |
| `audit_events.consumer_id` | VARCHAR | L2 (Business) | Business identifier | No masking | 7 years |
| `audit_events.route_id` | VARCHAR | L2 (Business) | APISIX route reference | No masking | 7 years |
| `audit_events.event_type` | ENUM | L2 (Business) | PROMPT_BLOCKED, PII_DETECTED, QUOTA_EXCEEDED, CONTENT_FILTERED, MASK_APPLIED, CANARY_ROLLBACK | No masking | 7 years |
| `audit_events.action_taken` | ENUM | L2 (Business) | BLOCKED, MASKED, WARNED, ALLOWED | No masking | 7 years |
| `audit_events.payload_excerpt` | TEXT | L3 (Masked PII) | Masked excerpt of blocked/flagged content | PII masked before storage: `j***@e***.com` | 7 years |
| `audit_events.rule_id` | VARCHAR | L2 (Business) | Which rule triggered the event | No masking | 7 years |
| `audit_events.metadata` | JSONB | L2 (Business) | Additional context (model, tokens, etc.) | No masking | 7 years |
| `billing_records.id` | UUID | L2 (Business) | Primary key | No masking | 7 years |
| `billing_records.consumer_id` | VARCHAR | L2 (Business) | Who incurred the cost | No masking | 7 years |
| `billing_records.model` | VARCHAR | L1 (Public) | LLM model used | No masking | 7 years |
| `billing_records.tokens_input` | INTEGER | L2 (Business) | Input token count | No masking | 7 years |
| `billing_records.tokens_output` | INTEGER | L2 (Business) | Output token count | No masking | 7 years |
| `billing_records.cost_dollars` | DECIMAL | L2 (Business) | Calculated cost | No masking | 7 years |
| `billing_records.timestamp` | TIMESTAMPTZ | L2 (Business) | Request time | No masking | 7 years |
| `billing_records.is_reconciled` | BOOLEAN | L1 (Operational) | Whether Lua estimate was reconciled by tiktoken | No masking | 7 years |
| `masking_audit.id` | UUID | L2 (Business) | Primary key | No masking | 7 years |
| `masking_audit.consumer_id` | VARCHAR | L2 (Business) | Who received masked data | No masking | 7 years |
| `masking_audit.route_id` | VARCHAR | L2 (Business) | Which route | No masking | 7 years |
| `masking_audit.field_path` | VARCHAR | L2 (Business) | JSONPath of masked field | No masking | 7 years |
| `masking_audit.mask_strategy` | VARCHAR | L2 (Business) | Which strategy applied (last4, redact, etc.) | No masking | 7 years |
| `masking_audit.rule_id` | VARCHAR | L2 (Business) | Which masking rule triggered | No masking | 7 years |
| `masking_audit.timestamp` | TIMESTAMPTZ | L2 (Business) | When masking occurred | No masking | 7 years |

### 2.3 Configuration Files / APISIX Metadata

| Field Name | Data Type | Classification | Justification | Masking Rule |
|------------|-----------|---------------|---------------|--------------|
| LLM provider API keys | STRING | **L4 (Highly Sensitive)** | Authentication credentials for LLM providers | Never logged. Stored in APISIX secrets (encrypted). Masked as `sk-****...XXXX` |
| APISIX Admin API key | STRING | **L4 (Highly Sensitive)** | Gateway admin access | Never logged. Stored in APISIX config (encrypted) |
| `ariactl` stored credentials | STRING | **L4 (Highly Sensitive)** | CLI admin credentials | Never logged. Stored in `~/.ariactl/config` with `0600` permissions |
| Webhook URLs | STRING | L2 (Confidential) | Alert destinations | Masked in logs as `https://hooks.slack.com/****` |
| Model pricing table | JSON | L2 (Confidential) | Per-model token pricing | No masking |
| Masking rules | JSON | L2 (Confidential) | JSONPath + strategy configuration | No masking |
| Quota configuration | JSON | L2 (Confidential) | Per-consumer limits | No masking |
| Canary schedule | JSON | L1 (Public) | Traffic split configuration | No masking |
| Detection patterns (regex) | JSON | L2 (Confidential) | Prompt injection / PII patterns | No masking |

---

## 3. Transit Data (Processed but NOT Stored by Aria)

Data that flows through the gateway and is processed by Aria plugins but is not persisted in its original form.

### 3.1 Module A: Shield — Transit

| Data Element | Classification | Direction | Processing | Storage |
|-------------|---------------|-----------|------------|---------|
| Prompt content (user messages) | **L3-L4 (may contain PII)** | Client -> Gateway -> LLM | Scanned for injection patterns and PII (US-A10, US-A11) | **Never stored in original form.** Masked excerpt in audit log only if flagged |
| System prompt content | L2 (Confidential) | Client -> Gateway -> LLM | Scanned for exfiltration patterns (US-A13) | Never stored |
| LLM response content | **L3 (may contain PII/harmful)** | LLM -> Gateway -> Client | Scanned for harmful content (US-A12) | Never stored |
| SSE stream chunks | **L3 (may contain PII)** | LLM -> Gateway -> Client | Passed through without buffering | Never stored |
| `usage.total_tokens` from LLM | L2 (Business) | LLM -> Gateway | Extracted for quota tracking | Stored in Redis/Postgres as aggregate counts |

### 3.2 Module B: Mask — Transit

| Data Element | Classification | Direction | Processing | Storage |
|-------------|---------------|-----------|------------|---------|
| Upstream API response (full) | **L3-L4 (contains PII fields)** | Upstream -> Gateway -> Client | JSONPath fields masked per policy (US-B01-B04) | **Never stored.** Only masking metadata logged |
| PII field values (PAN, MSISDN, etc.) | **L4 (PAN) / L3 (other PII)** | Upstream -> Gateway | Detected and masked in body_filter phase | **Never stored in original form.** Only masked version reaches client |
| NER-analyzed text | **L3 (PII text)** | Gateway -> Sidecar | NER entity detection (US-B06) | **Never stored.** Entity types logged (not values) |

### 3.3 Module C: Canary — Transit

| Data Element | Classification | Direction | Processing | Storage |
|-------------|---------------|-----------|------------|---------|
| Request (duplicated for shadow) | **Inherits original classification** | Gateway -> Shadow upstream | Duplicated for shadow diff (US-C06) | Never stored |
| Shadow response | **Inherits original classification** | Shadow upstream -> Sidecar | Compared with primary (status, structure, latency) | Diff metadata stored (L2), not response body |
| Primary response | **Inherits original classification** | Primary upstream -> Client | Normal forwarding | Never stored |

---

## 4. Data Flow Diagram

```
                                    ┌─────────────────┐
                                    │   LLM Provider   │
                                    │  (OpenAI, etc.)  │
                                    └────────▲─────────┘
                                             │ L3-L4 transit
                                             │ (prompts, responses)
┌──────────┐    L3-L4 transit    ┌───────────┴───────────────────┐
│  Client   │ ───────────────►   │        APISIX Gateway          │
│           │ ◄───────────────   │                                │
└──────────┘    L3 masked       │  Shield: scan, count, route    │
                                 │  Mask:   detect, mask, audit   │
                                 │  Canary: split, monitor, diff  │
                                 │                                │
                                 │     gRPC/UDS (L3 transit)      │
                                 │         ▼         ▼            │
                                 │  ┌──────────────────────┐     │
                                 │  │   Java Sidecar        │     │
                                 │  │  NER, tiktoken, diff  │     │
                                 │  └──────────────────────┘     │
                                 └──┬────────────┬───────────────┘
                                    │            │
                              ┌─────▼─────┐ ┌───▼──────────┐
                              │   Redis    │ │  PostgreSQL   │
                              │ L2: quotas │ │ L2: billing   │
                              │ L4: tokens │ │ L3: audit     │
                              └───────────┘ └──────────────┘
```

---

## 5. Masking Patterns (Reference)

Per VISION.md Section 5.2:

| PII Type | Classification | Example (Original) | Example (Masked) | Masking Strategy |
|----------|---------------|-------------------|------------------|-----------------|
| Credit Card (PAN) | **L4** | 4111111111111111 | ****-****-****-1111 | `last4` (Luhn-validated) |
| MSISDN / Phone | **L3** | +90 532 123 45 67 | +90 532 *** 45 67 | Middle digits masked |
| TC Kimlik (National ID) | **L3** | 12345678901 | ****56789** | Configurable |
| IMEI | **L3** | 352091001234567 | 35209100****** | Show TAC (first 8) only |
| Email | **L3** | john.doe@example.com | j***@e***.com | Local part + domain masked |
| IBAN | **L3** | TR330006100519786457841326 | TR33****1326 | Middle sections masked |
| IP Address | **L3** | 192.168.1.100 | 192.168.\*.\* | Last octets masked |
| Date of Birth | **L3** | 1990-05-13 | ****-**-13 | Year/month masked |

---

## 6. AI Agent Data Constraints (Per Data Governance Guideline)

| Rule | Applicability to Aria |
|------|----------------------|
| **[BLOCKING]** AI Agents MUST NOT access L4 data | AI Agents must not access provider API keys, tokenization mappings, or Admin API keys in any environment |
| **[BLOCKING]** AI Agents MUST NOT log L3/L4 in plain text | All log output from AI-generated code must mask PII fields |
| **[REQUIRED]** L3 data access requires human approval | AI Agents debugging masking issues need human approval to view L3 audit excerpts |
| **[ALLOWED]** Work with synthetic data | AI Agents use synthetic PII data for testing (never real PII) |
| **[ALLOWED]** Generate masking logic | AI Agents implement masking rules, validation, and audit logging |

---

## 7. Non-Production Data Strategy

| Environment | L4 Data | L3 Data | L2 Data | L1 Data |
|-------------|---------|---------|---------|---------|
| **Production** | Full access (authorized operators only) | Full access (role-based) | Full access | Open |
| **Staging** | Synthetic API keys, no real PAN | Synthetic PII (generated MSISDN, email, etc.) | Real data OK | Open |
| **Development** | Synthetic only | Synthetic only | Real data OK | Open |
| **CI/CD** | Synthetic only | Synthetic only | Synthetic OK | Open |

**Synthetic Data Requirements:**
- MSISDN: Valid Turkish format (`+90 5XX XXX XX XX`) with non-real numbers
- PAN: Luhn-valid test card numbers (e.g., `4111111111111111`)
- TC Kimlik: Valid-format but non-real 11-digit numbers
- Email: `test-*@example.com` domain
- IBAN: Valid-format but non-real IBANs

---

## 8. Encryption Requirements

| Scope | Standard | Implementation |
|-------|----------|----------------|
| Redis at rest | AES-256 (L4 data: tokenization store) | Redis TDE or application-level encryption for `aria:tokenize:*` keys |
| Redis in transit | TLS 1.3 | Redis TLS configuration |
| PostgreSQL at rest | AES-256 (standard TDE) | Database-level transparent data encryption |
| PostgreSQL in transit | TLS 1.3 | PostgreSQL SSL mode `require` |
| Provider API keys | AES-256 | APISIX secrets management (Vault integration recommended) |
| gRPC/UDS | N/A (local socket) | No network exposure — UDS has file-system permission control |

---

## 9. Retention Summary

| Data Category | Active Retention | Archive | Deletion |
|--------------|-----------------|---------|----------|
| Audit events (Postgres) | 1 year online | 7 years cold storage | Automated partition drop |
| Billing records (Postgres) | 2 years online | 7 years (tax/audit) | Automated partition drop |
| Masking audit (Postgres) | 1 year online | 7 years cold storage | Automated partition drop |
| Quota state (Redis) | Budget period (daily/monthly) | N/A | TTL expiry |
| Circuit breaker state (Redis) | 5 minutes | N/A | TTL expiry |
| Tokenization mappings (Redis) | Configurable TTL | N/A | TTL expiry |
| Audit buffer (Redis) | 1 hour max | N/A | Flushed to Postgres or TTL expiry |
| Application logs | 90 days (Loki) | N/A | Automated rotation |

---

## 10. Compliance Checklist

```
+------------------------------------------+
|     DATA CLASSIFICATION CHECKLIST        |
+------------------------------------------+
| DATA INVENTORY                           |
| [x] All stored data fields classified    |
| [x] All transit data elements classified |
| [x] Data flow diagram documented         |
| [x] Third-party data sharing documented  |
|     (LLM providers receive prompts)      |
+------------------------------------------+
| PROTECTION                               |
| [x] Encryption at rest for L3/L4         |
| [x] Encryption in transit (TLS 1.3)      |
| [x] Data masking patterns defined        |
| [x] Non-prod data strategy defined       |
+------------------------------------------+
| AUDIT                                    |
| [x] Audit trail for L3/L4 access         |
| [x] Retention policies defined           |
| [x] Masking rules for log output         |
+------------------------------------------+
| AI AGENT                                 |
| [x] L4 access forbidden for AI Agents    |
| [x] L3 access requires human approval    |
| [x] Synthetic data strategy for testing  |
+------------------------------------------+
```

---

*Document Version: 1.0 | Created: 2026-04-08*
*Source: VISION.md v1.0, DATA_GOVERNANCE_GUIDELINE.md v3.0.0*
*Status: Draft — Pending Product Owner Approval*
