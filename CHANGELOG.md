# Changelog

Image versions are independent of the ROCm, ComfyUI and ComfyUI Manager
versions. Only changes that affect the published image or the repository
commands are listed.

## 3.0.0

Rebuilt on `llama-rocm:3.0.1` (ROCm 10.1.0, Ubuntu 26.04, Python 3.14,
PyTorch 2.13.0), with ComfyUI 0.44.2 and ComfyUI Manager 4.2.2.

The image is no longer built on `transformers-rocm` directly but on
`llama-rocm`, so a working `llama-cpp-python` is part of the environment that
ComfyUI and its LLM nodes run in.

### Fixed: the container re-cloned ComfyUI forever (issue #7)

- Remove the `/check` seed-file scheme entirely. The old entrypoint used
  `touch /check/comfyui-check-seed-file` to remember whether ComfyUI had been
  cloned; when `/check` did not exist the `touch` failed, the `Makefile` target
  exited before writing the marker, and the container re-cloned ComfyUI on
  every restart while failing with `destination path '/comfyui' already
  exists`. Mounting `/check` as `tmpfs` made it worse: the marker then
  disappeared on restart.
- The ComfyUI checkout now lives at `/opt/comfyui` inside the image and is
  never written. The directory layout and the Python environment are verified
  on every start, both idempotently, so there is nothing to seed and no marker
  that can go missing.

### Fixed: Manager installs did not survive a restart

- Replace the `/opt/miniconda` host mount with an overlay virtualenv at
  `/data/.venv`. It is created on first start, contains only `base.pth`
  pointing at the image's `/opt/venv/lib/python3.14/site-packages`, and ComfyUI
  runs on that interpreter. `pip install` from the Manager lands on the volume,
  the base torch build stays visible but immutable, and `pip uninstall` works
  normally — pip refuses on its own to remove a package that lives in the
  image.
- `make reset-overlay` throws away every package the Manager installed and
  returns the container to the image's exact state, keeping models, outputs and
  the node checkouts.
- Mounting the whole Python installation on the host is no longer needed, and
  neither is the `sudo chmod -R ./data` the README used to require.

### Fixed: a custom node could replace the ROCm PyTorch build

- `docker/constraints.txt` is generated from what the base image actually ships
  and set as `PIP_CONSTRAINT` and `UV_CONSTRAINT`, so every `pip` and `uv` run
  inside the container — including the ones the Manager starts, which invoke
  `sys.executable -m pip` and cannot be intercepted on `PATH` — refuses to
  install a different torch, numpy or tokenizers. Previously a node that
  declared `torch` replaced the ROCm build with a CUDA wheel from PyPI.
- ComfyUI Manager is installed as a package from a pinned version rather than
  cloned into `custom_nodes`, so its version is reviewable and its files live
  in an immutable layer.
- Force the Manager to use pip rather than uv (`use_uv = False` in its
  `config.ini`, set by the entrypoint on every start). The Manager picks uv
  whenever it is importable, and uv does not read `.pth` files, so inside the
  overlay it saw none of the base image's packages: the Manager logged
  "PyTorch is not installed" and reinstalled the frontend into the overlay on
  every restart, shadowing the pinned copy.

### Changed: published on loopback, Manager sees a personal cloud

- `make run` publishes the port on `127.0.0.1` (`BIND`, override with
  `BIND=0.0.0.0`) instead of every host interface. ComfyUI has no
  authentication, and the Makefile already printed a `127.0.0.1` URL.
- The entrypoint sets `network_mode = personal_cloud` in
  `data/user/__manager/config.ini` on every start, overridable with
  `COMFYUI_NETWORK_MODE`. On a non-loopback listener — which a published port
  always is, since `-p` forwards to the container's eth0 — the Manager denies
  its install actions while the mode is `public`, regardless of
  `security_level`; only `personal_cloud` opens them. It is rewritten rather
  than seeded once because the Manager writes `public` into that file itself,
  so a seed would never fire on an existing volume. Combined with the loopback
  publish, this is an ordinary single-user install at the Manager's own default
  `security_level = normal`. Raising it to `weak` does not enable installs and
  does open the git-URL and fix-pack actions, so the image does not do it.
- Fix the README's loopback recipe: `-p 127.0.0.1:8188:8188` together with
  `COMFYUI_LISTEN=127.0.0.1` leaves the published port dead, because the
  forward targets eth0, not the container's loopback. The recipe now uses
  `--network host`.
- `smoke-test` fails if `network_mode` is no longer `personal_cloud` or if
  `security_level` was lowered to `weak`.

### Fixed: running the image without a GPU device failed

- `setpriv --groups ""` is rejected by util-linux 2.41.3 ("Invalid
  supplementary group id"), so any container started without `/dev/kfd` and
  `/dev/dri` — including the documented
  `docker run --rm IMAGE /app/test/smoke.py --no-gpu` — exited before running
  anything. An empty group set now uses `--clear-groups`.
- `test/smoke.py` had no exec bit, so `make smoke-test` failed with
  `Permission denied`; the Dockerfile now sets it.

### Changed

- One volume, `/data`, holds models, custom_nodes, input, output, temp, user,
  the overlay environment and the Hugging Face cache. The container runs as
  uid 10001 and the entrypoint grants the group ids of `/dev/kfd` and
  `/dev/dri`, so no `--privileged`, no `--group-add` and no host-side `chown`
  are needed.
- ComfyUI is enabled with `--enable-manager` by default; `COMFYUI_MANAGER=0`
  turns it off.
- `COMFYUI_LAUNCH_ARGS` still works and is no longer required: the port,
  listen address and base directory are set by the entrypoint. Passing
  `--base-directory`, `--listen` or `--port` through it now duplicates a flag.
- The `pip` and `pip3` on `PATH` in the image resolve to a wrapper that always
  targets `/data/.venv`, so a `docker exec ... pip install` cannot write into
  the image's own site-packages.
- Add `make base-constraints`, which regenerates both constraint files from the
  registry image, and `make pin-base` / `make pin-base-check` for the base
  digest.
- `make check` now also verifies that the lock does not shadow a base package
  and that the entrypoint and the pip wrapper parse.
- `make publish` retries the push and reuses already-uploaded layers, so an
  interrupted upload is resumed by rerunning it.

### Added

- `test/smoke.py` (`make smoke-test`): fifteen checks covering the pinned
  stack, the Manager, the overlay wiring, the constraint file, the directory
  layout, the unprivileged user, the Manager's pip backend, and the absence of
  `/check`. Needs no GPU
  model; the GPU checks are skipped with `--no-gpu`.
- `test/generate.py` (`make test`): renders a 512×512 image with `sd-turbo` in
  four steps and fails if the result is uniform, which is what a broken ROCm
  kernel produces instead of an error. The model is verified against a pinned
  SHA-256 before use.
- `tools/base_constraints.py`, `tools/pin_base.py`, and `versions.json` with
  `tools/versions.py`, which generate the Dockerfile blocks, `requirements.in`
  and the README tables so the pins cannot drift.
- OCI labels, including the base image digest and the ComfyUI and Manager
  commits, plus a healthcheck that queries ComfyUI's own API.
