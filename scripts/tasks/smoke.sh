#!/usr/bin/env bash
# End-to-end check of the live deployment using the synthetic user.
source "$(dirname "$0")/lib.sh"
TOKEN_RAW=$(gcloud secrets versions access latest --secret=synthetic-mcp-token)
MCP="$BASE_URL/mcp/$TOKEN_RAW"
rpc() { curl -sS -X POST "$MCP" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "$1"; }

# A fresh Hosting release can take a minute to reach every edge.
for i in $(seq 1 12); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/health"); [[ "$code" == 200 ]] && break
  sleep 10
done
if [[ "$code" != 200 ]]; then
  echo "--- $BASE_URL/health"; curl -sS -i "$BASE_URL/health" | head -c 1500; echo
  direct=$(gcloud functions describe healthz --region="$REGION" --format='value(serviceConfig.uri)' 2>/dev/null || true)
  [[ -n "$direct" ]] && { echo "--- $direct"; curl -sS -i "$direct" | head -c 800; echo; }
  fail "healthz returned $code"
fi
echo "healthz ok"
rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}' | grep -q '"krok"' || fail "MCP initialize failed"
echo "initialize ok"
rpc '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | grep -q '"get_workouts"' || fail "tools/list failed"
echo "tools/list ok"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/mcp/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" -H 'Content-Type: application/json' -d '{}'); [[ "$code" == 404 ]] || fail "unknown link returned $code (expected 404)"
echo "unknown link rejected"

ANALYTICS_TOKEN=$(gcloud secrets versions access latest --secret=krok-analytics-mcp-token)
ANALYTICS_MCP="$BASE_URL/analytics-mcp/$ANALYTICS_TOKEN"
analytics_rpc() { curl -sS -X POST "$ANALYTICS_MCP" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "$1"; }
analytics_rpc '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}' | grep -q '"krok-analytics"' || fail "Analytics MCP initialize failed"
analytics_rpc '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | grep -q '"activation_funnel"' || fail "Analytics MCP tools/list failed"
echo "analytics connector ok"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/analytics-mcp/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" -H 'Content-Type: application/json' -d '{}'); [[ "$code" == 404 ]] || fail "unknown analytics link returned $code (expected 404)"
echo "unknown analytics link rejected"
# Calls a tool and prints its (decoded) result text.
call() { rpc "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["content"][0]["text"])' 2>/dev/null; }
# check JSON_TEXT PYTHON_EXPRESSION_ON_d
check() { echo "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if ($2) else 1)" 2>/dev/null; }

# Ingestion is asynchronous: wait for the synthetic workout and its raw data to become queryable.
for i in $(seq 1 30); do
  out=$(call get_workouts '{"start_date":"2024-03-04","end_date":"2024-03-04","timezone":"Europe/Berlin"}')
  if check "$out" 'd["workouts"][0]["distance_km"] == 5 and d["workouts"][0]["raw_data"] == "complete"'; then
    echo "get_workouts ok (5 km run on 2024-03-04, raw data complete)"; break
  fi
  sleep 10
done
check "${out:-}" 'd["workouts"][0]["raw_data"] == "complete"' || { echo "${out:-}" | head -c 1000; fail "synthetic workout did not become queryable within 5 minutes"; }
zones=$(call workout_hr_zones '{"workout_id":"run-2024-03-04","max_hr":200}')
check "$zones" 'd["zones"][2]["seconds"] == 1800' || { echo "$zones" | head -c 800; fail "workout_hr_zones returned an unexpected answer"; }
echo "workout_hr_zones ok (1800 s in zone 3)"
splits=$(call workout_splits '{"workout_id":"run-2024-03-04"}')
check "$splits" 'len(d["splits"]) == 5 and all(s["moving_seconds"] == 360 for s in d["splits"])' || { echo "$splits" | head -c 800; fail "workout_splits returned an unexpected answer"; }
echo "workout_splits ok (5 x 6:00 km)"
route=$(call get_workout_route '{"workout_id":"run-2024-03-04","max_points":50}')
check "$route" 'd["trimmed_ends"] is True and d["returned"] > 10' || { echo "$route" | head -c 800; fail "get_workout_route returned an unexpected answer"; }
echo "get_workout_route ok (privacy trimming on)"
daily=$(call get_daily_context '{"start_date":"2024-03-01","end_date":"2024-03-01"}')
check "$daily" 'd["days"][0]["steps"] == 10000' || { echo "$daily" | head -c 800; fail "get_daily_context returned an unexpected answer"; }
echo "get_daily_context ok (10000 steps on 2024-03-01)"
