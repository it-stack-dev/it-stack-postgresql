#!/bin/bash
# entrypoint.sh — IT-Stack postgresql container entrypoint
set -euo pipefail

echo "Starting IT-Stack POSTGRESQL (Module 03)..."

# Source any environment overrides
if [ -f /opt/it-stack/postgresql/config.env ]; then
    # shellcheck source=/dev/null
    source /opt/it-stack/postgresql/config.env
fi

# Execute the upstream entrypoint or command
exec "$$@"
