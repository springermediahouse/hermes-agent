# ... (All your previous COPY and RUN commands stay the same) ...

ENV HERMES_WEB_DIST=/opt/hermes/hermes_cli/web_dist
ENV HERMES_TUI_DIR=/opt/hermes/ui-tui
ENV HERMES_HOME=/opt/data
ENV HERMES_WRITE_SAFE_ROOT=/opt/data
ENV HERMES_DISABLE_LAZY_INSTALLS=1
ENV HERMES_LAZY_INSTALL_TARGET=/opt/data/lazy-packages

ENV PATH="/opt/hermes/bin:/opt/hermes/.venv/bin:/opt/data/.local/bin:${PATH}"

# Fix: Create /opt/data and seed default config before defining VOLUME
RUN mkdir -p /opt/data

# Copy your local config.yaml to /opt/data so it serves as the base configuration
COPY config.yaml /opt/data/config.yaml

VOLUME [ "/opt/data" ]

ENTRYPOINT [ "/init", "/opt/hermes/docker/main-wrapper.sh" ]
# Starts the gateway process, which runs the web dashboard on port 8080
CMD [ "gateway", "run" ]
