#!/usr/bin/env bash
# Writes the App Store listing text (name, subtitle, keywords, description, promotional text). Never submits.
source "$(dirname "$0")/lib.sh"
python3 "$ROOT/scripts/tasks/update-listing.py"
