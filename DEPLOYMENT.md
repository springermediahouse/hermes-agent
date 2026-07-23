🚀 Complete End-to-End Deployment Guide: Hermes Agent on Starlight™ Hyperlift

This guide covers every step required to deploy Hermes Agent from scratch, configure authentication, set up OpenRouter for free LLM models, and integrate Higgsfield MCP for AI image/video generation.
📌 Phase 1: Set Up OpenRouter (LLM Provider)

    Go to openrouter.ai and sign up for an account.

    Navigate to Keys in your account dashboard and click Create Key.

    Give your key a name (e.g., Hermes Agent Key).

    Copy the generated API key (it will look like sk-or-v1-xxxxxxxxxxxx...) and save it somewhere temporary.

📌 Phase 2: Create & Configure Repository Files

Create or update the following 2 files at the root of your GitHub repository (springermediahouse/hermes-agent).
File 1: config.yaml

Create config.yaml at the root of the project:

dashboard:
  host: "0.0.0.0"
  port: 8080
  basic_auth:
    username: "springermedia"
    password: "YOUR_SECURE_PASSWORD" # Replace with your preferred login password

model:
  provider: "openrouter"
  default: "openrouter/free"
  api_key: "sk-or-v1-YOUR_OPENROUTER_API_KEY_HERE" # Replace with your key from Phase 1

  💡 Note: Hermes automatically hashes the plaintext password in memory upon bootup.

File 2: Dockerfile

Create or update Dockerfile at the root of the project:

FROM ghcr.io/astral-sh/uv:0.11.6-python3.13-trixie@sha256:b3c543b6c4f23a5f2df22866bd7857e5d304b67a564f4feab6ac22044dde719b AS uv_source
FROM node:22-bookworm-slim@sha256:7af03b14a13c8cdd38e45058fd957bf00a72bbe17feac43b1c15a689c029c732 AS node_source
FROM debian:13.4

ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright

RUN apt-get -o Acquire::Retries=3 update && \
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
    ca-certificates curl iputils-ping python3 python-is-python3 ripgrep ffmpeg gcc g++ make cmake python3-dev python3-venv libffi-dev libolm-dev procps git openssh-client docker-cli xz-utils && \
    rm -rf /var/lib/apt/lists/*

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
    curl -fsSL --retry 3 -o /tmp/s6-overlay-noarch.tar.xz "${base}/s6-overlay-noarch.tar.xz"; \
    curl -fsSL --retry 3 -o /tmp/s6-overlay-symlinks-noarch.tar.xz "${base}/s6-overlay-symlinks-noarch.tar.xz"; \
    curl -fsSL --retry 3 -o /tmp/s6-overlay-arch.tar.xz "${base}/s6-overlay-${s6_arch}.tar.xz"; \
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

COPY --chmod=0755 docker/tini-shim.sh /usr/bin/tini

RUN useradd -u 10000 -m -d /opt/data hermes

COPY --chmod=0755 --from=uv_source /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/

COPY --chmod=0755 --from=node_source /usr/local/bin/node /usr/local/bin/
COPY --from=node_source /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm
COPY --from=node_source /usr/local/lib/node_modules/corepack /usr/local/lib/node_modules/corepack
RUN ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \
    ln -sf /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx && \
    ln -sf /usr/local/lib/node_modules/corepack/dist/corepack.js /usr/local/bin/corepack

WORKDIR /opt/hermes

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

COPY pyproject.toml uv.lock ./
RUN touch ./README.md
RUN uv sync --frozen --no-install-project --extra all --extra messaging --extra anthropic --extra bedrock --extra azure-identity --extra hindsight --extra matrix

COPY web/ web/
COPY ui-tui/ ui-tui/
COPY apps/shared/ apps/shared/
RUN cd web && npm run build && \
    cd ../ui-tui && npm run build

COPY --link --chmod=0755 . .

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

COPY docker/s6-rc.d/ /etc/s6-overlay/s6-rc.d/

RUN mkdir -p /etc/cont-init.d && \
    printf '#!/command/with-contenv sh\nexec /opt/hermes/docker/stage2-hook.sh\n' \
        > /etc/cont-init.d/01-hermes-setup && \
    chmod +x /etc/cont-init.d/01-hermes-setup
COPY --chmod=0755 docker/cont-init.d/015-supervise-perms /etc/cont-init.d/015-supervise-perms
COPY --chmod=0755 docker/cont-init.d/02-reconcile-profiles /etc/cont-init.d/02-reconcile-profiles

ENV HERMES_WEB_DIST=/opt/hermes/hermes_cli/web_dist
ENV HERMES_TUI_DIR=/opt/hermes/ui-tui
ENV HERMES_HOME=/opt/data
ENV HERMES_WRITE_SAFE_ROOT=/opt/data
ENV HERMES_DISABLE_LAZY_INSTALLS=1
ENV HERMES_LAZY_INSTALL_TARGET=/opt/data/lazy-packages

ENV PATH="/opt/hermes/bin:/opt/hermes/.venv/bin:/opt/data/.local/bin:${PATH}"

RUN mkdir -p /opt/data
COPY config.yaml /opt/data/config.yaml

VOLUME [ "/opt/data" ]

ENTRYPOINT [ "/init", "/opt/hermes/docker/main-wrapper.sh" ]
CMD [ "gateway", "run" ]


📌 Phase 3: Commit & Deploy on Starlight™ Hyperlift

    Open your terminal in your project directory and commit changes to GitHub:


    git add config.yaml Dockerfile
git commit -m "Configure Hermes deployment and OpenRouter auth"
git push origin main

Log into Starlight™ Hyperlift Manager.

    Select your repository (springermediahouse/hermes-agent) and branch (main).

    Set Port to 8080.

    Click Deploy / Rebuild.

    Wait for the build logs to finish and display Container running.

📌 Phase 4: Access Dashboard & Log In

    Open your browser and navigate to your deployed domain (e.g., [https://agent.elremining.com/login](https://agent.elremining.com/login)).

    Log in using your credentials from config.yaml:

        Username: springermedia (Double check spelling: e, not c)

        Password: YOUR_SECURE_PASSWORD

    Verify that the status banner on the right side of the dashboard shows a green LIVE indicator instead of agent init failed.

📌 Phase 5: Add Higgsfield MCP for Image & Video Generation

    Sign up or log into higgsfield.ai.

    In the Hermes Dashboard web terminal, run the following command to link Higgsfield via Model Context Protocol:

    hermes mcp add higgsfield https://mcp.higgsfield.ai

    Test your integration by typing:

    "Generate a cinematic video prompt of a futuristic landscape using Higgsfield."
