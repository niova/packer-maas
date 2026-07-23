packer {
  required_version = ">= 1.11.0"
  required_plugins {
    qemu = {
      version = ">= 1.1.0, < 1.1.2"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "filename" {
  type        = string
  default     = "rocky10-bootc.tar.gz"
  description = "The filename of the tarball to produce"
}

variable "timeout" {
  type        = string
  default     = "1h"
  description = "Timeout for building the image"
}

variable "architecture" {
  type        = string
  default     = "x86_64"
  description = "The architecture to build the image for (x86_64 or aarch64)"
}

variable "host_is_arm" {
  type        = bool
  default     = false
  description = "The host architecture is aarch64"
}

variable "ovmf_suffix" {
  type        = string
  default     = ""
  description = "Suffix for OVMF CODE and VARS files. Newer systems such as Noble use _4M."
}

variable "use_kvm" {
  type        = bool
  default     = true
  description = "Use KVM acceleration. Set to false for environments without KVM support (e.g., GitHub Actions)."
}

# bootc-specific variables
variable "bootc_image_ref" {
  type        = string
  description = "Container image reference for bootc (e.g., registry:example.com/org/image:tag)"
}

variable "bootc_registry_url" {
  type        = string
  default     = ""
  description = "Container registry URL (for authentication)"
}

variable "bootc_registry_auth" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Base64 encoded auth token for container registry (username:password)"
}

variable "bootc_registry_insecure" {
  type        = bool
  default     = false
  description = "Allow insecure (HTTP) registry connections"
}

locals {
  qemu_arch = {
    "x86_64"  = "x86_64"
    "aarch64" = "aarch64"
  }
  uefi_imp = {
    "x86_64"  = "OVMF"
    "aarch64" = "AAVMF"
  }
  uefi_sfx = {
    "x86_64"  = "${var.ovmf_suffix}"
    "aarch64" = ""
  }
  qemu_machine = {
    "x86_64"  = var.use_kvm ? "accel=kvm" : "accel=tcg"
    "aarch64" = var.host_is_arm && var.use_kvm ? "virt,accel=kvm" : "virt,accel=tcg"
  }
  qemu_cpu = {
    "x86_64"  = var.use_kvm ? "host" : "max"
    "aarch64" = var.host_is_arm && var.use_kvm ? "host" : "max"
  }

  # bootc authentication configuration
  bootc_has_auth = var.bootc_registry_auth != "" && var.bootc_registry_url != ""

  bootc_auth_setup = local.bootc_has_auth ? "mkdir -p /etc/ostree/ /etc/containers/ /etc/containers/registries.conf.d/ && echo '{\"auths\": {\"${var.bootc_registry_url}\": {\"auth\": \"${var.bootc_registry_auth}\"}}}' | tee /etc/ostree/auth.json /etc/containers/auth.json && cat > /etc/containers/registries.conf.d/bootc-registry.conf <<'REGEOF'\n[[registry]]\nlocation=\"${var.bootc_registry_url}\"\ninsecure=${var.bootc_registry_insecure}\nREGEOF" : "# No authentication configured"
}

source "qemu" "rocky10-bootc" {
  boot_command    = ["<up><wait>", "e", "<down><down><down><left>", " console=ttyS0 inst.cmdline inst.text inst.ks=http://{{.HTTPIP}}:{{.HTTPPort}}/rocky10-bootc.ks <f10>"]
  boot_wait       = "5s"
  communicator    = "none"
  disk_size       = "45G"
  format          = "qcow2"
  headless        = true
  iso_checksum    = "file:http://download.rockylinux.org/pub/rocky/10/isos/${var.architecture}/CHECKSUM"
  iso_url         = "http://download.rockylinux.org/pub/rocky/10/isos/${var.architecture}/Rocky-10-latest-${var.architecture}-boot.iso"
  iso_target_path = "packer_cache/Rocky-10-latest-${var.architecture}-boot.iso"
  memory          = 4096
  cores           = var.use_kvm ? 4 : 2
  qemu_binary     = "qemu-system-${lookup(local.qemu_arch, var.architecture, "")}"
  qemuargs = [
    ["-serial", "stdio"],
    ["-boot", "strict=off"],
    ["-device", "qemu-xhci"],
    ["-device", "usb-kbd"],
    ["-device", "virtio-net-pci,netdev=net0"],
    ["-netdev", "user,id=net0"],
    ["-device", "virtio-blk-pci,drive=drive0,bootindex=0"],
    ["-device", "virtio-blk-pci,drive=cdrom0,bootindex=1"],
    ["-machine", "${lookup(local.qemu_machine, var.architecture, "")}"],
    ["-cpu", "${lookup(local.qemu_cpu, var.architecture, "")}"],
    ["-device", "virtio-gpu-pci"],
    ["-global", "driver=cfi.pflash01,property=secure,value=off"],
    ["-drive", "if=pflash,format=raw,unit=0,id=ovmf_code,readonly=on,file=/usr/share/${lookup(local.uefi_imp, var.architecture, "")}/${lookup(local.uefi_imp, var.architecture, "")}_CODE${lookup(local.uefi_sfx, var.architecture, "")}.fd"],
    ["-drive", "if=pflash,format=raw,unit=1,id=ovmf_vars,file=${var.architecture}_VARS.fd"],
    ["-drive", "file=output-rocky10-bootc/packer-rocky10-bootc,if=none,id=drive0,cache=writeback,discard=ignore,format=qcow2"],
    ["-drive", "file=packer_cache/Rocky-10-latest-${var.architecture}-boot.iso,if=none,id=cdrom0,media=cdrom"]
  ]
  shutdown_timeout = var.timeout
  http_content = {
    "/rocky10-bootc.ks" = templatefile("${path.root}/http/rocky10-bootc.ks.pkrtpl.hcl",
      {
        BOOTC_IMAGE_REF  = var.bootc_image_ref,
        BOOTC_PRE_AUTH   = local.bootc_auth_setup,
        BOOTC_POST_AUTH  = local.bootc_auth_setup
      }
    )
  }
}

build {
  sources = ["source.qemu.rocky10-bootc"]

  post-processor "shell-local" {
    inline = [
      "SOURCE=${source.name}",
      "OUTPUT=${var.filename}",
      "source ../scripts/fuse-nbd",
      "source ../scripts/fuse-tar-root",
      "rm -rf output-${source.name}",
    ]
    inline_shebang = "/bin/bash -e"
  }
}
