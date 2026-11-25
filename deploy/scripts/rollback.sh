#!/usr/bin/env bash
# Manual rollback on the prod EC2: send 100% of traffic to stable, remove canary.
#   bash /opt/smarttunes/scripts/rollback.sh
set -euo pipefail
source "$(dirname "$0")/common.sh"
rollback "${1:-manual rollback}"
