#!/usr/bin/env bash
# Hindsight on Azure — deployment wrapper (subscription-scope Bicep).
#
# Usage:
#   ./deploy.sh <subscription-id-or-name> what-if [params-file]   # preview only (default)
#   ./deploy.sh <subscription-id-or-name> create  [params-file]   # deploys — needs explicit approval
#
# Requires: az CLI with Bicep, an account with Owner on the target subscription, and the
# secrets exported as environment variables (see main.bicepparam / README.md).
# Runs on macOS and WSL2 (bash).

set -euo pipefail

SUBSCRIPTION="${1:?usage: deploy.sh <subscription> [what-if|create] [params-file]}"
MODE="${2:-what-if}"
PARAMS="${3:-main.local.bicepparam}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENT_LOCATION="${DEPLOY_LOCATION:-westeurope}"
DEPLOYMENT_NAME="hindsight-$(date -u +%Y%m%d-%H%M%S)"

if [ ! -f "$HERE/$PARAMS" ]; then
  echo "Parameter file '$PARAMS' not found. Copy main.bicepparam to main.local.bicepparam and fill in the tags." >&2
  exit 1
fi

for var in HINDSIGHT_PG_ADMIN_PASSWORD HINDSIGHT_TENANT_KEY HINDSIGHT_CP_ACCESS_KEY; do
  if [ -z "${!var:-}" ]; then
    echo "Environment variable $var is not set (load it from 1Password first)." >&2
    exit 1
  fi
done

echo "Compiling Bicep..."
az bicep build --file "$HERE/main.bicep" --stdout > /dev/null

case "$MODE" in
  what-if)
    az deployment sub what-if \
      --subscription "$SUBSCRIPTION" \
      --location "$DEPLOYMENT_LOCATION" \
      --name "$DEPLOYMENT_NAME" \
      --parameters "$HERE/$PARAMS"
    ;;
  create)
    az deployment sub create \
      --subscription "$SUBSCRIPTION" \
      --location "$DEPLOYMENT_LOCATION" \
      --name "$DEPLOYMENT_NAME" \
      --parameters "$HERE/$PARAMS" \
      --query properties.outputs -o json
    ;;
  *)
    echo "Mode must be 'what-if' or 'create'." >&2
    exit 2
    ;;
esac
