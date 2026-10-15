# syntax=docker/dockerfile:1
ARG BASE_IMAGE=node:22-bookworm-slim
ARG GO_IMAGE=golang:1.27.2-bookworm
FROM ${GO_IMAGE} AS go
FROM ${BASE_IMAGE}

COPY --from=go /usr/local/go /usr/local/go

ARG CODEX_VERSION=latest
ARG CLAUDE_VERSION=latest

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       bash ca-certificates curl git ripgrep procps python3 python3-venv build-essential \
    && rm -rf /var/lib/apt/lists/*
RUN npm install --global \
      "@openai/codex@${CODEX_VERSION}" \
      "@anthropic-ai/claude-code@${CLAUDE_VERSION}" \
    && npm cache clean --force \
    && { codex --version; claude --version; } > /opt/agent-versions.txt

ENV HOME=/home/node \
    PATH="/usr/local/go/bin:/home/node/go/bin:/home/node/.local/bin:${PATH}" \
    DISABLE_AUTOUPDATER=1 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
COPY --chmod=0555 entrypoint.sh /usr/local/bin/agent-entrypoint
RUN mkdir /workspace && chown node:node /workspace
WORKDIR /workspace
USER node
ENTRYPOINT ["/usr/local/bin/agent-entrypoint"]
CMD ["shell"]
