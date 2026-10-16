# syntax=docker/dockerfile:1
ARG BASE_IMAGE=node:24-trixie-slim
ARG GO_IMAGE=golang:1.27.2-trixie
FROM ${GO_IMAGE} AS go
FROM ${BASE_IMAGE}

COPY --from=go /usr/local/go /usr/local/go

ARG CODEX_VERSION=latest
ARG CLAUDE_VERSION=latest
ARG SANDBOX_UID=1000

# OpenSSH requires a passwd entry for the non-root runtime UID.
RUN if ! getent passwd "$SANDBOX_UID" >/dev/null; then usermod -u "$SANDBOX_UID" node; fi

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       bash ca-certificates curl git openssh-client ripgrep procps python3 python3-venv build-essential \
    && rm -rf /var/lib/apt/lists/*
RUN npm install --global --allow-scripts=@anthropic-ai/claude-code \
      "@openai/codex@${CODEX_VERSION}" \
      "@anthropic-ai/claude-code@${CLAUDE_VERSION}" \
    && npm cache clean --force \
    && { codex --version; claude --version; } > /opt/agent-versions.txt

ENV HOME=/home/node \
    CODEX_HOME=/home/node/.codex \
    PATH="/usr/local/go/bin:/home/node/go/bin:/home/node/.local/bin:${PATH}" \
    DISABLE_AUTOUPDATER=1 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
COPY --chmod=0555 entrypoint.sh /usr/local/bin/agent-entrypoint
RUN mkdir /workspace && chown node:node /workspace
WORKDIR /workspace
USER node
ENTRYPOINT ["/usr/local/bin/agent-entrypoint"]
CMD ["shell"]
