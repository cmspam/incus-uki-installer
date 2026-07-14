# incus-uki-installer

Install Debian or Ubuntu with the [Zabbly](https://github.com/zabbly) kernel,
[Incus](https://linuxcontainers.org/incus/), and ZFS, booted by a signed Unified
Kernel Image (UKI) and systemd-boot. Root can be on ZFS (with native or LUKS
encryption), or on ext4/xfs/btrfs with optional LVM and LUKS. The installer runs
from a live environment and writes to a target disk.

This is a sibling of
[proxmox-uki-installer](https://github.com/cmspam/proxmox-uki-installer) and uses
the same boot chain: instead of GRUB and a separate initramfs, the kernel, its
initramfs, and the kernel command line are one signed EFI binary, which is what
makes a durable TPM2 policy and Secure Boot practical.

## What it produces

- A single dracut UKI per kernel, built by `ukify`, placed in `EFI/Linux` on the
  EFI System Partition and discovered automatically by systemd-boot. It is
  rebuilt and re-signed on every kernel update through a `dpkg` kernel hook.
- The [Zabbly kernel](https://github.com/zabbly/linux) (`linux-zabbly`) by
  default, or the distribution's own kernel (`KERNEL=stock`).
- [Incus](https://github.com/zabbly/incus) from the Zabbly package repository.
- Root on ZFS: a single pool (default `rpool`) with a `rpool/ROOT/<distro>` boot
  dataset, imported by the dracut `zfs` module from the UKI. Optional OpenZFS
  native encryption (passphrase at boot) or LUKS underneath the pool.
- Or root on ext4/xfs/btrfs, with optional LVM (thin or thick) and LUKS2 with
  TPM2 auto-unlock (signed PCR 11 policy, so it survives kernel upgrades).
- Secure Boot using the Microsoft-signed shim plus a Machine Owner Key (MOK). The
  same MOK signs the UKI, systemd-boot, and DKMS modules (including OpenZFS where
  it is built by DKMS), so they load under kernel lockdown.

## Distribution and kernel matrix

`DISTRO` x `KERNEL` selects the base system and where ZFS comes from:

| DISTRO | KERNEL | Kernel package | ZFS source |
|---|---|---|---|
| `debian` (trixie) | `zabbly` | `linux-zabbly` | `openzfs-zfs-dkms` (Zabbly, DKMS) |
| `debian` (trixie) | `stock`  | `linux-image-amd64` (trixie stock for ZFS, trixie-backports otherwise) | `zfs-dkms` (Debian contrib, DKMS) |
| `ubuntu` (resolute/26.04) | `zabbly` | `linux-zabbly` | `openzfs-zfs-dkms` (Zabbly, DKMS) |
| `ubuntu` (resolute/26.04) | `stock`  | `linux-generic` | in-archive `zfsutils-linux` (module bundled in `linux-modules`, no DKMS) |

Incus always comes from the Zabbly Incus repository. Where ZFS is built by DKMS,
the module is compiled once during installation and signed with the MOK, so it
loads under Secure Boot. Zabbly ZFS is DKMS by design; there is no prebuilt
Zabbly ZFS kernel module.

For a **newer kernel together with a ZFS root on Debian, use `KERNEL=zabbly`**:
Zabbly ships an OpenZFS build matched to its kernel. Debian's contrib `zfs-dkms`
tracks the stock trixie kernel, so the `debian` + `stock` combination installs the
stock kernel when the root is ZFS (a trixie-backports kernel can be newer than
contrib ZFS supports and fail to build); it uses the backports kernel only for the
non-ZFS filesystems.

## Requirements

- A UEFI target machine.
- A live environment that has, or can install, the front-half tools
  (`debootstrap`, `cryptsetup`, `gdisk`, `dosfstools`, `parted`, and for a ZFS
  root, a working `zpool`). See "Which live image to run it from" below. For a
  ZFS root the live environment **must** have working ZFS, because the pool is
  created before the target system exists.
- Network access to the distribution and Zabbly package repositories.

## Which live image to run it from

A ZFS root (`FS=zfs`) requires the live environment to be able to run `zpool`,
because the pool is created before the target system exists. Not every generic
live image ships ZFS, so pick the media by what it actually carries:

- **Ubuntu Server live ISO (24.04 LTS or 26.04 LTS).** Ships `zfsutils-linux` and
  a ZFS-capable kernel, plus `apt`. Open a shell from the installer (on the
  Ubuntu Server installer, choose the shell / help menu), then run the installer.
  This is the environment the installer is developed and tested against.
- **Proxmox VE 9 ISO.** Debian trixie based and ships ZFS built into its kernel.
  Boot it and choose the debug/rescue shell. Useful if you already keep a Proxmox
  ISO around.

For a non-ZFS root (`FS=ext4`, `xfs`, `btrfs`) any current Debian or Ubuntu live
environment with a network connection works; ZFS is not needed in that case.

A plain Debian live/netinst image does **not** ship ZFS, so it cannot create a
ZFS root as-is. Use one of the images above for `FS=zfs`.

## Quick start

From the live environment, download both scripts into the same directory and run
`install.sh`. It is interactive by default.

```sh
mkdir incus-uki-installer && cd incus-uki-installer
curl -fsSLO https://raw.githubusercontent.com/cmspam/incus-uki-installer/main/install.sh
curl -fsSLO https://raw.githubusercontent.com/cmspam/incus-uki-installer/main/stage2.sh
sudo bash install.sh
```

`stage2.sh` must sit next to `install.sh`; the installer copies it into the
target and runs it inside the chroot. The installer asks for the distribution,
kernel, target disk, filesystem, encryption, Incus, Secure Boot, and passwords,
shows a summary, and asks for confirmation before it writes anything.

## Scripted install

Any setting can be supplied through the environment instead of a prompt. A value
passed in the environment is used as is and is never prompted for. Set
`NONINTERACTIVE=yes` (or run with a non-terminal stdin) to take defaults.

```sh
# Debian + Zabbly kernel + Incus, root on encrypted ZFS:
sudo NONINTERACTIVE=yes \
  DISTRO=debian KERNEL=zabbly \
  TARGET_DISK=/dev/disk/by-id/ata-... \
  FS=zfs ZFS_ENC=native ZFSPW='choose-a-passphrase' \
  SECUREBOOT=yes INCUS=yes \
  bash install.sh
```

On real hardware use a stable `/dev/disk/by-id/...` path; kernel names such as
`/dev/sda` can change between boots.

### Settings

| Variable | Values | Default |
|---|---|---|
| `DISTRO` | `debian`, `ubuntu` | `debian` |
| `KERNEL` | `zabbly`, `stock` | `zabbly` |
| `FS` | `zfs`, `ext4`, `xfs`, `btrfs` | `zfs` |
| `ZPOOL` | ZFS pool name (FS=zfs) | `rpool` |
| `ZFS_ENC` | `none`, `native`, `luks` (FS=zfs) | `none` |
| `INCUS` | `yes`, `no` | `yes` |
| `INCUS_CHANNEL` | `stable`, `daily`, `lts-6.0`, `lts-7.0` | `stable` |
| `PART_MODE` | `auto`, `freespace`, `custom` | `auto` |
| `TARGET_DISK` | disk to install onto (auto, freespace) | prompt |
| `ESP_PART` / `ROOT_PART` | existing partitions (custom) | |
| `FORMAT_ESP` | `yes`, `no` | `yes` (`no` when reusing) |
| `ESP_SIZE` | EFI partition size | `1GiB` |
| `ROOT_PART_SIZE` | root partition size, or `rest` | `rest` |
| `BTRFS_OPTS` | btrfs mount options | `compress=zstd:1,noatime,space_cache=v2,discard=async` |
| `USE_LVM` / `LVM_THIN` | `yes`, `no` (non-zfs) | `no` |
| `ROOT_SIZE` | root LV size, or `100%FREE` (LVM) | `100%FREE` |
| `USE_LUKS` | `yes`, `no` (non-zfs) | `no` |
| `SECUREBOOT` | `yes`, `no` | `yes` |
| `HOSTONLY` | `yes`, `no` | `no` |
| `HOSTNAME_` | target hostname | `incus` |
| `ROOTPW` | root password | `incus` |
| `LUKSPW` | LUKS passphrase (ZFS_ENC=luks or USE_LUKS) | `incus` |
| `ZFSPW` | ZFS native-encryption passphrase (ZFS_ENC=native) | `incus` |
| `MOKPW` | one-time MokManager password, 8 to 16 characters | `12345678` |
| `EXTRA_CMDLINE` | extra kernel command line, appended verbatim | |
| `MIRROR` | distribution mirror | distro default |

## Root on ZFS

With `FS=zfs` the installer creates a single pool on the root partition and a
boot dataset layout:

```
rpool                    (mountpoint=none)
  rpool/ROOT             (mountpoint=none)
    rpool/ROOT/<distro>  (mountpoint=/, the booted root)
```

`bootfs` is set on the pool and the kernel command line is
`root=zfs:rpool/ROOT/<distro>`. The dracut `zfs` module inside the UKI imports
the pool and mounts the root dataset. The pool is exported cleanly at the end of
the install so it imports on first boot without a force flag.

Incus can then use the same pool for its storage (`incus admin init`, ZFS
backend, existing pool `rpool`), or a separate pool or dataset you create.

### ZFS encryption

- `ZFS_ENC=native` uses OpenZFS native encryption on `rpool/ROOT`. The passphrase
  is prompted in the initramfs at every boot. TPM auto-unlock is not offered for
  native encryption.
- `ZFS_ENC=luks` puts the pool inside a LUKS2 container, reusing the same TPM2
  auto-unlock path as the non-ZFS installs (see below).
- `ZFS_ENC=none` is an unencrypted pool.

## LUKS and TPM2 auto-unlock

For the non-ZFS filesystems and for `ZFS_ENC=luks`, LUKS creates a passphrase
(slot 0) and a `crypttab` entry with `tpm2-device=auto`. The system boots on the
passphrase until you add the TPM. TPM enrollment binds to the Secure Boot state
(PCR 7), which is only stable once the MOK is enrolled at MokManager, so it is a
post-boot step:

1. Install with LUKS and a passphrase. Reboot.
2. First boot stops in MokManager. Enroll the MOK (enter `MOKPW`) and continue.
3. Enter the LUKS passphrase, log in, then run the helper and reboot:

   ```sh
   incus-tpm-enroll
   reboot
   ```

The root then unlocks from the TPM with no passphrase. The policy is signed
against PCR 11, so kernel and command-line changes do not break it.

## Secure Boot

Secure Boot is on by default. The installer keeps the firmware's Microsoft keys
and adds its own MOK. On the first boot the machine stops in MokManager (the blue
shim screen) to enroll the MOK; choose to enroll the key and enter the `MOKPW`
password. This one-time step lets the same key verify the UKI, systemd-boot, and
DKMS modules.

## Changing the kernel command line later

The kernel command line lives in `/etc/kernel/cmdline`. To change it:

```sh
$EDITOR /etc/kernel/cmdline
incus-uki-rebuild
reboot
```

`incus-uki-rebuild` regenerates the initramfs and rebuilds and re-signs the UKI
for every installed kernel (pass a version to do one). Run it after changing
`/etc/kernel/cmdline` or anything under `/etc/dracut.conf.d`. GRUB is not used and
`/etc/cmdline.d/*` is not read for UKIs; `/etc/kernel/cmdline` is the one source.

## Tested configurations

End-to-end boot verified (installed, rebooted, root mounted, logged in):

- Debian trixie + Zabbly kernel + ZFS root (unencrypted) + Incus, Secure Boot off:
  boots from the signed UKI, `rpool/ROOT/debian` mounts as root, `linux-zabbly` is
  the running kernel, Incus 7.2 is installed.
- Debian trixie + Zabbly kernel + ZFS root with **native encryption** + Incus: the
  dracut `zfs` module prompts for the passphrase in the initramfs, unlocks
  `rpool/ROOT`, and boots to login.

Implemented and installs cleanly, further boot validation in progress:

- ZFS LUKS encryption (shares the proven crypttab/TPM2 path), the stock-kernel
  combinations, Ubuntu (resolute), the non-ZFS filesystems, and Secure Boot with
  MOK enrollment.

The Secure Boot + LUKS + TPM2 auto-unlock chain is shared, unchanged, with
[proxmox-uki-installer](https://github.com/cmspam/proxmox-uki-installer), where it
is validated on real hardware. `testmatrix.sh` exercises the combinations against a
spare disk on a disposable VM.

## License

MIT
