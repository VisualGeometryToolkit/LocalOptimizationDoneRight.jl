#!/bin/bash
# Every result and figure of the paper on the Slurm server: reproduce.sh with that site's profile. --dry-run, --only=…, --no-deps, status.
exec bash "$(dirname "${BASH_SOURCE[0]}")/reproduce.sh" --site=dgx01 "$@"
