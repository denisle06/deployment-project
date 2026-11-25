#!/usr/bin/env bash
# Canary release on the prod EC2. Called by Jenkins over SSH:
#   deploy.sh <image@sha256:digest> <git-sha>
# Env options:
#   STAGES="10 100"          canary traffic percentages, in order
#   PROBES=50                HTTP probes per stage through Nginx
#   MAX_P95=2.0              latency gate in seconds
#   SIMULATE_FAILURE=false   true = fail the first gate on purpose (rollback demo)
set -euo pipefail
source "$(dirname "$0")/common.sh"

NEW_IMAGE=${1:?usage: deploy.sh <image@digest> <git-sha>}
NEW_VERSION=${2:?usage: deploy.sh <image@digest> <git-sha>}
STAGES=${STAGES:-"10 100"}
PROBES=${PROBES:-50}
MAX_P95=${MAX_P95:-2.0}
SIMULATE_FAILURE=${SIMULATE_FAILURE:-false}

# The last stage must be 100%: stable is only replaced once it receives no traffic.
case " $STAGES " in *" 100 "*) ;; *) STAGES="$STAGES 100" ;; esac

[ -f "$APP_DIR/app.env" ] || { log "Missing $APP_DIR/app.env (app secrets; check the smarttunes-prod-env credential)"; exit 1; }
install_nginx_site
log "Pulling $NEW_IMAGE"
docker pull -q "$NEW_IMAGE"

# probe_stage PCT -> PROBES requests through Nginx; pass only if no 5xx/timeouts,
# p95 latency under MAX_P95, and the canary actually served traffic (when < 100%).
probe_stage() {
    local pct=$1 errors=0 canary_hits=0 times out code rt body
    times=$(mktemp)
    for _ in $(seq 1 "$PROBES"); do
        out=$(curl -s -m 10 -w '\n%{http_code} %{time_total}' http://127.0.0.1/healthz.php || echo $'\n000 10')
        body=$(echo "$out" | head -n1)
        read -r code rt <<< "$(echo "$out" | tail -n1)"
        echo "$rt" >> "$times"
        if [ "$code" -ge 500 ] || [ "$code" = "000" ]; then errors=$((errors + 1)); fi
        if echo "$body" | grep -q "\"version\":\"${NEW_VERSION}\""; then canary_hits=$((canary_hits + 1)); fi
    done
    local p95
    p95=$(sort -n "$times" | awk -v n="$PROBES" 'NR == int(n * 0.95 + 0.5) {print; exit}')
    rm -f "$times"
    log "Stage ${pct}%: probes=${PROBES} canary_hits=${canary_hits} errors=${errors} p95=${p95}s"

    if [ "$SIMULATE_FAILURE" = "true" ]; then
        log "Gate FAILED: simulated failure requested (demo of automatic rollback)"
        return 1
    fi
    if [ "$errors" -gt 0 ]; then log "Gate FAILED: ${errors} errors"; return 1; fi
    if awk -v a="$p95" -v b="$MAX_P95" 'BEGIN {exit !(a > b)}'; then
        log "Gate FAILED: p95 ${p95}s > ${MAX_P95}s"; return 1
    fi
    # Missing evidence is a failure, not a pass.
    if [ "$canary_hits" -eq 0 ]; then log "Gate FAILED: canary received no probes"; return 1; fi
    log "Gate PASSED"
}

CURRENT_STABLE=$(get_var STABLE_IMAGE)

# First release: nothing to compare against, so go straight to stable.
if [ -z "$CURRENT_STABLE" ]; then
    log "First deployment: starting $NEW_VERSION as stable"
    set_var STABLE_IMAGE "$NEW_IMAGE"
    set_var CANARY_IMAGE "$NEW_IMAGE"
    compose up -d stable node-exporter cadvisor
    wait_healthy "$STABLE_PORT"
    set_weights 100 0
    exit 0
fi

if [ "$CURRENT_STABLE" = "$NEW_IMAGE" ]; then
    log "$NEW_VERSION is already stable; nothing to release"
    compose up -d stable node-exporter cadvisor
    set_weights 100 0
    exit 0
fi

# 1. Start the canary next to stable; it gets no traffic until it is healthy.
log "Starting canary $NEW_VERSION (stable stays $CURRENT_STABLE)"
set_var CANARY_IMAGE "$NEW_IMAGE"
compose up -d canary node-exporter cadvisor
if ! wait_healthy "$CANARY_PORT"; then rollback "canary failed readiness check"; exit 1; fi

# 2. Shift traffic stage by stage; any failed gate rolls back immediately.
for pct in $STAGES; do
    set_weights $((100 - pct)) "$pct"
    if ! probe_stage "$pct"; then rollback "gate failed at ${pct}%"; exit 1; fi
done

# 3. Promote: the canary image becomes stable, then the canary container is removed.
log "Promoting $NEW_VERSION to stable"
set_var STABLE_IMAGE "$NEW_IMAGE"
compose up -d stable
if ! wait_healthy "$STABLE_PORT"; then
    log "New stable failed health check; canary keeps 100% of traffic"
    exit 1
fi
set_weights 100 0
compose rm -sf canary > /dev/null
log "Release $NEW_VERSION complete"
