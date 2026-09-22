# Stremio

A self-hosted **Stremio streaming server** in Docker, exposed to your devices as
**trusted HTTPS over Tailscale** — so you can watch on
[web.stremio.com](https://web.stremio.com/) from any device on your tailnet,
without installing the Stremio app.

## Why HTTPS (and why Tailscale)

`web.stremio.com` is served over HTTPS, and browsers block an HTTPS page from
talking to a plain `http://` streaming server (mixed content). The "localhost is
fine" exception doesn't help here, because the device you watch on is a
*different* machine. So the streaming server must be reachable over **real,
browser-trusted HTTPS** — not a self-signed cert.

Tailscale does this for free: the `tailscale` sidecar joins your tailnet and runs
`tailscale serve`, which terminates HTTPS with a genuine Let's Encrypt
certificate for this node's MagicDNS name and reverse-proxies to the streaming
server. The `stremio-server` container shares the sidecar's network namespace, so
no ports are exposed publicly — access is purely tailnet-internal. (To let
friends outside your tailnet in, see [Sharing with friends outside your
tailnet](#sharing-with-friends-outside-your-tailnet).)

```
web.stremio.com  (open on any device on your tailnet)
        │  HTTPS — valid Let's Encrypt cert
        ▼
https://<hostname>.<your-tailnet>.ts.net     ← tailscale serve (sidecar)
        │  127.0.0.1:11470  (shared netns)
        ▼
stremio/server                               ← the streaming server
```

## Quick start

Requires [Docker](https://docs.docker.com/get-docker/) and a
[Tailscale](https://tailscale.com/) account (the free plan is enough).

```bash
git clone https://github.com/intisy/stremio-compose
cd stremio-compose
cp config.env.example config.env   # then fill in TS_AUTHKEY (step 2)
```

### 1. Enable HTTPS in your tailnet (one-time)
In the Tailscale admin console:
- **DNS** → enable **MagicDNS**.
- **DNS** → **HTTPS Certificates** → **Enable HTTPS**.

(Both are required for `tailscale serve` to obtain a cert.)

### 2. Get an auth key
Create one at <https://login.tailscale.com/admin/settings/keys> →
**Generate auth key** (reusable is convenient). Put it in `config.env`:

```env
TS_AUTHKEY=tskey-auth-xxxxxxxxxxxx
TS_HOSTNAME=stremio
```

`config.env` is gitignored. (A `config.env.example` is committed as a template.)

### 3. Start it

**Windows:** double-click `docker-compose.bat`, or from a terminal:
```powershell
.\docker-compose.ps1 up
```

**Linux / macOS:**
```bash
chmod +x docker-compose.sh
./docker-compose.sh up
```

On first run the sidecar authenticates to your tailnet and fetches its cert. The
launcher then prints the URL to use — something like
`https://stremio.<your-tailnet>.ts.net/`. Re-print it anytime with the `url`
command.

### 4. Point Stremio at it (on the watching device)
Open <https://web.stremio.com/> → **Settings** → **Streaming server** → set the
**Streaming server URL** to the `https://stremio.<your-tailnet>.ts.net/` value
from step 3. It should flip to **connected**.

## Commands
| Command | What it does |
|---------|--------------|
| `up` (default) | Start the stack and print the HTTPS URL |
| `down` | Stop and remove both containers |
| `restart` | Recreate the stack |
| `logs` | Follow logs (watch the tailnet node authenticate here) |
| `url` | Re-print the HTTPS URL for web.stremio.com |

e.g. `.\docker-compose.ps1 logs` or `./docker-compose.sh url`.

## Configuration — `config.env`
| Key | Purpose |
|-----|---------|
| `TS_AUTHKEY` | Tailscale auth key for the sidecar to join your tailnet. **Required.** |
| `TS_HOSTNAME` | MagicDNS name of the node → `https://<TS_HOSTNAME>.<tailnet>.ts.net/`. Default `stremio`. |
| `PUBLIC_ACCESS` | `true` serves over Tailscale Funnel, reachable from the open internet. Default `false` (tailnet-only). See below. |
| `WATCH_DEVICE_IP` | The watch device's tailnet IP (`100.x.y.z`). Documentation only — used in the optional ACL below. |

## Optional: lock access to just your watch device
By default any device on your tailnet can reach the server. To restrict it to
only your watch device, add a rule in your Tailscale **Access Controls** (replace
the IP with your `WATCH_DEVICE_IP`, and `stremio` with your `TS_HOSTNAME`):

```jsonc
{
  "acls": [
    // Only the watch device may reach the stremio node's HTTPS port.
    { "action": "accept", "src": ["100.x.y.z"], "dst": ["stremio:443"] }
  ]
}
```
(Adjust to fit the rest of your policy file; tag the node or use its MagicDNS
name as the `dst` if you prefer.)

## Sharing with friends outside your tailnet
Set `PUBLIC_ACCESS=true` in `config.env` and the sidecar switches from
`tailscale serve` to **[Tailscale Funnel](https://tailscale.com/kb/1223/funnel)**:
the same `https://<hostname>.<tailnet>.ts.net/` URL becomes reachable from the
open internet, so friends can paste it into web.stremio.com with no Tailscale
account and nothing to install.

> [!WARNING]
> **The public URL has no authentication.** `stremio/server` ships without any
> login, so anyone who has the link can drive torrent downloads through your IP
> and saturate your uplink. Treat the URL as a credential, and turn it off when
> you're not sharing. Funnel also relays traffic through Tailscale's
> infrastructure rather than peer-to-peer — it isn't built for sustained video
> and may be rate-limited, so expect worse throughput than tailnet-direct.

### One-time tailnet setup
Funnel needs the `funnel` node attribute in your **Access Controls** policy file
(this is separate from the HTTPS certs toggle in step 1):

```jsonc
{
  "nodeAttrs": [
    { "target": ["autogroup:member"], "attr": ["funnel"] }
  ]
}
```

### Turn it on
```env
PUBLIC_ACCESS=true
```
Then `.\docker-compose.ps1 restart` (or `./docker-compose.sh restart`). The
launcher prints the public URL and flags that it's internet-facing.

Setting it back to `false` and restarting returns the node to tailnet-only.
Anything other than `true`/`1`/`yes`/`on` counts as off, so a typo fails closed —
and running `docker compose up` directly, bypassing the launcher, always stays
private.

### Alternative: share the node instead
If your friends are willing to install Tailscale, **[node
sharing](https://tailscale.com/kb/1084/sharing)** is strictly better — direct
WireGuard at full speed, no public URL, revocable per person, and it doesn't
consume your tailnet's user seats. Admin console → **Machines** → the `stremio`
node → **⋯** → **Share**. Leave `PUBLIC_ACCESS=false` in that case.

## Layout
```
docker-compose.bat            Windows entry point (double-click) -> docker-compose.ps1
docker-compose.ps1 / .sh      launcher: up / down / restart / logs / url
docker-compose.yml            two services: tailscale sidecar + stremio/server
serve.json                    tailscale serve config (HTTPS:443 -> 127.0.0.1:11470)
funnel.json                   same, plus AllowFunnel (used when PUBLIC_ACCESS=true)
config.env                    auth key + hostname (gitignored)
config.env.example            template for config.env
data/                         tailscale node state + stremio cache (gitignored)
```

## Auth key lifecycle (90-day cap is fine)
The auth key is only used at **first join**; the node identity then persists in
`data/tailscale`, so the key is never read again.
- The launcher now only requires `TS_AUTHKEY` when the node hasn't joined yet —
  so once it's up you can **blank the key in `config.env`** and restarts still work.
- For a node that never needs re-auth, go to the admin console → **Machines** →
  the `stremio` node → **⋯** → **Disable key expiry**. (That's the real
  "unlimited" — the 90-day auth-key cap is irrelevant after first join.)

## Notes
- **Local debugging:** the host can reach the raw server at
  `http://127.0.0.1:11470` (bound to localhost only). Remote devices always use
  the tailnet HTTPS URL.
- **Updating:** `docker compose pull && .\docker-compose.ps1 restart` pulls newer
  `stremio/server` and `tailscale` images.
- The node identity persists in `data/tailscale`, so restarts reuse the same
  tailnet node instead of creating `stremio-1`, `stremio-2`, …
- **If the public URL doesn't resolve with `PUBLIC_ACCESS=true`:** check `logs`
  for a Funnel permission error — that means the `funnel` node attribute is
  missing from your Access Controls policy. Funnel is also limited to ports 443,
  8443 and 10000; this stack uses 443.
- **If the HTTPS URL returns 502:** the streaming server's listener isn't up —
  run the `restart` command (or `docker compose restart stremio-server`).
  Don't run `tailscale up --reset` while the stack is starting; it disrupts the
  shared network namespace before the server binds port 11470.

## License
MIT
