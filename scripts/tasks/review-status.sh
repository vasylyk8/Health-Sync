#!/usr/bin/env bash
# Read-only: prints the App Store review state of every iOS version and recent review submissions.
source "$(dirname "$0")/lib.sh"
python3 "$ROOT/scripts/tasks/review-status.py"
