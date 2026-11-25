#!/usr/bin/env bash
# Shared helpers for deploy.sh and rollback.sh (run on the prod EC2 as ubuntu).

APP_DIR=/opt/smarttunes
ENV_FILE="$APP_DIR/.env"                                   # STABLE_IMAGE / CANARY_IMAGE
UPSTREAM_CONF=/etc/nginx/conf.d/smarttunes-upstream.conf
SERVER_CONF=/etc/nginx/conf.d/smarttunes.conf
STABLE_PORT=8081
CANARY_PORT=8082

log() { echo "[$(date '+%H:%M:%S')] $*"; }

compose() {
    docker compose --project-directory "$APP_DIR" -f "$APP_DIR/docker-compose.yml" "$@"
}

get_var() {   # get_var KEY -> value from .env (empty if missing)
    [ -f "$ENV_FILE" ] && grep -E "^$1=" "$ENV_FILE" | tail -n1 | cut -d= -f2- || true
}

set_var() {   # set_var KEY VALUE -> create or replace KEY in .env
    touch "$ENV_FILE"
    if grep -qE "^$1=" "$ENV_FILE"; then
        sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"
    else
        echo "$1=$2" >> "$ENV_FILE"
    fi
}

install_nginx_site() {
    sudo cp "$APP_DIR/nginx/smarttunes.conf" "$SERVER_CONF"
}

# set_weights STABLE% CANARY% -> rewrite the Nginx upstream, validate, reload.
# Nginx has no weight 0, so a 0% backend is left out of the upstream entirely.
set_weights() {
    local stable=$1 canary=$2 tmp
    tmp=$(mktemp)
    {
        echo "# Managed by deploy.sh: stable=${stable}% canary=${canary}%"
        echo "upstream smarttunes_app {"
        # max_fails=0: never auto-eject a failing canary; the gate decides.
        [ "$stable" -gt 0 ] && echo "    server 127.0.0.1:${STABLE_PORT} weight=${stable} max_fails=0;"
        [ "$canary" -gt 0 ] && echo "    server 127.0.0.1:${CANARY_PORT} weight=${canary} max_fails=0;"
        echo "}"
    } > "$tmp"
    sudo cp "$tmp" "$UPSTREAM_CONF"
    rm -f "$tmp"
    sudo nginx -t -q
    sudo systemctl reload nginx
    log "Traffic weights: stable=${stable}% canary=${canary}%"
}

# wait_healthy PORT -> poll healthz.php directly on one container (max ~60 s).
wait_healthy() {
    local port=$1
    for _ in $(seq 1 30); do
        if curl -fsS "http://127.0.0.1:${port}/healthz.php" > /dev/null 2>&1; then
            log "Container on :${port} is healthy"
            return 0
        fi
        sleep 2
    done
    log "Container on :${port} did not become healthy"
    return 1
}

# rollback REASON -> all traffic back to stable, canary removed.
rollback() {
    local started=$SECONDS
    log "ROLLBACK: $1"
    set_weights 100 0
    compose rm -sf canary > /dev/null 2>&1 || true
    set_var CANARY_IMAGE "$(get_var STABLE_IMAGE)"
    log "Rollback complete in $((SECONDS - started))s; stable=$(get_var STABLE_IMAGE)"
}
