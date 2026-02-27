# Dockerfile — IT-Stack POSTGRESQL wrapper
# Module 03 | Category: database | Phase: 1
# Base image: postgres:16

FROM postgres:16

# Labels
LABEL org.opencontainers.image.title="it-stack-postgresql" \
      org.opencontainers.image.description="PostgreSQL primary database" \
      org.opencontainers.image.vendor="it-stack-dev" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.source="https://github.com/it-stack-dev/it-stack-postgresql"

# Copy custom configuration and scripts
COPY src/ /opt/it-stack/postgresql/
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
