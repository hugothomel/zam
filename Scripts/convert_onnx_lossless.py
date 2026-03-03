#!/usr/bin/env python3
"""
Lossless ONNX → CoreML conversion for world model denoiser + decoder.

Automatically discovers unnamed GroupNorm scale/bias tensors in the ONNX graph
and maps them to PyTorch state dict names by tracing graph adjacency.

Usage:
    /path/to/forge/.venv/bin/python convert_onnx_lossless.py \
        --onnx-dir /tmp/jurassic_onnx \
        --output-dir /tmp/jurassic_coreml
"""

import argparse
import json
import os
import shutil
import subprocess
import sys

import coremltools as ct
import numpy as np
import onnx
import torch
import torch.nn as nn
from onnx import numpy_helper

FORGE_PATH = "/Users/hugohernandez/labzone/alakazam-forge"


# ---------------------------------------------------------------------------
# ONNX graph tracing: auto-map unnamed GroupNorm params to PyTorch names
# ---------------------------------------------------------------------------

def build_graph_maps(model):
    output_to_node = {}
    consumers_map = {}
    for node in model.graph.node:
        for out in node.output:
            output_to_node[out] = node
        for inp in node.input:
            consumers_map.setdefault(inp, []).append(node)
    return output_to_node, consumers_map


def trace_forward_named(output_name, consumers_map, max_depth=12):
    """BFS forward to find named denoiser.* weights nearby."""
    visited = set()
    queue = [(output_name, 0)]
    results = []
    while queue:
        name, depth = queue.pop(0)
        if depth > max_depth or name in visited:
            continue
        visited.add(name)
        for node in consumers_map.get(name, []):
            for inp in node.input:
                if inp.startswith("denoiser.") and "weight" in inp:
                    results.append((depth, inp))
            for out in node.output:
                queue.append((out, depth + 1))
    return sorted(results)


def auto_discover_groupnorm_mapping(model):
    """
    Auto-discover unnamed GroupNorm scale/bias in the ONNX graph.

    GroupNorm is decomposed as:
      InstanceNorm(default scale/bias) → Mul(trained scale) → Add(trained bias)

    Strategy 1: Add output names contain the PyTorch path directly, e.g.
      /inner_model/unet/d_blocks.2/resblocks.0/attn/norm/norm/Add_output_0
    Strategy 2 (fallback): Add output is group_norm_N — trace forward to find
      the nearest named weight to determine the module path.
    """
    init_map = {init.name: init for init in model.graph.initializer}
    output_to_node, consumers_map = build_graph_maps(model)

    mapping = {}

    # Find all Add nodes that use unnamed trained (C,1,1) tensors
    for node in model.graph.node:
        if node.op_type != "Add":
            continue

        # Find bias tensor (unnamed initializer with shape (C,1,1))
        bias_name = None
        mul_output = None
        for inp in node.input:
            if inp in init_map and not inp.startswith("denoiser."):
                arr = numpy_helper.to_array(init_map[inp])
                if len(arr.shape) == 3 and arr.shape[1] == 1 and arr.shape[2] == 1:
                    bias_name = inp
            elif inp in output_to_node:
                mul_output = inp

        if not bias_name:
            continue

        # Check if trained
        bias_arr = numpy_helper.to_array(init_map[bias_name])
        if np.allclose(bias_arr, 0.0, atol=1e-5):
            # Check scale too — if both default, skip
            scale_name = None
            if mul_output and mul_output in output_to_node:
                mul_node = output_to_node[mul_output]
                if mul_node.op_type == "Mul":
                    for inp in mul_node.input:
                        if inp in init_map and not inp.startswith("denoiser."):
                            arr = numpy_helper.to_array(init_map[inp])
                            if len(arr.shape) == 3 and arr.shape[1] == 1 and arr.shape[2] == 1:
                                scale_name = inp
            if scale_name:
                scale_arr = numpy_helper.to_array(init_map[scale_name])
                if np.allclose(scale_arr, 1.0, atol=1e-5):
                    continue  # Both default, skip
            else:
                continue

        # Find scale tensor from the Mul node feeding into Add
        scale_name = None
        if mul_output and mul_output in output_to_node:
            mul_node = output_to_node[mul_output]
            if mul_node.op_type == "Mul":
                for inp in mul_node.input:
                    if inp in init_map and not inp.startswith("denoiser."):
                        arr = numpy_helper.to_array(init_map[inp])
                        if len(arr.shape) == 3 and arr.shape[1] == 1 and arr.shape[2] == 1:
                            scale_name = inp

        if not scale_name:
            continue

        gn_output = node.output[0]

        # Strategy 1: output name contains PyTorch path
        # e.g. /inner_model/unet/d_blocks.2/resblocks.0/attn/norm/norm/Add_output_0
        if "/norm/norm/" in gn_output or "/norm_out/norm/" in gn_output:
            # Extract path: strip leading / and trailing /Add_output_0
            path = gn_output.split("/Add_output_0")[0].lstrip("/")
            # Convert slashes to dots: inner_model/unet/... → inner_model.unet....
            pytorch_path = "denoiser." + path.replace("/", ".")
            mapping[scale_name] = pytorch_path + ".weight"
            mapping[bias_name] = pytorch_path + ".bias"
            continue

        # Strategy 2: group_norm_N style — trace forward
        if gn_output.startswith("group_norm_"):
            forward = trace_forward_named(gn_output, consumers_map)
            if not forward:
                continue
            next_weight = forward[0][1]
            if ".attn.qkv_proj.weight" in next_weight:
                base = next_weight.replace(".attn.qkv_proj.weight", ".attn.norm.norm")
                mapping[scale_name] = base + ".weight"
                mapping[bias_name] = base + ".bias"
            elif "conv_out.weight" in next_weight:
                base = next_weight.replace("conv_out.weight", "norm_out.norm")
                mapping[scale_name] = base + ".weight"
                mapping[bias_name] = base + ".bias"

    return mapping


# ---------------------------------------------------------------------------
# Weight extraction and model building
# ---------------------------------------------------------------------------

def extract_all_weights(onnx_path):
    """Extract ALL weights from ONNX, including auto-mapped unnamed GroupNorm."""
    model = onnx.load(onnx_path)

    # Auto-discover GroupNorm mapping
    gn_mapping = auto_discover_groupnorm_mapping(model)
    print(f"  Auto-discovered {len(gn_mapping)} unnamed GroupNorm params")

    weights = {}
    for init in model.graph.initializer:
        arr = numpy_helper.to_array(init)
        name = init.name

        if name in gn_mapping:
            pytorch_name = gn_mapping[name]
            if arr.ndim == 3 and arr.shape[1] == 1 and arr.shape[2] == 1:
                arr = arr.squeeze()
            weights[pytorch_name] = torch.from_numpy(arr.copy())
        else:
            weights[name] = torch.from_numpy(arr.copy())

    return weights


def detect_model_config(weights, T, C):
    """Infer model architecture config from weight tensor shapes."""
    conv_in_w = weights.get("denoiser.inner_model.conv_in.weight")
    first_ch = conv_in_w.shape[0] if conv_in_w is not None else 64

    act_emb_w = weights.get("denoiser.inner_model.act_emb.0.weight")
    num_actions = act_emb_w.shape[0] if act_emb_w is not None else 7

    cond_proj_w = weights.get("denoiser.inner_model.cond_proj.0.weight")
    cond_channels = cond_proj_w.shape[0] if cond_proj_w is not None else 256

    num_levels = 0
    while f"denoiser.inner_model.unet.d_blocks.{num_levels}.resblocks.0.conv1.weight" in weights:
        num_levels += 1

    channels = []
    for level in range(num_levels):
        key = f"denoiser.inner_model.unet.d_blocks.{level}.resblocks.0.conv1.weight"
        channels.append(weights[key].shape[0])

    depths = []
    for level in range(num_levels):
        depth = 0
        while f"denoiser.inner_model.unet.d_blocks.{level}.resblocks.{depth}.conv1.weight" in weights:
            depth += 1
        depths.append(depth)

    attn_depths = []
    for level in range(num_levels):
        has_attn = f"denoiser.inner_model.unet.d_blocks.{level}.resblocks.0.attn.qkv_proj.weight" in weights
        attn_depths.append(has_attn)

    config = {
        "channels": channels,
        "depths": depths,
        "attn_depths": attn_depths,
        "cond_channels": cond_channels,
        "num_actions": num_actions,
        "img_channels": C,
    }
    print("  Detected config:")
    for k, v in config.items():
        print(f"    {k}: {v}")
    return config


class DenoiserWrapperForExport(nn.Module):
    def __init__(self, inner_forward_fn, sigma_data=0.5, sigma_offset_noise=0.0):
        super().__init__()
        self.sigma_data = sigma_data
        self.sigma_offset_noise = sigma_offset_noise
        self._inner_forward = inner_forward_fn

    def forward(self, noisy_next_obs, sigma, prev_obs, prev_act):
        sigma_adj = (sigma ** 2 + self.sigma_offset_noise ** 2).sqrt()
        c_in = 1 / (sigma_adj ** 2 + self.sigma_data ** 2).sqrt()
        c_skip = self.sigma_data ** 2 / (sigma_adj ** 2 + self.sigma_data ** 2)
        c_out = sigma_adj * c_skip.sqrt()
        c_noise = sigma_adj.log() / 4

        c_in = c_in.view(-1, 1, 1, 1)
        c_skip = c_skip.view(-1, 1, 1, 1)
        c_out = c_out.view(-1, 1, 1, 1)

        rescaled_obs = prev_obs / self.sigma_data
        rescaled_noise = noisy_next_obs * c_in
        # For consistency models (1-step), sigma_cond = 0 (target is clean signal)
        c_noise_cond = torch.zeros_like(c_noise)
        model_output = self._inner_forward(rescaled_noise, c_noise, c_noise_cond, rescaled_obs, prev_act)

        d = c_skip * noisy_next_obs + c_out * model_output
        d = d.clamp(-1, 1)
        return d


def convert_denoiser(onnx_dir, output_dir):
    print("\n=== Converting denoiser ===")

    if FORGE_PATH not in sys.path:
        sys.path.insert(0, FORGE_PATH)

    with open(os.path.join(onnx_dir, "init_state.json")) as f:
        init_data = json.load(f)
    T, C, H, W = init_data["T"], init_data["C"], init_data["H"], init_data["W"]
    print(f"  Dims: T={T}, C={C}, H={H}, W={W}")

    print("  Extracting ALL weights from ONNX...")
    weights = extract_all_weights(os.path.join(onnx_dir, "denoiser.onnx"))
    config = detect_model_config(weights, T, C)

    from forge.models.diffusion.denoiser import Denoiser, DenoiserConfig
    from forge.models.diffusion.inner_model import InnerModelConfig

    inner_cfg = InnerModelConfig(
        img_channels=config["img_channels"],
        num_steps_conditioning=T,
        cond_channels=config["cond_channels"],
        depths=config["depths"],
        channels=config["channels"],
        attn_depths=config["attn_depths"],
        num_actions=config["num_actions"],
    )
    denoiser_cfg = DenoiserConfig(
        inner_model=inner_cfg,
        sigma_data=0.5,
        sigma_offset_noise=0.0,
        noise_previous_obs=False,
    )

    print("  Building PyTorch model...")
    denoiser = Denoiser(denoiser_cfg)
    denoiser.eval()

    print("  Loading weights...")
    state_dict = denoiser.state_dict()
    loaded = 0
    skipped = []
    for name, param in state_dict.items():
        candidates = [name, f"denoiser.{name}"]
        found = False
        for onnx_name in candidates:
            if onnx_name in weights:
                w = weights[onnx_name]
                if w.shape == param.shape:
                    state_dict[name] = w.float()
                    loaded += 1
                    found = True
                else:
                    skipped.append(f"{name}: shape mismatch {w.shape} vs {param.shape}")
                    found = True
                break
        if not found:
            skipped.append(f"{name}: not found")

    denoiser.load_state_dict(state_dict, strict=False)
    print(f"  Loaded {loaded}/{len(state_dict)} weights")

    if skipped:
        print(f"  FAILED: {len(skipped)} weights missing:")
        for s in skipped:
            print(f"    {s}")
        return None

    wrapper = DenoiserWrapperForExport(
        inner_forward_fn=denoiser.inner_model,
        sigma_data=denoiser.cfg.sigma_data,
        sigma_offset_noise=denoiser.cfg.sigma_offset_noise,
    )
    wrapper.eval()

    noisy = torch.randn(1, C, H, W)
    sigma = torch.tensor([5.0])
    obs = torch.randn(1, T * C, H, W)
    act = torch.randint(0, config["num_actions"], (1, T), dtype=torch.int64)

    print("  Testing forward pass...")
    with torch.no_grad():
        out = wrapper(noisy, sigma, obs, act)
        print(f"  Output: shape={out.shape}, range=[{out.min():.4f}, {out.max():.4f}]")

    print("  Tracing...")
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (noisy, sigma, obs, act))

    print("  Converting to CoreML...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="noisy_next_obs", shape=(1, C, H, W)),
            ct.TensorType(name="sigma", shape=(1,)),
            ct.TensorType(name="prev_obs", shape=(1, T * C, H, W)),
            ct.TensorType(name="prev_act", shape=(1, T), dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="denoised")],
        minimum_deployment_target=ct.target.iOS17,
        source="pytorch",
    )

    out_path = os.path.join(output_dir, "denoiser.mlpackage")
    mlmodel.save(out_path)
    size_mb = sum(
        os.path.getsize(os.path.join(dp, fn))
        for dp, _, fns in os.walk(out_path) for fn in fns
    ) / 1024 / 1024
    print(f"  Saved: {out_path} ({size_mb:.1f} MB)")
    return out_path


class SimpleResBlock(nn.Module):
    """ResBlock matching ONNX decoder: conv1 + SiLU + conv2 + residual (no SiLU after conv2)."""
    def __init__(self, channels):
        super().__init__()
        self.conv1 = nn.Conv2d(channels, channels, 3, padding=1)
        self.conv2 = nn.Conv2d(channels, channels, 3, padding=1)

    def forward(self, x):
        h = torch.nn.functional.silu(self.conv1(x))
        h = self.conv2(h)
        return x + h


class OnnxDecoder(nn.Module):
    """Decoder matching the ONNX graph exactly:
    conv_in + SiLU → up_blocks[ResBlock + ConvTranspose + SiLU]... → conv_out[ResBlock + Conv2d] → Clip(-1,1)
    """
    def __init__(self, weights):
        super().__init__()
        # Infer architecture from weight shapes
        in_ch = weights["conv_in.weight"].shape[1]   # latent channels
        ch0 = weights["conv_in.weight"].shape[0]      # first hidden channels

        self.conv_in = nn.Conv2d(in_ch, ch0, 3, padding=1)

        # Build up_blocks from weights
        self.up_blocks = nn.ModuleList()
        level = 0
        while f"up_blocks.{level}.0.conv1.weight" in weights:
            ch = weights[f"up_blocks.{level}.0.conv1.weight"].shape[0]
            res = SimpleResBlock(ch)
            up_ch = weights[f"up_blocks.{level}.1.weight"].shape[1]
            up = nn.ConvTranspose2d(ch, up_ch, 4, stride=2, padding=1)
            self.up_blocks.append(nn.ModuleList([res, up]))
            level += 1

        # conv_out: ResBlock + final Conv2d
        out_res_ch = weights["conv_out.0.conv1.weight"].shape[0]
        self.conv_out_res = SimpleResBlock(out_res_ch)
        out_ch = weights["conv_out.1.weight"].shape[0]
        self.conv_out = nn.Conv2d(out_res_ch, out_ch, 3, padding=1)

    def forward(self, x):
        x = torch.nn.functional.silu(self.conv_in(x))
        for res, up in self.up_blocks:
            x = res(x)
            x = torch.nn.functional.silu(up(x))
        x = self.conv_out_res(x)
        x = self.conv_out(x)
        return x.clamp(-1, 1)


def convert_decoder(onnx_dir, output_dir):
    print("\n=== Converting decoder ===")

    onnx_path = os.path.join(onnx_dir, "decoder.onnx")
    if not os.path.exists(onnx_path):
        print("  No decoder.onnx found, skipping")
        return None

    model = onnx.load(onnx_path)
    input_name = model.graph.input[0].name
    print(f"  Input: {input_name}")

    if input_name != "latent":
        print(f"  Unknown input: {input_name}, skipping")
        return None

    weights = {}
    for init in model.graph.initializer:
        weights[init.name] = torch.from_numpy(numpy_helper.to_array(init).copy())
    print(f"  Weights: {len(weights)} tensors")

    # Try forge Decoder first, fall back to OnnxDecoder
    try:
        if FORGE_PATH not in sys.path:
            sys.path.insert(0, FORGE_PATH)
        from forge.models.autoencoder import Decoder, AutoencoderConfig
        first_conv = weights.get("conv_in.weight")
        base_ch = first_conv.shape[0] if first_conv is not None else 32
        ae_cfg = AutoencoderConfig(latent_channels=4, base_channels=base_ch)
        decoder = Decoder(ae_cfg)
        decoder.eval()
        state_dict = decoder.state_dict()
        loaded = sum(1 for n in state_dict if n in weights and weights[n].shape == state_dict[n].shape)
        if loaded == len(state_dict):
            for name in state_dict:
                state_dict[name] = weights[name].float()
            decoder.load_state_dict(state_dict)
            print(f"  Using forge Decoder: {loaded}/{len(state_dict)} weights")
        else:
            raise ValueError("Forge decoder doesn't match")
    except Exception:
        print("  Forge Decoder mismatch, building from ONNX structure...")
        decoder = OnnxDecoder(weights)
        decoder.eval()
        # Load weights by name mapping
        state_dict = decoder.state_dict()
        loaded = 0
        for name in state_dict:
            # Map: up_blocks.N.0.convX → up_blocks.N.0.convX
            #       conv_out_res.convX → conv_out.0.convX
            #       conv_out.weight → conv_out.1.weight
            onnx_name = name
            if name.startswith("conv_out_res."):
                onnx_name = name.replace("conv_out_res.", "conv_out.0.")
            elif name.startswith("conv_out."):
                onnx_name = name.replace("conv_out.", "conv_out.1.")
            if onnx_name in weights and weights[onnx_name].shape == state_dict[name].shape:
                state_dict[name] = weights[onnx_name].float()
                loaded += 1
        decoder.load_state_dict(state_dict)
        print(f"  Loaded {loaded}/{len(state_dict)} weights")

    example = torch.randn(1, 4, 64, 64)
    with torch.no_grad():
        out = decoder(example)
        print(f"  Output: shape={out.shape}")
        traced = torch.jit.trace(decoder, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="latent", shape=(1, 4, 64, 64))],
        outputs=[ct.TensorType(name="rgb")],
        minimum_deployment_target=ct.target.iOS17,
        source="pytorch",
    )

    out_path = os.path.join(output_dir, "decoder.mlpackage")
    mlmodel.save(out_path)
    size_mb = sum(
        os.path.getsize(os.path.join(dp, fn))
        for dp, _, fns in os.walk(out_path) for fn in fns
    ) / 1024 / 1024
    print(f"  Saved: {out_path} ({size_mb:.1f} MB)")
    return out_path


def compile_mlpackage(mlpackage_path, output_dir):
    result = subprocess.run(
        ["xcrun", "coremlcompiler", "compile", mlpackage_path, output_dir],
        capture_output=True, text=True,
    )
    name = os.path.splitext(os.path.basename(mlpackage_path))[0]
    expected = os.path.join(output_dir, f"{name}.mlmodelc")
    if os.path.exists(expected):
        print(f"  Compiled: {expected}")
        return expected
    print(f"  Compile error: {result.stderr.strip()[:200]}")
    return mlpackage_path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--onnx-dir", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    denoiser_path = convert_denoiser(args.onnx_dir, args.output_dir)
    if denoiser_path is None:
        print("\nABORTED: Denoiser had missing weights!")
        sys.exit(1)

    decoder_path = convert_decoder(args.onnx_dir, args.output_dir)

    print("\n=== Compiling to .mlmodelc ===")
    compile_mlpackage(denoiser_path, args.output_dir)
    if decoder_path:
        compile_mlpackage(decoder_path, args.output_dir)

    shutil.copy2(
        os.path.join(args.onnx_dir, "init_state.json"),
        os.path.join(args.output_dir, "init_state.json"),
    )

    print(f"\nDone! Files in {args.output_dir}:")
    for f in sorted(os.listdir(args.output_dir)):
        p = os.path.join(args.output_dir, f)
        if os.path.isdir(p):
            sz = sum(os.path.getsize(os.path.join(dp, fn)) for dp, _, fns in os.walk(p) for fn in fns)
        else:
            sz = os.path.getsize(p)
        print(f"  {f}: {sz / 1024 / 1024:.1f} MB")


if __name__ == "__main__":
    main()
