#!/usr/bin/env bash
# Re-sends the open App Review submission after a rejection (build checked first). Run only when the owner says submit.
source "$(dirname "$0")/lib.sh"
python3 "$ROOT/scripts/tasks/resubmit-review.py"
