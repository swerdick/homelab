# mirdain (CT 143)

GPU-worker k3s agent — the AI/ROCm half of the amdgpu-sharing design
(ROADMAP "Anduril Phase 2"). Joins gondor's cluster tainted
`homelab.vingilot.internal/role=gpu:NoSchedule`; only workloads with a
matching toleration (ComfyUI, llama-swap) land here.

## GPU is shared, not claimed

Binds the same `/dev/dri/renderD129` + `/dev/kfd` as the anduril gaming CT
(117) — no card0 (KMS stays anduril's; compute never needs it). RDNA4 has no
SR-IOV, so arbitration is operational:

- `just gpu-gaming-mode` — cordon + drain before a heavy gaming session
- `just gpu-ai-mode` — uncordon afterward
- `just gpu-stop-mirdain` / `just gpu-start-mirdain` — also frees the 16G RAM cap

ROCm/Vulkan userspace lives in pod images, NOT in this CT (plain Trixie).
If a pod ever drops privileged, use the GID actually stamped on the nodes
(`stat -c %g /dev/kfd` on earendil) — at build time udev had stamped 991,
which no longer matches `getent group render` (993), so check, don't assume.

## Config split

Created with `pct` and IMPORTED into terraform (privileged-CT feature flags +
bind mounts are root@pam-only via the API token — HTTP 403). The raw lxc.*
lines (GPU devices; k3s-in-LXC: kmsg, tun, proc:rw sys:rw, apparmor
unconfined, cleared cap.drop), `features`, and the mpN binds are managed by
ansible (setup-mirdain-lxc.yaml) against /etc/pve/lxc/143.conf; mirdain.tf
carries `mount_point` blocks as documentation only (ignore_changes).

Create command (fresh build):

    pct create 143 local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst \
      --hostname mirdain --unprivileged 0 --ostype debian \
      --cores 4 --cpuunits 50 --memory 16384 --swap 0 \
      --rootfs local-zfs:24 \
      --net0 name=eth0,bridge=vmbr0,ip=192.168.1.43/24,gw=192.168.1.1 \
      --searchdomain vingilot.internal \
      --features nesting=1,keyctl=1 \
      --onboot 1 --startup order=30 \
      --ssh-public-keys /root/.ssh/authorized_keys \
      --start 0

Then: setup-mirdain-lxc.yaml (host side) -> pct start 143 ->
site-mirdain.yaml (in-guest converge + k3s join). `swap=0` is deliberate:
kubelet-correct — memory pressure fails loud in-cgroup instead of paging
model weights to the rpool SSD.

## Storage

- rootfs 24G on local-zfs: OS + k3s state only
- mp0 scratch/mirdain-k3s (100G) at /var/lib/rancher: containerd image store
- mp1 bulk/ai-models (150G) at /bulk/ai-models: model weights + generation
  outputs. The image-managed dirs (comfyui/, outputs/, comfyui-user/) are
  smb-READ-only — the image re-chowns them root:root 0755 every boot. The
  `extra/` tree (smbuser:shares, ansible-owned, wired in via
  --extra-model-paths-config) is the Finder drag-drop target for
  checkpoints/loras/etc. comfyui-user + both loras trees are
  restic-protected (aglarond mp8-mp10); checkpoints deliberately not
  (re-downloadable).
  Quota trimmed from the planned 300G: bulk had 267G free at creation
  (2026-08).
