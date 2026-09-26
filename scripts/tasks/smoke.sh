#!/usr/bin/env bash
# End-to-end check of the live deployment using the synthetic user.
source "$(dirname "$0")/lib.sh"
TOKEN_RAW=$(gcloud secrets versions access latest --secret=synthetic-mcp-token)
MCP="$BASE_URL/mcp/$TOKEN_RAW"
rpc() { curl -sS -X POST "$MCP" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "$1"; }

code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/healthz"); [[ "$code" == 200 ]] || fail "healthz returned $code"
echo "healthz ok"
rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}' | grep -q '"health-sync"' || fail "MCP initialize failed"
echo "initialize ok"
rpc '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | grep -q '"summarize"' || fail "tools/list failed"
echo "tools/list ok"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/mcp/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" -H 'Content-Type: application/json' -d '{}'); [[ "$code" == 404 ]] || fail "unknown link returned $code (expected 404)"
echo "unknown link rejected"
# Ingestion is asynchronous: wait for the synthetic data to become queryable.
for i in $(seq 1 30); do
  out=$(rpc '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"summarize","arguments":{"type":"StepCount","start_date":"2024-03-01","end_date":"2024-03-31","period":"none"}}}')
  if echo "$out" | grep -q '285000'; then echo "summarize ok (285000 steps in March 2024)"; exit 0; fi
  sleep 10
done
echo "$out" | head -c 1000
fail "synthetic data did not become queryable within 5 minutes"
