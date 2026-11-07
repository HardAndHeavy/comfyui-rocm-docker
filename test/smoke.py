#!/usr/bin/env python3
"""Check the image without a GPU, a model, or a running server.

Run as `make smoke-test`. It answers one question: does this image behave the
way the README promises — pinned stack, working Manager, overlay that survives a
restart, and a constraint file that cannot let a custom node replace ROCm
PyTorch with a CUDA wheel.

Every check corresponds to a failure that actually shipped in an earlier
version of this image or to the bug in issue #7, so a regression here is a
regression users would hit.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

import torch

COMFYUI_HOME = Path(os.environ.get("COMFYUI_HOME", "/opt/comfyui"))
BASE_DIR = Path(os.environ.get("COMFYUI_BASE_DIRECTORY", "/data"))
OVERLAY = Path(os.environ.get("COMFYUI_OVERLAY", "/data/.venv"))
BASE_VENV = Path(os.environ.get("COMFYUI_BASE_VENV", "/opt/venv"))
CONSTRAINTS = Path("/opt/comfyui-constraints.txt")

failures: list[str] = []


def check(name: str, fn) -> None:
    try:
        detail = fn()
    except Exception as exc:  # noqa: BLE001 - a report, not a control flow tool
        failures.append(f"{name}: {exc}")
        print(f"FAIL {name}: {exc}")
    else:
        print(f"ok   {name}" + (f" — {detail}" if detail else ""))


def comfyui_checkout() -> str:
    version_file = COMFYUI_HOME / "comfyui_version.py"
    if not version_file.is_file():
        raise AssertionError(f"no ComfyUI checkout at {COMFYUI_HOME}")
    version = version_file.read_text().split('"')[1]
    head = subprocess.run(
        ["git", "-C", str(COMFYUI_HOME), "rev-parse", "HEAD"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    return f"{version} ({head[:9]})"


def gpu_stack() -> str:
    if torch.version.hip is None:
        raise AssertionError("PyTorch is not a ROCm build")
    import importlib.metadata as md

    return f"torch {md.version('torch')}, HIP {torch.version.hip}"


def comfyui_imports() -> str:
    """The modules ComfyUI and the Manager import at startup.

    A missing one used to surface only as a traceback on the first page load.
    `folder_paths` is imported with --base-directory unset on purpose: it must
    not require the volume to exist to be importable.
    """
    sys.path.insert(0, str(COMFYUI_HOME))
    modules = [
        "comfyui_manager",
        "folder_paths",
        "comfy.cli_args",
        "aiohttp",
        "av",
        "sqlalchemy",
        "alembic",
        "pydantic",
        "pydantic_settings",
        "kornia",
        "spandrel",
        "einops",
        "torchsde",
        "blake3",
        "simpleeval",
        "yarl",
    ]
    for module in modules:
        __import__(module)
    return f"{len(modules)} modules"


def manager_version() -> str:
    """The manager must be a package, not a git clone in custom_nodes.

    Shipping it as a package is what makes its version pinnable and its files
    immutable; a clone would be re-resolved by every `make run`.
    """
    import comfyui_manager

    version = getattr(comfyui_manager, "__version__", None)
    if version is None:
        import importlib.metadata as md

        version = md.version("comfyui-manager")
    path = Path(comfyui_manager.__file__).resolve()
    if COMFYUI_HOME in path.parents:
        raise AssertionError(f"Manager is installed inside the ComfyUI checkout: {path}")
    if (BASE_DIR / "custom_nodes" / "ComfyUI-Manager").exists():
        raise AssertionError("a legacy ComfyUI-Manager clone exists in custom_nodes")
    return version


def manager_requirements() -> str:
    """ComfyUI disables --enable-manager unless this file's pin is installed."""
    req = COMFYUI_HOME / "manager_requirements.txt"
    if not req.is_file():
        raise AssertionError("manager_requirements.txt is missing from the checkout")
    return req.read_text().strip()


def constraints_match() -> str:
    import importlib.metadata as md

    if not CONSTRAINTS.is_file():
        raise AssertionError(f"{CONSTRAINTS} is missing")
    offenders = []
    for line in CONSTRAINTS.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        name, want = line.split("==")
        try:
            got = md.version(name)
        except md.PackageNotFoundError:
            offenders.append(f"{name} missing")
            continue
        if got != want:
            offenders.append(f"{name} {got} != {want}")
    if offenders:
        raise AssertionError("; ".join(offenders))
    return f"{sum(1 for l in CONSTRAINTS.read_text().splitlines() if '==' in l)} pins enforced"


def constraint_blocks_torch() -> str:
    """The whole point of the constraint file: pip must refuse to swap the GPU stack.

    A dry-run install of another torch has to fail. If it succeeded, a custom
    node asking the Manager for `torch` would replace the ROCm build.
    """
    result = subprocess.run(
        [sys.executable, "-m", "pip", "install", "--dry-run", "torch==2.9.0"],
        capture_output=True, text=True,
    )
    if result.returncode == 0:
        raise AssertionError(
            "pip would happily install a different torch; PIP_CONSTRAINT is not "
            "being applied, so a custom node can break the image"
        )
    return "another torch is rejected by the resolver"


def overlay_wiring() -> str:
    """base.pth must point at the image's site-packages, and pip must resolve to the overlay.

    This is what replaced the /opt/miniconda mount. If base.pth is wrong, the
    overlay silently shadows the pinned numpy or cannot import torch at all.
    """
    if not (OVERLAY / "bin" / "python").exists():
        raise AssertionError(f"no overlay interpreter at {OVERLAY}")
    version = f"{sys.version_info.major}.{sys.version_info.minor}"
    pth = OVERLAY / "lib" / f"python{version}" / "site-packages" / "base.pth"
    if not pth.is_file():
        raise AssertionError(f"{pth} is missing")
    recorded = pth.read_text().strip()
    expected = str(BASE_VENV / "lib" / f"python{version}" / "site-packages")
    if recorded != expected:
        raise AssertionError(f"base.pth points at {recorded}, expected {expected}")
    probe = subprocess.run(
        [str(OVERLAY / "bin" / "python"), "-c",
         "import sys, torch; print(sys.prefix); print(torch.__file__)"],
        capture_output=True, text=True,
    )
    if probe.returncode != 0:
        raise AssertionError(f"the overlay interpreter cannot import torch: {probe.stderr.strip()}")
    prefix, torch_path = probe.stdout.split()
    if prefix != str(OVERLAY):
        raise AssertionError(f"the overlay interpreter reports prefix {prefix}")
    if not torch_path.startswith(expected):
        raise AssertionError(f"torch resolved to {torch_path}, outside the base image")
    return f"{OVERLAY} -> {expected}"


def manager_uses_pip() -> str:
    """The Manager must not use uv as its pip backend.

    uv does not read .pth files, so inside the overlay `uv pip list` sees only
    the overlay's own packages and reports the base image's torch, transformers
    and frontend as missing. The Manager then "fixes" the frontend by
    reinstalling it into the overlay on every start, shadowing the pinned copy.
    """
    conf = Path(os.environ.get("COMFYUI_BASE_DIRECTORY", "/data")) / "user" / "__manager" / "config.ini"
    if not conf.is_file():
        raise AssertionError(f"{conf} is missing; the entrypoint should create it")
    values = {}
    for line in conf.read_text().splitlines():
        if "=" in line and not line.startswith("["):
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip()
    if values.get("use_uv", "").lower() not in ("false", "0", "no"):
        raise AssertionError(f"use_uv is {values.get('use_uv')!r}; the Manager would use uv")
    # Any base package the Manager reinstalled into the overlay is a symptom.
    version = f"{sys.version_info.major}.{sys.version_info.minor}"
    leaked = sorted(
        p.name for p in (OVERLAY / "lib" / f"python{version}" / "site-packages").glob("comfyui_frontend_package*")
    )
    if leaked:
        raise AssertionError(
            "the Manager reinstalled a base package into the overlay: " + ", ".join(leaked)
        )
    return "pip backend, no shadowed base packages"


def no_seed_files() -> str:
    """The failure in issue #7: a missing /check directory, and a clone loop.

    The image must not depend on /check or on any marker file to know whether it
    has been initialised.
    """
    for path in ("/check", COMFYUI_HOME / "Makefile", BASE_DIR / "comfyui-check-seed-file"):
        if Path(path).exists():
            raise AssertionError(f"{path} exists; initialization marker logic is back")
    env = os.environ.get("COMFYUI_BASE_DIRECTORY")
    if env != "/data":
        raise AssertionError(f"COMFYUI_BASE_DIRECTORY is {env!r}, expected /data")
    return "no /check, no seed files, base directory is /data"


def base_directory_layout() -> str:
    """A brand new volume must already look complete after the entrypoint."""
    required = [
        "models/checkpoints", "models/loras", "models/vae", "models/clip_vision",
        "models/controlnet", "models/upscale_models", "models/diffusion_models",
        "models/text_encoders", "models/embeddings",
        "custom_nodes", "input", "output", "temp", "user", "previews",
    ]
    missing = [name for name in required if not (BASE_DIR / name).is_dir()]
    if missing:
        raise AssertionError("missing under /data: " + ", ".join(missing))
    return f"{len(required)} directories"


def runs_unprivileged() -> str:
    if os.geteuid() == 0:
        raise AssertionError(
            "running as root; the entrypoint should have dropped privileges "
            "(set COMFYUI_ALLOW_ROOT=1 to opt in deliberately)"
        )
    return f"uid {os.getuid()}"


def manager_sees_writable_volume() -> str:
    """Manager writes into the volume, not into the image.

    It reports a read-only base directory as an unusable install target, so a
    writable custom_nodes plus an overlay site-packages is the whole contract.
    """
    version = f"{sys.version_info.major}.{sys.version_info.minor}"
    overlay_site = OVERLAY / "lib" / f"python{version}" / "site-packages"
    for path in (BASE_DIR / "custom_nodes", overlay_site):
        if not os.access(path, os.W_OK):
            raise AssertionError(f"{path} is not writable by uid {os.getuid()}")
        probe = Path(tempfile.mkstemp(dir=path)[1])
        probe.unlink()
    if os.access(COMFYUI_HOME, os.W_OK):
        raise AssertionError(f"{COMFYUI_HOME} is writable; the checkout must be immutable")
    return "custom_nodes and the overlay are writable, the checkout is not"


def git_remote_check() -> str:
    """`git remote get-url` is how the Manager derives a node's origin."""
    result = subprocess.run(
        ["git", "-C", str(COMFYUI_HOME), "config", "--get", "remote.origin.url"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise AssertionError("the ComfyUI checkout has no origin remote")
    return result.stdout.strip()


def server_responds(url: str) -> str:
    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            payload = json.load(response)
    except urllib.error.URLError as exc:
        raise AssertionError(f"{url} is not responding: {exc}") from exc
    system = payload.get("system", {})
    return f"{system.get('comfyui_version', '?')}, python {system.get('python_version', '?')}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--no-gpu", action="store_true",
        help="only assert that torch is a ROCm build; skip the device query",
    )
    parser.add_argument(
        "--url", default=None,
        help="also check a running ComfyUI server, e.g. http://127.0.0.1:8188",
    )
    args = parser.parse_args()

    check("ComfyUI checkout", comfyui_checkout)
    check("ROCm PyTorch", gpu_stack)
    if not args.no_gpu:
        check("GPU device", lambda: torch.cuda.get_device_name(0))
    check("ComfyUI imports", comfyui_imports)
    check("ComfyUI Manager", manager_version)
    check("Manager requirements", manager_requirements)
    check("Manager uses pip, not uv", manager_uses_pip)
    check("constraint pins", constraints_match)
    check("GPU stack is protected", constraint_blocks_torch)
    check("overlay environment", overlay_wiring)
    check("no /check, no seed files", no_seed_files)
    check("base directory layout", base_directory_layout)
    check("runs unprivileged", runs_unprivileged)
    check("volume is writable", manager_sees_writable_volume)
    check("checkout origin", git_remote_check)
    if args.url:
        check("running server", lambda: server_responds(args.url))

    if failures:
        print(f"\n{len(failures)} check(s) failed", file=sys.stderr)
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
