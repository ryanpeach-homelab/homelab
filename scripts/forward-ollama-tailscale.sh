#!/usr/bin/env bash
#
# Forward `ollama serve` over Tailscale (tailnet-only, HTTPS) and persist it on startup.
#
# What this does:
#   1. Configures ollama to accept the hostname forwarded by `tailscale serve`
#      (otherwise ollama returns 403 for non-localhost Host headers).
#   2. Locks port 11434 down to the tailscale0 interface so it is NOT exposed
#      on your local LAN.
#
# The `tailscale serve` proxy (https://rgpeach10-mini.tail15cd2b.ts.net -> 127.0.0.1:11434)
# and the ollama systemd unit are both already boot-persistent, so no startup
# unit is needed.
#
# Run with: sudo ./forward-ollama-tailscale.sh   (it will re-exec itself with sudo)

set -euo pipefail

TS_IFACE="tailscale0"
OLLAMA_PORT="11434"
SERVE_URL="https://rgpeach10-mini.tail15cd2b.ts.net/"

# Re-exec with sudo if not already root.
if [[ $EUID -ne 0 ]]; then
  echo ">> Re-running with sudo..."
  exec sudo -- "$0" "$@"
fi

echo "==> 1. Making ollama accept the forwarded hostname (listen on all interfaces)"
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf <<EOF
[Service]
Environment="OLLAMA_HOST=0.0.0.0:${OLLAMA_PORT}"
EOF
systemctl daemon-reload
systemctl restart ollama
echo "    ollama restarted with OLLAMA_HOST=0.0.0.0:${OLLAMA_PORT}"

echo "==> 2. Restricting port ${OLLAMA_PORT} to the ${TS_IFACE} interface only"
# Order matters: the interface-specific allow is added first so it wins for
# tailnet traffic; the broad deny then blocks ${OLLAMA_PORT} everywhere else.
ufw allow in on "${TS_IFACE}" to any port "${OLLAMA_PORT}" proto tcp
ufw deny  in                  to any port "${OLLAMA_PORT}" proto tcp

echo
echo "==> Firewall status:"
ufw status verbose || true

echo
if ! ufw status | grep -q "Status: active"; then
  cat <<'WARN'
!! ufw is INACTIVE, so the rules above are not being enforced yet.
   To activate: sudo ufw enable
   WARNING: enabling ufw turns on default-deny for ALL incoming traffic and
   could block other inbound services on this machine. Make sure anything you
   rely on (e.g. SSH) is allowed before enabling.
WARN
fi

echo
echo "==> Verifying the tailscale endpoint (expect HTTP 200):"
sleep 1
code=$(curl -s -o /dev/null -w "%{http_code}" "${SERVE_URL}" || echo "ERR")
echo "    ${SERVE_URL} -> ${code}"
if [[ "${code}" == "200" ]]; then
  echo "    Success: ollama is reachable over Tailscale."
else
  echo "    Not 200 yet. If ufw is inactive the verify may still pass via loopback;"
  echo "    if it's 403, confirm the ollama restart picked up the override."
fi
