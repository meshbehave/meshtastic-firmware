# traceroute-sniffer patch

This branch (`traceroute-sniffer`) is a minimal patch on top of the upstream
[meshtastic/firmware](https://github.com/meshtastic/firmware) `develop` branch.

It makes `meshtasticd` forward **all traceroute packets passing through your
node** to any connected client (phone app, Python script, etc.), not just ones
addressed to you. One ~5-line change.

---

## What changed

**`src/modules/TraceRouteModule.cpp`** — `alterReceivedProtobuf()`:

```cpp
// Forward passing traceroute packets to connected client (sniffer mode).
// isToUs() is false when this packet is routed through us, not to us.
if (!isToUs(&p)) {
    meshtastic_MeshPacket *copy = packetPool.allocCopy(p);
    if (copy)
        service->sendToPhone(copy);
}
```

`isToUs()` returns false when a packet is merely routed *through* us on its
way somewhere else. Without this patch those packets are silently forwarded
at the radio level and never surfaced to the API. With it, a copy is sent to
the phone API so any connected client can observe them.

---

## Pre-built binaries

Grab the latest release binary for your architecture from the releases page:

**https://github.com/meshbehave/meshtastic-firmware/releases**

Tags follow the format `v<upstream-version>-sniffer-<YYYYMMDD>` (e.g.
`v2.7.20-sniffer-20260221`). Pick the most recent tag for the latest build.

| File | Target |
|------|--------|
| `meshtasticd-arm64` | RPi 3/4/5 — 64-bit Raspberry Pi OS / Ubuntu arm64 |
| `meshtasticd-armhf` | RPi 2/3/4 — Raspbian / 32-bit Debian armhf |

---

## Installing on Raspberry Pi

### 1. Find the latest release tag

Visit **https://github.com/meshbehave/meshtastic-firmware/releases** and note
the tag name of the most recent release (e.g. `v2.7.20-sniffer-20260221`).

### 2. Download

```bash
# Set the tag you want to install
TAG=v2.7.20-sniffer-20260221   # replace with latest from releases page

# armhf (32-bit Raspbian)
curl -L "https://github.com/meshbehave/meshtastic-firmware/releases/download/${TAG}/meshtasticd-armhf" \
  -o /tmp/meshtasticd-sniffer
chmod +x /tmp/meshtasticd-sniffer

# arm64 (64-bit Raspberry Pi OS / Ubuntu)
curl -L "https://github.com/meshbehave/meshtastic-firmware/releases/download/${TAG}/meshtasticd-arm64" \
  -o /tmp/meshtasticd-sniffer
chmod +x /tmp/meshtasticd-sniffer

# verify
/tmp/meshtasticd-sniffer --version
```

### 3. Install (safe, survives apt upgrades)

`dpkg-divert` tells the package manager to put any future official binary at
`.official` instead of overwriting our patched one:

```bash
sudo systemctl stop meshtasticd
sudo cp /usr/bin/meshtasticd /usr/bin/meshtasticd.official   # backup
sudo cp /tmp/meshtasticd-sniffer /usr/bin/meshtasticd        # install
sudo dpkg-divert --add --no-rename \
    --divert /usr/bin/meshtasticd.official /usr/bin/meshtasticd
sudo systemctl start meshtasticd
```

After this, `apt upgrade meshtasticd` will update `.official` but will never
touch `/usr/bin/meshtasticd`.

### 4. Optional — MOTD reminder

```bash
sudo tee /etc/update-motd.d/99-meshtasticd > /dev/null << 'EOF'
#!/bin/sh
BINARY=/usr/bin/meshtasticd
VERSION=$("$BINARY" --version 2>&1 | head -1)
DIVERTED=$(dpkg-divert --list "$BINARY" 2>/dev/null)

if [ -n "$DIVERTED" ]; then
    echo "⚠  meshtasticd: PATCHED (traceroute-sniffer) — $VERSION"
    echo "   Switching between patched and official:"
    echo "   https://github.com/meshbehave/meshtastic-firmware/blob/traceroute-sniffer/SNIFFER.md"
else
    echo "   meshtasticd: official — $VERSION"
fi
EOF
sudo chmod +x /etc/update-motd.d/99-meshtasticd
```

---

## Reverting to official

```bash
sudo systemctl stop meshtasticd
sudo rm /usr/bin/meshtasticd
sudo dpkg-divert --remove /usr/bin/meshtasticd
sudo mv /usr/bin/meshtasticd.official /usr/bin/meshtasticd
sudo systemctl start meshtasticd
```

---

## Using the sniffer

Connect a Python client and subscribe to the `meshtastic.receive.traceroute`
topic:

```python
import meshtastic.tcp_interface
from pubsub import pub

def on_traceroute(packet, interface):
    print(packet)

pub.subscribe(on_traceroute, 'meshtastic.receive.traceroute')
iface = meshtastic.tcp_interface.TCPInterface('localhost')

import time
while True:
    time.sleep(1)
```

---

## Maintenance — setting up the sync workflow

The `sync_upstream.yml` workflow pushes branches and tags on your behalf.
GitHub intentionally prevents `GITHUB_TOKEN` (the default) from triggering
other workflows when it pushes — so a Personal Access Token (PAT) is required.
Without it the tag gets pushed but `build_sniffers.yml` never runs.

### 1. Create a fine-grained PAT

1. Go to **GitHub → Settings → Developer settings → Personal access tokens →
   Fine-grained tokens**:
   https://github.com/settings/personal-access-tokens/new

2. Fill in the form:

   | Field | Value |
   |---|---|
   | **Token name** | `meshtastic-sniffer-sync` (or any name you'll recognise) |
   | **Expiration** | Set to your preference — note the date so you can renew before it expires |
   | **Resource owner** | `meshbehave` (the org) |
   | **Repository access** | Only select repositories → `meshbehave/meshtastic-firmware` |

3. Under **Permissions → Repository permissions**, set:

   | Permission | Access |
   |---|---|
   | **Contents** | Read and write |

   Everything else can stay at *No access*.

4. Click **Generate token** and **copy the token immediately** — GitHub will
   not show it again.

### 2. Add the token as a repository secret

1. Go to:
   https://github.com/meshbehave/meshtastic-firmware/settings/secrets/actions

2. Click **New repository secret**.

3. Set:
   - **Name:** `GH_PAT`
   - **Secret:** paste the token you copied

4. Click **Add secret**.

### 3. Verify

Manually trigger `sync_upstream.yml` from the Actions tab. After it completes,
`build_sniffers.yml` should start automatically within a few seconds, triggered
by the new dated tag.

### Renewing the PAT

When the PAT expires, `sync_upstream.yml` will fail at the push step. Repeat
steps 1–2 above (generate a new token, update the `GH_PAT` secret). No changes
to the workflow files are needed.

---

## CI / building from source

Two workflows under `.github/workflows/`:

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `build_sniffers.yml` | push `v*-sniffer-*` tag | Builds arm64 + armhf, publishes GitHub Release |
| `sync_upstream.yml` | every Monday 03:00 UTC | Syncs upstream develop, rebases this branch, pushes a new dated tag |
| `debug_armhf.yml` | `workflow_dispatch` | Manual build on self-hosted armhf runner |

**Runners:**
- `arm64` — `ubuntu-24.04-arm` (GitHub-hosted)
- `armhf` — self-hosted `[rpi-armhf]` runner (Raspbian Trixie 32-bit)

Builds are published automatically every Monday if upstream has advanced.
Each build gets a unique dated tag (`v<upstream-version>-sniffer-<YYYYMMDD>`)
so every release is preserved and any build can be rolled back to.
