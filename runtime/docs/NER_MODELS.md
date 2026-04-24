# NER Models for the Mask Sidecar

The `aria-runtime` sidecar ships with the NER **engine code** but not with the
model artefacts, because bundling them would push the image size from ~200 MB
to ~600 MB even for deployments that don't need NER. Install the models you
need per the recipes below; the registry auto-skips engines whose files are
missing.

## Option A — Apache OpenNLP (English)

Official pre-trained models for English PERSON / LOCATION / ORGANIZATION.
Apache 2.0 licensed, ~10 MB per model, no GPU required.

```bash
MODELS_DIR=/opt/aria/models/opennlp
sudo mkdir -p "$MODELS_DIR"
cd "$MODELS_DIR"

# These URLs point to the OpenNLP maintained releases on SourceForge;
# mirror them inside your organisation if you need an airgapped build.
curl -L -o en-ner-person.bin       https://opennlp.sourceforge.net/models-1.5/en-ner-person.bin
curl -L -o en-ner-location.bin     https://opennlp.sourceforge.net/models-1.5/en-ner-location.bin
curl -L -o en-ner-organization.bin https://opennlp.sourceforge.net/models-1.5/en-ner-organization.bin
```

Point the sidecar at them:

```yaml
aria:
  mask:
    ner:
      engines: ["opennlp"]
      opennlp:
        models-dir: /opt/aria/models/opennlp
```

## Option B — Turkish BERT via DJL + ONNX Runtime

Default target: [`savasy/bert-base-turkish-ner-cased`](https://huggingface.co/savasy/bert-base-turkish-ner-cased)
(MIT licence). Train-set includes Turkish news/wiki with high-quality
person/location/organization coverage — strong fit for TR kamu
(government) and kurumsal (enterprise) workloads.

### One-time: export to ONNX

The engine reads ONNX (not HuggingFace Transformers) so inference needs no
Python runtime. Export once, distribute the artefacts.

```bash
# Requires Python with optimum[exporters] and onnx:
pip install "optimum[exporters]" onnx onnxruntime transformers

MODELS_DIR=/opt/aria/models/turkish-bert
mkdir -p "$MODELS_DIR"

optimum-cli export onnx \
  --model savasy/bert-base-turkish-ner-cased \
  --task token-classification \
  --opset 14 \
  "$MODELS_DIR"

# After export, only two files are needed at runtime:
#   $MODELS_DIR/model.onnx
#   $MODELS_DIR/tokenizer.json
# The exporter writes additional files; you can slim by removing the rest.
```

### Point the sidecar at it

```yaml
aria:
  mask:
    ner:
      engines: ["turkish-bert"]          # or ["opennlp", "turkish-bert"] for both
      turkish-bert:
        model-path: /opt/aria/models/turkish-bert/model.onnx
        tokenizer-path: /opt/aria/models/turkish-bert/tokenizer.json
        # Default labels match savasy/bert-base-turkish-ner-cased.
        # Override only if using a different checkpoint:
        # labels: ["O", "B-PER", "I-PER", "B-ORG", "I-ORG", "B-LOC", "I-LOC"]
```

### Option B.1 — Bundled image (airgapped)

To bake the Turkish model into the sidecar bootJar (good for airgapped
kamu deployments), place the files under
`src/main/resources/models/turkish-bert/` before building:

```bash
mkdir -p aria-runtime/src/main/resources/models/turkish-bert
cp "$MODELS_DIR/model.onnx"      aria-runtime/src/main/resources/models/turkish-bert/
cp "$MODELS_DIR/tokenizer.json"  aria-runtime/src/main/resources/models/turkish-bert/

./gradlew bootJar -PwithTurkishNer=true
```

The resulting JAR is ~400 MB larger but self-contained.

## Option C — Any other HuggingFace token-classification model

The `turkish-bert` engine is mis-named for historical reasons — it is a
generic HuggingFace NER loader. Point it at any `AutoModelForTokenClassification`
that has been exported to ONNX:

```yaml
aria:
  mask:
    ner:
      turkish-bert:
        id: my-custom-ner             # engines list uses this id
        model-path: /opt/aria/models/custom/model.onnx
        tokenizer-path: /opt/aria/models/custom/tokenizer.json
        labels: ["O", "B-PERSON", "I-PERSON", ...]  # must match model output order
```

Examples known to work:

| Model | Language | Licence |
|-------|----------|---------|
| `savasy/bert-base-turkish-ner-cased` | Turkish | MIT |
| `akdeniz27/bert-base-turkish-cased-ner` | Turkish | MIT |
| `Davlan/bert-base-multilingual-cased-ner-hrl` | Multilingual (10 langs) | Apache 2.0 |
| `Babelscape/wikineural-multilingual-ner` | Multilingual (9 langs) | CC-BY-NC-SA |

Check each model's licence against your deployment context.

## Verification

After installing models, restart the sidecar and check the startup log:

```
OpenNLP NER engine: loaded 3 model(s) from /opt/aria/models/opennlp: [person, location, organization]
DJL/HF NER engine [turkish-bert] ready: inputs=[input_ids, attention_mask, token_type_ids] labels=7 needsTokenTypeIds=true
NER pipeline: registered engine 'opennlp' (ready=true)
NER pipeline: registered engine 'turkish-bert' (ready=true)
NER pipeline assembled with 2 engine(s), minConfidence=0.7
```

If an engine reports `not ready`, check the log line immediately above for the
cause (missing file, permissions, unsupported ONNX opset).
