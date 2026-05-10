#!/usr/bin/env bash
#
# blink1-cloudflared.sh — drive a blink(1) USB LED from cloudflared activity.
#
# States (lowest to highest priority):
#   1. Tunnel healthy           -> solid dim blue
#   2. SSH session active       -> solid amber (overrides healthy)
#   3. HTTP request just served -> brief green flash (overrides both)
#   *. Metrics unreachable      -> dim red
#
# "SSH active" = cloudflared has an ESTABLISHED TCP connection to local sshd
# (i.e. the tunnel is configured with `service: ssh://localhost:22`).
# "HTTP request" = the cloudflared_tunnel_total_requests counter advanced
# since the last poll. This fires per request, not per TCP connection — so a
# busy keep-alive connection still produces visible flashes.
#
# Requirements:
#   - blink1-tool on PATH (brew install blink1-tool)
#   - cloudflared running with metrics enabled, e.g. in ~/.cloudflared/config.yml:
#         metrics: localhost:20241
#     or on the CLI: cloudflared tunnel --metrics localhost:20241 run <name>
#
# Usage:
#   ./blink1-cloudflared.sh
#   METRICS_URL=http://localhost:20241/metrics ./blink1-cloudflared.sh
#
# Ctrl-C turns the LED off and exits.

set -uo pipefail

METRICS_URL="${METRICS_URL:-http://localhost:20241/metrics}"
POLL_INTERVAL="${POLL_INTERVAL:-1}"
SSH_PORT="${SSH_PORT:-22}"
HTTP_FLASH_MS="${HTTP_FLASH_MS:-180}"

# Colors as R,G,B (0-255). Tweak to taste.
COLOR_HEALTHY="${COLOR_HEALTHY:-0,0,40}"      # dim blue
COLOR_SSH="${COLOR_SSH:-90,40,0}"             # amber
COLOR_HTTP="${COLOR_HTTP:-0,255,0}"           # bright green
COLOR_DOWN="${COLOR_DOWN:-40,0,0}"            # dim red
COLOR_OFF="0,0,0"

BLINK1_TOOL="${BLINK1_TOOL:-$(command -v blink1-tool 2>/dev/null || true)}"
if [[ -z "$BLINK1_TOOL" || ! -x "$BLINK1_TOOL" ]]; then
  echo "blink1-tool not found. Install with: brew install blink1-tool" >&2
  echo "Or set BLINK1_TOOL=/path/to/blink1-tool" >&2
  exit 1
fi

set_color() {
  "$BLINK1_TOOL" --rgb "$1" -q >/dev/null 2>&1 || true
}

cleanup() {
  set_color "$COLOR_OFF"
  exit 0
}
trap cleanup INT TERM

# Sum cloudflared_tunnel_total_requests across all label sets. Returns
# nonzero (and empty stdout) if the metrics endpoint is unreachable.
get_request_count() {
  local body
  body=$(curl -fsS --max-time 2 "$METRICS_URL" 2>/dev/null) || return 1
  printf '%s\n' "$body" \
    | awk '/^cloudflared_tunnel_total_requests[ {]/ {sum += $NF} END {print sum+0}'
}

has_ssh_connection() {
  local pids pid
  pids=$(pgrep -x cloudflared 2>/dev/null || true)
  [[ -z "$pids" ]] && return 1
  for pid in $pids; do
    if lsof -nP -p "$pid" -a -iTCP:"$SSH_PORT" -sTCP:ESTABLISHED 2>/dev/null \
        | grep -q .; then
      return 0
    fi
  done
  return 1
}

sleep_ms() {
  awk -v ms="$1" 'BEGIN { system("sleep " ms/1000) }'
}

current_color=""
apply_color() {
  if [[ "$1" != "$current_color" ]]; then
    set_color "$1"
    current_color="$1"
  fi
}

prev_count=""

echo "Watching $METRICS_URL (Ctrl-C to stop)"

while true; do
  if ! count=$(get_request_count) || [[ -z "$count" ]]; then
    apply_color "$COLOR_DOWN"
    prev_count=""
    sleep "$POLL_INTERVAL"
    continue
  fi

  if has_ssh_connection; then
    base_color="$COLOR_SSH"
  else
    base_color="$COLOR_HEALTHY"
  fi

  if [[ -n "$prev_count" && "$count" -gt "$prev_count" ]]; then
    set_color "$COLOR_HTTP"
    sleep_ms "$HTTP_FLASH_MS"
    current_color=""  # force re-apply of base after the flash
  fi

  apply_color "$base_color"
  prev_count="$count"
  sleep "$POLL_INTERVAL"
done
