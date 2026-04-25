# Security Policy

## Supported versions

Only the latest minor version receives security patches. As of 2026-04-25, that is **v0.1.x** (community tier). Once v0.2.0 ships, v0.1.x will receive critical security patches for one further minor release cycle, after which it is end-of-life.

| Version | Status | Security patches |
|---|---|---|
| v0.1.1 | ✅ Current | Yes |
| v0.1.0 | ⚠️ Superseded by v0.1.1 (same-day patch — closes FINDING-005) | Use v0.1.1 |
| v0.1.0-pre-freeze (2026-04-08, never publicly released) | ❌ Never released | n/a |

Enterprise tier customers (CISO Security · DPO Privacy · CFO FinOps) receive security patches per their commercial SLA.

## Reporting a vulnerability

**Do NOT open a public GitHub issue for security vulnerabilities.** Public disclosure before a patch is available puts every operator at risk.

Send the report to **`security@3eai-labs.com`**, ideally encrypted with our PGP key (planned — until the key is published, plain e-mail is acceptable for the initial contact and we'll co-ordinate an encrypted channel for the technical detail).

**Include in your report:**
- A description of the vulnerability and the affected component (Lua plugin? Java sidecar? Helm chart? Documentation that misleads operators into an insecure configuration?)
- Reproduction steps — minimal, executable; we'll work from your reproducer
- Affected version(s)
- Your assessment of impact (data exposure / privilege escalation / denial of service / availability / confidentiality / integrity)
- Whether you believe this is being exploited in the wild (we hope not, but please tell us)
- Whether you'd like credit in the eventual advisory (and the name / handle to use)

We will **not** ask you to refrain from publishing your finding — we ask only that you give us a reasonable disclosure window (see below) before you do so.

## Our response timeline

| Step | Target |
|---|---|
| Acknowledge receipt | Within 2 business days |
| Initial triage (severity assessment + scope confirmation) | Within 5 business days |
| Patch development for confirmed Critical/High | Within 14 calendar days |
| Patch development for confirmed Medium/Low | Within 30 calendar days |
| Co-ordinated public disclosure | After patch is shipped, typically within 7 days of patch release |

We use **CVSS v3.1** for severity scoring. The maintainer's assessment is the working severity unless you supply a defensible counter-score.

## What we consider in scope

✅ **In scope:**
- Vulnerabilities in the Lua plugins (`apisix/plugins/aria-{shield,mask,canary}.lua` + `apisix/plugins/lib/*.lua`)
- Vulnerabilities in the `aria-runtime` Java sidecar code
- Vulnerabilities in the Helm chart, docker-compose configuration, or shipped Dockerfile that lead operators into insecure deployments by default
- Documentation that prescribes an insecure configuration or omits a security-relevant warning
- Vulnerabilities in our build / release / CI pipelines that could lead to supply-chain compromise

❌ **Out of scope:**
- Vulnerabilities in upstream APISIX, Spring Boot, Lettuce, R2DBC, jtokkit, OpenNLP, DJL, ONNX Runtime, etc. — please report those to the upstream project. We'll bump our pinned version once they ship a fix.
- Operator misconfigurations (running with default secrets in production, exposing the sidecar's loopback port to the public internet, granting the sidecar DDL on a shared cluster). Documentation gaps that *enable* misconfiguration are in scope; the misconfiguration itself is not.
- Findings against `v0.1.0-pre-freeze` (the never-publicly-released 2026-04-08 baseline). Re-test against `v0.1.1` first.
- DoS via known-expensive operations called legitimately (e.g. submitting a 10 MB body for NER inference). Use rate limiting in front of the gateway. New DoS classes (e.g. quadratic complexity in a parser) are in scope.
- Theoretical vulnerabilities without a working reproducer, unless the theoretical case is straightforward to demonstrate.

## What we do not do

- **No bug bounty.** We are a small team. We deeply appreciate responsible disclosures and will credit you in the advisory; we cannot pay for them.
- **No "security hall of fame" page.** Each advisory credits the reporter individually (with permission).
- **No legal threats for good-faith security research.** Test against your own deployments only; don't test against `3eai-labs.com` or any operator we host without explicit prior permission.

## Public security advisories

Confirmed and patched vulnerabilities will be published as GitHub Security Advisories on this repository. The advisory will include CVE assignment (where applicable), CVSS score, affected versions, mitigation guidance, patched versions, and credit (with reporter's permission).

---

**Maintainer:** Levent Sezgin Genç (3eAI Labs Ltd)
**Security contact:** `security@3eai-labs.com`
**General contact:** `levent.genc@3eai-labs.com`
