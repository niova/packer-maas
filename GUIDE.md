# Rocky 10 bootc over MAAS PXE — line-by-line guide

Install a **Rocky Linux 10 bootc** (OCI image-mode) OS onto a VM/bare-metal host
that PXE-boots on a **MAAS-managed isolated network**, and make it boot its **local
disk** after install (no reinstall loop) — the same behavior Cobbler gives you with
`nopxe` + `netboot_enabled`.

This guide is written so you can copy each block and run it, and understand why.

## Topology

```
 KVM host
 ├── VM "maas"    (Ubuntu + MAAS)   isolated NIC 192.168.200.2 , user NIC (egress)
 └── VM "lattice" (target)          isolated NIC 192.168.200.3 , user NIC (egress)
                                     MAC 52:54:00:dd:2e:a9
 isolated libvirt network: "isolated-bridge"  (192.168.200.0/24, MAAS DHCP)
```

- **Isolated NIC**: PXE + MAAS traffic. Static IP, **no default route**.
- **User NIC** (QEMU SLIRP, `10.0.2.x`): default route → internet, so Anaconda can
  pull the bootc image from the private registry.

Substitute your own values:

| Thing | This lab |
|-------|----------|
| MAAS host (isolated) | `192.168.200.2` |
| Target IP / MAC | `192.168.200.3` / `52:54:00:dd:2e:a9` |
| bootc image | `lora.lustre.software/lattice_stream/lattice-rocky10-niova:2026072418` |
| Registry | `lora.lustre.software` |
| HTTP server | `192.168.200.2:8080` |
| VNC | MAAS `:5900`, target `:5901` |

---

## Part 0 — MAAS controller VM

If you don't already have MAAS running, build the controller VM first:
see [`references/maas-controller-vm.md`](references/maas-controller-vm.md).

In MAAS: enable managed DHCP on the `192.168.200.0/24` subnet (isolated NIC), and
add a **reserved static IP** mapping `192.168.200.3` ↔ `52:54:00:dd:2e:a9`.

All commands below run **on the MAAS host** unless noted. SSH in:

```bash
ssh ubuntu@192.168.200.2     # password: P@ssw0rd (this lab)
```

---

## Part 1 — Installer assets on the MAAS host

### 1.1 Loop-mount the Rocky boot ISO

```bash
sudo mkdir -p /srv/rockypxe/iso
# put the Rocky 10 boot ISO for your target arch somewhere, e.g. /home/ubuntu/
#   x86_64 : Rocky-10.2-x86_64-boot.iso
#   aarch64: Rocky-10.2-aarch64-boot.iso
echo '/home/ubuntu/Rocky-10.2-x86_64-boot.iso /srv/rockypxe/iso iso9660 loop,ro,nofail 0 0' \
  | sudo tee -a /etc/fstab
sudo mount /srv/rockypxe/iso
```

> **Arch note.** `images/pxeboot/{vmlinuz,initrd.img}` exist on both arches, so the
> copy step below is identical. Only three things change for aarch64: the ISO
> above, the server `ARCH` constant (§2.1), and the target `virt-install` firmware
> (§Part 5). MAAS serves the arch-appropriate GRUB automatically.

### 1.2 Copy kernel + initrd into the web root

```bash
sudo mkdir -p /srv/rockypxe/www /srv/rockypxe/state
sudo cp /srv/rockypxe/iso/images/pxeboot/vmlinuz    /srv/rockypxe/www/vmlinuz
sudo cp /srv/rockypxe/iso/images/pxeboot/initrd.img /srv/rockypxe/www/initrd.img
sudo ln -s /srv/rockypxe/iso /srv/rockypxe/www/iso   # serve inst.repo/stage2
```

Anaconda pulls `inst.repo`/`inst.stage2` from `http://192.168.200.2:8080/iso/`,
which is the loop-mounted ISO.

---

## Part 2 — The HTTP server (installer + Cobbler-style netboot toggle)

A plain `python3 -m http.server` only serves static files. We need three dynamic
behaviors, so we run a small custom server instead. It:

- serves the static assets (`vmlinuz`, `initrd.img`, `lattice.cfg`, `iso/`),
- `GET /grub/<mac>.cfg` → returns the **installer** stanza, or a **chainload-local-disk**
  stanza if a marker exists, or the **MAAS default chain** for MACs it doesn't manage,
- `GET /nopxe/<mac>` → creates the marker (called from kickstart `%post`),
- `GET /pxe/<mac>` → removes the marker (re-arm a reinstall).

### 2.1 Install the server

Copy [`references/rockypxe_server.py`](references/rockypxe_server.py) to the host,
then edit the top constants for your environment:

```python
SERVER = "192.168.200.2:8080"           # host:port GRUB/Anaconda reach
KNOWN_MACS = {"52:54:00:dd:2e:a9"}       # MACs this server manages
ARCH = "x86_64"                          # or "aarch64"
```

> `ARCH` drives the chainloaded EFI path (`shimx64.efi`/`BOOTX64.EFI` vs
> `shimaa64.efi`/`BOOTAA64.EFI`) and the installer serial console (`ttyS0` vs
> `ttyAMA0`). Set it to match the **target**, not the MAAS controller.

```bash
sudo install -m 755 rockypxe_server.py /srv/rockypxe/rockypxe_server.py
sudo mkdir -p /srv/rockypxe/state
```

> Why `KNOWN_MACS`? Unmanaged MACs get the standard MAAS chain config, so other
> machines on the same MAAS keep booting normally.

### 2.2 systemd unit

Copy [`references/rockypxe-http.service`](references/rockypxe-http.service) to
`/etc/systemd/system/`, then:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now rockypxe-http.service
systemctl is-active rockypxe-http.service     # -> active
```

> Port note: we use **8080** because 8000 is Squid and MAAS uses 5240/5248; VNC
> uses 5900/5901. Pick any free port, but change it in **all three** places
> (server `SERVER`, `grub.cfg`, kickstart `@SERVER@`).

### 2.3 Test every endpoint before touching GRUB

```bash
MAC=52:54:00:dd:2e:a9
curl -fsS http://127.0.0.1:8080/lattice.cfg | head -3    # static served
curl -fsS http://127.0.0.1:8080/grub/$MAC.cfg           # installer stanza
curl -fsS http://127.0.0.1:8080/nopxe/$MAC              # -> marker created
curl -fsS http://127.0.0.1:8080/grub/$MAC.cfg           # now chainloader stanza
curl -fsS http://127.0.0.1:8080/pxe/$MAC               # re-arm (remove marker)
```

---

## Part 3 — The kickstart

Render [`references/lattice.cfg.template`](references/lattice.cfg.template) to
`/srv/rockypxe/www/lattice.cfg`, substituting every `@...@` placeholder.

Key parts and why:

- **Two `network` lines**: static on the isolated NIC with `--nodefroute`, DHCP on
  the egress NIC. This guarantees the default route (and thus registry pulls) goes
  out the internet-connected NIC, not the isolated one.
- **`ostreecontainer --url=... --transport=registry`**: this is what makes it a
  **bootc / image-mode** install instead of a package install.
- **`%pre` auth.json**: lets the *installer environment* pull the image.
  **`%post` auth.json**: lets the *installed system* pull future bootc upgrades.
- **`%post` curl `/nopxe/<mac>`**: the Cobbler-style trigger — tells the server
  "this MAC is installed", so the next PXE boots the disk.
- **`reboot --eject`**: reboots into the freshly installed system.

### Registry auth (do not commit the secret)

`@BASE64_AUTH@` is `base64("user:token")`. Generate and inject at provisioning time:

```bash
# on a trusted shell; do not echo into logs/PRs
AUTH=$(printf '%s' "ci:<REGISTRY_TOKEN>" | base64 -w0)
sudo sed -i "s#@BASE64_AUTH@#${AUTH}#g" /srv/rockypxe/www/lattice.cfg
```

Verify the file has exactly two `"auth":` entries (`%pre` and `%post`) and no
leftover placeholder or token in comments.

---

## Part 4 — Hijack the MAAS GRUB pre-loader

MAAS UEFI netboot serves **GRUB2** (not iPXE). GRUB reads `/grub/grub.cfg`
**statically** from disk. We replace it so the target MAC fetches its per-MAC config
from our HTTP server; everything else falls through to normal MAAS.

```bash
GDIR=/var/snap/maas/common/maas/tftp_root/grub
sudo cp -a "$GDIR/grub.cfg" "$GDIR/grub.cfg.maas-orig"   # back up original
# install references/grub.cfg (edit the 192.168.200.2:8080 to your host:port)
sudo cp grub.cfg "$GDIR/grub.cfg"
```

The installed `grub.cfg` (see [`references/grub.cfg`](references/grub.cfg)) does:

```grub
configfile (http,192.168.200.2:8080)/grub/${net_default_mac}.cfg
# safety net if HTTP fails:
configfile /grub/grub.cfg-${net_default_mac}
configfile /grub/grub.cfg-default-${grub_cpu}
```

> **Critical lesson.** Do **not** gate this with a GRUB `if [ ... ]` or
> `if regexp ... "${net_default_mac}"`. In the MAAS GRUB 2.06 build those
> comparisons silently fail and GRUB falls through to MAAS's Ubuntu image.
> But `${net_default_mac}` substitutes correctly **inside a `configfile` path**
> (MAAS itself relies on that). So we let the **HTTP server** decide per-MAC,
> keyed by the URL — no fragile GRUB conditionals.

Restore anytime with:

```bash
sudo cp -a "$GDIR/grub.cfg.maas-orig" "$GDIR/grub.cfg"
```

---

## Part 5 — Create and boot the target VM

Run this **on the KVM host** (not the MAAS VM). Boot order can be `hd,network`
(disk-first, faster) or `network,hd` (network-first). Both work: once installed,
GRUB chainloads the disk regardless.

```bash
sudo virt-install --name lattice --cpu host --vcpus 4 --memory 4096 --hvm --accelerate \
  --disk /home/anovik/VMs/workspace/lattice.qcow2,format=qcow2,bus=virtio,size=64 \
  --network network=isolated-bridge,model=virtio,mac='52:54:00:dd:2e:a9' \
  --network user,model=virtio \
  --boot uefi,network,hd \
  --osinfo detect=on,require=off \
  --controller scsi,model=virtio-scsi \
  --graphics vnc,listen=0.0.0.0,port=5901 --noautoconsole
```

- `--network network=isolated-bridge,...,mac=...` — isolated NIC, PXE + MAAS.
- `--network user,...` — QEMU SLIRP egress NIC (default route → internet).
- `--boot uefi,...` — UEFI/OVMF (MAAS UEFI netboot needs this).
- `--graphics ...,port=5901` — 5900 is the MAAS VM.

> **aarch64 target.** Add `--arch aarch64 --machine virt` and drop nothing else
> except the implicit `q35` (ARM has no `q35`). `--boot uefi` makes libvirt pick
> AAVMF firmware. Confirm `arm64` boot resources are imported in MAAS first, and
> that the server has `ARCH = "aarch64"`. Example delta:
>
> ```bash
> sudo virt-install --name lattice --arch aarch64 --machine virt \
>   --cpu host --vcpus 4 --memory 4096 --accelerate \
>   --disk .../lattice.qcow2,format=qcow2,bus=virtio,size=64 \
>   --network network=isolated-bridge,model=virtio,mac='52:54:00:dd:2e:a9' \
>   --network user,model=virtio \
>   --boot uefi,network,hd --osinfo detect=on,require=off \
>   --controller scsi,model=virtio-scsi \
>   --graphics vnc,listen=0.0.0.0,port=5901 --noautoconsole
> ```

### Watch it install (on the MAAS host)

```bash
journalctl -f -o cat | grep -Ei 'grub.cfg|8080|nopxe|boot-kernel|dd:2e:a9'
```

Open VNC `:5901`. Expected sequence:

1. `GET /grub/<mac>.cfg 200` → **installer** stanza → Anaconda text installer.
2. Kickstart runs; `ostreecontainer` pulls the image out the egress NIC.
3. `%post` → `GET /nopxe/<mac> 200` → marker created.
4. `reboot --eject` → PXE again → `GET /grub/<mac>.cfg 200` → **chainloader** stanza.
5. VNC prints `Chainloading (hdX,gpt1)/EFI/rocky/shimx64.efi` (aarch64:
   `shimaa64.efi`) → installed OS boots.

---

## Part 6 — Verify the deployment

```bash
ssh luser@192.168.200.3          # password: Luser (this lab); root via sudo

hostnamectl | grep -E 'hostname|Operating System|Kernel'
sudo bootc status                # shows spec/booted image, digest, store=ostreeContainer
ostree admin status              # single deployment, ostree-unverified-registry:...
ip -brief addr; ip route show default   # egress NIC holds the default route
```

`bootc status` should show your `IMAGE` under both `spec.image` and
`status.booted.image`, with a matching digest.

---

## Everyday operations

| Task | Command (MAAS host) |
|------|---------------------|
| Reinstall this host | `curl -fsS http://192.168.200.2:8080/pxe/52:54:00:dd:2e:a9` then `virsh destroy/start lattice` |
| Keep booting disk | leave the marker (default after install) |
| Onboard another machine | add its MAC to `KNOWN_MACS`, restart service, render a kickstart, add reservation |
| Faster steady-state boot | set VM boot order `hd,network` (`virt-xml lattice --edit --boot hd,network`) |
| Undo the GRUB hijack | restore `grub.cfg.maas-orig` (Part 4) |

---

## Why each non-obvious decision was made

- **GRUB, not DHCP/iPXE snippets** — MAAS UEFI serves GRUB2; iPXE `user-class`
  never matches, so DHCP snippets silently do nothing.
- **HTTP-side MAC logic, not GRUB `if`** — GRUB 2.06 `if`/`regexp` on
  `${net_default_mac}` failed; `configfile` path substitution works.
- **`chainloader`, not `exit`** — after install, GRUB `exit` let OVMF pick a second
  PXE/UEFI-HTTP boot (→ Ubuntu) instead of the disk. Chainloading the arch shim
  (`/EFI/rocky/shimx64.efi`, or `shimaa64.efi` on aarch64; found via `search --file`)
  boots the disk deterministically.
- **Two NICs** — isolated NIC has no default route so registry pulls can't leak onto
  the isolated net; the SLIRP NIC provides internet egress.
- **Arch is server-side** — one `ARCH` constant in `rockypxe_server.py` switches
  the EFI shim path and serial console; `grub.cfg` and kickstart stay identical.

## File map

| File | Purpose |
|------|---------|
| `references/rockypxe_server.py` | the HTTP server (installer + netboot toggle) |
| `references/rockypxe-http.service` | systemd unit for the server |
| `references/lattice.cfg.template` | kickstart template (`@...@` placeholders) |
| `references/grub.cfg` | replacement MAAS GRUB pre-loader |
| `references/grub.cfg.maas-orig` | pristine MAAS pre-loader (restore target) |
| `references/maas-controller-vm.md` | how the MAAS controller VM itself was built |
| `SKILL.md` | agent-invocable skill version of this guide |
