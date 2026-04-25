# Detecting Turkish Personal Data at the AI Gateway

*A technical deep-dive into TC Kimlik checksum, Turkish-BERT NER, and the trade-offs of regex versus ML for PII detection*

*2026-04-25 · 3eAI Labs Ltd*

When a Turkish bank, telco, or government agency starts routing application traffic to a large-language-model provider, one of the first questions that comes up — and rightly — is how to keep Turkish citizens' personal data from leaking into a third-party processor's pipeline. The KVKK (Kişisel Verilerin Korunması Kanunu, the Turkish Personal Data Protection Law) is more strict than many international comparisons, the audit cycle is real, and the data-minimisation expectation is non-trivial. This post explains how we addressed Turkish PII detection inside Gatekeeper specifically — what the regex layer catches, what the NER layer catches, where the boundaries between them are, and what trade-offs we accepted.

## Why Turkish PII is its own problem

The general AI-governance products on the market in 2025-2026 do a reasonable job with Anglophone PII — names recognised by English NER models, US Social Security Numbers, US-format phone numbers, common email patterns. They do less well with Turkish PII, for two reasons.

The first reason is structural. The TC Kimlik (Turkish national ID) is an eleven-digit number with a specific mod-11 checksum that no commodity PII regex tests for. Without the checksum, you cannot reliably distinguish "11111111110" (an obviously invalid placeholder, fails checksum) from "10000000146" (a structurally-valid TC Kimlik that an actual Turkish citizen owns). Most general-purpose PII patterns either reject any eleven-digit number that begins with "1" (false-positive everywhere) or accept any eleven-digit number (false-negative everywhere); neither is operationally useful. Properly-validating the TC Kimlik catches structurally-valid IDs, ignores random eleven-digit numbers, and produces low false-positive rates on real Turkish prompt content.

The second reason is linguistic. Names, addresses, and free-text descriptions in Turkish are not in the training data of Anglophone NER models in any meaningful sense. The Apache OpenNLP English NER models will recognise "John Smith" as a PERSON with reasonable confidence; they will not recognise "Mehmet Yılmaz" as a PERSON because they were not trained on Turkish names. Even multilingual NER models trained on broad corpora (XLM-R, mBERT, even the larger Llama variants) tend to underperform on Turkish entity recognition compared to Turkish-specific models trained on Turkish text. For a Turkish-jurisdiction deployment, this is the difference between catching most personal data in free-text fields and missing most of it.

We decided early that any Turkish-jurisdiction deployment had to do significantly better than the general-PII-product baseline. This post explains the two layers we built — the Turkish-aware regex layer and the Turkish-BERT NER layer — and the design choices we made about how they interact.

## Layer one: regex with checksum validation

The Lua-side regex layer in Gatekeeper runs first, before any ML inference. There are three reasons it goes first. First, it is fast — a single regex pass over a typical prompt or response payload is sub-millisecond, while an NER inference call involves an HTTP bridge round-trip plus model evaluation, typically 50-200ms depending on payload size and model. Second, it is deterministic — for a structural pattern like a TC Kimlik or a credit card number, the regex with checksum is *more* reliable than an ML model that might or might not have seen that specific pattern in training. Third, it short-circuits the ML layer for fields that are already classified — running NER against text fields that we already know contain a Luhn-valid PAN or a mod-11-valid TC Kimlik is wasted compute and produces noisier downstream results.

The TC Kimlik regex implementation in `apisix/plugins/lib/aria-pii.lua` looks roughly like this (simplified for blog purposes):

```lua
local function is_valid_tc_kimlik(s)
    -- Must be exactly 11 digits
    if not s:match("^%d%d%d%d%d%d%d%d%d%d%d$") then
        return false
    end

    -- First digit cannot be 0
    if s:sub(1, 1) == "0" then
        return false
    end

    local digits = {}
    for i = 1, 11 do
        digits[i] = tonumber(s:sub(i, i))
    end

    -- 10th digit checksum: ((sum of odd-positioned digits 1-9 * 7) -
    --                      (sum of even-positioned digits 2-8)) mod 10
    local odd_sum = digits[1] + digits[3] + digits[5] + digits[7] + digits[9]
    local even_sum = digits[2] + digits[4] + digits[6] + digits[8]
    local digit10 = ((odd_sum * 7) - even_sum) % 10
    if digit10 ~= digits[10] then
        return false
    end

    -- 11th digit checksum: (sum of digits 1-10) mod 10
    local total_sum = 0
    for i = 1, 10 do
        total_sum = total_sum + digits[i]
    end
    if (total_sum % 10) ~= digits[11] then
        return false
    end

    return true
end
```

The mod-11 checksum is what makes this useful. Without it, every eleven-digit number in a prompt would be flagged as a candidate TC Kimlik and the false-positive rate would make the detection unusable. With it, the false-positive rate drops to genuinely random eleven-digit numbers that happen to satisfy both checksums by coincidence — which is rare enough that the few false positives that do occur can be tolerated and tagged for operator review.

The same checksum-aware approach is taken for the seven other built-in PII patterns:

- **PAN (credit card number)** uses the Luhn checksum, which is the international standard for credit card validation and rules out essentially all non-card numbers that happen to be 13-19 digits long.
- **MSISDN (phone number)** uses country-code-aware parsing — Turkish mobile numbers start with +90 5XX, landlines have specific patterns, and the regex tolerates the common formatting variants (with or without country code, with or without separator characters).
- **IBAN** uses the ISO-7064 mod-97 checksum, which is the international standard for IBAN validation. Turkish IBANs (TR followed by 24 digits) get the same validation as German, French, or any other IBAN.
- **IMEI** uses the Luhn checksum (yes, IMEIs use Luhn too — the same algorithm credit cards use), which catches structurally-valid IMEIs and rules out random fifteen-digit sequences.
- **Email** uses a permissive RFC-5322-compatible regex that catches the common forms without trying to fully validate the RFC's edge cases.
- **IP address** matches IPv4 dotted-quad and IPv6 in the standard textual representations.
- **Date-of-birth** matches common Turkish (DD.MM.YYYY) and ISO (YYYY-MM-DD) formats with reasonable bounds checking.

For each of these, the implementation in `aria-pii.lua` applies the structural pattern first and the checksum (where applicable) second. A field that matches both is classified with high confidence as that PII type and is sent through the configured mask strategy in the Mask plugin's response pipeline.

## Layer two: Turkish-BERT NER for everything else

The regex layer is good at structural patterns. It is not good at the things regex layers are universally bad at — names embedded in sentences, addresses in free-text, descriptions of life circumstances in benefit applications, references to family members in clinical notes. For these, you need named-entity recognition.

We chose `savasy/bert-base-turkish-ner-cased` as the default Turkish NER model. The reasons are unglamorous but solid: it was trained specifically on Turkish text, it is available on HuggingFace under MIT-compatible licensing, it converts cleanly to ONNX format (which is what we run it as inside the Java sidecar via Deep Java Library and ONNX Runtime), and the entity labels it produces (PERSON, LOCATION, ORGANIZATION, MISC) align directly with the categories that data-protection frameworks care about.

The conversion to ONNX is a one-time operation that the operator does as part of deployment setup. The recipe is documented in [`runtime/docs/NER_MODELS.md`](../../../runtime/docs/NER_MODELS.md) — essentially `optimum-cli export onnx --model savasy/bert-base-turkish-ner-cased` with the appropriate task argument, then mount the resulting `model.onnx` and `tokenizer.json` into the sidecar's model directory. We deliberately do not bundle the model weights in the slim community-tier container image (it would push the image size from a few hundred MB to roughly 1 GB), but the enterprise DPO tier ships with the model bundled for operators who want a single-container deployment.

The runtime inference path is straightforward enough to describe in prose. The Mask plugin's Lua side, after running the regex pass, identifies fields that did not match a structural pattern and that the operator's policy says should be NER-checked. Those fields' contents are batched into a single HTTP `POST /v1/mask/detect` call to the sidecar, with the language hint set (typically `tr` for Turkish-jurisdiction deployments, but configurable per route). The sidecar's `MaskController` receives the call, hands it to `NerDetectionService`, which fans out to whatever engines are registered in `aria.mask.ner.engines` configuration. For a typical Turkish-jurisdiction deployment, both engines are registered: OpenNLP for English content (the inference is fast and the engine is permanently loaded in JVM heap) and the DJL HuggingFace engine for Turkish content (loaded as ONNX, a few hundred MB resident). Each engine returns its detected spans; `NerDetectionService` unions and dedupes the results, applies the `min_confidence` filter (default 0.7, configurable), and returns the merged list.

The Mask plugin then maps the returned spans back to field paths in the original payload (the `assign_entities_to_parts` Lua function does this — it tracks character offsets so that an entity detected at character 47-58 in the concatenated content is correctly attributed to whichever JSON field originally contained that text), applies the configured mask strategy to each detected entity, and emits the masking-audit event.

## The two-layer circuit breaker

The NER bridge call is an HTTP call, and HTTP calls fail in operationally-interesting ways — the sidecar might be unreachable, the model might be slow, the JVM might hit a GC pause. Without protection, a sustained sidecar issue could cause the Mask plugin to time-out on every request, which is unacceptable for a hot-path component.

We protect the bridge with two layers of circuit breaker. The outer layer lives in Lua, in `aria-circuit-breaker.lua`, backed by `ngx.shared.dict` so the state is shared across OpenResty workers. It tracks per-endpoint failure counts in a sliding window, opens after the configured failure threshold (default: 5 failures within a 30-second window), and short-circuits subsequent calls during the cooldown window (default: 30 seconds). When the cooldown expires, it transitions to a half-open state and lets through a small number of probe calls; if those succeed, the breaker closes; if they fail, the cooldown extends.

The inner layer lives in Java, inside the sidecar, implemented via Resilience4j wrapping the `NerDetectionService` call. It protects the engine itself from sustained downstream failures — for example, if the ONNX model file becomes corrupted or the Turkish-BERT engine starts throwing on every inference, the inner breaker trips and `NerDetectionService` returns an empty result set rather than continuing to try. Both breakers emit Prometheus metrics so operators can see when each is tripping.

The defense-in-depth pattern matters because the failure modes the two breakers protect against are different. The outer breaker (Lua) protects the gateway from waste — it saves the cost of opening an HTTP connection and waiting for a response when the sidecar has already shown it is unresponsive. The inner breaker (Java) protects the engine from compounding failures — if the engine is repeatedly throwing because of a model file corruption, retrying is not going to help and consuming JVM thread resources doing so makes the situation worse. Either breaker on its own would be incomplete; both together cover the failure modes that occur in practice.

## The fail-mode policy

When the NER bridge fails — circuit open, sidecar unreachable, timeout exceeded — the Mask plugin needs to decide what to do. Two policies are configurable: `open` (the availability-first default — return regex-only results, accept that some PII will go through unmasked) and `closed` (the defensive option — redact all candidate fields, accept that some legitimate fields will be over-masked). The choice is per-route; operators set it based on their tolerance for false-negative versus false-positive in the specific use case.

This is one of the small design choices that has the biggest effect on whether the product fits a specific deployment. A customer-care assistant where an over-masked field would frustrate the agent might use `open` mode. An external-facing API where an unmasked PII field would be a compliance incident might use `closed` mode. The same plugin, the same NER bridge, the same fail-over: the policy is what determines what the plugin actually does in the failure case.

## What this looks like in production

A typical Turkish-jurisdiction deployment running both layers sees the following pattern in production. The vast majority of structural PII (TC Kimlik, IBAN, MSISDN, PAN, IMEI) is caught by the regex layer in sub-millisecond time, with checksum validation keeping the false-positive rate to genuinely random matches that happen to satisfy the checksum by coincidence (rare enough that operator review is feasible). Free-text fields (names in clinical notes, addresses in benefit applications, descriptions of personal circumstances in support tickets) are routed to the NER bridge, which catches the entities the regex layer misses. The Lua circuit breaker keeps the gateway safe from sidecar-side problems; the JVM circuit breaker keeps the sidecar safe from engine-side problems. The fail-mode policy lets operators tune the failure-case behaviour to the specific use case.

The metrics that operators watch in production are unsurprising: `aria_mask_ner_calls_total{route, result}` shows the NER call rate split by success/failure result, `aria_mask_ner_latency_ms` shows the bridge latency distribution, `aria_mask_ner_entities_total{type}` shows the per-entity-type detection rate, and `aria_mask_ner_circuit_state{endpoint}` shows the circuit-breaker state as a gauge. The combination of these tells operators whether the NER bridge is healthy, what it is detecting, and whether the failure-case behaviour is being exercised.

## What we did not do, and why

We did not build a custom Turkish NER model. The `savasy/bert-base-turkish-ner-cased` model is well-tuned for general Turkish text, has community traction, and is permissively licensed. Building our own would have been a months-long effort that produced a marginally different output, which was not a good use of time when a production-quality alternative existed. Operators who need a custom Turkish-NER model — for example, clinical-NER trained on Turkish medical records — can plug it in through the existing `NerEngine` interface; the architecture supports it directly and we have not seen a reason to constrain that flexibility.

We did not pretend that NER catches everything. Some categories of personal data are not entity-shaped — for example, "the patient with the rare condition X who lives near the only specialist clinic in city Y" can identify a specific individual without any named entity appearing in the text. NER is one tool in the data-minimisation toolkit, not the whole toolkit. The role-based policies in the Mask plugin let operators apply additional conservatism to fields where free-text descriptions might contain identification-by-implication that NER cannot catch.

We did not bundle the model weights in the community image. The slim image is a few hundred megabytes; the bundled image with the Turkish-BERT model is roughly 1 GB. The split was deliberate — operators who want the slim image can pull the model separately (the documented one-command export), and operators who want the bundled image can use the enterprise-DPO build that ships with it. Both options exist; operators choose based on their deployment constraints.

## Where to go from here

If you are running an LLM integration that handles Turkish citizen data and you are thinking about how to add PII detection in front of it, the [QUICK_START](../../05_user/QUICK_START.md) is the ten-minute path to a working stack with both layers active. The [DATASHEET](../product/DATASHEET.md) has the technical specifics of every shipped capability. The [solution brief for public sector](../solutions/SOLUTION_BRIEF_public_sector.md), [for banking](../solutions/SOLUTION_BRIEF_banking.md), and [for telecommunications](../solutions/SOLUTION_BRIEF_telco.md) cover the sector-specific evaluation considerations.

If you are building a competing product or a custom version of this for your own organisation, the code is on [GitHub](https://github.com/3eAI-Labs/gatekeeper) under Apache 2.0 — `aria-pii.lua` is where the regex layer lives, the `mask/ner/` package in the sidecar repo is where the NER engine lives, and the `aria-circuit-breaker.lua` shared library is the per-endpoint breaker that wraps any sidecar HTTP bridge. We are happy to answer questions about specific implementation choices over email at `levent.genc@3eai-labs.com`.

— Levent
