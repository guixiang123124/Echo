#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCS_DIR="$ROOT_DIR/docs"
VERCEL="npx -y vercel"

TARGET="${1:-preview}"

echo "[1/3] Checking Vercel auth..."
if ! $VERCEL whoami >/dev/null 2>&1; then
  echo "Vercel CLI is not authenticated."
  echo "Run: npx -y vercel login"
  exit 1
fi

cd "$DOCS_DIR"

echo "[2/3] Deploying docs from $DOCS_DIR ..."
if [[ "$TARGET" == "prod" ]]; then
  DEPLOY_URL="$($VERCEL deploy --prod --yes)"
else
  DEPLOY_URL="$($VERCEL deploy --yes)"
fi

echo "[3/3] Done."
echo "Deployment URL: $DEPLOY_URL"
