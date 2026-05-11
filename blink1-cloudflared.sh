#!/usr/bin/env bash
#
# blink1-cloudflared.sh — drive a blink(1) USB LED from cloudflared activity.
#
# States (lowest to highest priority):
#   1. Tunnel healthy           -> solid dim blue
#   2. Vite dev server up       -> solid teal-green (overrides healthy)
#   3. SSH session active       -> solid amber (overrides healthy/vite)
#   3b. SSH + Vite both active  -> alternates SSH and Vite every ALTERNATE_S
#                                  with a hardware fade between them
#   4. HTTP request just served -> brief green flash (overrides everything)
#   *. Metrics unreachable      -> dim red
#   *. No edge connections      -> off (cloudflared is up but can't reach
#                                  the Cloudflare edge, e.g. no network)
#
# "SSH active" = cloudflared has an ESTABLISHED TCP connection to local sshd
# (i.e. the tunnel is configured with `service: ssh://localhost:22`).
# "HTTP request" = the cloudflared_tunnel_total_requests counter advanced
# since the last poll. This fires per request, not per TCP connection — so a
# busy keep-alive connection still produces visible flashes.
#
# Requirements:
#   - blink1-tool on PATH (brew install blink1 — the formula is named "blink1"
#     but ships the blink1-tool CLI from github.com/todbot/blink1-tool)
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

# Load .env from the script's directory if present. Existing environment
# variables win, so `FOO=bar ./blink1-cloudflared.sh` still overrides .env.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$script_dir/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$script_dir/.env"
  set +a
fi

METRICS_URL="${METRICS_URL:-http://localhost:20241/metrics}"
POLL_INTERVAL="${POLL_INTERVAL:-1}"
SSH_PORT="${SSH_PORT:-22}"
VITE_PORT="${VITE_PORT:-4173}"
HTTP_FLASH_MS="${HTTP_FLASH_MS:-180}"
ALTERNATE_S="${ALTERNATE_S:-3}"     # seconds per color when SSH+Vite both active
FADE_MS="${FADE_MS:-500}"           # blink1 hardware fade duration during alternation

# Colors as R,G,B (0-255). Tweak to taste.
COLOR_HEALTHY="${COLOR_HEALTHY:-0,0,40}"      # dim blue
COLOR_SSH="${COLOR_SSH:-255,165,0}"           # amber
COLOR_VITE="${COLOR_VITE:-0,200,120}"         # teal-green
COLOR_HTTP="${COLOR_HTTP:-0,255,0}"           # bright pure green
COLOR_DOWN="${COLOR_DOWN:-40,0,0}"            # dim red
COLOR_OFF="0,0,0"

BLINK1_TOOL="${BLINK1_TOOL:-$(command -v blink1-tool 2>/dev/null || true)}"
if [[ -z "$BLINK1_TOOL" || ! -x "$BLINK1_TOOL" ]]; then
  echo "blink1-tool not found. Install with: brew install blink1" >&2
  echo "Or set BLINK1_TOOL=/path/to/blink1-tool" >&2
  exit 1
fi

set_color() {
  "$BLINK1_TOOL" --rgb "$1" -q >/dev/null 2>&1 || true
}

# Set color with a hardware fade over MILLIS milliseconds.
set_color_fade() {
  "$BLINK1_TOOL" --rgb "$1" -m "$2" -q >/dev/null 2>&1 || true
}

cleanup() {
  set_color "$COLOR_OFF"
  exit 0
}
trap cleanup INT TERM

# Fetch the cloudflared metrics body once. Returns nonzero if unreachable.
fetch_metrics() {
  curl -fsS --max-time 2 "$METRICS_URL" 2>/dev/null
}

# Sum a Prometheus metric across all label sets in a metrics body.
#   $1 = metrics body, $2 = metric name
sum_metric() {
  printf '%s\n' "$1" \
    | awk -v name="$2" '$0 ~ ("^" name "[ {]") {sum += $NF} END {print sum+0}'
}

# Detect an SSH session opened through the tunnel by looking for an
# ESTABLISHED TCP connection on the loopback interface where one end is
# the local sshd port. cloudflared (running as root via launchd) opens a
# loopback connection to 127.0.0.1:22 for each tunneled SSH session, and
# netstat sees it without sudo. This intentionally ignores remote SSH
# connections from the LAN, since those don't terminate on loopback.
has_ssh_connection() {
  netstat -an -p tcp 2>/dev/null | awk -v port="$SSH_PORT" '
    $NF == "ESTABLISHED" {
      local = $4; foreign = $5
      local_loop  = (local  ~ /^127\./ || local  ~ /^::1\./)
      foreign_loop = (foreign ~ /^127\./ || foreign ~ /^::1\./)
      port_re = "\\." port "$"
      if (local_loop && foreign_loop && (local ~ port_re || foreign ~ port_re)) {
        found = 1
      }
    }
    END { exit !found }
  '
}

# Detect a process listening on VITE_PORT (e.g. `vite preview` on 4173).
# netstat shows LISTEN sockets without sudo regardless of owner.
vite_listening() {
  netstat -an -p tcp 2>/dev/null | awk -v port="$VITE_PORT" '
    $NF == "LISTEN" && $4 ~ ("\\." port "$") { found = 1 }
    END { exit !found }
  '
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
  if ! body=$(fetch_metrics); then
    apply_color "$COLOR_DOWN"
    prev_count=""
    sleep "$POLL_INTERVAL"
    continue
  fi

  ha_connections=$(sum_metric "$body" cloudflared_tunnel_ha_connections)
  count=$(sum_metric "$body" cloudflared_tunnel_total_requests)

  # cloudflared is up locally but has no active connections to the
  # Cloudflare edge — no traffic can flow, so treat as offline and
  # turn the LED off regardless of local Vite/SSH state.
  if (( ha_connections == 0 )); then
    apply_color "$COLOR_OFF"
    prev_count="$count"
    sleep "$POLL_INTERVAL"
    continue
  fi

  ssh_active=0; vite_active=0
  has_ssh_connection && ssh_active=1
  vite_listening && vite_active=1

  fade_this_frame=0
  if (( ssh_active && vite_active )); then
    # Alternate every ALTERNATE_S seconds based on wall-clock time bucket.
    if (( ($(date +%s) / ALTERNATE_S) % 2 == 0 )); then
      base_color="$COLOR_SSH"
    else
      base_color="$COLOR_VITE"
    fi
    fade_this_frame=1
  elif (( ssh_active )); then
    base_color="$COLOR_SSH"
  elif (( vite_active )); then
    base_color="$COLOR_VITE"
  else
    base_color="$COLOR_HEALTHY"
  fi

  if [[ -n "$prev_count" && "$count" -gt "$prev_count" ]]; then
    set_color "$COLOR_HTTP"
    sleep_ms "$HTTP_FLASH_MS"
    current_color=""  # force re-apply of base after the flash
  fi

  if (( fade_this_frame )) && [[ "$base_color" != "$current_color" ]]; then
    set_color_fade "$base_color" "$FADE_MS"
    current_color="$base_color"
  else
    apply_color "$base_color"
  fi

  prev_count="$count"
  sleep "$POLL_INTERVAL"
done
