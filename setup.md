# Running this devcontainer on a Hetzner server (Tailscale + Sysbox + Docker-in-Docker)

This guide sets up a remote, headless development environment where **Claude Code
runs with `bypassPermissions` inside a container, and that container can itself
run Docker commands** — without ever exposing the host's Docker or filesystem to
Claude.

It is written for the following environment (yours):

| Property        | Value                                                            |
| --------------- | --------------------------------------------------------------- |
| Host            | Hetzner Cloud server, Ubuntu 22.04 / 24.04, 4 vCPU, 8 GB RAM     |
| Docker          | `docker-ce` already installed (rootful)                          |
| Access          | SSH as `root` via certificate/key (no password), over Tailscale  |
| Network         | Tailscale; Hetzner firewall: inbound UDP 41641 only, outbound TCP any + UDP 123 |
| Extra storage   | `/mnt/data_prod2` (treated as off-limits for the sandbox — see [§9](#9-the-mntdata_prod2-storage)) |

---

## 1. How it works and why it is safe

```
Hetzner host (Ubuntu, docker-ce "rootful")
│
├─ Tailscale  ── your only way in (SSH rides the tailnet)
│
└─ docker run --runtime=sysbox-runc  ← the Sysbox runtime
   │
   └─ devcontainer  (user: vscode, Claude runs here with bypassPermissions)
      │   • own Docker daemon (dockerd) started on boot
      │   • CPU/RAM/PID limits applied
      │
      └─ dockerd ──► your project's containers (nested, isolated)
```

Three isolation layers protect the host:

1. **Sysbox user namespace.** The container runs under `sysbox-runc`, so `root`
   *inside* the container maps to an **unprivileged** user on the host. Even
   `root` in the container — and therefore the `vscode` user's passwordless
   `sudo` — cannot touch host files or the host's Docker.
2. **No host Docker socket.** We never bind-mount `/var/run/docker.sock`. The
   container gets its *own* `dockerd`. The project's containers are started by
   that inner daemon and are invisible to the host. This is the key reason we use
   Sysbox instead of the "easy" socket mount, which would give Claude effective
   root on your host.
3. **Read-only config + resource limits.** `.devcontainer/`, `.git/config` and
   `.git/hooks` are mounted read-only (Claude can't rewrite its own container
   config or inject git hooks), and the container is capped at 3 CPUs / 6 GB RAM
   / 4096 PIDs so a runaway build can't take the host down.

### Your security assessment — my take

Your reasoning is sound. Specifically:

- **Tailscale-only, SSH by key/cert:** solid. SSH is not reachable from the
  public internet at all. **Root login is acceptable here** given you are the
  sole admin and auth is key-only — the real trust boundary is the container, not
  the host login user. Using a non-root `dev` user (below) is cleaner but
  optional.
- **`docker-ce` rootful, preinstalled:** correct and required — Sysbox needs
  rootful Docker (it does **not** work with rootless Docker or the Snap package).
- **Trust model:** correct that `.devcontainer`/`.git` read-only mounts stop
  Claude from editing its own container config or planting hooks.

Two things to watch, covered below: your **outbound-UDP-123-only firewall will
break DNS** unless you adjust it ([§2](#2-hetzner-cloud-firewall)), and
**`/mnt/data_prod2`** should stay out of the sandbox ([§9](#9-the-mntdata_prod2-storage)).

---

## 2. Hetzner Cloud Firewall

Create a Cloud Firewall in the Hetzner Console and attach it to the server.
Hetzner Cloud Firewalls are **stateful**, so replies to allowed connections are
permitted automatically.

### Inbound rules

| Protocol | Port  | Source            | Purpose                          |
| -------- | ----- | ----------------- | -------------------------------- |
| UDP      | 41641 | `0.0.0.0/0`, `::/0` | Tailscale direct (WireGuard)     |

Everything else inbound is dropped — including SSH 22. **That is intended:** you
reach SSH through Tailscale, not the public port.

### Outbound rules

| Protocol | Port        | Destination         | Purpose                         |
| -------- | ----------- | ------------------- | ------------------------------- |
| TCP      | `1-65535`   | `0.0.0.0/0`, `::/0` | HTTPS, git, Docker pulls, Tailscale DERP |
| UDP      | `123`       | `0.0.0.0/0`, `::/0` | NTP (clock → TLS cert validity) |

> ### ⚠️ DNS caveat — read this before you lock it down
>
> With outbound UDP restricted to **123 only**, **DNS over UDP (port 53) is
> blocked**. The glibc resolver does *not* automatically retry over TCP, so
> `apt`, `git clone`, `docker pull`, and Claude's API calls will all fail name
> resolution. This affects the host **and** every (nested) container.
>
> **Recommended fix — add one outbound rule:**
>
> | Protocol | Port | Destination         | Purpose |
> | -------- | ---- | ------------------- | ------- |
> | UDP      | `53` | `0.0.0.0/0`, `::/0` | DNS     |
>
> This barely changes your exposure: outbound **TCP is already fully open**, so
> anything that wanted to exfiltrate data or phone home can already do so over
> TCP/443. DNS-over-UDP is simply the thing that makes the box usable. (The
> upstream project already treats DNS as an open exfiltration channel.)
>
> **Strict alternative (keep UDP = 123 only):** configure **DNS-over-TLS** on the
> host so all DNS rides TCP 853. Edit `/etc/systemd/resolved.conf`:
> ```ini
> [Resolve]
> DNS=1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net
> DNSOverTLS=yes
> ```
> then `systemctl restart systemd-resolved`. Note this is **more fragile with
> nested Docker**: Docker's embedded resolver forwards to upstreams over UDP, and
> with systemd-resolved's `127.0.0.53` stub, containers fall back to `8.8.8.8:53`
> (UDP → blocked). You would then also have to set an explicit `"dns"` in the
> inner Docker daemon config pointing at a TCP/DoT-capable resolver. Unless you
> have a hard requirement for UDP-123-only, prefer the one-rule DNS fix above.

### What this means for Tailscale

Allowing **inbound** UDP 41641 permits direct peer connections *in*, but because
**outbound** UDP (other than 123) is blocked, the server can't complete the
outbound side of a direct UDP handshake. Tailscale will therefore connect via its
**DERP relay over TCP 443** (fully allowed). This works perfectly for SSH — it's
just slightly higher latency than a direct link.

If you later want direct (lower-latency) connections, also allow **outbound UDP
41641 and 3478** (STUN). Not required for this setup.

Finally: in the Hetzner Console, **enable Backups** and take a **Snapshot** once
everything works (see [§8](#8-finish-up)).

---

## 3. Install Tailscale (on the host, as root)

```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up
```

Follow the printed URL to authorize the machine in your tailnet. Then confirm:

```bash
tailscale status
tailscale ip -4            # the 100.x.y.z address you SSH to
tailscale netcheck         # expect "UDP: false" given the firewall → DERP relay (fine)
```

From now on you SSH in over the tailnet address:

```bash
# from your laptop — note: NO -A (see §7, do not forward your SSH agent)
ssh root@100.x.y.z
```

> Optional: `tailscale up --ssh` enables Tailscale SSH (auth via your tailnet
> identity, no SSH keys to manage). Fine to use instead of key-based SSH; not
> required.

---

## 4. Prepare the host

Run as `root`.

### 4a. Verify the Docker you have is compatible with Sysbox

```bash
lsb_release -ds                                   # Ubuntu 22.04 or 24.04
dpkg --print-architecture                         # amd64 (CX/CPX) or arm64 (CAX)
which docker                                       # must be /usr/bin/docker ...
snap list 2>/dev/null | grep -i docker || echo "no snap docker (good)"   # ... and NOT snap
docker info --format '{{.SecurityOptions}}'       # must NOT contain "rootless"
docker version --format '{{.Server.Version}}'
```

If Docker came from Snap or runs rootless, Sysbox won't work — reinstall
`docker-ce` from Docker's apt repo first. (Your server has `docker-ce`
preinstalled rootful, so this should already pass.)

### 4b. Add swap (8 GB RAM is tight once Claude runs Docker builds)

Hetzner images ship without swap. A 4 GB swapfile gives headroom:

```bash
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 4G /swapfile && chmod 600 /swapfile
  mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
free -h
```

### 4c. (Recommended) Create a non-root `dev` user to run `devc`

Keeps projects, tokens and `.gitconfig` out of root's home. The container remains
the real boundary, so this is hygiene, not a hard security control.

```bash
adduser --disabled-password --gecos "" dev
usermod -aG docker dev          # docker group ≈ root on host; only trusted users
# switch to it whenever you work:
su - dev
# (re-login / re-su so the docker group takes effect, then `docker run --rm hello-world`)
```

> The rest of this guide can be run either as `root` or as `dev`. If you use
> `dev`, run everything from [§6](#6-install-the-devc-tooling-as-the-working-user) on as `dev`.

---

## 5. Install Sysbox (on the host, as root)

Sysbox provides the `sysbox-runc` runtime that makes safe Docker-in-Docker
possible.

> **Ubuntu 24.04 needs Sysbox ≥ v0.7.1.** That release added support for Ubuntu
> 24.04 / kernel 6.8+. Use the latest release.

```bash
# The installer restarts Docker and requires NO running containers:
docker ps                    # must be empty; stop anything listed first

apt-get update && apt-get install -y jq

# Download the latest sysbox-ce .deb for your architecture from:
#   https://github.com/nestybox/sysbox/releases
# amd64 example (check the releases page for the current version/URL):
ARCH=$(dpkg --print-architecture)   # amd64 or arm64
VER=0.7.1
wget "https://downloads.nestybox.com/sysbox/releases/v${VER}/sysbox-ce_${VER}-0.linux_${ARCH}.deb" \
  -O /tmp/sysbox-ce.deb
# (If that URL 404s, grab the exact asset link from the GitHub releases page.)

apt-get install -y /tmp/sysbox-ce.deb
```

Verify:

```bash
docker info 2>/dev/null | grep -iA3 runtimes          # should list sysbox-runc
docker run --rm --runtime=sysbox-runc alpine echo ok  # should print: ok
```

If `sysbox-runc` is missing or the test fails, see
[Troubleshooting](#troubleshooting).

---

## 6. Install the `devc` tooling (as the working user)

Do this as `dev` (recommended) or `root`.

```bash
# Node.js (via fnm, no root needed) — devcontainers CLI needs Node
curl -fsSL https://fnm.vercel.app/install | bash
source ~/.bashrc 2>/dev/null || source ~/.profile
fnm install 22 && fnm default 22

npm install -g @devcontainers/cli

# Clone YOUR fork (this repo) and install the devc helper
git clone https://github.com/conradconzett/claude-code-devcontainer ~/.claude-devcontainer
~/.claude-devcontainer/install.sh self-install
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
export PATH="$HOME/.local/bin:$PATH"

devc help     # sanity check
```

> Using your own fork means your Sysbox/Docker customizations (already committed
> in this repo) survive `devc update`. To pull later changes into the tooling:
> `devc update`.

---

## 7. Authenticate Claude (headless)

Two options — pick one.

**A. One-time OAuth token (best for headless servers).** On your laptop:

```bash
claude setup-token          # prints sk-ant-oat01-...
```

On the server, store it for the working user (file perms `600`) and rebuild:

```bash
echo 'export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...' >> ~/.bashrc
chmod 600 ~/.bashrc
source ~/.bashrc
```

The token is forwarded into the container; `post_install.py` runs a one-shot
handshake so `claude` starts without the login wizard.

**B. Interactive login.** Skip the token and just run `claude` inside the
container later — open the printed URL in your laptop browser and paste the code
back. Auth persists in a volume across rebuilds.

> ### SSH agent & GitHub — do not hand Claude your keys
> - **Never `ssh -A` to this server.** Agent forwarding would let container code
>   authenticate as you to anything your key can reach.
> - Inside the container, use `gh auth login` with a **fine-grained** GitHub
>   token scoped to only the repos you need, and enable **branch protection on
>   `main`**.
> - Keep production secrets out of `/workspace`. Use `.env` files with **test**
>   values only.

---

## 8. Run a project

```bash
tmux new -s claude                       # survives SSH drops
mkdir -p ~/projects/myproject && cd ~/projects/myproject
git init                                 # the template mounts .git/config & .git/hooks
devc .                                    # install template + build + start container
devc shell                                # open a zsh shell inside
```

Inside the container, confirm Docker-in-Docker works, then start Claude:

```bash
docker run --rm hello-world              # Docker inside the container works
docker compose version
git clone https://github.com/you/your-docker-project.git && cd your-docker-project
claude                                    # bypassPermissions is preconfigured
```

Everyday commands:

```bash
devc shell       # shell into the container
devc exec CMD    # run one command inside
devc rebuild     # rebuild image (auth/history/docker-image volumes survive)
devc upgrade     # update Claude Code in the container
devc destroy     # remove container + volumes + image for this project (use this, not `docker rm`)
```

### Finish up

- On GitHub, set **branch protection** on `main`.
- Confirm you connect **without** `ssh -A`.
- Take a **Hetzner Snapshot** — your "known-good" state to roll back to.

---

## 9. The `/mnt/data_prod2` storage

The `prod` in the name is a flag. Two cases:

- **It holds production data / a prod service runs on this box.** Then this is
  not an ideal dev host: installing Sysbox restarts Docker (downtime), and
  Claude's builds compete with prod for 8 GB RAM. Consider a separate small
  Hetzner server for development (a few € / month). If you keep everything on one
  box: **never** `devc mount /mnt/data_prod2 ...` into the container, and don't
  put projects there.
- **It's just extra disk.** You may point the *inner* Docker's data-root or your
  project checkouts at it for space, but still treat it as untrusted-by-Claude:
  do not bind-mount it read-write into the sandbox. If you only need the *host*
  Docker image store on the big disk, set `data-root` in `/etc/docker/daemon.json`
  on the host (not inside the container) and restart Docker **before** installing
  Sysbox.

When in doubt, keep it unmounted. The container never needs it.

---

## Troubleshooting

**`dockerd` won't start inside the container.** Check the log:
```bash
devc exec cat /var/log/dockerd.log
```
The most common cause is the container not running under Sysbox. Verify on the
host:
```bash
docker info 2>/dev/null | grep -i sysbox-runc          # runtime present?
docker inspect <container> --format '{{.HostConfig.Runtime}}'   # should be sysbox-runc
```
Confirm `.devcontainer/devcontainer.json` has `"--runtime=sysbox-runc"` in
`runArgs` (it does in this repo). If you edited `runArgs`, re-run `devc rebuild`.

**`sysbox-runc` not listed by `docker info`.** The Sysbox install didn't complete
(often because containers were running during install). Stop all containers and
reinstall the `.deb`; then `systemctl status sysbox`.

**DNS failures (`could not resolve host`), `apt`/`git`/`docker pull` hang.** Your
outbound firewall is blocking UDP 53. Apply the DNS fix in
[§2](#2-hetzner-cloud-firewall). Quick tests:
```bash
getent hosts github.com        # on host
devc exec getent hosts github.com   # inside container
```

**Tailscale only reachable via relay / `netcheck` shows `UDP: false`.** Expected
with this firewall (outbound UDP limited to 123). SSH still works over DERP/TCP.
To get direct connections, allow outbound UDP 41641 + 3478.

**`devc .` errors about a missing `.git` mount.** Run `git init` in the project
first (the template mounts `.git/config` and `.git/hooks`). The tooling strips
those mounts automatically for non-repos, but a repo is the intended setup.

**Permission errors on `/var/lib/docker` after first boot.** Sysbox ID-maps that
volume on first use; it must start empty. If you created it by hand or reused a
dirty volume, `devc destroy` and let `devc .` recreate it.

**`claude` shows the onboarding wizard despite a token.** Ensure
`CLAUDE_CODE_OAUTH_TOKEN` is exported in the working user's shell *before*
`devc rebuild`, then rebuild.

---

## What changed in this fork (vs. upstream Trail of Bits)

- `Dockerfile`: installs Docker Engine (client + daemon) and adds `vscode` to the
  `docker` group; installs the `start-dockerd` helper.
- `devcontainer.json`: `--runtime=sysbox-runc`, CPU/RAM/PID limits, a persistent
  `/var/lib/docker` volume, and a `postStartCommand` that starts the inner
  `dockerd`.
- `start-dockerd.sh`: starts the in-container Docker daemon and waits until it's
  ready (and refuses to run over a bind-mounted host socket).
- `install.sh`: `devc template` now also ships `start-dockerd.sh`, and treats the
  Docker volume as a default mount.
- `.gitattributes`: forces LF on scripts so Windows edits can't break the shebang.

These are additive; the laptop/Docker-Desktop workflow in `README.md` still works
(Sysbox is only required on the host that runs the container — if a host lacks
`sysbox-runc`, remove `--runtime=sysbox-runc` from `runArgs`, and you lose the
in-container Docker safety and must not mount the host socket).
