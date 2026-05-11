# blink1-cloudflared

Drive a [blink(1)](https://blink1.thingm.com/) USB RGB LED from your Mac's
[cloudflared](https://github.com/cloudflare/cloudflared) tunnel activity.
Lets you see at a glance whether the tunnel is healthy, whether anyone has
an SSH session through it, whether a local Vite dev server is up, and when
HTTP requests are being served — without staring at logs or `lsof`.

## States

| Priority | State                       | Default color           | Detection                                                         |
|----------|-----------------------------|-------------------------|-------------------------------------------------------------------|
| 1        | Metrics endpoint reachable  | dim blue (`0,0,40`)     | `curl` to `METRICS_URL` succeeds                                  |
| 2        | Vite serving on `VITE_PORT` | teal-green (`0,200,120`)| `netstat` shows a `LISTEN` on `VITE_PORT`                         |
| 3        | SSH session through tunnel  | amber (`255,165,0`)     | loopback `ESTABLISHED` TCP pair touching `SSH_PORT`               |
| 3b       | SSH **and** Vite both up    | alternates 3 ↔ 2        | hardware fade between amber and teal-green every `ALTERNATE_S`s   |
| 4        | HTTP request just served    | bright green (`0,255,0`)| `cloudflared_tunnel_total_requests` counter advanced              |
| —        | Metrics unreachable         | dim red (`40,0,0`)      | `curl` failed                                                     |
| —        | No edge connections         | off                     | `cloudflared_tunnel_ha_connections` is `0`                        |
| —        | LAN up, no internet         | red blink every ~3s     | TCP probe to `PROBE_HOST:PROBE_PORT` fails                        |
| —        | No physical network         | red pulse every ~1s     | `scutil --nwi` has no `en*` (Wi-Fi/Ethernet) interface reachable  |

The HTTP flash overrides any base color, then the script returns to whatever
the base state is. Higher priority wins; the alternation only happens when SSH
and Vite are both active simultaneously.

## Requirements

- macOS (uses BSD `netstat` syntax)
- A blink(1) device
- [`blink1-tool`](https://github.com/todbot/blink1-tool) on `PATH`:
  ```sh
  brew install blink1
  ```
  (the formula is named `blink1`; it ships the `blink1-tool` CLI)
- `cloudflared` running with its Prometheus metrics endpoint enabled. Either:
  - add `metrics: localhost:20241` to `~/.cloudflared/config.yml`, or
  - launch with `cloudflared tunnel --metrics localhost:20241 run <name>`

  Verify with:
  ```sh
  curl -s http://localhost:20241/metrics | grep cloudflared_tunnel_total_requests
  ```

## Install & run

```sh
git clone https://github.com/tenorune/blink1-cloudflared.git
cd blink1-cloudflared
chmod +x blink1-cloudflared.sh
./blink1-cloudflared.sh
```

Ctrl-C turns the LED off and exits.

## Configuration

Copy `.env.example` to `.env` and edit. The script auto-loads `.env` from its
own directory on startup. Explicit environment variables still win, so this
also works:

```sh
COLOR_HEALTHY=0,0,255 ./blink1-cloudflared.sh
```

| Variable          | Default                              | Purpose                                          |
|-------------------|--------------------------------------|--------------------------------------------------|
| `METRICS_URL`     | `http://localhost:20241/metrics`     | cloudflared Prometheus endpoint                  |
| `POLL_INTERVAL`   | `1`                                  | Seconds between polls                            |
| `HTTP_FLASH_MS`   | `180`                                | Length of HTTP request flash (ms)                |
| `SSH_PORT`        | `22`                                 | Local sshd port                                  |
| `VITE_PORT`       | `4173`                               | Local port a Vite preview/dev server listens on  |
| `ALTERNATE_S`     | `3`                                  | Seconds per color when SSH + Vite both active    |
| `FADE_MS`         | `500`                                | blink(1) hardware fade duration during alternation|
| `PROBE_HOST`      | `1.1.1.1`                            | Host for the TCP reachability probe              |
| `PROBE_PORT`      | `443`                                | Port for the TCP reachability probe              |
| `PROBE_TIMEOUT`   | `1`                                  | TCP connect timeout (s) for the probe            |
| `PULSE_FADE_MS`   | `500`                                | Half-cycle fade duration for the "no route" pulse|
| `BLINK_ON_MS`     | `200`                                | Flash duration for the "no internet" blink       |
| `BLINK_OFF_MS`    | `2800`                               | Dark gap for the "no internet" blink             |
| `COLOR_HEALTHY`   | `0,0,40`                             | R,G,B (0–255)                                    |
| `COLOR_VITE`      | `0,200,120`                          | R,G,B                                            |
| `COLOR_SSH`       | `255,165,0`                          | R,G,B                                            |
| `COLOR_HTTP`      | `0,255,0`                            | R,G,B                                            |
| `COLOR_DOWN`      | `40,0,0`                             | R,G,B                                            |
| `BLINK1_TOOL`     | first `blink1-tool` on `PATH`        | Override the binary path                         |

## Notes

- **SSH detection** matches any ESTABLISHED loopback TCP connection touching
  `SSH_PORT`. cloudflared (running as root via launchd) opens a `127.0.0.1:22`
  connection to local sshd for each tunneled SSH session, which `netstat -an`
  sees without sudo. Remote SSH from your LAN doesn't trigger it because those
  connections aren't loopback.
- **HTTP** is detected per-request via the cloudflared metrics counter, so
  bursts of requests on a single keep-alive connection still produce visible
  flashes.
- **Vite detection** is a generic LISTEN check on `VITE_PORT` — anything
  bound to that port will trigger it. Set `VITE_PORT` to whatever your build
  actually serves on (Vite's `preview` defaults to 4173, `dev` to 5173).
- **Network detection** has three layers, checked in this order each poll:
  1. `scutil --nwi` — if no `en*` (Wi-Fi / Ethernet / USB-C) interface is
     reachable, the LED pulses red on a ~1s cycle. Virtual interfaces
     (`utun`, `ipsec`, `ppp`, ...) are deliberately ignored so an active
     VPN tunnel doesn't mask a Wi-Fi outage. `route get default` was
     tried first but it's unreliable on macOS — it stays "up" via VPN
     and stale entries after Wi-Fi drops.
  2. TCP connect to `PROBE_HOST:PROBE_PORT` (default `1.1.1.1:443`) with a
     `PROBE_TIMEOUT`-second timeout — if that fails, the LAN is up but the
     internet isn't, and the LED blinks red every ~3s.
  3. `cloudflared_tunnel_ha_connections` — if cloudflared is up but has no
     active connections to the Cloudflare edge, the LED turns off.

  This responds within ~1s of Wi-Fi going off, instead of waiting ~30s for
  cloudflared's own QUIC keep-alives to time out.
- If the LED looks dark, the dim defaults may be too dim for ambient light.
  Bump `COLOR_HEALTHY` and `COLOR_DOWN` higher in `.env`.

## License

MIT — see [LICENSE](LICENSE).
