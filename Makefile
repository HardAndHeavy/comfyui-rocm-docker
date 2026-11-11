DOCKER ?= docker

# Optional HSA override for GPUs whose arch is not built into the image. The
# detection is by PCI name and is off unless HSA_OVERRIDE=1, because the
# fallback in that file claims gfx900/9.0.0, which is wrong for any card newer
# than a Vega and would make a working GPU report the wrong architecture.
ifeq ($(HSA_OVERRIDE),1)
include hsa_override.mk
GPU_ENV = -e HSA_OVERRIDE_GFX_VERSION=$(HSA_OVERRIDE_GFX_VERSION)
endif
# Comma-separated tags to apply to the locally built image. `make build tags=a,b`
# publishes several aliases without rebuilding.
tags ?= 3.0.2
IMAGE ?= comfyui-rocm
PUBLISH_IMAGE ?= hardandheavy/comfyui-rocm
tag ?= 3.0.2

LOCAL_IMAGE = $(IMAGE):$(tag)
BUILD_DATE ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
GIT_REVISION ?= $(shell git rev-parse HEAD)
# One image is built and then aliased, so a second name never costs a rebuild.
_ = $(foreach t,$(tags),$(eval TAG_ARGS += -t $(IMAGE):$(t)))

# Lock generation must be reproducible too, so the generator is pinned and
# verified instead of silently using whatever uv is on PATH.
UV ?= uv
UV_VERSION ?= 0.13.7
UV_LOCK_FLAGS = --python-version 3.14 \
	--python-platform x86_64-unknown-linux-gnu \
	--prerelease disallow \
	--generate-hashes \
	--no-annotate \
	--emit-index-url \
	--custom-compile-command 'make lock'
# The ROCm constraints name wheels that only exist on AMD's index (`torch` is
# 2.13.0+rocm10.1.0), while AMD's index also mirrors some PyPI packages at
# older versions — markupsafe there is older than the one the base ships. With
# `first-index` the mirror wins and resolution dies on a package that is not
# even emitted; `unsafe-best-match` lets both indexes be searched. It is safe
# here because every base package is constrained to an exact version and every
# emitted package is hash-pinned, so a substituted artifact cannot install.
UV_LOCK_INDEXES = --index https://stable.repo.amd.com/rocm/whl-next/ \
	--default-index https://pypi.org/simple \
	--index-strategy unsafe-best-match
# The lock describes what to add on top of the base image, so the base's own
# packages are constraints and are not emitted: pinning them again would either
# duplicate a library or invite pip to reinstall one the image already has.
UV_LOCK_BASE = --constraints docker/base-constraints.txt
BASE_PACKAGES = $(shell grep -v '^#' docker/base-constraints.txt | cut -d= -f1)
UV_LOCK_EXCLUDE = $(foreach p,$(BASE_PACKAGES),--no-emit-package $(p))

# A multi-gigabyte layer over a home connection gets reset mid-upload often
# enough that a single push attempt is not a reliable release step. Each rerun
# reuses the layers the registry already accepted, so plain retries converge.
PUSH_RETRIES ?= 8
PUSH_RETRY_DELAY ?= 20

# $(call push_with_retries,<image reference>)
define push_with_retries
	@attempt=1; \
	while [ $$attempt -le $(PUSH_RETRIES) ]; do \
		echo "Push attempt $$attempt/$(PUSH_RETRIES): $(1)"; \
		if $(DOCKER) push $(1); then \
			break; \
		fi; \
		if [ $$attempt -eq $(PUSH_RETRIES) ]; then \
			echo "Giving up after $(PUSH_RETRIES) attempts; already-uploaded layers are kept, rerun \`make publish\` to continue."; \
			exit 1; \
		fi; \
		echo "Interrupted; retrying in $(PUSH_RETRY_DELAY)s (completed layers are reused)."; \
		sleep $(PUSH_RETRY_DELAY); \
		attempt=$$((attempt + 1)); \
	done
endef

PORT ?= 8188
MODEL_REPOSITORY ?= stabilityai/sd-turbo
MODEL_REVISION ?= b261bac6fd2cf515557d5d0707481eafa0485ec2
MODEL_FILE ?= sd_turbo.safetensors
MODEL_SHA256 ?= 3f067a1b943cf162f2b8f8588f6cf5824bd5b4c7d1d88d87164b9ca123616549
MODEL_URL = https://huggingface.co/$(MODEL_REPOSITORY)/resolve/$(MODEL_REVISION)/$(MODEL_FILE)

DATA ?= $(CURDIR)/data
# Match the host owner for bind mounts, including a not-yet-created data/.
PUID ?= $(shell id -u)
PGID ?= $(shell id -g)
CONTAINER ?= comfyui
# ComfyUI has no authentication. Publishing on 127.0.0.1 keeps it reachable only
# from this machine, which is also what makes the Manager's `personal_cloud`
# network mode (seeded by the entrypoint) an accurate statement rather than a
# claim. Override with BIND=0.0.0.0 to expose it to the network — and then set
# `network_mode = public` in data/user/__manager/config.ini.
BIND ?= 127.0.0.1

# --group-add is not needed: the entrypoint reads the gid of /dev/kfd and
# /dev/dri itself and hands it to setpriv. --ipc=host avoids the small /dev/shm
# of the default bridge network, which ComfyUI's dataloaders need.
DOCKER_RUN_FLAGS = --rm \
	-e PUID=$(PUID) -e PGID=$(PGID) \
	--ipc=host \
	--device=/dev/kfd \
	--device=/dev/dri \
	$(GPU_ENV) \
	-v $(DATA):/data

build:
	$(DOCKER) build \
		--build-arg IMAGE_VERSION=$(tag) \
		--build-arg IMAGE_REVISION=$(GIT_REVISION) \
		--build-arg IMAGE_CREATED=$(BUILD_DATE) \
		$(TAG_ARGS) \
		-f Dockerfile .

# Stays offline: nothing here reaches the network, so it is safe to run in a
# pre-commit hook. The constraint files are checked against the pinned digest,
# not against whatever the tag points at now — that is `make pin-base-check`.
check:
	$(DOCKER) build --check -f Dockerfile .
	python3 -B tools/versions.py check
	python3 -B tools/versions.py check-lock
	python3 -B -m py_compile test/smoke.py test/generate.py tools/versions.py tools/base_constraints.py tools/pin_base.py
	sh -n docker/pip
	bash -n docker/entrypoint.sh

# Propagate versions.json into the Dockerfile blocks, requirements.in and the
# README table.
versions:
	python3 -B tools/versions.py sync

# Regenerate docker/base-constraints.txt and docker/constraints.txt from the
# base image. Run after the base image version or digest changes.
base-constraints:
	python3 -B tools/base_constraints.py

# Resolve the digest of the published base image and write it into versions.json.
# Run after publishing a new llama-rocm release, then `make versions`.
pin-base:
	python3 -B tools/pin_base.py

# `make check` stays offline; this target asks the registry whether the recorded
# pin still matches the tag. Run it before a release.
pin-base-check:
	python3 -B tools/pin_base.py --check

# Run only for an intentional dependency update; normal builds use the lock.
lock:
	@test "$$($(UV) --version | cut -d' ' -f2)" = "$(UV_VERSION)" \
		|| { echo "uv $(UV_VERSION) is required, found $$($(UV) --version)"; exit 1; }
	$(UV) pip compile requirements.in \
		--output-file requirements.lock \
		$(UV_LOCK_FLAGS) \
		$(UV_LOCK_INDEXES) \
		$(UV_LOCK_BASE) \
		$(UV_LOCK_EXCLUDE)

# --- running -------------------------------------------------------------
# No model download here: `make run` must start ComfyUI immediately on a fresh
# checkout, and a 5 GB download would look like a hang. `make test` fetches it.
run:
	$(DOCKER) run -d --name $(CONTAINER) \
		$(DOCKER_RUN_FLAGS) \
		-p $(BIND):$(PORT):8188 \
		$(LOCAL_IMAGE)
	@echo "ComfyUI: http://127.0.0.1:$(PORT)  (logs: make logs)"

logs:
	$(DOCKER) logs -f $(CONTAINER)

# `run` uses --rm, so stopping is enough to remove the container too.
stop:
	-$(DOCKER) stop $(CONTAINER)

# Throw away everything ComfyUI Manager installed, back to the image's state.
# Models, outputs and custom-node checkouts are untouched: only the overlay
# virtualenv is removed, and the entrypoint rebuilds it on the next start.
reset-overlay:
	$(DOCKER) run --rm -v $(DATA):/data --entrypoint bash $(LOCAL_IMAGE) -c \
		'rm -rf /data/.venv && echo "overlay removed; it will be recreated on next start"'

# Run curl in the image so a Docker-owned data directory also works, and verify
# the download against a pinned hash before it becomes visible to ComfyUI.
download-model:
	$(DOCKER) run --rm \
		-v $(DATA):/data \
		--entrypoint bash $(LOCAL_IMAGE) -c '\
		set -e; \
		dest=/data/models/checkpoints/$(MODEL_FILE); \
		if [ ! -f "$$dest" ]; then \
			mkdir -p /data/models/checkpoints; \
			curl -fL --retry 5 --retry-delay 2 -C - \
				-o "$$dest.part" "$(MODEL_URL)"; \
			echo "$(MODEL_SHA256)  $$dest.part" | sha256sum -c -; \
			mv "$$dest.part" "$$dest"; \
		else \
			echo "Model already downloaded: $$dest"; \
		fi'

# Checks the image itself: imports, the pinned stack, the Manager, and that the
# overlay plumbing works. Needs no GPU and no model.
smoke-test:
	$(DOCKER) run $(DOCKER_RUN_FLAGS) $(LOCAL_IMAGE) /app/test/smoke.py --no-gpu

# End-to-end: renders an image through the pinned model and checks the output.
# This is the test that catches a broken ROCm stack or a broken overlay.
test: download-model
	$(DOCKER) run $(DOCKER_RUN_FLAGS) -v $(CURDIR):/app $(LOCAL_IMAGE) \
		python /app/test/generate.py

publish:
	@if [ "$(tag)" = "latest" ]; then \
		echo "Refusing to publish without an explicit release tag (for example, tag=3.0.2)."; \
		exit 1; \
	fi
	$(DOCKER) image tag $(LOCAL_IMAGE) $(PUBLISH_IMAGE):$(tag)
	$(call push_with_retries,$(PUBLISH_IMAGE):$(tag))
	$(DOCKER) image tag $(LOCAL_IMAGE) $(PUBLISH_IMAGE):latest
	$(call push_with_retries,$(PUBLISH_IMAGE):latest)

.PHONY: build check versions base-constraints pin-base pin-base-check lock \
	run logs stop reset-overlay download-model smoke-test test publish
