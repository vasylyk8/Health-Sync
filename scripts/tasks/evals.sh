#!/usr/bin/env bash
# Real Claude + ChatGPT answer fixed questions through the live connector (synthetic user).
source "$(dirname "$0")/lib.sh"
cd "$ROOT/scripts/evals"
npm install --no-audit --no-fund --silent
TOKEN_RAW=$(gcloud secrets versions access latest --secret=synthetic-mcp-token)
echo "::add-mask::$TOKEN_RAW"
MCP_URL="$BASE_URL/mcp/$TOKEN_RAW" node run.mjs
