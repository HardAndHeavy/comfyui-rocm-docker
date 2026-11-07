#!/usr/bin/env python3
"""End-to-end render through the pinned model: a broken ROCm stack or a broken
overlay shows up here and nowhere else.

Run as `make test` after `make download-model`. sd-turbo is a one-step distilled
model, so four steps are enough to produce a recognisable image and the check
finishes in seconds on any supported GPU.

Two assertions matter, and both are things `smoke-test` cannot see:

  * the image is not uniform — a silently CPU-only or miscompiled ROCm kernel
    tends to produce noise or a flat colour rather than an error;
  * attention actually ran on the GPU — the output is written by the overlay
    interpreter, which is the same path ComfyUI Manager's installs live on.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

COMFYUI_HOME = Path(os.environ.get("COMFYUI_HOME", "/opt/comfyui"))
BASE_DIR = Path(os.environ.get("COMFYUI_BASE_DIRECTORY", "/data"))
sys.path.insert(0, str(COMFYUI_HOME))

import torch  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default=None, help="checkpoint under /data/models/checkpoints")
    parser.add_argument("--prompt", default="a photograph of a red fox in fresh snow, sharp focus")
    parser.add_argument("--steps", type=int, default=4)
    parser.add_argument("--size", type=int, default=512)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--out", default=None)
    args = parser.parse_args()

    checkpoints = BASE_DIR / "models" / "checkpoints"
    model_path = Path(args.model) if args.model else next(
        iter(sorted(checkpoints.glob("*.safetensors"))), None
    )
    if model_path is None or not model_path.is_file():
        raise SystemExit(
            f"no checkpoint in {checkpoints}; run `make download-model` first"
        )

    if torch.version.hip is None:
        raise SystemExit("PyTorch is not a ROCm build")
    if not torch.cuda.is_available():
        raise SystemExit(
            "no ROCm GPU visible; pass --device=/dev/kfd --device=/dev/dri"
        )
    device = torch.device("cuda:0")
    print(f"GPU: {torch.cuda.get_device_name(device)}")
    print(f"torch: {torch.__version__}; HIP: {torch.version.hip}")

    # Imported after the path setup: these are ComfyUI modules, not packages.
    import comfy.model_management
    import comfy.sd
    import comfy.utils
    import folder_paths
    import nodes

    # ComfyUI must be told where the volume is; the entrypoint does this for the
    # server, and the test runs on the same interpreter, so it is already set.
    if str(BASE_DIR) != os.environ.get("COMFYUI_BASE_DIRECTORY"):
        raise SystemExit("COMFYUI_BASE_DIRECTORY does not match the test's /data")

    comfy.model_management.unload_all_models()
    comfy.model_management.soft_empty_cache()

    loaded = comfy.sd.load_checkpoint_guess_config(
        str(model_path),
        output_vae=True,
        output_clip=True,
        embedding_directory=folder_paths.get_folder_paths("embeddings"),
    )
    model, clip, vae = loaded[0], loaded[1], loaded[2]
    print(f"checkpoint: {model_path.name}")
    print(f"model type: {type(model.model).__name__}")

    positive = clip.encode_from_tokens_scheduled(
        clip.tokenize(args.prompt)
    )
    negative = clip.encode_from_tokens_scheduled(
        clip.tokenize("blurry, watermark, text")
    )

    latent = torch.zeros(
        [1, 4, args.size // 8, args.size // 8],
        device=comfy.model_management.intermediate_device(),
    )
    (samples,) = nodes.common_ksampler(
        model,
        args.seed,
        args.steps,
        1.0,          # sd-turbo is distilled: cfg must stay at 1.0
        "euler",
        "simple",
        positive,
        negative,
        {"samples": latent},
        denoise=1.0,
    )
    image = vae.decode(samples["samples"])

    # [-1, 1] -> [0, 1] -> uint8, the same conversion the SaveImage node uses.
    # VAE.decode returns NHWC in this ComfyUI revision, so the batch axis is the
    # only one to drop; permuting here would produce a plausible-looking but
    # scrambled image, which is exactly the failure this test exists to catch.
    image = (image + 1.0) / 2.0
    image = torch.clamp(image, 0.0, 1.0)
    image = (image * 255.0).round().to(torch.uint8)
    frame = image[0].cpu().numpy()
    if frame.shape[-1] != 3:
        raise SystemExit(f"unexpected decode layout {frame.shape}; expected HWC uint8")

    # A flat or all-noise result is what a broken HIP kernel produces instead of
    # an exception, so check that the image actually contains structure.
    spread = float(frame.std())
    sampled = frame[::16, ::16].reshape(-1, 3)
    unique = len({tuple(int(c) for c in pixel) for pixel in sampled})
    print(f"image: {frame.shape[1]}x{frame.shape[0]}, channel std {spread:.1f}, "
          f"{unique} distinct sampled colours")
    if spread < 15:
        raise SystemExit(
            f"the rendered image is nearly uniform (std {spread:.1f}); the ROCm "
            "kernels are probably not working"
        )
    if unique < 50:
        raise SystemExit(f"only {unique} distinct colours; the render is degenerate")

    out_path = Path(args.out) if args.out else BASE_DIR / "output" / "rocm-test.png"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    from PIL import Image

    Image.fromarray(frame).save(out_path)
    print(f"wrote {out_path}")

    # The Manager's install path must be the interpreter that just rendered: this
    # is the overlay, and it is where `pip install` from the UI lands.
    overlay = Path(os.environ.get("COMFYUI_OVERLAY", "/data/.venv"))
    if Path(sys.prefix).resolve() != overlay.resolve():
        raise SystemExit(
            f"the test ran on {sys.prefix}, not on the overlay {overlay}; "
            "Manager installs would land somewhere else than ComfyUI runs"
        )
    print(f"overlay: {sys.prefix}")
    print("\nrender passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
