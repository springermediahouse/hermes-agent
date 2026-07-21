FROM ghcr.io/astral-sh/uv:0.11.6-python3.13-trixie@sha256:b3c543b6c4f23a5f2df22866bd7857e5d304b67a564f4feab6ac22044dde719b AS uv_source
# Node 22 LTS source stage. Debian trixie's bundled nodejs is pinned to 20.x
# which reached EOL in April 2026 — we copy node + npm + corepack from the
# upstream node:22 image instead so we can stay on a supported LTS without
# waiting for Debian 14 (forky, ~mid-2027). Bookworm-based slim image used
# so the produced binary links against glibc 2.36, which runs cleanly on
# our Debian 13 (trixie, glibc 2.41) runtime. Bumping to a new Node major
# is a one-line ARG change; see #4977.
FROM node:22-bookworm-slim@sha256:7af03b14a13c8cdd38e45058fd957bf00a72bbe17feac43b1c15a689c029c732 AS node_source
FROM debian:13.4

# Disable Python stdout buffering to ensure logs are printed immediately.
# Do not write .pyc files at runtime: /opt/hermes is immutable in the
# published container and writable state belongs under /opt/data.
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

# Store Playwright browsers outside the volume mount so the build-time
# install survives the /opt/data volume overlay at runtime.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright

# Install system dependencies in one layer, clear APT cache.
# tini was previously PID 1 to reap orphaned zombie processes (MCP stdio
# subprocesses, git, bun, etc.) that would otherwise accumulate when hermes
# ran as PID 1. See #15012. Phase 2 of the s6-overlay supervision plan
# replaces tini with s6-overlay's /init (PID 1 = s6-svscan), which reaps
# zombies non-blockingly on SIGCHLD and additionally supervises the main
# hermes process, the dashboard, and per-profile gateways.
RUN apt-get -o Acquire::Retries=3 update && \
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
    ca-certificates curl iputils-ping python3 python-is-python3 ripgrep ffmpeg gcc g++ make cmake python3-dev python3-venv libffi-dev libolm-dev procps git openssh-client docker-cli xz-utils && \
    rm -rf /var/lib/apt/lists/*

# ---------- s6-overlay install ----------
# s6-overlay provides supervision for the main hermes process, the dashboard,
# and per-profile gateways. /init becomes PID 1 below — see ENTRYPOINT.
#
# Multi-arch: BuildKit auto-populates TARGETARCH (amd64 / arm64). s6-overlay
# uses tarball names keyed on the kernel arch string (x86_64 / aarch64), so
# we map between them inline. The noarch + symlinks tarballs are
# architecture-independent and reused as-is.
#
# We use `curl` instead of `ADD` for ALL three tarballs: `ADD` evaluates its
# URL at parse time (no ARG / TARGETARCH substitution) and — critically for
# CI reliability — cannot retry, so a single GitHub-release CDN blip fails
# the whole 15-45 min build. curl -fsSL --retry 3 self-heals those blips,
# and every tarball is still checksum-verified below before extraction.
ARG TARGETARCH
ARG S6_OVERLAY_VERSION=3.2.3.0
ARG S6_OVERLAY_NOARCH_SHA256=b720f9d9340efc8bb07528b9743813c836e4b02f8693d90241f047998b4c53cf
ARG S6_OVERLAY_X86_64_SHA256=a93f02882c6ed46b21e7adb5c0add86154f01236c93cd82c7d682722e8840563
ARG S6_OVERLAY_AARCH64_SHA256=0952056ff913482163cc30e35b2e944b507ba1025d78f5becbb89367bf344581
ARG S6_OVERLAY_SYMLINKS_SHA256=a60dc5235de3ecbcf874b9c1f18d73263ab99b289b9329aa950e8729c4789f0e
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
        amd64) s6_arch="x86_64"; s6_arch_sha="${S6_OVERLAY_X86_64_SHA256}" ;; \
        arm64) s6_arch="aarch64"; s6_arch_sha="${S6_OVERLAY_AARCH64_SHA256}" ;; \
        *) echo "Unsupported TARGETARCH=${TARGETARCH} for s6-overlay" >&2; exit 1 ;; \
    esac; \
    base="https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}"; \
    curl -fsSL --retry 3 -o /tmp/s6-overlay-noarch.tar.xz \
        "${base}/s6-overlay-noarch.tar.xz"; \
    curl -fsSL --retry 3 -o /tmp/s6-overlay-symlinks-noarch.tar.xz \
        "${base}/s6-overlay-symlinks-noarch.tar.xz"; \
    curl -fsSL --retry 3 -o /tmp/s6-overlay-arch.tar.xz \
        "${base}/s6-overlay-${s6_arch}.tar.xz"; \
    { \
        printf '%s  %s\n' "${S6_OVERLAY_NOARCH_SHA256}" /tmp/s6-overlay-noarch.tar.xz; \
        printf '%s  %s\n' "${s6_arch_sha}" /tmp/s6-overlay-arch.tar.xz; \
        printf '%s  %s\n' "${S6_OVERLAY_SYMLINKS_SHA256}" /tmp/s6-overlay-symlinks-noarch.tar.xz; \
    } > /tmp/s6-overlay.sha256; \
    sha256sum -c /tmp/s6-overlay.sha256; \
    tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz; \
    tar -C / -Jxpf /tmp/s6-overlay-arch.tar.xz; \
    tar -C / -Jxpf /tmp/s6-overlay-symlinks-noarch.tar.xz; \
    rm /tmp/s6-overlay-*.tar.xz /tmp/s6-overlay.sha256

# #34192 / #66679: backward-compat shim for orchestration templates that
# still reference the legacy /usr/bin/tini entrypoint (Hostinger's
# 'Hermes WebUI' catalog, NAS compose projects that preserve an old
# entrypoint on image update, etc.). A plain symlink to /init made the
# path exist, but forwarded tini flags like `-g` into s6-overlay's
# rc.init as the container CMD (`rc.init: 91: -g: not found`) and
# boot-looped any `restart: unless-stopped` deploy. The shim strips the
# tini CLI surface, then exec's /init + main-wrapper — see
# docker/tini-shim.sh. Safe to drop once the affected catalogs are
# updated.
COPY --chmod=0755 docker/tini-shim.sh /usr/bin/tini

# Non-root user for runtime; UID can be overridden via HERMES_UID at runtime
RUN useradd -u 10000 -m -d /opt/data hermes

COPY --chmod=0755 --from=uv_source /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/

# Node 22 LTS: copy the node binary plus the bundled npm + corepack JS
# installs from the upstream image. npm and npx are recreated as symlinks
# because they're symlinks in the source image (and need to live on PATH).
# See node_source stage at the top of the file for the version-bump
# rationale (#4977).
COPY --chmod=0755 --from=node_source /usr/local/bin/node /usr/local/bin/
COPY --from=node_source /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm
COPY --from=node_source /usr/local/lib/node_modules/corepack /usr/local/lib/node_modules/corepack
RUN ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \
    ln -sf /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx && \
    ln -sf /usr/local/lib/node_modules/corepack/dist/corepack.js /usr/local/bin/corepack

WORKDIR /opt/hermes

# ---------- Layer-cached dependency install ----------
# Copy only package manifests first so npm install + Playwright are cached
# unless the lockfiles themselves change.
COPY package.json package-lock.json ./
COPY web/package.json web/
COPY ui-tui/package.json ui-tui/
COPY ui-tui/packages/hermes-ink/ ui-tui/packages/hermes-ink/
COPY apps/shared/ apps/shared/

ENV npm_config_install_links=false

RUN npm install --prefer-offline --no-audit --fetch-retries=5 && \
    for i in 1 2 3; do \
        npx playwright install --with-deps chromium --only-shell && break || \
        { [ "$i" = 3 ] && exit 1; echo "playwright install failed (attempt $i); retrying in 10s"; sleep 10; }; \
    done && \
    npm cache clean --force

# ---------- Layer-cached Python dependency install ----------
COPY pyproject.toml uv.lock ./
RUN touch ./README.md
RUN uv sync --frozen --no-install-project --extra all --extra messaging --extra anthropic --extra bedrock --extra azure-identity --extra hindsight --extra matrix

# ---------- Frontend build (cached independently from Python source) ----------
COPY web/ web/
COPY ui-tui/ ui-tui/
COPY apps/shared/ apps/shared/
RUN cd web && npm run build && \
    cd ../ui-tui && npm run build

# ---------- Source code ----------
# Updated --chmod to numerical octal format for Kaniko compatibility
COPY --link --chmod=0755 . .

# ---------- Permissions ----------
RUN uv pip install --no-cache-dir --no-deps -e "."

USER root
RUN mkdir -p /opt/hermes/bin && \
    cp /opt/hermes/docker/hermes-exec-shim.sh /opt/hermes/bin/hermes && \
    chmod 0755 /opt/hermes/bin/hermes && \
    printf 'docker\n' > /opt/hermes/.install_method

ARG HERMES_GIT_SHA=
RUN if [ -n "${HERMES_GIT_SHA}" ]; then \
        printf '%s\n' "${HERMES_GIT_SHA}" > /opt/hermes/.hermes_build_sha; \
    fi

# ---------- s6-overlay service wiring ----------
COPY docker/s6-rc.d/ /etc/s6-overlay/s6-rc.d/

RUN mkdir -p /etc/cont-init.d && \
    printf '#!/command/with-contenv sh\nexec /opt/hermes/docker/stage2-hook.sh\n' \
        > /etc/cont-init.d/01-hermes-setup && \
    chmod +x /etc/cont-init.d/01-hermes-setup
COPY --chmod=0755 docker/cont-init.d/015-supervise-perms /etc/cont-init.d/015-supervise-perms
COPY --chmod=0755 docker/cont-init.d/02-reconcile-profiles /etc/cont-init.d/02-reconcile-profiles

# ---------- Runtime ----------
ENV HERMES_WEB_DIST=/opt/hermes/hermes_cli/web_dist
ENV HERMES_TUI_DIR=/opt/hermes/ui-tui
ENV HERMES_HOME=/opt/data
ENV HERMES_WRITE_SAFE_ROOT=/opt/data
ENV HERMES_DISABLE_LAZY_INSTALLS=1
ENV HERMES_LAZY_INSTALL_TARGET=/opt/data/lazy-packages

ENV PATH="/opt/hermes/bin:/opt/hermes/.venv/bin:/opt/data/.local/bin:${PATH}"
RUN mkdir -p /opt/data
VOLUME [ "/opt/data" ]

ENTRYPOINT [ "/init", "/opt/hermes/docker/main-wrapper.sh" ]
CMD [ ]
