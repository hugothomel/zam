#!/usr/bin/env python3
"""
Convert knightfall_002 PyTorch checkpoints to CoreML.
Adapted from AlakazamClip/Scripts/convert_via_pytorch.py — loads .pt instead of ONNX.

Run with: /Users/hugohernandez/labzone/alakazam-forge/.venv/bin/python convert_knightfall.py
"""

import os
import shutil
import sys

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn

# Add forge to path (both root and forge/ subdir for pickled models that use "models.*")
FORGE_PATH = "/Users/hugohernandez/labzone/alakazam-forge"
sys.path.insert(0, FORGE_PATH)
sys.path.insert(0, os.path.join(FORGE_PATH, "forge"))

from forge.models.diffusion.denoiser import Denoiser, DenoiserConfig
from forge.models.diffusion.inner_model import InnerModelConfig
from forge.models.autoencoder import Decoder, AutoencoderConfig


class DenoiserWrapperForExport(nn.Module):
    """Simplified wrapper that just does the forward pass through the loaded model."""

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
        model_output = self._inner_forward(rescaled_noise, c_noise, c_noise, rescaled_obs, prev_act)

        d = c_skip * noisy_next_obs + c_out * model_output
        d = d.clamp(-1, 1).add(1).div(2).mul(255).floor().div(255).mul(2).sub(1)
        return d


def detect_config_from_pt(weights: dict) -> dict:
    """Infer model architecture config from .pt state dict shapes."""
    # Keys have "denoiser.inner_model." prefix
    prefix = "denoiser.inner_model."

    conv_in_w = weights[f"{prefix}conv_in.weight"]
    first_ch = conv_in_w.shape[0]
    img_channels = conv_in_w.shape[1] // 5  # (T+1)*C input channels, T=4 so /5

    act_emb_w = weights[f"{prefix}act_emb.0.weight"]
    num_actions = act_emb_w.shape[0]

    cond_proj_w = weights[f"{prefix}cond_proj.0.weight"]
    cond_channels = cond_proj_w.shape[0]

    # Count UNet levels
    num_levels = 0
    while f"{prefix}unet.d_blocks.{num_levels}.resblocks.0.conv1.weight" in weights:
        num_levels += 1

    channels = []
    for level in range(num_levels):
        key = f"{prefix}unet.d_blocks.{level}.resblocks.0.conv1.weight"
        channels.append(weights[key].shape[0])

    depths = []
    for level in range(num_levels):
        depth = 0
        while f"{prefix}unet.d_blocks.{level}.resblocks.{depth}.conv1.weight" in weights:
            depth += 1
        depths.append(depth)

    attn_depths = []
    for level in range(num_levels):
        has_attn = f"{prefix}unet.d_blocks.{level}.attns.0.qkv_proj.weight" in weights
        attn_depths.append(has_attn)

    config = {
        "channels": channels,
        "depths": depths,
        "attn_depths": attn_depths,
        "cond_channels": cond_channels,
        "num_actions": num_actions,
        "img_channels": img_channels,
    }
    print(f"  Detected config:")
    for k, v in config.items():
        print(f"    {k}: {v}")
    return config


def convert_denoiser(pt_path: str, output_path: str, T: int, C: int, H: int, W: int):
    """Convert denoiser .pt state dict → CoreML."""
    print(f"\n=== Converting denoiser ===")
    print(f"  Source: {pt_path}")

    # Load state dict
    print("  Loading .pt weights...")
    weights = torch.load(pt_path, map_location="cpu", weights_only=True)
    config = detect_config_from_pt(weights)

    # Build model
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

    # Load weights — strip "denoiser." prefix to match model state dict
    print("  Loading weights into model...")
    state_dict = denoiser.state_dict()
    loaded = 0
    skipped = []
    for name in state_dict:
        candidates = [name, f"denoiser.{name}"]
        found = False
        for pt_name in candidates:
            if pt_name in weights:
                w = weights[pt_name]
                if w.shape == state_dict[name].shape:
                    state_dict[name] = w.float()
                    loaded += 1
                    found = True
                else:
                    skipped.append(f"{name}: shape mismatch {w.shape} vs {state_dict[name].shape}")
                    found = True
                break
        if not found:
            skipped.append(f"{name}: not found")

    if skipped:
        print(f"  Warning: {len(skipped)} weights skipped:")
        for s in skipped[:10]:
            print(f"    {s}")

    denoiser.load_state_dict(state_dict, strict=False)
    print(f"  Loaded {loaded}/{len(state_dict)} weights")

    # Create wrapper
    wrapper = DenoiserWrapperForExport(
        inner_forward_fn=denoiser.inner_model,
        sigma_data=denoiser.cfg.sigma_data,
        sigma_offset_noise=denoiser.cfg.sigma_offset_noise,
    )
    wrapper.eval()

    # Test
    noisy = torch.randn(1, C, H, W)
    sigma = torch.tensor([5.0])
    obs = torch.randn(1, T * C, H, W)
    act = torch.randint(0, config["num_actions"], (1, T), dtype=torch.int64)

    print("  Testing forward pass...")
    with torch.no_grad():
        out = wrapper(noisy, sigma, obs, act)
        print(f"  Output: shape={out.shape}, range=[{out.min():.4f}, {out.max():.4f}]")

    # Trace
    print("  Tracing...")
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (noisy, sigma, obs, act))

    # Convert to CoreML
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

    mlmodel.save(output_path)
    size_mb = sum(
        os.path.getsize(os.path.join(dp, fn))
        for dp, _, fns in os.walk(output_path) for fn in fns
    ) / 1024 / 1024
    print(f"  Saved: {output_path} ({size_mb:.1f} MB)")


def convert_decoder(pt_path: str, output_path: str, C: int, H: int, W: int):
    """Convert decoder .pt checkpoint → CoreML."""
    print(f"\n=== Converting decoder ===")
    print(f"  Source: {pt_path}")

    # Load — this is a dict with 'decoder_state_dict' and 'config'
    print("  Loading .pt checkpoint...")
    checkpoint = torch.load(pt_path, map_location="cpu", weights_only=False)

    if isinstance(checkpoint, dict) and "decoder_state_dict" in checkpoint:
        decoder_sd = checkpoint["decoder_state_dict"]
        config = checkpoint.get("config")
        print(f"  Config: {config}")
    else:
        # Fallback: might be a full model or just a state dict
        decoder_sd = checkpoint if isinstance(checkpoint, dict) else checkpoint.state_dict()
        config = None

    # Build decoder
    if config is not None:
        ae_cfg = config
    else:
        ae_cfg = AutoencoderConfig(
            in_channels=3,
            latent_channels=C,
            base_channels=8,
            num_blocks=2,
            upscale_factor=4,
        )

    print(f"  AutoencoderConfig: {ae_cfg}")
    decoder = Decoder(ae_cfg)
    decoder.eval()

    # Load weights
    state_dict = decoder.state_dict()
    loaded = 0
    for name in state_dict:
        if name in decoder_sd and decoder_sd[name].shape == state_dict[name].shape:
            state_dict[name] = decoder_sd[name].float()
            loaded += 1
    decoder.load_state_dict(state_dict, strict=False)
    print(f"  Loaded {loaded}/{len(state_dict)} weights")

    # Test
    example = torch.randn(1, C, H, W)
    with torch.no_grad():
        out = decoder(example)
        print(f"  Output: shape={out.shape}, range=[{out.min():.4f}, {out.max():.4f}]")

    # Trace
    print("  Tracing...")
    with torch.no_grad():
        traced = torch.jit.trace(decoder, example)

    # Convert
    print("  Converting to CoreML...")
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="latent", shape=(1, C, H, W))],
        outputs=[ct.TensorType(name="rgb")],
        minimum_deployment_target=ct.target.iOS17,
        source="pytorch",
    )

    mlmodel.save(output_path)
    size_mb = sum(
        os.path.getsize(os.path.join(dp, fn))
        for dp, _, fns in os.walk(output_path) for fn in fns
    ) / 1024 / 1024
    print(f"  Saved: {output_path} ({size_mb:.1f} MB)")


def main():
    # Paths
    denoiser_pt = "/Users/hugohernandez/Downloads/knightfall_002/knightfall_002/denoiser/agent_epoch_00750.pt"
    decoder_pt = "/Users/hugohernandez/Downloads/knightfall_002/knightfall_002_autoencoder/autoencoder_small_decoder_epoch_050.pt"
    init_state = "/Users/hugohernandez/labzone/web_wm_onnx/public/init/knightfall_002/init_state.json"
    output_dir = "/Users/hugohernandez/labzone/alakazam_appclip/Zam/Resources/EmbeddedModels/knightfall_002"

    os.makedirs(output_dir, exist_ok=True)

    # Dims from init_state
    import json
    with open(init_state) as f:
        dims = json.load(f)
    T, C, H, W = dims["T"], dims["C"], dims["H"], dims["W"]
    print(f"Dims: T={T}, C={C}, H={H}, W={W}")

    # Convert denoiser
    convert_denoiser(denoiser_pt, os.path.join(output_dir, "denoiser.mlpackage"), T, C, H, W)

    # Convert decoder
    convert_decoder(decoder_pt, os.path.join(output_dir, "decoder.mlpackage"), C, H, W)

    # Copy init state
    shutil.copy2(init_state, os.path.join(output_dir, "init_state.json"))

    print(f"\nDone! Files in {output_dir}:")
    for f in sorted(os.listdir(output_dir)):
        p = os.path.join(output_dir, f)
        if os.path.isdir(p):
            sz = sum(os.path.getsize(os.path.join(dp, fn))
                     for dp, _, fns in os.walk(p) for fn in fns)
        else:
            sz = os.path.getsize(p)
        print(f"  {f}: {sz/1024/1024:.1f} MB")


if __name__ == "__main__":
    main()
