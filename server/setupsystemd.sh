#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EXECUTABLE_NAME="music-backup-server"
EXECUTABLE_PATH="${SCRIPT_DIR}/${EXECUTABLE_NAME}"
SERVICE_PATH="/etc/systemd/system/${EXECUTABLE_NAME}.service"

# Verifica i privilegi: se non è root, avvisa l'utente ed esce
if [[ "${EUID}" -ne 0 ]]; then
    echo "Errore: Questo script richiede i privilegi di amministratore." >&2
    echo "Per favore, eseguilo di nuovo usando: sudo $0" >&2
    exit 1
fi

# Rileva l'utente che ha invocato sudo (per non far girare il servizio come root)
RUN_USER="${SUDO_USER:-root}"

if ! command -v systemctl >/dev/null 2>&1; then
    echo "Errore: systemctl non e' disponibile. Questo sistema non sembra usare systemd." >&2
    exit 1
fi

if [[ ! -f "${EXECUTABLE_PATH}" ]]; then
    echo "Errore: eseguibile non trovato: ${EXECUTABLE_PATH}" >&2
    exit 1
fi

if [[ ! -x "${EXECUTABLE_PATH}" ]]; then
    echo "Rendo eseguibile ${EXECUTABLE_PATH}..."
    chmod +x "${EXECUTABLE_PATH}"
fi

echo "Creo il servizio systemd ${EXECUTABLE_NAME}.service..."
cat > "${SERVICE_PATH}" <<EOF
[Unit]
Description=Music Backup Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
WorkingDirectory=${SCRIPT_DIR}
ExecStart=${EXECUTABLE_PATH}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${EXECUTABLE_NAME}.service"
systemctl restart "${EXECUTABLE_NAME}.service" 2>/dev/null || systemctl start "${EXECUTABLE_NAME}.service"

echo "Servizio installato e avviato: ${EXECUTABLE_NAME}.service"
echo "Stato del servizio:"
systemctl --no-pager --full status "${EXECUTABLE_NAME}.service" || true