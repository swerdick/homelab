# Tirion CA Rotation Runbook

When and how to rotate the tirion root CA, and every cert/config that needs to follow.

## When to rotate

Rotate the tirion CA root immediately if any of these happen:

- The root CA private key (`/etc/step-ca/secrets/root_ca_key`) is exposed (committed to Git, leaked in logs, copied to an untrusted host)
- The intermediate CA private key is exposed (similar paths under `/etc/step-ca/secrets/`)
- Suspected compromise of the tirion LXC itself
- Any host that previously had access to the keys is decommissioned in an untrusted way

Rotate the root CA on a planned cadence if you want to:

- Refresh the CA every few years before its 10-year validity expires
- Change CA naming, key algorithm, or other metadata

Don't rotate just for renewal. Tirion's intermediate auto-renews on its own; only the root sticks around for 10 years.

## What rotation requires

Conceptually, three layers of work:

1. **Generate fresh CA on tirion** — wipes the old keys and creates a new root + intermediate, restarting step-ca with the new identity
2. **Re-distribute the new root cert** to every host that needs to trust the CA
3. **Re-issue every leaf cert** that was signed by the old CA, since they're now untrusted

The work is mostly mechanical, but step 3 has many sub-tasks easy to miss. This runbook lists them all.

## Pre-rotation checklist

Before doing anything destructive:

- Verify recent PBS backups exist for the tirion LXC (VMID 141). If the rotation goes wrong, restoring the LXC restores the old CA.
- Confirm thorondor can SSH to all hosts that will need re-distribution (earendil, gondor, erebor, aglarond, plus tirion itself)
- Check that no certificate operations are mid-flight (ACME orders in progress, cert-manager renewals queued)
- Have the tirion CA password ready (stored at `/etc/step-ca/password` on tirion)

## Step 1: Rotate tirion's CA

SSH to tirion as root. The tirion LXC doesn't have sudo (we run as root directly).

```bash
ssh root@tirion

# Stop step-ca
systemctl stop step-ca

# Save the password (we'll reuse it for the new init)
cat /etc/step-ca/password > /tmp/ca_password
chown step:step /tmp/ca_password
chmod 600 /tmp/ca_password

# Move old config aside (don't delete — keeps a forensic copy)
mv /etc/step-ca /etc/step-ca.compromised-$(date +%Y%m%d)
mkdir -p /etc/step-ca
chown step:step /etc/step-ca

# Re-init the CA. Match the existing DNS names + address from the old ca.json,
# which lives at /etc/step-ca.compromised-<date>/config/ca.json if you need to check.
su step -s /bin/bash -c '
  STEPPATH=/etc/step-ca step ca init \
    --name "Vingilot Homelab CA" \
    --dns "tirion.vingilot.internal,tirion,ca.vingilot.internal" \
    --address ":443" \
    --provisioner "admin" \
    --password-file /tmp/ca_password \
    --provisioner-password-file /tmp/ca_password \
    --deployment-type standalone
'

# Re-add the ACME provisioner (init only creates the JWK admin provisioner)
su step -s /bin/bash -c '
  STEPPATH=/etc/step-ca step ca provisioner add acme --type ACME
'

# Move the password file into the standard location
mv /tmp/ca_password /etc/step-ca/password
chown step:step /etc/step-ca/password
chmod 600 /etc/step-ca/password

# Start step-ca with the new identity
systemctl start step-ca

# Verify it's healthy. Use -k since trust hasn't propagated yet.
sleep 2
curl -k https://localhost:443/health
# Expect: {"status":"ok"}

# Verify the new root cert is genuinely new
step certificate inspect /etc/step-ca/certs/root_ca.crt --short
# Note the serial number and validity dates

# Compare to the old one (still in the compromised-* directory)
step certificate inspect /etc/step-ca.compromised-*/certs/root_ca.crt --short
# Serial numbers and fingerprints MUST be different
```

Pause here. Don't move on until you've verified the new CA is operational and serving health checks.

## Step 2: Re-distribute the new root cert

### 2a. Update the checked-in cert

The cert lives at `ansible/files/vingilot-root-ca.crt` and is the source of truth for both the Ansible playbook and `just trust-ca-mac`. Refresh it from tirion:

```bash
exit  # back to thorondor
ssh root@tirion 'cat /etc/step-ca/certs/root_ca.crt' > ansible/files/vingilot-root-ca.crt

# Sanity check: subject + validity should reflect the new CA
openssl x509 -in ansible/files/vingilot-root-ca.crt -noout -subject -issuer -dates
```

### 2b. Push to all Linux hosts via Ansible

```bash
cd ansible
ansible-playbook playbooks/distribute-root-ca.yaml
```

The playbook is OS-family aware:

- **Debian-family** (earendil, tirion, gondor, nfs, smb, aglarond, erebor): writes `/usr/local/share/ca-certificates/vingilot-root-ca.crt`, runs `update-ca-certificates`.
- **RedHat-family** (anduril/Bazzite when on): writes `/etc/pki/ca-trust/source/anchors/vingilot-root-ca.crt`, runs `update-ca-trust`.
- Hosts that are unreachable (anduril off) are reported in the recap and skipped — re-run when they're up.

### 2c. Trust on the macOS controller (thorondor)

```bash
just trust-ca-mac
```

That adds the cert to `/Library/Keychains/System.keychain`. The recipe also reminds you of the Firefox `security.enterprise_roots.enabled` toggle.

### 2d. iOS / iPadOS devices

The playbook can't help here — handle each device manually:

1. AirDrop `ansible/files/vingilot-root-ca.crt` to the device.
2. Install the resulting Profile (Settings prompts you).
3. **Settings → General → About → Certificate Trust Settings** — toggle on "Vingilot Homelab CA Root CA" (or whatever the new CN is).

### 2e. Restart any service that cached the old trust store

Long-running TLS clients (Go binaries, JVMs, etc.) load the system trust store at startup. After a root rotation, restart them on the affected hosts. Currently relevant:

- **Alloy** (all 6 alloy hosts): `ansible -m systemd -a 'name=alloy state=restarted' alloy`

Add new entries here as more long-running TLS clients are added.

### 2f. Verify

After all the above, verify each host trusts the new CA:

```bash
# Without -k flag — TLS verification must succeed against the new CA
curl https://tirion.vingilot.internal/health
# Expect: {"status":"ok"}

ssh gondor 'curl -sf https://tirion.vingilot.internal/health'
ssh earendil 'curl -sf https://tirion.vingilot.internal/health'
ssh erebor 'curl -sf https://tirion.vingilot.internal/health'
ssh aglarond 'curl -sf https://tirion.vingilot.internal/health'
# Each should print {"status":"ok"}
```

### macOS Keychain cleanup

`just trust-ca-mac` adds the new cert but doesn't remove the old one — both will be in the System Keychain. The new cert chain works correctly because macOS will pick the trusted one, but the orphaned old cert is clutter.

Find and remove the old cert by its old subject name:

```bash
# Find the old cert (its subject differs from the new one — adjust based on what
# the previous CA was called)
security find-certificate -c "<old CA subject name>" -Z /Library/Keychains/System.keychain | grep "SHA-1"

# Delete by SHA-1 hash
sudo security delete-certificate -Z <SHA1_HASH> /Library/Keychains/System.keychain

# Verify only the new cert is present
security find-certificate -c "<new CA subject name>" -Z /Library/Keychains/System.keychain
```

## Step 3: Re-issue every leaf cert

This is where rotations get missed. Every cert signed by the old CA is now distrusted. Each one needs to be re-issued via the new CA's ACME endpoint.

Walk through each cert location:

### 3a. earendil (PVE)

The pveproxy cert needs to be re-issued. ACME account on earendil already exists; just re-order:

```bash
ssh root@earendil
pvenode acme cert order --force
```

Watch the task output. Should complete in ~10 seconds with "TASK OK". The new cert is automatically installed at `/etc/pve/local/pveproxy-ssl.pem` and pveproxy is restarted.

Verify:

```bash
exit  # back to thorondor
echo | openssl s_client -connect earendil.vingilot.internal:8006 -servername earendil.vingilot.internal 2>&1 | grep -E "Verify return code|issuer"
# Verify return code: 0 (ok)
# issuer should reference the new CA name
```

Browser tab to https://earendil.vingilot.internal:8006/ should show "Connection secure".

### 3b. erebor (PBS)

Same flow but PBS-specific CLI:

```bash
ssh root@erebor
proxmox-backup-manager cert order
```

**Quirk:** PBS's `proxmox-backup-proxy` doesn't always pick up the new cert on reload. If the browser still shows the old cert after the order, restart the service:

```bash
systemctl restart proxmox-backup-proxy
# Or as a last resort, reboot the LXC: pct reboot 130 (from earendil)
```

Verify:

```bash
exit  # back to thorondor
echo | openssl s_client -connect erebor.vingilot.internal:8007 -servername erebor.vingilot.internal 2>&1 | grep -E "Verify return code|issuer"
```

### 3c. cert-manager ClusterIssuer (k3s on gondor)

The ClusterIssuer in `gondor/infrastructure/instances/cert-manager/clusterissuer.yaml` has the old CA cert inlined in its `caBundle:` field. This needs updating to the new root.

```bash
# Get the new root cert content (already on thorondor from distribute-root-ca.sh)
cat ~/.config/vingilot/root-ca.crt | head -1
# Verify: -----BEGIN CERTIFICATE-----

# Generate the base64 form
base64 -i ~/.config/vingilot/root-ca.crt | tr -d '\n'
# Copy that string

# Edit gondor/infrastructure/instances/cert-manager/clusterissuer.yaml
# Replace the value of caBundle: with the new base64 string
```

Validate locally before pushing:

```bash
just validate gondor/infrastructure/instances/cert-manager
# Expect: clusterissuer.cert-manager.io/tirion configured (server dry run)
```

Commit and push:

```bash
git add gondor/infrastructure/instances/cert-manager/clusterissuer.yaml
git commit -m "chore(cert-manager): update caBundle for tirion CA rotation"
git push
just reconcile
```

After Flux applies the new ClusterIssuer:

```bash
kubectl get clusterissuer tirion
# Expect READY: True with status "The ACME account was registered with the ACME server"

# Cert-manager re-registers an account against the new CA.
# All existing Certificates managed by cert-manager will eventually re-issue
# during their normal renewal cycle. To force-renew immediately:

kubectl get certificates -A
# For each Certificate, force renewal:
kubectl annotate certificate <name> -n <namespace> cert-manager.io/issue-temporary-certificate="true" --overwrite
# Or delete the Secret holding the cert; cert-manager will re-issue:
kubectl delete secret <cert-secret-name> -n <namespace>
```

### 3d. PVE→PBS pinned fingerprints

If `/etc/pve/storage.cfg` on earendil has a `fingerprint` field on the PBS storage entry, that fingerprint is now stale. The cert-rotation post-mortem from May 2026 showed this is a common miss.

Two options:

**Option A (recommended): remove the pinned fingerprint.** Rely on PKI chain validation now that the root is in earendil's system trust store.

```bash
ssh root@earendil
pvesm set <pbs-storage-name> --delete fingerprint
pvesm status
# 'main' (or whatever the PBS storage name is) should show 'active'
```

**Option B: re-pin to the new fingerprint.** Less robust — every cert renewal changes the fingerprint, requiring re-pinning. Not recommended.

### 3e. Anything else relying on the cert

For any service we add that uses tirion-issued certs, this list grows. Check:

- **Custom scripts** that pin a fingerprint or expect a specific CA subject
- **CI/CD configurations** that include the CA cert as trusted
- **External monitoring** with TLS connections to internal services

## Step 4: Verify and document

After all the above:

```bash
# Verify all hosts can still reach all services with valid TLS
for host in thorondor gondor earendil erebor aglarond; do
    echo "=== $host ==="
    if [[ "$host" == "thorondor" ]]; then
        curl -sf https://tirion.vingilot.internal/health > /dev/null && echo "tirion OK"
        curl -sf https://earendil.vingilot.internal:8006/ > /dev/null && echo "earendil OK"
        curl -sf https://erebor.vingilot.internal:8007/ > /dev/null && echo "erebor OK"
        curl -sf https://grafana.vingilot.internal/ > /dev/null && echo "grafana OK"
    else
        ssh "$host" 'curl -sf https://tirion.vingilot.internal/health' > /dev/null && echo "tirion OK"
    fi
done
```

Update the date and rotation reason in the homelab journal:

- When the rotation happened
- Why it happened (compromise, planned, etc.)
- Any deviations from this runbook

## Common pitfalls

**The old cert lingers in the macOS System Keychain.** Browser may pick it up first and show a name mismatch warning. Delete via `security delete-certificate` as in step 2.

**PVE storage.cfg pinned fingerprints.** Every PBS storage entry pins a fingerprint by default when added through the UI. After rotation, every pin is stale. Delete pins; rely on PKI validation.

**PBS `proxmox-backup-proxy` doesn't reload cleanly.** Even after a successful cert order, the running daemon may continue serving the old cert until restarted. `systemctl restart proxmox-backup-proxy` or reboot the LXC.

**cert-manager doesn't re-issue certs eagerly.** After updating the ClusterIssuer caBundle, existing Certificates will work until their natural renewal cycle. To force re-issuance, delete the cert Secret or annotate the Certificate.

**Forgetting `pvenode acme cert order --force` on earendil.** The PVE host has its own cert (separate from any guest); without re-ordering it, browser warnings persist on the Proxmox UI. Easy to miss because the PVE host's cert is "just there" — no Flux or scripted process renews it; you have to remember.

**ACME accounts persist across CA rotations.** Both `pvenode acme` and `proxmox-backup-manager acme` keep their old account configurations pointing at the new CA's URL (which still resolves). The accounts themselves work fine because step-ca treats them as legitimate ACME identities, but if you ever want a clean state, delete and re-register them.

**Hosts running their own cert-renewal automation may fail silently.** If anything renews on a cron or systemd timer, the next renewal attempt against the new CA may fail without notification. After rotation, manually trigger renewals everywhere to flush out failures while attention is high.

## What this rotation cost (May 2026 reference)

The May 2026 rotation took ~3 hours total. Breakdown:

- ~30 min: rotate tirion CA + verify
- ~15 min: distribute new root cert to all hosts + verify
- ~30 min: update cert-manager ClusterIssuer caBundle + verify
- ~30 min: re-issue earendil + erebor certs via Proxmox built-in ACME
- ~60 min: surface and fix the missed earendil pveproxy + storage fingerprint issues days later

Most of the post-rotation pain came from the missed sub-tasks in step 3 — they only manifested when something else (PBS storage operations, browser visit) needed the affected service. A complete pass through this runbook would have caught them all on the first round.