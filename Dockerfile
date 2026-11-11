# syntax=docker/dockerfile:1.7
#
# ComfyUI on ROCm, on top of the published llama-rocm image.
#
# The base image supplies ROCm, the pinned PyTorch stack, a CPython virtualenv
# at /opt/venv and a HIP build of llama-cpp-python. This repository adds
# ComfyUI itself, its Python dependencies under a hash-pinned lock, and the
# runtime plumbing that makes ComfyUI Manager's installs survive a restart.
#
# ---- why the old image was fragile -------------------------------------
#
# Every previous version of this image fought the same problem: ComfyUI Manager
# installs custom nodes into custom_nodes/ and their Python dependencies into
# site-packages, and only one of the two can be volume-mounted without also
# pinning the whole Python installation on the host. The old image mounted
# /opt/miniconda for exactly that reason, which meant a conda tree on the host,
# a "seed file" under /check to remember whether it had been populated, and an
# entrypoint that re-cloned ComfyUI when that seed file was missing — the
# failure in issue #7, where `touch /check/...` failed because /check did not
# exist and the container looped on `git clone` forever.
#
# This image has no seed files and no /check. Two mechanisms replace all of it:
#
#   /data           one volume: models, custom_nodes, input, output, temp,
#                   user, plus the overlay environment below. Created by the
#                   entrypoint on first start, so `docker run` needs no
#                   pre-created directories and no `chmod -R` of the volume.
#
#   /data/.venv     a virtualenv that the entrypoint creates on every start
#                   (cheap, idempotent, no seed file). Its site-packages is
#                   empty except for base.pth pointing at the base image's
#                   site-packages. ComfyUI runs on this interpreter, so:
#                     - `pip install` from the Manager lands on the volume,
#                     - the base torch/ROCm build stays visible but immutable,
#                     - `pip uninstall` works normally, and pip itself refuses
#                       to remove a package that lives in the image.
#
# ---- why this survives a bad custom node -------------------------------
#
# PIP_CONSTRAINT/UV_CONSTRAINT point at docker/constraints.txt, generated from
# what the base image actually ships. A node that declares `torch` gets a
# resolver error instead of silently replacing the ROCm build with a CUDA wheel
# from PyPI — the most common way a ComfyUI container is broken. Everything
# else (a node's own dependencies) installs into the overlay and is disposable:
# `make reset-overlay` throws it away and returns to the image's exact state.
#
# Both constraint files are generated from the registry image by
# tools/base_constraints.py; the build asserts they match the installed base.

# BEGIN GENERATED: tools/versions.py args
ARG BASE_IMAGE=hardandheavy/llama-rocm:3.0.2@sha256:f5a7d22b7e360e19c7ab43cd91c7c51bc5df15ace4f4897d0d3ed5dce2c4790e
FROM ${BASE_IMAGE}

# Re-declared inside the stage: an ARG before FROM is not visible after it.
ARG IMAGE_VERSION=3.0.2
ARG IMAGE_REVISION=unknown
ARG IMAGE_CREATED=1970-01-01T00:00:00Z
ARG COMFYUI_VERSION=0.44.2
ARG COMFYUI_REVISION=e6515b16ed360b01bd6548bffaca193f88f181fb
# END GENERATED

# BEGIN GENERATED: tools/versions.py labels
LABEL org.opencontainers.image.title="comfyui-rocm" \
      org.opencontainers.image.description="ComfyUI with ROCm support for AMD Radeon GPUs" \
      org.opencontainers.image.source="https://github.com/HardAndHeavy/comfyui-rocm-docker" \
      org.opencontainers.image.url="https://hub.docker.com/r/hardandheavy/comfyui-rocm" \
      org.opencontainers.image.documentation="https://github.com/HardAndHeavy/comfyui-rocm-docker#readme" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${IMAGE_REVISION}" \
      org.opencontainers.image.created="${IMAGE_CREATED}" \
      org.opencontainers.image.base.name="hardandheavy/llama-rocm:3.0.2" \
      org.opencontainers.image.base.digest="sha256:f5a7d22b7e360e19c7ab43cd91c7c51bc5df15ace4f4897d0d3ed5dce2c4790e" \
      ru.hardandheavy.comfyui.version="0.44.2" \
      ru.hardandheavy.comfyui.revision="e6515b16ed360b01bd6548bffaca193f88f181fb" \
      ru.hardandheavy.comfyui-manager.version="4.2.2" \
      ru.hardandheavy.state-directory="/data"
# END GENERATED

# BEGIN GENERATED: tools/versions.py apt
ARG APT_SNAPSHOT=20261106T000000Z
RUN set -eux; \
    printf '%s\n' \
        'Types: deb' \
        "URIs: https://snapshot.ubuntu.com/ubuntu/${APT_SNAPSHOT}/" \
        'Suites: resolute resolute-updates resolute-security' \
        'Components: main universe restricted multiverse' \
        'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg' \
        > /etc/apt/sources.list.d/ubuntu.sources; \
    printf '%s\n' \
        'Acquire::Retries "3";' \
        'Acquire::http::Timeout "20";' \
        'Acquire::https::Timeout "20";' \
        > /etc/apt/apt.conf.d/80-network-retries; \
    apt-get update --error-on=any; \
    apt-get install -y --no-install-recommends \
        libegl1=1.7.0-3 \
        libgl1=1.7.0-3 \
        libglib2.0-0t64=2.88.0-1ubuntu0.1 \
        tini=0.19.0-6; \
    rm -rf /var/lib/apt/lists/*
# END GENERATED

# /usr/local/bin precedes the base image's /opt/venv/bin on purpose: it is where
# the `pip` wrapper lives, and without the ordering a plain `docker exec ... pip
# install` resolves to the base venv's pip and writes into the image's own
# site-packages, which is ephemeral and can shadow a pinned package. `python`
# is unaffected: there is no /usr/local/bin/python, so it still resolves to the
# base interpreter. The entrypoint prepends the overlay to PATH for ComfyUI.
ENV DEBIAN_FRONTEND=noninteractive \
    PATH=/usr/local/bin:/usr/local/sbin:/opt/venv/bin:/opt/rocm/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_INPUT=1 \
    COMFYUI_HOME=/opt/comfyui \
    COMFYUI_BASE_DIRECTORY=/data \
    COMFYUI_OVERLAY=/data/.venv \
    COMFYUI_LISTEN=0.0.0.0 \
    COMFYUI_PORT=8188 \
    HF_HOME=/data/huggingface

# The ComfyUI checkout is fetched by object id, not by tag: a tag can be moved,
# a commit cannot. It lives outside /data so that a fresh volume still starts
# with the pinned, reviewed code, and the version file is generated by ComfyUI's
# own release process, which makes it a cheap integrity check on the checkout.
RUN set -eux; \
    git init "${COMFYUI_HOME}"; \
    git -C "${COMFYUI_HOME}" remote add origin https://github.com/comfyanonymous/ComfyUI.git; \
    git -C "${COMFYUI_HOME}" fetch --depth 1 origin "${COMFYUI_REVISION}"; \
    git -C "${COMFYUI_HOME}" checkout --detach FETCH_HEAD; \
    test "$(git -C "${COMFYUI_HOME}" rev-parse HEAD)" = "${COMFYUI_REVISION}"; \
    test "$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "${COMFYUI_HOME}/comfyui_version.py")" = "${COMFYUI_VERSION}"

# Dependencies are installed from a hash-pinned lock resolved *against* the base
# image (`make lock`), so it cannot pick a numpy or tokenizers other than the
# ones the base already has. Base-owned packages are excluded from the lock by
# name and `make check` fails if one creeps back in.
#
# --no-compile: the layer is read-only at runtime, so a .pyc cache is dead
# weight; ComfyUI starts once per container and import time is not the cost.
COPY requirements.lock /opt/requirements/requirements.lock
RUN set -eux; \
    python -m pip install --no-cache-dir --no-compile --require-hashes \
        --requirement /opt/requirements/requirements.lock; \
    python -m pip check; \
    rm -rf /opt/requirements

# The protected subset of the base stack, enforced for every pip and uv run in
# the container — including the ones ComfyUI Manager starts, which invoke
# `sys.executable -m pip` and therefore cannot be intercepted by a PATH shim.
COPY docker/constraints.txt /opt/comfyui-constraints.txt
ENV PIP_CONSTRAINT=/opt/comfyui-constraints.txt \
    UV_CONSTRAINT=/opt/comfyui-constraints.txt

# ComfyUI's own modules are imported by the check below, and `comfyui_manager`
# imports `comfy.cli_args` from the checkout, so the working directory has to be
# the checkout before anything is verified. A relative import here would
# otherwise pass in a shell and fail in the build.
WORKDIR ${COMFYUI_HOME}

# Fail the build, not the first custom node, if an import is missing or if the
# constraint file drifted from the base the image is actually built on.
RUN python - <<'PY'
import pathlib
import re
import importlib.metadata as md

import torch

assert torch.version.hip is not None, "a ROCm-enabled PyTorch wheel is required"

for module in (
    "comfyui_frontend_package",
    "comfyui_manager",
    "folder_paths",
    "aiohttp",
    "av",
    "sqlalchemy",
    "alembic",
    "pydantic",
    "kornia",
    "spandrel",
    "einops",
    "torchsde",
    "blake3",
    "simpleeval",
):
    __import__(module)

constraints = pathlib.Path("/opt/comfyui-constraints.txt").read_text().splitlines()
mismatch = []
for line in constraints:
    if not line or line.startswith("#"):
        continue
    name, version = line.split("==")
    try:
        installed = md.version(name)
    except md.PackageNotFoundError:
        installed = "missing"
    # Local builds carry a +suffix the constraint records verbatim; compare the
    # public version too so a base rebuild that only changes the suffix is
    # reported rather than silently accepted.
    if installed != version and re.split(r"\+(?!.*\+)", installed)[0] != re.split(r"\+(?!.*\+)", version)[0]:
        mismatch.append(f"{name}: constraint {version}, installed {installed}")
if mismatch:
    raise SystemExit(
        "docker/constraints.txt does not match the base image:\n  "
        + "\n  ".join(mismatch)
        + "\nRun `make base-constraints`."
    )

print(f"torch: {torch.__version__}; HIP: {torch.version.hip}")
print(f"constraints: {len(constraints)} entries match the base image")
PY

# Run unprivileged. The base image owns uid 1000 for `ubuntu`, so ours takes
# 10001 instead of colliding with it; PUID/PGID remap it at start time, and the
# entrypoint adds the video/render group ids of /dev/kfd and /dev/dri, so no
# --privileged, no --group-add and no host-side chown are needed.
RUN set -eux; \
    groupadd --gid 10001 comfyui; \
    useradd --uid 10001 --gid 10001 --create-home --shell /bin/bash comfyui; \
    mkdir -p "${COMFYUI_BASE_DIRECTORY}"; \
    chown comfyui:comfyui "${COMFYUI_BASE_DIRECTORY}"; \
    # ComfyUI Manager calls git on the checkout, and git refuses to operate on a
    # repository owned by another uid ("dubious ownership"). The checkout stays
    # root-owned and read-only; the exception is what makes it usable.
    su comfyui -c "git config --global --add safe.directory ${COMFYUI_HOME}"

# The self-test ships in the image: `make smoke-test` and `make test` run it from
# /app, and an operator with the published image can run the same checks without
# the repository (`docker run --rm IMAGE python /app/test/smoke.py --no-gpu`).
# It is executed directly by the entrypoint, so it needs the exec bit: a git
# checkout does not preserve it for a 100644 file.
COPY test /app/test
RUN chmod 0755 /app/test/smoke.py /app/test/generate.py

COPY docker/pip /usr/local/bin/pip
COPY docker/entrypoint.sh /usr/local/bin/comfyui-entrypoint
RUN chmod 0755 /usr/local/bin/pip /usr/local/bin/comfyui-entrypoint

VOLUME ["/data"]
EXPOSE 8188

# Asks ComfyUI's own API rather than a socket, so it fails when the process is
# alive but the graph server cannot queue work.
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD python -c "import os,sys,urllib.request; \
port=os.environ.get('COMFYUI_PORT','8188'); \
sys.exit(0 if urllib.request.urlopen(f'http://127.0.0.1:{port}/system_stats', timeout=5).status == 200 else 1)"

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/comfyui-entrypoint"]
CMD ["main.py"]
