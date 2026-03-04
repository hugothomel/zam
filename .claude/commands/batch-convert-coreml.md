# Batch Convert New ONNX Models to CoreML and Upload to GCS

Convert ONNX world models from the Forge training pipeline into compiled CoreML `.mlmodelc` bundles, then upload them to GCS for the Zam iOS app to fetch dynamically.

## Workflow

1. Fetch ONNX index from GCS (lists all trained models)
2. Fetch CoreML index from GCS (lists already-converted models)
3. Diff to find new models that need conversion
4. For each new model: download ONNX → convert → compile → upload .mlmodelc
5. Update the CoreML index.json on GCS

## Step-by-Step Instructions

### Step 1: Fetch the ONNX model index

```bash
gsutil cat gs://alakazam-forge-data/onnx/index.json
```

If `gsutil` isn't available, use the signer API:

```bash
curl -s "https://onnx-signer-294479657775.us-west1.run.app/?action=index"
```

Parse the JSON. Each entry has: `id`, `name`, `description`, `game_id`, `config` (C, H, W, T, num_actions, action_names, default_action), `denoiser` settings, `decoder` settings, and `paths` (relative to the ONNX bucket).

### Step 2: Fetch the CoreML index

```bash
gsutil cat gs://alakazam-models/coreml/index.json
```

If this file doesn't exist yet, create an empty index:

```json
{
  "version": 1,
  "updated_at": "",
  "models": []
}
```

### Step 3: Diff the indexes

Compare model IDs. Any model ID present in the ONNX index but absent from the CoreML index needs conversion.

If no new models, print "All models up to date" and stop.

### Step 4: Convert each new model

For each new model ID:

#### 4a. Create temp directory

```bash
mkdir -p /tmp/coreml_convert/{id}
```

#### 4b. Download ONNX files

```bash
gsutil cp gs://alakazam-forge-data/onnx/{id}/denoiser.onnx /tmp/coreml_convert/{id}/
gsutil cp gs://alakazam-forge-data/onnx/{id}/init_state.json /tmp/coreml_convert/{id}/
# Only if the model has a decoder (is_latent=true):
gsutil cp gs://alakazam-forge-data/onnx/{id}/decoder.onnx /tmp/coreml_convert/{id}/
```

#### 4c. Run conversion

Use the lossless conversion script with the forge venv:

```bash
/Users/hugohernandez/labzone/alakazam-forge/.venv/bin/python3 \
  /Users/hugohernandez/labzone/zam/Scripts/convert_onnx_lossless.py \
  --onnx-dir /tmp/coreml_convert/{id} \
  --output-dir /tmp/coreml_convert/{id}/output
```

This script:
- Auto-detects model config from ONNX weight shapes
- Reconstructs the PyTorch model using forge architecture classes
- Auto-discovers unnamed GroupNorm parameters via graph tracing
- Wraps in inference wrapper (c_noise_cond = zeros for consistency models)
- Traces → converts to CoreML .mlpackage
- Compiles via `xcrun coremlcompiler` to .mlmodelc
- Also converts the decoder if decoder.onnx is present

Output files in `/tmp/coreml_convert/{id}/output/`:
- `denoiser.mlmodelc/` (compiled)
- `decoder.mlmodelc/` (compiled, if latent model)
- `init_state.json` (copied)

#### 4d. Upload compiled models to GCS

```bash
gsutil -m cp -r /tmp/coreml_convert/{id}/output/denoiser.mlmodelc gs://alakazam-models/coreml/{id}/
gsutil cp /tmp/coreml_convert/{id}/output/init_state.json gs://alakazam-models/coreml/{id}/
# If decoder exists:
gsutil -m cp -r /tmp/coreml_convert/{id}/output/decoder.mlmodelc gs://alakazam-models/coreml/{id}/
```

### Step 5: Update the CoreML index

Add new model entries to the CoreML index. Each entry should carry over config from the ONNX index:

```json
{
  "id": "{id}",
  "name": "Model Name",
  "description": "Description from ONNX index",
  "game_id": "{game_id}",
  "is_latent": true,
  "config": {
    "C": 4, "H": 64, "W": 64, "T": 4,
    "num_actions": 5,
    "action_names": ["NOOP", "FORWARD", "LEFT", "RIGHT", "SHOOT"],
    "default_action": 0
  },
  "denoiser": {
    "num_steps": 1,
    "sigma_min": 0.002,
    "sigma_max": 5.0
  },
  "decoder": {
    "output_h": 256,
    "output_w": 256,
    "latent_scale_min": null,
    "latent_scale_max": null
  },
  "paths": {
    "denoiser": "coreml/{id}/denoiser.mlmodelc",
    "decoder": "coreml/{id}/decoder.mlmodelc",
    "init_state": "coreml/{id}/init_state.json"
  }
}
```

Paths are relative to `https://storage.googleapis.com/alakazam-models/`.

Upload the updated index:

```bash
gsutil cp /tmp/coreml_convert/index.json gs://alakazam-models/coreml/index.json
```

### Step 6: Clean up

```bash
rm -rf /tmp/coreml_convert/
```

## Key References

- **Conversion script**: `/Users/hugohernandez/labzone/zam/Scripts/convert_onnx_lossless.py`
- **Forge venv**: `/Users/hugohernandez/labzone/alakazam-forge/.venv/bin/python3`
- **ONNX bucket**: `gs://alakazam-forge-data/onnx/`
- **CoreML bucket**: `gs://alakazam-models/coreml/`
- **GCS public base**: `https://storage.googleapis.com/alakazam-models/`
- **ONNX signer API**: `https://onnx-signer-294479657775.us-west1.run.app/?action=index`

## Important Notes

- The conversion script requires the forge codebase at `/Users/hugohernandez/labzone/alakazam-forge` for model architecture classes
- `c_noise_cond` is set to zeros for consistency models (noise_previous_obs=False). If a model was trained with noise_previous_obs=True, the script would need modification
- CoreML prev_act input is float32 (even though PyTorch uses int64)
- The .mlmodelc bundles are pre-compiled — no on-device compilation needed
- The Zam app fetches `coreml/index.json` on launch and dynamically adds new models to the feed
