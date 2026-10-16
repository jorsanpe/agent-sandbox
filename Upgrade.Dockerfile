# syntax=docker/dockerfile:1
ARG TARGET_IMAGE=agent-sandbox:base
ARG CURRENT_IMAGE=agent-sandbox:dev
FROM ${TARGET_IMAGE} AS target
FROM ${CURRENT_IMAGE}
USER root
COPY --from=target /usr/local/go /opt/agent-sandbox-upgrade/go
COPY --from=target /usr/local/lib/node_modules/npm /opt/agent-sandbox-upgrade/npm
COPY --from=target /usr/local/bin/node /usr/local/bin/node
COPY --from=target /usr/local/bin/agent-entrypoint /usr/local/bin/agent-entrypoint
COPY --from=target /etc/apt/sources.list.d/debian.sources /opt/agent-sandbox-upgrade/debian.sources
COPY --from=target /usr/share/keyrings /opt/agent-sandbox-upgrade/keyrings
COPY upgrade-image.sh /opt/agent-sandbox-upgrade/upgrade-image.sh
RUN bash /opt/agent-sandbox-upgrade/upgrade-image.sh
ENV HOME=/home/node CODEX_HOME=/home/node/.codex PATH="/usr/local/go/bin:/home/node/go/bin:/home/node/.local/bin:${PATH}" \
    DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
USER node
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/agent-entrypoint"]
CMD ["shell"]
