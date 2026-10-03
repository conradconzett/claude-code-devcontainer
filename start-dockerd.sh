#!/usr/bin/env bash
# Start the in-container Docker daemon (Docker-in-Docker) and wait until it is
# ready. Safe to run repeatedly: it is a no-op if a daemon is already up.
#
# This is invoked from devcontainer.json's "postStartCommand", so it runs on
# every container start. It relies on the container running under the Sysbox
# runtime, which lets an inner dockerd run without --privileged and keeps it
# isolated from the host's Docker. See setup.md.
set -euo pipefail

log() { echo "[start-dockerd] $*" >&2; }

# Already running? Nothing to do.
if docker info >/dev/null 2>&1; then
  log "Docker daemon already running."
  exit 0
fi

# Sanity check: refuse to start a second daemon over a bind-mounted HOST socket.
# If /var/run/docker.sock is a bind mount from the host, running dockerd here is
# both wrong and dangerous, so bail loudly instead.
if [ -S /var/run/docker.sock ] && grep -q ' /var/run/docker.sock ' /proc/mounts 2>/dev/null; then
  log "ERROR: /var/run/docker.sock looks bind-mounted from the host."
  log "Refusing to start an inner daemon. Use the Sysbox runtime instead of"
  log "mounting the host Docker socket (see setup.md)."
  exit 1
fi

LOG_FILE=/var/log/dockerd.log
log "Starting dockerd (logging to ${LOG_FILE})..."
sudo mkdir -p /var/lib/docker
# Launch detached; dockerd must outlive this script.
sudo sh -c "nohup dockerd >>'${LOG_FILE}' 2>&1 &"

# Wait up to ~30s for the socket to come up.
for _ in $(seq 1 30); do
  if docker info >/dev/null 2>&1; then
    log "Docker daemon is ready."
    exit 0
  fi
  sleep 1
done

log "ERROR: dockerd did not become ready in time. Last log lines:"
sudo tail -n 40 "${LOG_FILE}" >&2 || true
log "Common cause: the container is not running under the Sysbox runtime."
log "Verify the host has sysbox-runc and that runArgs has --runtime=sysbox-runc."
exit 1
