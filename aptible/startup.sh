#!/bin/bash
set -euo pipefail

# ------------------------------------------------
# Configuration with defaults
# ------------------------------------------------
TOKEN_FILE="${TOKEN_FILE:-/home/aptible/.aptible/tokens.json}"

PG1_APP="${PG1_APP:-postgresql-db}"
PG1_INTERNAL_PORT="${PG1_INTERNAL_PORT:-25432}"
PG1_PUBLIC_PORT="${PG1_PUBLIC_PORT:-54321}"

# configure second PostgreSQL tunnel if needed
# PG2_APP="${PG2_APP:-postgresql-db2}"
# PG2_INTERNAL_PORT="${PG2_INTERNAL_PORT:-25433}"
# PG2_PUBLIC_PORT="${PG2_PUBLIC_PORT:-54322}"

REDIS_APP="${REDIS_APP:-redis-db}"
REDIS_INTERNAL_PORT="${REDIS_INTERNAL_PORT:-51596}"
REDIS_PUBLIC_PORT="${REDIS_PUBLIC_PORT:-51597}"
REDIS_TLS_EXTRA_DOMAINS="${REDIS_TLS_EXTRA_DOMAINS:-}"

PG1_LOG="${PG1_LOG:-/var/log/postgresql1-tunnel.log}"
# PG2_LOG="${PG2_LOG:-/var/log/postgresql2-tunnel.log}"
REDIS_LOG="${REDIS_LOG:-/var/log/redis-tunnel.log}"
UI_LOG="${UI_LOG:-/var/log/terminal-ui.log}"
UI_PORT="${UI_PORT:-3000}"

export HOME="${HOME:-/root}"
export APTIBLE_HOME="${APTIBLE_HOME:-/home/aptible/.aptible}"

# ------------------------------------------------
# Logging helpers
# ------------------------------------------------
log() {
  echo "[aptible-tunnel] $*"
}

fatal() {
  echo "[aptible-tunnel][FATAL] $*" >&2
  exit 1
}

# ------------------------------------------------
# Wait for Aptible token
# ------------------------------------------------
wait_for_token() {
  log "Waiting for Aptible token..."

  for i in $(seq 1 6000); do
    if [ -s "$TOKEN_FILE" ]; then
      if aptible apps >/dev/null 2>&1; then
        log "Aptible token found and valid"
        return 0
      else
        log "Aptible token present but authentication failed; waiting for renewed token..."
      fi
    fi
    sleep 1
  done

  fatal "tokens.json missing, empty, or invalid"
}

# ------------------------------------------------
# Start Aptible tunnels
# ------------------------------------------------
start_tunnels() {

  log "Starting PostgreSQL tunnels..."

  (echo 'y' | aptible db:tunnel "$PG1_APP" \
    --port="$PG1_INTERNAL_PORT" \
    > "$PG1_LOG" 2>&1) &
  PG1_PID=$!

  if [ -n "${PG2_APP:-}" ]; then
    (echo 'y' | aptible db:tunnel "$PG2_APP" \
      --port="$PG2_INTERNAL_PORT" \
      > "$PG2_LOG" 2>&1) &
    PG2_PID=$!
  fi

  log "Starting Redis tunnel..."

  (echo 'y' | aptible db:tunnel "$REDIS_APP" \
    --port="$REDIS_INTERNAL_PORT" \
    > "$REDIS_LOG" 2>&1) &
  REDIS_PID=$!

  sleep 3
}

# ------------------------------------------------
# Wait for tunnel ready
# ------------------------------------------------
wait_for_tunnel_ready() {

  local LOG_FILE="$1"
  local NAME="$2"
  local TIMEOUT=60

  log "Waiting for $NAME tunnel..."

  for i in $(seq 1 "$TIMEOUT"); do

    if grep -q "Connected. Ctrl-C to close connection." "$LOG_FILE"; then
      log "$NAME tunnel READY"
      return 0
    fi

    if grep -qiE "authentication" "$LOG_FILE"; then
      tail -n 50 "$LOG_FILE"
      log "$NAME tunnel authentication failed; waiting for token renewal and restarting tunnels"
      wait_for_token
      log "Restarting tunnels after token renewal"
      kill ${PG1_PID:-} ${PG2_PID:-} ${REDIS_PID:-} 2>/dev/null || true
      wait || true
      start_tunnels
      sleep 1
      continue
    fi

    if grep -qiE "error|failed|denied" "$LOG_FILE"; then
      tail -n 50 "$LOG_FILE"
      fatal "$NAME tunnel failed"
    fi

    sleep 1
  done

  fatal "$NAME tunnel timeout"
}

# ------------------------------------------------
# Wait for port binding
# ------------------------------------------------
wait_for_port_binding() {

  local PORT="$1"
  local NAME="$2"

  log "Waiting for $NAME port $PORT..."

  for i in $(seq 1 60); do
    if ss -lnt | grep -q ":$PORT"; then
      log "$NAME listening on $PORT"
      return 0
    fi
    sleep 1
  done

  fatal "$NAME did not bind to $PORT"
}

# ------------------------------------------------
# PostgreSQL proxy
# ------------------------------------------------
start_pg_proxy() {

  log "Starting PostgreSQL proxies..."

  socat TCP-LISTEN:${PG1_PUBLIC_PORT},fork,reuseaddr,bind=0.0.0.0 \
        TCP:127.0.0.1:${PG1_INTERNAL_PORT} &
  PG1_SOCAT_PID=$!

  if [ -n "${PG2_APP:-}" ]; then
    socat TCP-LISTEN:${PG2_PUBLIC_PORT},fork,reuseaddr,bind=0.0.0.0 \
          TCP:127.0.0.1:${PG2_INTERNAL_PORT} &
    PG2_SOCAT_PID=$!
  fi

  sleep 2

  ss -lnt | grep ":${PG1_PUBLIC_PORT}" >/dev/null || fatal "PG1 proxy failed"
  if [ -n "${PG2_APP:-}" ]; then
    ss -lnt | grep ":${PG2_PUBLIC_PORT}" >/dev/null || fatal "PG2 proxy failed"
  fi

  log "PostgreSQL proxies started"
}

# ------------------------------------------------
# Generate Redis TLS certificate
# ------------------------------------------------
generate_redis_cert() {

  CERT_DIR="/etc/ssl/redis-proxy"
  mkdir -p "$CERT_DIR"

  if [ ! -f "$CERT_DIR/server.pem" ]; then

    log "Generating Redis TLS certificate..."

    # Build SAN list: default SANs + extra domains from environment
    SAN_LIST="DNS:localhost,IP:127.0.0.1"
    
    # Add extra domains if specified in REDIS_TLS_EXTRA_DOMAINS
    if [ -n "$REDIS_TLS_EXTRA_DOMAINS" ]; then
      log "Adding extra domains to Redis TLS certificate: $REDIS_TLS_EXTRA_DOMAINS"
      IFS=',' read -ra EXTRA_DOMAINS <<< "$REDIS_TLS_EXTRA_DOMAINS"
      for domain in "${EXTRA_DOMAINS[@]}"; do
        SAN_LIST="${SAN_LIST},DNS:${domain}"
      done
    fi

    openssl req -x509 -newkey rsa:4096 \
      -keyout "$CERT_DIR/server.key" \
      -out "$CERT_DIR/server.pem" \
      -days 365 \
      -nodes \
      -subj "/CN=localhost" \
      -addext "subjectAltName=${SAN_LIST}" \
      2>/dev/null

    chmod 600 "$CERT_DIR/server.key"
  fi
}

# ------------------------------------------------
# Ensure hostname resolution
# ------------------------------------------------
ensure_hostname_resolution() {

  if ! getent hosts ng-pep-aptible | grep -q "127.0.0.1"; then
    echo "127.0.0.1 ng-pep-aptible" >> /etc/hosts
  fi
}

# ------------------------------------------------
# Redis TLS proxy
# ------------------------------------------------
start_redis_tls_proxy() {

  log "Starting Redis TLS proxy..."

  ensure_hostname_resolution
  generate_redis_cert

  socat \
  OPENSSL-LISTEN:${REDIS_PUBLIC_PORT},fork,reuseaddr,bind=0.0.0.0,cert=/etc/ssl/redis-proxy/server.pem,key=/etc/ssl/redis-proxy/server.key,verify=0 \
  OPENSSL:ng-pep-aptible:${REDIS_INTERNAL_PORT},verify=1,cafile=/etc/ssl/certs/ca-certificates.crt,commonname=*.aptible.in \
  &

  REDIS_SOCAT_PID=$!

  sleep 3

  ss -lnt | grep ":${REDIS_PUBLIC_PORT}" >/dev/null || fatal "Redis proxy failed"

  log "Redis TLS proxy started"
}

# ------------------------------------------------
# Start Terminal UI
# ------------------------------------------------
start_terminal_ui() {

  log "Starting Terminal UI on http://localhost:${UI_PORT}"

  # Run ttyd as root with aptible user for the shell
  HOME=/home/aptible APTIBLE_HOME=/root/.aptible BASH_ENV="" /usr/local/bin/ttyd -p ${UI_PORT} -u 1000 -g 1000 -w /home/aptible --writable bash > "$UI_LOG" 2>&1 &
  UI_PID=$!
}

# ------------------------------------------------
# Monitor processes
# ------------------------------------------------
monitor_processes() {

  log "======================================"
  log "All services started successfully"
  log "======================================"

  log "PG1: 0.0.0.0:${PG1_PUBLIC_PORT} → 127.0.0.1:${PG1_INTERNAL_PORT}"
  if [ -n "${PG2_APP:-}" ]; then
    log "PG2: 0.0.0.0:${PG2_PUBLIC_PORT} → 127.0.0.1:${PG2_INTERNAL_PORT}"
  fi
  log "Redis TLS: 0.0.0.0:${REDIS_PUBLIC_PORT}"
  log "Terminal UI: http://localhost:${UI_PORT}"

  log "======================================"

  while true; do

    for PID in \
    "$PG1_PID" \
    "${PG2_PID:-}" \
    "$REDIS_PID" \
    "$PG1_SOCAT_PID" \
    "${PG2_SOCAT_PID:-}" \
    "$REDIS_SOCAT_PID" \
    "${UI_PID:-}"
    do

      if [ -n "$PID" ] && ! kill -0 "$PID" 2>/dev/null; then
        fatal "Process died (PID: $PID)"
      fi

    done

    sleep 5

  done
}

# ------------------------------------------------
# Cleanup
# ------------------------------------------------
cleanup() {

  log "Stopping services..."

  kill \
  ${PG1_PID:-} \
  ${PG2_PID:-} \
  ${REDIS_PID:-} \
  ${PG1_SOCAT_PID:-} \
  ${PG2_SOCAT_PID:-} \
  ${REDIS_SOCAT_PID:-} \
  ${UI_PID:-} \
  2>/dev/null || true

  wait || true

  log "Shutdown complete"
}

trap cleanup EXIT INT TERM

# ------------------------------------------------
# MAIN
# ------------------------------------------------

log "======================================"
log "Aptible Tunnel Service Starting"
log "======================================"

start_terminal_ui

wait_for_token

rm -f /root/.aptible/ssh/id_rsa /root/.aptible/ssh/id_rsa.pub 2>/dev/null || true

start_tunnels

wait_for_tunnel_ready "$PG1_LOG" "PostgreSQL-1"
if [ -n "${PG2_APP:-}" ]; then
  wait_for_tunnel_ready "$PG2_LOG" "PostgreSQL-2"
fi
wait_for_tunnel_ready "$REDIS_LOG" "Redis"

wait_for_port_binding "$PG1_INTERNAL_PORT" "PostgreSQL-1"
if [ -n "${PG2_APP:-}" ]; then
  wait_for_port_binding "$PG2_INTERNAL_PORT" "PostgreSQL-2"
fi
wait_for_port_binding "$REDIS_INTERNAL_PORT" "Redis"

start_pg_proxy

start_redis_tls_proxy

monitor_processes