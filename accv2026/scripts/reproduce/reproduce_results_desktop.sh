#!/bin/bash
# Every result and figure of the paper on a workstation (local backend): reproduce.sh with the desktop site. --dry-run, --only=…, --no-deps, status.
exec bash "$(dirname "${BASH_SOURCE[0]}")/reproduce.sh" --site=desktop "$@"
