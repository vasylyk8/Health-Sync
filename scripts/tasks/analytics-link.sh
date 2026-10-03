#!/usr/bin/env bash
# Prints the private operator connector URL. Run only in a trusted terminal; treat it like a password.
source "$(dirname "$0")/lib.sh"
TOKEN_RAW=$(gcloud secrets versions access latest --secret=krok-analytics-mcp-token)
echo "Private KROK Analytics connector (do not paste into tickets or logs):"
echo "$BASE_URL/analytics-mcp/$TOKEN_RAW"

