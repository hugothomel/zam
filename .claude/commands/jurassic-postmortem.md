# Jurassic Model: Conversion Postmortem

Explain how we solved the jurassic game integration. Use this as reference when converting future ONNX latent models to CoreML.

## Model Identity

- **GCS name**: `jurassic_test_deploy_remix` (ID `c257bd31-f303-4d45-9c0f-0a374b7ef9fd`)
- **Architecture**: Latent-space consistency model (C=4, H=64, W=64, T=4, 3 actions)
- **UNet**: 4 levels, channels `[32, 64, 128, 256]`, depths `[2, 2, 2, 2]`, attention at levels 2-3
- **Files**: denoiser.onnx (79.5 MB), decoder.onnx (0.1 MB), init_state.json (1.3 MB)

## Bugs Hit (in order)

### 1. 26 Unnamed GroupNorm Weights

The ONNX model had 277 named weights (`denoiser.*`) plus 26 unnamed tensors with shape `(C, 1, 1)`. These were GroupNorm scale/bias parameters — ONNX export decomposes `GroupNorm` into `InstanceNorm(default) -> Mul(scale) -> Add(bias)`, losing the original parameter names.

**Fix**: Parse the PyTorch module path directly from the Add node output name (e.g. `/inner_model/unet/d_blocks.2/resblocks.0/attn/norm/norm/Add_output_0` maps to `inner_model.unet.d_blocks.2.resblocks.0.attn.norm.norm.bias`). Squeeze `(C, 1, 1)` to `(C,)` for PyTorch GroupNorm. Result: 303/303 weights loaded.

### 2. `c_noise_cond` Bug (Same as Tube Runner dc27ab1)

The export wrapper passed `c_noise` for both sigma and sigma_cond:
```python
model_output = self._inner_forward(rescaled_noise, c_noise, c_noise, ...)  # WRONG
```
For consistency models (1-step), `sigma_cond` must be **zeros** because inference denoises to the clean signal. The web ONNX runtime passes 0 for `sigma_cond`, but the CoreML conversion baked the wrong value in.

**Fix**:
```python
c_noise_cond = torch.zeros_like(c_noise)  # NOT c_noise
model_output = self._inner_forward(rescaled_noise, c_noise, c_noise_cond, ...)
```

### 3. CoreML Truncated Quantization Chain

The wrapper included a quantization round-trip: `.clamp(-1,1).add(1).div(2).mul(255).floor().div(255).mul(2).sub(1)`. CoreML's optimizer truncated after `.floor()`, producing output in `[0, 255]` instead of `[-1, 1]`.

**Fix**: Remove quantization entirely — it's unnecessary for CoreML inference. The denoiser should output raw `[-1, 1]` values.

### 4. Decoder Architecture Mismatches (3 sub-bugs)

The forge's built-in `Decoder` class didn't match the ONNX graph (1/20 weights matched). A custom `OnnxDecoder` was built, but had three activation placement errors:

| Bug | ONNX Graph | Initial PyTorch |
|-----|-----------|----------------|
| After `conv2` in ResBlock | No activation | Had SiLU (extra) |
| After `ConvTranspose2d` | SiLU | No activation (missing) |
| After `conv_in` | SiLU | No activation (missing) |
| Final output | `Clip(-1, 1)` | No clamping (missing) |

These caused decoder output in `[-17.89, 10.41]` instead of `[-1, 1]`, rendering as a cyan dotted grid.

**Fix**: Match activation placement exactly to the ONNX graph. The correct decoder architecture:
```
conv_in (4->32, 3x3) -> SiLU
up_block_0: conv1->SiLU->conv2->residual_add -> ConvTranspose(32->16, stride=2) -> SiLU
up_block_1: conv1->SiLU->conv2->residual_add -> ConvTranspose(16->8, stride=2) -> SiLU
conv_out: conv1->SiLU->conv2->residual_add -> Conv(8->3, 3x3) -> Clip(-1, 1)
```

## Key Config Values

- **Latent scale**: min=-8.824, max=9.229 (from GCS model config)
- **Actions**: `["NOOP", "LEFT", "RIGHT"]`
- **Denoiser**: 1-step consistency, sigmaMin=0.002, sigmaMax=5.0

## Conversion Script

The generalized script lives at `Scripts/convert_onnx_lossless.py`. It handles GroupNorm auto-discovery, architecture detection, and the c_noise_cond fix for all models.

## Lessons for Future Conversions

1. **Always check `c_noise_cond`**: Consistency models (numSteps=1) need `sigma_cond=zeros`. Multi-step diffusion models may need `sigma_cond=c_noise`. Verify against the web runtime.
2. **Don't add quantization**: CoreML's graph optimizer can truncate operation chains. Output raw float values.
3. **Trace the ONNX decoder graph node-by-node**: Don't assume the forge `Decoder` class matches. Export decompositions change activation placement.
4. **Check for unnamed ONNX tensors**: GroupNorm parameters get unnamed during export. Use output path parsing to map them back.
5. **Validate output ranges at every stage**: PyTorch output, CoreML output, decoder output should all be in `[-1, 1]`. If not, something is wrong.
