#!/bin/bash
# Container entrypoint: build the persistent state, then run ComfyUI as an
# unprivileged user that can open the GPU.
#
# There are no seed files and no /check directory. Everything here is
# idempotent and cheap, and runs on every start:
#
#   1. create the directory layout under /data,
#   2. create the overlay virtualenv at /data/.venv if it is missing,
#   3. point the overlay at the image's site-packages with base.pth,
#   4. drop privileges and exec ComfyUI on the overlay interpreter.
#
# A restart therefore loses nothing that ComfyUI Manager installed: the custom
# node checkouts live in /data/custom_nodes and their Python dependencies in
# /data/.venv, both on the volume. A damaged overlay is thrown away with
# `make reset-overlay` instead of by rebuilding the image.
set -euo pipefail

BASE_DIR="${COMFYUI_BASE_DIRECTORY:-/data}"
OVERLAY="${COMFYUI_OVERLAY:-${BASE_DIR}/.venv}"
BASE_VENV="${COMFYUI_BASE_VENV:-/opt/venv}"
PUID="${PUID:-10001}"
PGID="${PGID:-10001}"
RUN_USER="${COMFYUI_USER:-comfyui}"

log() { printf '[entrypoint] %s\n' "$*" >&2; }
die() { printf '[entrypoint] error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Directory layout
# ---------------------------------------------------------------------------
# ComfyUI derives models/, custom_nodes/, input/, output/, temp/, user/ and
# previews/ from --base-directory, so creating them here is what makes a brand
# new volume look complete on the first start.
for dir in models custom_nodes input output temp user previews huggingface; do
    mkdir -p "${BASE_DIR}/${dir}"
done

# The conventional per-model-type directories, so `docker cp`, the README and
# external tools do not have to guess whether they exist yet.
for dir in checkpoints loras vae clip_vision controlnet upscale_models \
           diffusion_models text_encoders embeddings; do
    mkdir -p "${BASE_DIR}/models/${dir}"
done

# ---------------------------------------------------------------------------
# 2. Ownership
# ---------------------------------------------------------------------------
# Only meaningful as root, and only the directories that receive writes are
# walked: a recursive chown over a models directory holding hundreds of
# gigabytes is not something to repeat on every start. The runtime user creates
# everything below the top-level directories, so chowning those is enough.
device_groups() {
    local node gid
    for node in /dev/kfd /dev/dri/renderD* /dev/dri/card*; do
        [ -e "$node" ] || continue
        gid="$(stat -c '%g' "$node" 2>/dev/null || true)"
        [ -n "$gid" ] && [ "$gid" != "0" ] && printf '%s\n' "$gid"
    done | sort -u
}

if [ "$(id -u)" = "0" ]; then
    if id -u "${RUN_USER}" >/dev/null 2>&1; then
        current_uid="$(id -u "${RUN_USER}")"
        current_gid="$(id -g "${RUN_USER}")"
        if [ "${PGID}" != "${current_gid}" ]; then
            groupmod --gid "${PGID}" "${RUN_USER}"
        fi
        if [ "${PUID}" != "${current_uid}" ]; then
            usermod --uid "${PUID}" "${RUN_USER}"
        fi
    else
        groupadd --gid "${PGID}" "${RUN_USER}"
        useradd --uid "${PUID}" --gid "${PGID}" --create-home \
            --shell /bin/bash "${RUN_USER}"
    fi

    chown -R "${PUID}:${PGID}" "${BASE_DIR}/user" "${BASE_DIR}/custom_nodes" \
        "${BASE_DIR}/temp" "${BASE_DIR}/input" "${BASE_DIR}/output" \
        "${BASE_DIR}/previews" 2>/dev/null || true
    chown "${PUID}:${PGID}" "${BASE_DIR}" "${BASE_DIR}/models" \
        "${BASE_DIR}/huggingface" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 3. Overlay environment
# ---------------------------------------------------------------------------
# This is the replacement for the old /opt/miniconda mount. The problem is
# unchanged — Manager writes packages into site-packages, and mounting the whole
# Python installation from the host was how the previous image kept them — but
# the solution is smaller and does not pin a Python tree on the host.
#
# A virtualenv on the volume gives pip an environment it owns, so install and
# uninstall both work normally, while base.pth keeps the image's packages
# importable and immutable. Creating it costs a directory tree and is done
# unconditionally rather than guarded by a marker file that can go missing.
if [ ! -x "${OVERLAY}/bin/python" ]; then
    log "creating overlay environment at ${OVERLAY}"
    "${BASE_VENV}/bin/python" -m venv --without-pip "${OVERLAY}" \
        || die "could not create ${OVERLAY}; is the volume writable by uid $(id -u)?"
fi

# Read the version from the base interpreter rather than hard-coding it, so a
# base image moving to a new CPython needs no change here.
py_version="$("${BASE_VENV}/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
base_site="${BASE_VENV}/lib/python${py_version}/site-packages"
overlay_site="${OVERLAY}/lib/python${py_version}/site-packages"
mkdir -p "${overlay_site}"
# Rewritten on every start: the base image decides which site-packages the
# overlay inherits, and an image upgrade must not leave a stale path behind.
printf '%s\n' "${base_site}" > "${overlay_site}/base.pth"

# `pip` and `pip3` in the overlay's bin come first on PATH, so a shell-level
# install from a custom node lands in the volume. The wrapper is a single file;
# the symlinks make it answer to both names.
for name in pip pip3; do
    ln -sf /usr/local/bin/pip "${OVERLAY}/bin/${name}"
done

if [ "$(id -u)" = "0" ]; then
    chown -R "${PUID}:${PGID}" "${OVERLAY}" 2>/dev/null || true
fi

# --- ComfyUI Manager: force pip, never uv ---------------------------------
# The Manager picks uv as its pip backend whenever the uv module is importable,
# and uv is a dependency of the Manager package, so it always is. uv does not
# read .pth files, so `uv pip list` inside the overlay reports only the overlay's
# own packages — torch, transformers and the frontend from the base image are
# invisible. The Manager trusts that listing: it logs "PyTorch is not installed"
# and "fixes" the missing frontend by reinstalling it into the overlay on every
# start, which then shadows the pinned copy. config.ini is the only switch it
# exposes (`use_uv`), and with it off the Manager shells out to
# `sys.executable -m pip`, whose list is correct.
manager_conf_dir="${BASE_DIR}/user/__manager"
manager_conf="${manager_conf_dir}/config.ini"
mkdir -p "${manager_conf_dir}"
if [ ! -f "${manager_conf}" ]; then
    printf '%s\n' '[default]' 'use_uv = False' > "${manager_conf}"
elif grep -q '^use_uv' "${manager_conf}"; then
    sed -i 's/^use_uv *=.*/use_uv = False/' "${manager_conf}"
else
    printf '%s\n' 'use_uv = False' >> "${manager_conf}"
fi

# --- ComfyUI Manager: the listener is a personal cloud, not a public host ---
# The Manager decides what it may do from two inputs: the listen address and
# `network_mode`. On a non-loopback address with the default `public`, the
# install actions (`middle+`) are denied *regardless* of `security_level` — only
# `personal_cloud` opens them, and `security_level = weak` does not (it widens
# `high` instead, which is git-URL and fix-pack, i.e. more than we want).
#
# The image cannot listen on loopback: `-p` forwards to the container's eth0,
# so binding 127.0.0.1 inside makes the published port dead. What makes the
# `personal_cloud` claim true is therefore the publish side: `make run` binds
# the port to 127.0.0.1, so the only reachable client is the owner on this
# machine.
#
# This is an environment variable rather than a one-time seed because the
# Manager writes `network_mode = public` into config.ini itself on its first
# start: a seed-if-absent rule would never fire on an existing volume, so
# upgrades would keep the broken behaviour. It is also consistent with the rest
# of the image, where COMFYUI_LISTEN and COMFYUI_PORT are the configuration
# surface and config.ini is derived. Exposing the port further means the claim
# is false: pass COMFYUI_NETWORK_MODE=public.
manager_network_mode="${COMFYUI_NETWORK_MODE:-personal_cloud}"
case "${manager_network_mode}" in
    public|private|offline|personal_cloud) ;;
    *) die "COMFYUI_NETWORK_MODE must be public, private, offline or personal_cloud, got '${manager_network_mode}'" ;;
esac
# `sed` replaces in place and appends when the key is absent, so one pass covers
# both a fresh file and one the Manager has already written.
if grep -q '^network_mode' "${manager_conf}"; then
    sed -i "s|^network_mode *=.*|network_mode = ${manager_network_mode}|" "${manager_conf}"
else
    printf '%s\n' "network_mode = ${manager_network_mode}" >> "${manager_conf}"
fi

if [ "$(id -u)" = "0" ]; then
    chown -R "${PUID}:${PGID}" "${BASE_DIR}/user" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 4. Run ComfyUI
# ---------------------------------------------------------------------------
# The overlay interpreter is chosen explicitly rather than through PATH, so the
# image's own `python` is never the one that ends up running ComfyUI: that would
# put Manager's installs back into a read-only layer.
export VIRTUAL_ENV="${OVERLAY}"
# setpriv changes the uid but not HOME, which stays /root from the image. git
# reads its global config ($HOME/.gitconfig) and ComfyUI Manager caches under it,
# so pointing HOME at the runtime user's directory is what makes `git -C
# /opt/comfyui` work and keeps the Manager's state on the volume.
export HOME="/home/${RUN_USER}"
export TMPDIR="${BASE_DIR}/temp"
# The overlay's bin comes first so a bare `pip` writes to the volume; the rest of
# the base image's PATH is kept as-is, because /opt/rocm/bin and /opt/venv/bin
# are on it and dropping them would break hipcc and the base tooling.
export PATH="${OVERLAY}/bin:${PATH}"
export COMFYUI_BASE_DIRECTORY="${BASE_DIR}"
export COMFYUI_OVERLAY="${OVERLAY}"

# Launch arguments belong to ComfyUI only. Anything else (a `docker exec`
# command, a test script, an interactive shell) is run verbatim, so adding them
# unconditionally would hand ComfyUI's flags to a program that does not parse
# them.
# What to run. ComfyUI is the default; anything else is a user command (`bash`,
# a test script, `pip freeze`) executed verbatim on the overlay interpreter.
# The distinction matters: handing ComfyUI's flags to another program makes it
# fail to parse its own arguments.
#
# Both `main.py` (the image CMD) and `python main.py` (what the README shows)
# mean ComfyUI. `python <script>` and any other command are user commands.
wants_comfyui=0
if [ "${1:-}" = "main.py" ]; then
    wants_comfyui=1
    run=( "${OVERLAY}/bin/python" main.py )
elif [ "${1:-}" = "python" ] && [ "${2:-}" = "main.py" ]; then
    wants_comfyui=1
    run=( "${OVERLAY}/bin/python" main.py )
elif [ "${1:-}" = "python" ]; then
    shift
    run=( "${OVERLAY}/bin/python" "$@" )
else
    run=( "$@" )
fi

launch_args=()
if [ "${wants_comfyui}" = "1" ]; then
    launch_args=(
        --listen "${COMFYUI_LISTEN:-0.0.0.0}"
        --port "${COMFYUI_PORT:-8188}"
        --base-directory "${BASE_DIR}"
    )
    # The Manager ships in the image, so it is on by default; COMFYUI_MANAGER=0
    # turns it off for a locked-down deployment.
    if [ "${COMFYUI_MANAGER:-1}" != "0" ]; then
        launch_args+=(--enable-manager)
    fi
    # COMFYUI_LAUNCH_ARGS is kept because every earlier version of this image
    # used it and the README documents it. Word splitting is intended: the value
    # is a command-line fragment, e.g. "--lowvram --force-fp16".
    if [ -n "${COMFYUI_LAUNCH_ARGS:-}" ]; then
        # shellcheck disable=SC2206
        launch_args+=(${COMFYUI_LAUNCH_ARGS})
    fi
fi

if [ "$(id -u)" = "0" ]; then
    extra_groups="$(device_groups | paste -sd, -)"
    if [ -n "${extra_groups}" ]; then
        log "granting GPU device group(s) ${extra_groups}"
    fi
    if [ "${COMFYUI_ALLOW_ROOT:-0}" = "1" ]; then
        log "COMFYUI_ALLOW_ROOT=1: running as root"
        exec "${run[@]}" "${launch_args[@]}"
    fi
    # --groups replaces the supplementary set, so --clear-groups is the other
    # way to say "no supplementary groups". `--groups ""` is not equivalent:
    # util-linux 2.41.3 parses the empty value as an invalid group id and
    # refuses to start, which is what happened whenever no GPU device was
    # passed through (`docker run IMAGE /app/test/smoke.py --no-gpu`).
    if [ -n "${extra_groups}" ]; then
        groups_arg=( --groups "${extra_groups}" )
    else
        groups_arg=( --clear-groups )
    fi
    exec setpriv \
        --reuid "${PUID}" --regid "${PGID}" \
        "${groups_arg[@]}" \
        -- "${run[@]}" "${launch_args[@]}"
fi

exec "${run[@]}" "${launch_args[@]}"
