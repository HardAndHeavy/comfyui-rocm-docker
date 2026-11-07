# ComfyUI on AMD Radeon GPUs in Docker

<h4 align="center">
    <p>
        <b>English</b> |
        <a href="docs/README_ru.md">Русский</a>
    </p>
</h4>

[ComfyUI](https://github.com/comfyanonymous/ComfyUI) in a reproducible Docker
image for AMD Radeon GPUs, published as
[`hardandheavy/comfyui-rocm`](https://hub.docker.com/r/hardandheavy/comfyui-rocm).

Custom nodes and their Python dependencies installed from ComfyUI Manager
survive a restart. There is no conda tree on the host, no seed file, and no
`chmod -R` of your data directory — the failure modes of the previous versions
of this image, including the one reported in
[issue #7](https://github.com/HardAndHeavy/comfyui-rocm-docker/issues/7).

## Quick start

```bash
git clone https://github.com/HardAndHeavy/comfyui-rocm-docker
cd comfyui-rocm-docker
make run
```

ComfyUI appears at <http://localhost:8188> after the first start. The first run
creates `./data` and the overlay environment in it; a model is only downloaded
by `make test`, never by `make run`.

To use a published image without building:

```bash
docker run -d --name comfyui \
  --ipc=host \
  --device=/dev/kfd --device=/dev/dri \
  -v "$PWD/data:/data" \
  -p 8188:8188 \
  hardandheavy/comfyui-rocm:latest
```

## How state is organised

Everything writable lives in one volume. Nothing inside the image is written at
runtime, so the container can run unprivileged and the image can be rebuilt
without touching your data.

| Path | Contents |
| --- | --- |
| `/data/models` | checkpoints, loras, vae, controlnet, upscale_models, diffusion_models, text_encoders, embeddings, clip_vision |
| `/data/custom_nodes` | custom nodes installed from the Manager or by hand |
| `/data/input`, `/data/output`, `/data/temp`, `/data/user` | ComfyUI's working directories and its database |
| `/data/.venv` | the overlay environment: every Python package the Manager installed |
| `/data/huggingface` | `HF_HOME`, so downloaded models are cached on the volume |

`/data/.venv` is the part worth understanding. It is a virtualenv whose
site-packages contains one file, `base.pth`, pointing at the image's
`/opt/venv/lib/python3.14/site-packages`. ComfyUI runs on the overlay
interpreter, which means:

- `pip install` from the Manager writes to the volume and survives a restart;
- the image's ROCm PyTorch build stays importable but cannot be written to;
- `pip uninstall` works normally, and pip refuses on its own to remove a package
  that lives in the image layer;
- throwing the overlay away (`make reset-overlay`) returns the container to the
  exact state of the image, keeping models and outputs.

This replaces the `/opt/miniconda` mount of the previous image. That mount
pinned an entire Python installation on the host, and the seed file used to
remember whether it had been populated is what broke in issue #7.

## The GPU stack is protected

`docker/constraints.txt` lists the GPU stack the base image ships, and it is set
as `PIP_CONSTRAINT` and `UV_CONSTRAINT` for every pip and uv run in the
container. A custom node that declares `torch` or `numpy` gets a resolver error
instead of silently replacing the ROCm build with a CUDA wheel from PyPI — the
usual way a ComfyUI container breaks after installing an extension.

A node's own dependencies, which are not on that list, install into the overlay
and are disposable. If one of them breaks ComfyUI, `make reset-overlay` fixes it
in seconds.

## Commands

```bash
make run                # start on port 8188 (PORT=... to change)
make logs               # follow the container log
make stop               # stop and remove the container
make build              # build the image for this repository
make check              # offline consistency checks (versions, lock, syntax)
make smoke-test         # checks the image; needs no GPU and no model
make test               # renders an image through the pinned model
make reset-overlay      # drop everything the Manager installed
make publish            # push tag and :latest (release only)
```

`make test` downloads `stabilityai/sd-turbo` (about 5 GB) into
`./data/models/checkpoints`, verifies it against a pinned SHA-256, renders a
512×512 image with four steps, and fails if the result is uniform — which is
what a broken ROCm kernel produces instead of an error.

## Configuration

All settings are environment variables; pass them with `-e` or through compose.

| Variable | Default | Purpose |
| --- | --- | --- |
| `COMFYUI_LAUNCH_ARGS` | empty | extra ComfyUI flags, e.g. `--lowvram --force-fp16` |
| `COMFYUI_LISTEN` | `0.0.0.0` | listen address |
| `COMFYUI_PORT` | `8188` | listen port, inside the container |
| `COMFYUI_MANAGER` | `1` | set to `0` to start without ComfyUI Manager |
| `PUID` / `PGID` | `10001` / `10001` | run as these ids instead |
| `COMFYUI_ALLOW_ROOT` | `0` | set to `1` to keep running as root |
| `HF_HOME` | `/data/huggingface` | Hugging Face cache location |

Do not pass `--base-directory`, `--listen` or `--port` through
`COMFYUI_LAUNCH_ARGS`: the entrypoint sets them, and a duplicate flag makes
ComfyUI use the last value.

The `--listen` default is `0.0.0.0` because the container is expected to be
reached from the host over a published port. ComfyUI and ComfyUI Manager both
treat a non-loopback address as more exposed: the Manager drops to a stricter
security level, which disables its remote install buttons. If you only need it
on the local machine, mount on loopback instead and keep it simple:

```bash
docker run -d --name comfyui --ipc=host \
  --device=/dev/kfd --device=/dev/dri \
  -v "$PWD/data:/data" -p 127.0.0.1:8188:8188 \
  -e COMFYUI_LISTEN=127.0.0.1 \
  hardandheavy/comfyui-rocm:latest
```

## Adding models

Drop files into the matching directory under `./data/models` while the container
runs; ComfyUI's file list is refreshed by the reload button in the UI.

| Model type | Directory |
| --- | --- |
| Checkpoint | `models/checkpoints` |
| LoRA | `models/loras` |
| VAE | `models/vae` |
| ControlNet | `models/controlnet` |
| Upscaler | `models/upscale_models` |
| Diffusion model | `models/diffusion_models` |
| Text encoder | `models/text_encoders` |
| CLIP vision | `models/clip_vision` |
| Embedding | `models/embeddings` |

Models are found on [civitai.com](https://civitai.com/) or
[huggingface.co](https://huggingface.co/).

## Version 3.0.0 software stack

See the [changelog](CHANGELOG.md) for release highlights. The image version is
independent of the ROCm, ComfyUI and Manager versions.

<!-- versions:begin -->
| Component | Version |
| --- | --- |
| Base image | hardandheavy/llama-rocm:3.0.1@sha256:c1936e82e527b7f9b82d469f42b66806df49fd45e00d09384dac9e8deb590053 |
| ComfyUI | 0.44.2 (e6515b16e) |
| ComfyUI Manager | 4.2.2 |
| Python | 3.14 |
| Persistent state | `/data`: models, custom_nodes, input, output, user, `.venv`, `home` |
<!-- versions:end -->

`versions.json` is the single source of truth for these pins. The Dockerfile
build arguments and OCI labels, `requirements.in` and the table above are
generated from it by `tools/versions.py`, so they cannot drift apart. Edit
`versions.json`, run `make versions`, then `make base-constraints` if the base
image changed. `make check` fails if anything is out of date.

## Requirements

- Linux x86_64 with an AMD GPU supported by ROCm 10.1.
- A compatible AMDGPU kernel driver exposing `/dev/kfd` and `/dev/dri`.
- Docker Engine 24 or newer with BuildKit.
- `make` and `git` for the repository commands.
- [`uv`](https://docs.astral.sh/uv/) 0.13.7 only when regenerating the lock; the
  version is pinned in the `Makefile` and verified by `make lock`.

The ROCm user-space stack ships inside the image, so installing it on the host
is not required — only the kernel driver is. For the host driver, follow the
[AMD ROCm installation guide](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/).

## Design notes

The image is layered deliberately, and each layer is a separate repository:

```
rocm/dev-ubuntu-26.04      ROCm, Ubuntu
  └─ transformers-rocm     pinned PyTorch, Transformers, venv at /opt/venv
       └─ llama-rocm       llama-cpp-python with a HIP backend
            └─ comfyui-rocm   this image: ComfyUI, its deps, the overlay scheme
```

Keeping the compile of llama.cpp in its own image means ComfyUI inherits a
tested binary instead of building it on every machine, and nodes that run LLMs
inside ComfyUI need nothing extra.

Inside this image:

- **Everything is pinned.** APT is frozen to a `snapshot.ubuntu.com` timestamp,
  Python packages come from hash-pinned locks, and ComfyUI is fetched by commit
  rather than by tag, so a moved tag cannot change a build.
- **The base is pinned by digest.** `make pin-base` asks the registry what
  `llama-rocm:3.0.1` currently points at and records it, and refuses to write a
  pin when the versioned tag and `latest` disagree.
- **The lock resolves against the base.** `make lock` uses
  `docker/base-constraints.txt` and excludes every package the base ships, so
  ComfyUI cannot pull a second numpy or an older tokenizers. `make check` fails
  if one reappears.
- **The build proves itself.** ComfyUI's version file is compared with the
  pinned `versions.json`, every module ComfyUI and the Manager import is
  imported during the build, and `docker/constraints.txt` is compared with what
  is actually installed.
- **Runtime is unprivileged.** The entrypoint reads the group ids of `/dev/kfd`
  and `/dev/dri`, grants them, and drops privileges; there is no `--privileged`
  and no `--group-add` to get wrong.

### Why there is no `/check`

The previous image used a marker file in `/check` to decide whether it had
already cloned ComfyUI. When `/check` did not exist, `touch` failed, the
`Makefile` target exited before writing the marker, and the container
re-cloned ComfyUI on every restart while failing with
`destination path '/comfyui' already exists` (issue #7). Mounting `/check` as
`tmpfs` made the loop worse, because the marker then disappeared every time.

This image has no marker: the layout is created and the overlay is verified on
every start, both of which are idempotent and cheap. The ComfyUI checkout lives
in the image at `/opt/comfyui` and is never written, so there is nothing to
seed.

## Troubleshooting

**`no ROCm GPU visible`** — `/dev/kfd` and `/dev/dri` are not passed through, or
the host driver is missing. Check with `ls -l /dev/kfd /dev/dri` and
`rocminfo` on the host.

**`permission denied` writing to `./data`** — the container runs as uid 10001 by
default. Either let the entrypoint own the directory (`sudo chown -R 10001:10001
./data`) or run with your own ids: `make run PUID=$(id -u) PGID=$(id -g)`.

**ComfyUI starts but the Manager refuses to install anything** — it enforces a
security level that depends on `--listen`. On a non-loopback address it requires
`security_level` to be `normal` or lower in its configuration under `/data/user`,
and it reports the setting and a link to its documentation in the message. This
is a deliberate restriction of the Manager, not a problem with the image; the
entrypoint does not weaken it for you.

**A custom node broke ComfyUI** — `make reset-overlay` removes every package the
Manager installed and returns to the image's state. Models, outputs and the
node checkouts are untouched.

**`resolver error` mentioning torch** — this is intended. `docker/constraints.txt`
prevents a node from replacing the ROCm build.

## License

[Apache-2.0](LICENSE). ComfyUI itself is GPL-3.0; this repository ships no
ComfyUI code, only a recipe that fetches it at build time.
