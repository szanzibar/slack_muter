#!/usr/bin/env bash
# Pull, rebuild, and restart the slack_bot container.
# Run from the project root on the host:  ./deploy.sh
set -euo pipefail

cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  echo "error: .env not found. Copy .env.default to .env and fill it in." >&2
  exit 1
fi

echo "==> git pull"
git pull --ff-only

echo "==> docker compose build"
docker compose build

echo "==> docker compose up -d"
docker compose up -d

echo "==> done. tail logs with: docker compose logs -f"
