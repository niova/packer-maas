# Rocky 10 bootc (Image-Based) Packer template for MAAS

## Introduction

This is an **alternative** Packer template for Rocky 10 that uses **bootc** (image-based/OSTree) deployment instead of traditional package installation.

**⚠️ IMPORTANT LIMITATION:**
bootc builds use XFS filesystems which **cannot be processed in GitHub Actions** due to lack of kernel module support. This template is designed for **local builds only** on systems with KVM access.

**Use this variant if:**
- You want immutable infrastructure
- Your OS is built as a container image
- You need atomic updates and rollbacks
- You're deploying edge/embedded systems
- **You can build locally (not in CI/CD)**

**Use the standard `rocky10.pkr.hcl` if:**
- You want traditional package-based installation
- You need a mutable, customizable OS
- You're doing standard MAAS bare-metal deployments
- **You need CI/CD automation**

## What is bootc?

**bootc** enables deploying container images as bootable operating systems:
- OS is pulled from a container registry (like Docker Hub, Quay.io)
- Entire system is immutable and atomic
- Updates = pull new container image
- Easy rollbacks to previous image versions
- Similar to Fedora CoreOS, RHEL for Edge

## Prerequisites

### Build Prerequisites
Same as standard Rocky 10 template:
- Ubuntu 22.04+ with KVM support
- qemu-utils, libnbd-bin, nbdkit, fuse2fs
- qemu-system, ovmf
- Packer v1.11.0+

### Container Image Prerequisites
You **must** have:
1. A pre-built **bootc-compatible container image** in a registry
2. Registry credentials (if private)
3. Image reference (e.g., `registry:example.com/org/rocky10-bootc:latest`)

## Building Your bootc Container Image

Before using this Packer template, you need to build a bootc container image. Example Containerfile:

```dockerfile
FROM quay.io/centos-bootc/centos-bootc:stream10

# Install necessary packages for MAAS
RUN dnf install -y cloud-init cloud-utils-growpart NetworkManager && \
    dnf clean all

# Enable cloud-init
RUN systemctl enable cloud-init cloud-init-local cloud-config cloud-final

# MAAS compatibility
RUN mkdir -p /etc/NetworkManager/conf.d && \
    echo -e "[main]\nplugins=keyfile\ndns=default" > /etc/NetworkManager/conf.d/99-maas.conf
```

Build and push:
```bash
podman build -t registry.example.com/rocky10-bootc:latest .
podman push registry.example.com/rocky10-bootc:latest
```

## Building the MAAS Image

### Using Makefile

```bash
cd rocky10

# Public registry (no authentication)
make -f Makefile.bootc \
  BOOTC_IMAGE_REF="quay.io/user/rocky10-bootc:latest"

# Private registry with authentication
make -f Makefile.bootc \
  BOOTC_IMAGE_REF="registry:registry.example.com/org/rocky10-bootc:latest" \
  BOOTC_REGISTRY_URL="registry.example.com" \
  BOOTC_REGISTRY_AUTH="dXNlcm5hbWU6cGFzc3dvcmQ=" \
  BOOTC_REGISTRY_INSECURE=false
```

### Authentication Token

Generate base64 auth token:
```bash
echo -n "username:password" | base64
# Result: dXNlcm5hbWU6cGFzc3dvcmQ=
```

### Using Packer Directly

```bash
packer init rocky10-bootc.pkr.hcl

packer build \
  -var bootc_image_ref="quay.io/user/rocky10-bootc:latest" \
  -var bootc_registry_url="quay.io" \
  -var bootc_registry_auth="YOUR_BASE64_AUTH" \
  rocky10-bootc.pkr.hcl
```

## Uploading to MAAS

Upload exactly like the standard Rocky 10 image:

```bash
maas $PROFILE boot-resources create name='custom/rocky10-bootc' \
    title='Rocky 10 bootc (Immutable)' \
    architecture='amd64/generic' \
    base_image='rhel/10' \
    filetype='tgz' \
    content@=rocky10-bootc.tar.gz
```

## Key Differences from Standard Template

| Feature | Standard (`rocky10.pkr.hcl`) | bootc (`rocky10-bootc.pkr.hcl`) |
|---------|------------------------------|----------------------------------|
| OS Installation | Package-based (DNF/YUM) | Container image-based |
| Packages | Explicit list in kickstart | Pre-installed in container image |
| Updates | `dnf update` | Pull new container image |
| Filesystem | ext4 | XFS (bootc default) |
| Mutability | Mutable | Immutable |
| Rollback | Manual | Built-in (OSTree) |
| Build Time | ~1.5-2 hours | Faster (~30-45 min, downloads image) |

## Environment Variables

### Required
- `BOOTC_IMAGE_REF`: Container image reference (e.g., `registry:example.com/org/image:tag`)

### Optional
- `BOOTC_REGISTRY_URL`: Registry hostname for authentication
- `BOOTC_REGISTRY_AUTH`: Base64 encoded `username:password`
- `BOOTC_REGISTRY_INSECURE`: Set to `true` for HTTP registries (default: `false`)
- `ARCH`: Architecture (`x86_64` or `aarch64`)
- `TIMEOUT`: Build timeout (default: `1h`)

## Testing Locally with virt-install

Before running the full Packer build, you can quickly test the bootc kickstart using `virt-install`:

### Prerequisites
```bash
sudo apt-get install qemu-system libvirt-daemon-system virtinst virt-viewer
```

### Quick Test Command
```bash
# Download Rocky 10 netboot ISO
wget http://download.rockylinux.org/pub/rocky/10/isos/x86_64/Rocky-10-latest-x86_64-boot.iso

# Edit your kickstart to point to your bootc image
# Then run virt-install
virt-install --name rocky10-bootc-test \
  --cpu host --vcpus 4 --memory 4096 \
  --disk /var/lib/libvirt/images/rocky10-bootc-test.qcow2,format=qcow2,bus=virtio,size=64 \
  --osinfo rocky10 \
  --machine q35 \
  --accelerate \
  --graphics vnc,listen=127.0.0.1,port=5900 \
  --qemu-commandline="-device virtio-net,netdev=user.0,bus=pcie.0,addr=0x10 -netdev user,id=user.0,hostfwd=tcp::5555-:22" \
  --initrd-inject rocky10/http/rocky10-bootc.ks.pkrtpl.hcl \
  --extra-args="inst.ks=file:/rocky10-bootc.ks.pkrtpl.hcl inst.sshd console=ttyS0" \
  --location Rocky-10-latest-x86_64-boot.iso \
  --noautoconsole

# Connect with VNC viewer
virt-viewer --connect qemu:///system rocky10-bootc-test
# Or: vncviewer localhost:5900
```

### Using HTTP-served Kickstart
You can also serve the kickstart via HTTP (like Packer does):

```bash
# Start a simple HTTP server in rocky10/http/
cd rocky10/http
python3 -m http.server 8000

# Then use in virt-install:
--extra-args="inst.ks=http://10.0.2.2:8000/rocky10-bootc.ks.pkrtpl.hcl inst.sshd"
```

**Note:** You'll need to manually replace template variables (`${BOOTC_IMAGE_REF}`, etc.) in the kickstart file for manual testing.

## Troubleshooting

### Image Pull Fails
Check registry authentication and network access from the installer.

### bootc Not Found
Ensure you're using Rocky Linux 10 (or CentOS Stream 10+) which includes bootc.

### EFI Mount Error
If you see `rm: cannot remove '/mnt/sysimage/boot/efi': Device or resource busy`:
- This was fixed by explicitly defining `/boot/efi` partition instead of using `reqpart`
- Make sure you're using the latest kickstart from this repo

### MAAS Deployment Fails
Verify your container image includes:
- cloud-init
- NetworkManager
- Proper systemd units enabled

## References

- [bootc Documentation](https://containers.github.io/bootc/)
- [CentOS bootc Images](https://quay.io/repository/centos-bootc/centos-bootc)
- [Image Mode for RHEL](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/composing_installing_and_managing_rhel_for_edge_images/index)
- [virt-install Documentation](https://manpages.ubuntu.com/manpages/jammy/man1/virt-install.1.html)
