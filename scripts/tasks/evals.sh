#!/usr/bin/env bash
# Real Claude + ChatGPT answer fixed questions through the live connector (synthetic user).
source "$(dirname "$0")/lib.sh"
cd "$ROOT/scripts/evals"
npm install --no-audit --no-fund --silent
TOKEN_RAW=$(gcloud secrets versions access latest --secret=synthetic-mcp-token)
ANALYTICS_TOKEN=$(gcloud secrets versions access latest --secret=krok-analytics-mcp-token)
echo "::add-mask::$TOKEN_RAW"
echo "::add-mask::$ANALYTICS_TOKEN"
MCP_URL="$BASE_URL/mcp/$TOKEN_RAW" ANALYTICS_MCP_URL="$BASE_URL/analytics-mcp/$ANALYTICS_TOKEN" node run.mjs
