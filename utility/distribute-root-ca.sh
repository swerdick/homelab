#!/usr/bin/env bash
# Distributes tirion's root cert to clients that should trust it.
# Run from thorondor.

set -euo pipefail

CERT_LOCAL="${HOME}/.config/vingilot/root-ca.crt"
mkdir -p "$(dirname "${CERT_LOCAL}")"

# --- Fetch from tirion ---
echo "Fetching root cert from tirion..."
ssh root@tirion 'cat /etc/step-ca/certs/root_ca.crt' > "${CERT_LOCAL}"
echo "✓ Saved to ${CERT_LOCAL}"

# --- Trust on macOS (thorondor) ---
echo
echo "Adding to macOS System Keychain..."
echo "(You'll be prompted for sudo and Keychain admin auth.)"
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "${CERT_LOCAL}"
echo "✓ Trusted on thorondor."

# --- Trust on Debian-based hosts reachable directly via SSH ---
# Includes earendil (Proxmox host), gondor (k3s VM), and tirion itself.
# Skipped: nfs (120) and smb (121) — neither needs TLS client trust for any
# realistic workload. NFS/SMB don't use X.509 for transport.
echo
echo "Distributing to directly-reachable Debian hosts..."
# earendil and tirion connect as root (per ~/.ssh/config); no sudo needed
for host in earendil tirion; do
    echo "  → ${host}"
    scp -O "${CERT_LOCAL}" "${host}:/tmp/vingilot-root-ca.crt"
    ssh "${host}" 'install -m 644 /tmp/vingilot-root-ca.crt /usr/local/share/ca-certificates/vingilot-root-ca.crt && update-ca-certificates && rm /tmp/vingilot-root-ca.crt'
done

# gondor connects as pseudo; needs sudo
echo "  → gondor"
scp -O "${CERT_LOCAL}" "gondor:/tmp/vingilot-root-ca.crt"
ssh gondor 'sudo install -m 644 /tmp/vingilot-root-ca.crt /usr/local/share/ca-certificates/vingilot-root-ca.crt && sudo update-ca-certificates && rm /tmp/vingilot-root-ca.crt'

# --- Trust on LXCs (via earendil + pct exec) ---
# erebor (PBS) and aglarond (restic) both make TLS client connections to
# things in vingilot.internal and need to trust the chain.
echo
echo "Distributing to LXCs via earendil..."
scp -O "${CERT_LOCAL}" "root@earendil:/tmp/vingilot-root-ca.crt"
for entry in "130:erebor" "131:aglarond"; do
    vmid="${entry%:*}"
    name="${entry#*:}"
    echo "  → LXC ${vmid} (${name})"
    ssh root@earendil "pct push ${vmid} /tmp/vingilot-root-ca.crt /tmp/vingilot-root-ca.crt && pct exec ${vmid} -- bash -c 'install -m 644 /tmp/vingilot-root-ca.crt /usr/local/share/ca-certificates/vingilot-root-ca.crt && update-ca-certificates && rm /tmp/vingilot-root-ca.crt'"
done
ssh root@earendil 'rm /tmp/vingilot-root-ca.crt'

echo
echo "✓ Root cert distributed."
echo
echo "Hosts NOT included (handle when relevant):"
echo "  - anduril (Bazzite): different cert path on Fedora-based systems."
echo "    When powered on, run from anduril:"
echo "      step ca bootstrap --ca-url https://tirion.vingilot.internal --fingerprint <fp>"
echo "    Or manually:"
echo "      sudo cp <cert> /etc/pki/ca-trust/source/anchors/vingilot-root-ca.crt"
echo "      sudo update-ca-trust"
echo
echo "  - nfs (120) / smb (121): skipped — no TLS client use case."
echo "    If you ever stand one up behind ingress or talking to an internal"
echo "    HTTPS service, add it to the LXC loop above."
echo
echo "For iOS: AirDrop ${CERT_LOCAL} to your phone, install the profile,"
echo "then go to Settings → General → About → Certificate Trust Settings"
echo "and toggle on trust for 'vingilot.internal'."