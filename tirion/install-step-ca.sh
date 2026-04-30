#!/usr/bin/env bash
# Installs and bootstraps step-ca on tirion.
# Run from thorondor: ssh tirion 'bash -s' < tirion/install-step-ca.sh
# Idempotent — safe to re-run.

set -euo pipefail

if [[ "$(hostname)" != "tirion" ]]; then
    echo "ERROR: this script is for tirion; got hostname '$(hostname)'"
    exit 1
fi

# --- Config ---
CA_NAME="vingilot.internal"
CA_DNS_NAMES="tirion,tirion.vingilot.internal,ca.vingilot.internal"
CA_LISTEN_ADDRESS=":443"
ACME_PROVISIONER_NAME="acme"
JWK_PROVISIONER_NAME="admin"
STEPPATH="/etc/step-ca"

# --- Add Smallstep apt repo (idempotent) ---
if [[ ! -f /etc/apt/sources.list.d/smallstep.sources ]]; then
    echo "Adding Smallstep apt repo..."
    apt-get update
    apt-get install -y --no-install-recommends curl gpg ca-certificates
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://packages.smallstep.com/keys/apt/repo-signing-key.gpg \
        -o /etc/apt/keyrings/smallstep.asc

    cat > /etc/apt/sources.list.d/smallstep.sources <<EOF
Types: deb
URIs: https://packages.smallstep.com/stable/debian
Suites: debs
Components: main
Signed-By: /etc/apt/keyrings/smallstep.asc
EOF
    apt-get update
fi

# --- Install step-cli and step-ca ---
echo "Installing step-cli and step-ca..."
apt-get install -y step-cli step-ca

echo "Versions installed:"
step --version
step-ca --version

# --- Create the 'step' user (apt package doesn't create it) ---
if ! id step >/dev/null 2>&1; then
    echo "Creating 'step' system user..."
    useradd --system --home-dir "${STEPPATH}" --shell /usr/sbin/nologin step
fi

# --- Bootstrap the CA (idempotent) ---
mkdir -p "${STEPPATH}"
chown step:step "${STEPPATH}"

if [[ -f "${STEPPATH}/config/ca.json" ]]; then
    echo "step-ca already initialized at ${STEPPATH} — skipping init."
else
    echo "Initializing CA..."

    # Generate a random password and save it
    PASSWORD_FILE="${STEPPATH}/password"
    openssl rand -base64 32 > "${PASSWORD_FILE}"
    chmod 600 "${PASSWORD_FILE}"
    chown step:step "${PASSWORD_FILE}"

    # Run init as the step user
    sudo -u step env STEPPATH="${STEPPATH}" step ca init \
        --name="${CA_NAME}" \
        --dns="${CA_DNS_NAMES}" \
        --address="${CA_LISTEN_ADDRESS}" \
        --provisioner="${JWK_PROVISIONER_NAME}" \
        --password-file="${PASSWORD_FILE}" \
        --provisioner-password-file="${PASSWORD_FILE}"

    echo "✓ CA initialized."
fi

# --- Add ACME provisioner (idempotent) ---
if ! sudo -u step env STEPPATH="${STEPPATH}" step ca provisioner list 2>/dev/null \
        | grep -q "\"name\": \"${ACME_PROVISIONER_NAME}\""; then
    echo "Adding ACME provisioner '${ACME_PROVISIONER_NAME}'..."
    sudo -u step env STEPPATH="${STEPPATH}" step ca provisioner add \
        "${ACME_PROVISIONER_NAME}" --type ACME
else
    echo "ACME provisioner '${ACME_PROVISIONER_NAME}' already exists — skipping."
fi

# --- Install systemd unit ---
# Apt package doesn't ship one, so we write our own.
# Allows step-ca to bind to :443 without running as root.
if [[ ! -f /etc/systemd/system/step-ca.service ]]; then
    echo "Installing systemd unit..."
    cat > /etc/systemd/system/step-ca.service <<EOF
[Unit]
Description=step-ca service
Documentation=https://smallstep.com/docs/step-ca
Documentation=https://smallstep.com/docs/step-ca/certificate-authority-server-production
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=30
StartLimitBurst=3
ConditionFileNotEmpty=${STEPPATH}/config/ca.json
ConditionFileNotEmpty=${STEPPATH}/password

[Service]
Type=simple
User=step
Group=step
Environment=STEPPATH=${STEPPATH}
WorkingDirectory=${STEPPATH}
ExecStart=/usr/bin/step-ca config/ca.json --password-file=password
ExecReload=/bin/kill --signal HUP \$MAINPID
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
StartLimitInterval=30
StartLimitBurst=3

# Hardening
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=65536
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectHostname=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictRealtime=true
RestrictSUIDSGID=true
RemoveIPC=true
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
fi

systemctl enable --now step-ca

sleep 2

if systemctl is-active --quiet step-ca; then
    echo "✓ step-ca is running."
else
    echo "✗ step-ca failed to start. Investigate with:"
    echo "    journalctl -u step-ca -n 50 --no-pager"
    exit 1
fi

# --- Print summary ---
echo
echo "=========================================================="
echo "step-ca is up. Root certificate fingerprint:"
sudo -u step env STEPPATH="${STEPPATH}" step certificate fingerprint "${STEPPATH}/certs/root_ca.crt"
echo
echo "Root cert: ${STEPPATH}/certs/root_ca.crt"
echo "ACME endpoint:"
echo "  https://tirion.vingilot.internal/acme/${ACME_PROVISIONER_NAME}/directory"
echo "=========================================================="