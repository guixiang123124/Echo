#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="$ROOT_DIR/backend"
RAILWAY="npx -y @railway/cli"

SERVICE_NAME="${RAILWAY_SERVICE_NAME:-echo-api}"
ENV_NAME="${RAILWAY_ENVIRONMENT:-production}"
PROJECT_ID="${RAILWAY_PROJECT_ID:-}"

echo "[1/4] Checking Railway auth..."
if ! $RAILWAY whoami >/dev/null 2>&1; then
  echo "Railway CLI is not authenticated."
  echo "Run: npx -y @railway/cli login --browserless"
  exit 1
fi

cd "$BACKEND_DIR"

echo "[2/4] Linking Railway project/service..."
if [[ -n "$PROJECT_ID" ]]; then
  $RAILWAY link --project "$PROJECT_ID" --service "$SERVICE_NAME" --environment "$ENV_NAME"
else
  echo "RAILWAY_PROJECT_ID is empty. If this is your first deploy, run:"
  echo "  npx -y @railway/cli link --service $SERVICE_NAME --environment $ENV_NAME"
fi

echo "[3/4] Syncing env vars from backend/.env.production (if exists)..."
if [[ -f "$BACKEND_DIR/.env.production" ]]; then
  while IFS='=' read -r key value; do
    [[ -z "${key:-}" ]] && continue
    [[ "$key" =~ ^[[:space:]]*# ]] && continue
    key="$(echo "$key" | xargs)"
    value="${value%$'\r'}"
    $RAILWAY variable set --service "$SERVICE_NAME" --environment "$ENV_NAME" --skip-deploys "$key=$value" >/dev/null
  done < "$BACKEND_DIR/.env.production"
  echo "Environment variables synced."
else
  echo "No backend/.env.production file found. Skipping env sync."
fi

echo "[4/5] Building backend..."
npm run build

echo "[5/5] Deploying backend service..."
cd "$ROOT_DIR"
$RAILWAY up --service "$SERVICE_NAME" --environment "$ENV_NAME"

echo "Deployment command sent. Check logs with:"
echo "  npx -y @railway/cli logs --service $SERVICE_NAME --environment $ENV_NAME"
