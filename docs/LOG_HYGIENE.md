# Keeping connector links out of logs

A connector link is `https://<site>/mcp/<token>`. The token is the only credential protecting a user's
Health data, and the server stores only its SHA-256 hash. But Cloud Run writes every request, including
its full URL, to Cloud Logging (`run.googleapis.com/requests`), where it is kept for 30 days by default.
Anyone who can read those logs could replay a link. This contradicts "only a hash of each link is stored".

The app's own log lines never contain the token (`tool call`, `mcp request failed` log only the tool,
provider, timing and status), so excluding the request log loses very little.

## Fix (run once, as a project owner)

```bash
PROJECT=<your-project-id>

# 1. Stop new request logs for the MCP function from being stored.
gcloud logging sinks update _Default --project="$PROJECT" \
  --add-exclusion='name=exclude-mcp-request-urls,description=Request URLs contain connector tokens,filter=logName:"run.googleapis.com%2Frequests" AND httpRequest.requestUrl:"/mcp/"'

# 2. Check it took effect (the exclusion should be listed).
gcloud logging sinks describe _Default --project="$PROJECT" --format='value(exclusions)'
```

## Existing logs

Exclusions only apply to new entries. Logs already stored expire on their own after the bucket's
retention period (30 days for `_Default`). To remove them now, delete the request log; this removes
request logs for every function in the project, not only the MCP one:

```bash
gcloud logging logs delete run.googleapis.com%2Frequests --project="$PROJECT"
```

## Verify

Open Logs Explorer with `httpRequest.requestUrl:"/mcp/"` after a few minutes of use. There should be no
new entries. Tool calls remain visible through the app's own `tool call` log lines.

## Trade-off

You lose per-request latency and status codes from Cloud Run for `/mcp/`. The `tool call` log lines
(tool, provider, milliseconds, ok/error) and the Cloud Run metrics (request count, latency, errors)
still work, because metrics are collected separately from logs.
