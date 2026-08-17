#!/usr/bin/env bash
set -euo pipefail

COMPOSE_DIR="${1:-/opt/remnanode}"

cd "$COMPOSE_DIR"
docker compose pull
docker compose up -d

docker image prune -f
