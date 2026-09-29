#!/usr/bin/env bash
# Adds the owner and second tester to the internal TestFlight group.
source "$(dirname "$0")/lib.sh"
python3 "$ROOT/scripts/tasks/testers.py"
