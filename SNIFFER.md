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

> **Preferred path:** use the upgrade script (works for first install *and*
> later upgrades). See **[Upgrade custom-built meshtasticd](#upgrade-custom-built-meshtasticd)**
> below. The manual steps in this section remain as a low-level reference.

### Manual first install (reference)

#### 1. Find the latest release tag

Visit **https://github.com/meshbehave/meshtastic-firmware/releases** and note
the tag name of the most recent release (e.g. `v2.7.26-sniffer-20260718`).

#### 2. Download

```bash
# Set the tag you want to install
TAG=v2.7.26-sniffer-20260718   # replace with latest from releases page

# armhf (32-bit Raspbian)
curl -fL "https://github.com/meshbehave/meshtastic-firmware/releases/download/${TAG}/meshtasticd-armhf" \
  -o /tmp/meshtasticd-sniffer
chmod +x /tmp/meshtasticd-sniffer

# arm64 (64-bit Raspberry Pi OS / Ubuntu)
curl -fL "https://github.com/meshbehave/meshtastic-firmware/releases/download/${TAG}/meshtasticd-arm64" \
  -o /tmp/meshtasticd-sniffer
chmod +x /tmp/meshtasticd-sniffer

# verify
file /tmp/meshtasticd-sniffer
/tmp/meshtasticd-sniffer --version
```

#### 3. Install (safe, survives apt upgrades)

`dpkg-divert` tells the package manager to put any future official binary at
`.official` instead of overwriting our patched one:

```bash
sudo systemctl stop meshtasticd
sudo cp /usr/bin/meshtasticd /usr/bin/meshtasticd.official   # backup stock binary
sudo cp /tmp/meshtasticd-sniffer /usr/bin/meshtasticd        # install
sudo dpkg-divert --add --no-rename \
    --divert /usr/bin/meshtasticd.official /usr/bin/meshtasticd
sudo systemctl start meshtasticd
```

After this, `apt upgrade meshtasticd` will update `.official` but will never
touch `/usr/bin/meshtasticd`.

### MOTD reminder (humans + AI agents)

Install a login banner that points at **this guide** (always the
`traceroute-sniffer` branch HEAD on GitHub). Agents SSHing into the machine
should read the MOTD, open the guide, and fetch the **latest** upgrade script
from the same branch (do **not** keep a long-lived local copy of the script as
the driver — it goes stale).

```bash
sudo tee /etc/update-motd.d/99-meshtasticd > /dev/null << 'EOF'
#!/bin/sh
BINARY=/usr/bin/meshtasticd
VERSION=$("$BINARY" --version 2>&1 | head -1)
DIVERTED=$(dpkg-divert --list "$BINARY" 2>/dev/null)
DOC_URL="https://github.com/meshbehave/meshtastic-firmware/blob/traceroute-sniffer/SNIFFER.md"
UPGRADE_ANCHOR="${DOC_URL}#upgrade-custom-built-meshtasticd"
SCRIPT_URL="https://raw.githubusercontent.com/meshbehave/meshtastic-firmware/traceroute-sniffer/bin/upgrade-meshtasticd-sniffer.sh"

if [ -n "$DIVERTED" ]; then
    echo "⚠  meshtasticd: PATCHED (traceroute-sniffer) — $VERSION"
else
    echo "   meshtasticd: official — $VERSION"
fi
echo "   Docs (read before changing the daemon):"
echo "     $DOC_URL"
echo "   Upgrade guide:"
echo "     $UPGRADE_ANCHOR"
echo "   Upgrade script (always re-fetch from branch HEAD; do not cache forever):"
echo "     $SCRIPT_URL"
echo "   If docs/host layout disagree: STOP — do not improvise stop/start/divert."
EOF
sudo chmod +x /etc/update-motd.d/99-meshtasticd
```

Re-run the `tee` block after pulling MOTD text changes from this file so
deployed hosts pick up new wording.

---

## Upgrade custom-built meshtasticd

This section is the **source of truth** for upgrading a host that already runs
(or will run) the traceroute-sniffer binary. It is written for **humans and AI
agents** that arrive over SSH.

### Design rules

| Rule | Why |
|------|-----|
| Always re-fetch `upgrade-meshtasticd-sniffer.sh` from **branch HEAD** | Avoids stale local helpers that diverge from the repo |
| Always re-read **this** `SNIFFER.md` from branch HEAD | Same reason for docs |
| Pin the **binary** to a **release tag** (`v*-sniffer-*`) | Binaries are immutable release assets; branch tip is not a binary channel |
| Do not write config or NodeDB | Upgrade replaces `/usr/bin/meshtasticd` only |
| Prefer the script over hand-rolled `curl` + `cp` | Encodes precheck, checksum, backup, health gate, rollback |

**Canonical URLs (branch `traceroute-sniffer` HEAD):**

```text
Docs:   https://github.com/meshbehave/meshtastic-firmware/blob/traceroute-sniffer/SNIFFER.md
Script: https://raw.githubusercontent.com/meshbehave/meshtastic-firmware/traceroute-sniffer/bin/upgrade-meshtasticd-sniffer.sh
Releases: https://github.com/meshbehave/meshtastic-firmware/releases
```

There is **no** supported “install script once under `/usr/local/sbin` and
forget it” path. Every upgrade session should start by downloading the script
again from GitHub.

### What the script does

`bin/upgrade-meshtasticd-sniffer.sh`:

1. **Precheck** — arch (`armhf` / `arm64`), disk, systemd unit, current version,
   `dpkg-divert` state, presence of `/etc/meshtasticd` & `/var/lib/meshtasticd`
2. **Resolve tag** — `--tag` or GitHub `releases/latest`
3. **Download** matching asset (`meshtasticd-armhf` or `meshtasticd-arm64`)
4. **Verify** — size, sha256 when the release API provides `digest`, `file` ELF
   class, `ldd` (fail on `not found`), smoke `--version`
5. **Backup** — copy live binary to
   `/var/backups/meshtasticd-sniffer/meshtasticd.prev-<UTC>` (+ `meshtasticd.prev` symlink)
6. **Deploy** — `systemctl stop` → `install` binary → ensure `dpkg-divert` →
   `systemctl start`
7. **Sanity** — unit active within timeout; print version/status
8. **Auto-rollback** — if health check fails, restore backup and fail non-zero

It does **not** modify `/etc/meshtasticd` or `/var/lib/meshtasticd`.

### Flags

| Flag | Meaning |
|------|---------|
| `--tag TAG` | Release tag to install (recommended) |
| `--dry-run` | Precheck + download + verify only |
| `--yes` | Required to actually stop/install/start |
| `--rollback` | Restore newest backup under `/var/backups/meshtasticd-sniffer` |
| `--force-install` | Allow first install when divert is missing |
| `--skip-ldd` | Do not fail on missing shared libs (avoid unless you know why) |
| `--binary-path PATH` | Default `/usr/bin/meshtasticd` |
| `--service NAME` | Default `meshtasticd` |

### Procedure for humans

Run **on the device** (or `ssh host 'bash -s' < …` carefully).

```bash
# 1) Fetch LATEST script from branch HEAD (every time)
SCRIPT_URL="https://raw.githubusercontent.com/meshbehave/meshtastic-firmware/traceroute-sniffer/bin/upgrade-meshtasticd-sniffer.sh"
curl -fsSL "$SCRIPT_URL" -o /tmp/upgrade-meshtasticd-sniffer.sh

# 2) Optional: skim this guide from HEAD as well
# curl -fsSL "https://raw.githubusercontent.com/meshbehave/meshtastic-firmware/traceroute-sniffer/SNIFFER.md" | less

# 3) Dry-run (no service impact)
bash /tmp/upgrade-meshtasticd-sniffer.sh --dry-run
# or pin a known release:
bash /tmp/upgrade-meshtasticd-sniffer.sh --tag v2.7.26-sniffer-20260718 --dry-run

# 4) Apply (short mesh downtime while the unit restarts)
bash /tmp/upgrade-meshtasticd-sniffer.sh --tag v2.7.26-sniffer-20260718 --yes

# First-time install on a stock meshtasticd package (no divert yet):
# bash /tmp/upgrade-meshtasticd-sniffer.sh --tag v2.7.26-sniffer-20260718 --force-install --yes
```

### Procedure for AI agents (SSH)

When asked to upgrade sniffer `meshtasticd` on a host:

1. **SSH** into the host (use the operator’s jump host / keys as configured).
2. **Read discovery hints** — MOTD (`/etc/update-motd.d/99-meshtasticd` or
   login banner) and/or fetch this file:
   `https://raw.githubusercontent.com/meshbehave/meshtastic-firmware/traceroute-sniffer/SNIFFER.md`
3. **Fetch the upgrade script from branch HEAD** (never assume a local copy is
   current):
   `https://raw.githubusercontent.com/meshbehave/meshtastic-firmware/traceroute-sniffer/bin/upgrade-meshtasticd-sniffer.sh`
4. Run **`--dry-run`** first; paste/summarize precheck output for the operator
   if anything fails (arch, divert, ldd, disk).
5. Agree on a **release tag** (prefer an explicit `v*-sniffer-*` over floating
   `latest` on production nodes).
6. Apply with **`--yes`** (and **`--force-install`** only for true first install).
7. Confirm `systemctl is-active meshtasticd`, new `--version`, and recent
   `journalctl -u meshtasticd` for errors.
8. On failure: run
   `bash /tmp/upgrade-meshtasticd-sniffer.sh --rollback --yes`
   and report.

**Stop and escalate** if:

- host arch is not `armhf` / `arm64`
- `dpkg-divert` is missing and the operator did not approve `--force-install`
- `ldd` reports missing libraries
- the machine layout is not the documented paths and the operator did not
  override `--binary-path` / `--service`

**Do not** invent alternate install paths, wipe `/var/lib/meshtasticd`, or
`dpkg-divert --remove` during a normal upgrade.

### Rollback

```bash
# Re-fetch script (branch HEAD), then:
bash /tmp/upgrade-meshtasticd-sniffer.sh --rollback --yes
```

Backups live under `/var/backups/meshtasticd-sniffer/` by default.

### Reverting to official (stock package binary)

This undoes the sniffer patch entirely (not the same as `--rollback` to a
previous sniffer build):

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
| `debug_armhf.yml` | `workflow_dispatch` | Manual armhf build via arm64 jump host + SSH |

**Runners:**
- `arm64` — `ubuntu-24.04-arm` (GitHub-hosted)
- `armhf` — self-hosted `[self-hosted, Linux, ARM64]` jump host SSHes to an armhf build machine (`ARMHF_BUILD_HOST` repo variable); see `bin/ci/build-meshtasticd-armhf-remote.sh`

Builds are published automatically every Monday if upstream has advanced.
Each build gets a unique dated tag (`v<upstream-version>-sniffer-<YYYYMMDD>`)
so every release is preserved and any build can be rolled back to.

**Device upgrades** use `bin/upgrade-meshtasticd-sniffer.sh` (always fetched from
this branch HEAD) — not the CI runners.
