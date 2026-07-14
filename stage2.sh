#!/bin/bash
# Runs inside the chroot on the freshly debootstrapped Debian/Ubuntu target.
#
# Boot design (from proxmox-uki-installer, proven):
#   firmware -> shim + MOK -> systemd-boot -> signed UKI
#   UKI = dracut initrd wrapped by ukify, signed for Secure Boot (MOK) AND
#         carrying a signed PCR policy (.pcrsig/.pcrpkey) so a TPM LUKS seal is
#         bound to the PCR-signing public key and survives kernel upgrades.
#   One MOK signs the UKI, systemd-boot, and DKMS modules (zfs, etc).
#
# Zabbly/Incus/ZFS additions:
#   kernel  = linux-zabbly (default) or the distro stock kernel (KERNEL=stock)
#   zfs     = openzfs-zfs-dkms (zabbly) / zfs-dkms (debian contrib) / bundled (ubuntu stock)
#   incus   = from the zabbly incus repo
#   FS=zfs  -> root on ZFS (rpool/ROOT/<distro>), dracut 90zfs, root=zfs: cmdline.
#
# The UKI is (re)built by our zz-ukify kernel hook; a FINAL explicit rebuild at
# the end guarantees the DKMS zfs module and the final cmdline are baked in.
set -euo pipefail
. /root/install.env
export DEBIAN_FRONTEND=noninteractive
KDIR=/var/lib/sbkeys

log(){ printf '\n\033[1;33m--- %s\033[0m\n' "$*"; }

# ---------- apt noninteractive ----------
cat > /etc/apt/apt.conf.d/90noninteractive <<'EOF'
APT::Get::Assume-Yes "true";
Dpkg::Options { "--force-confdef"; "--force-confold"; }
EOF

# ---------- identity ----------
log "hostname"
echo "$HOSTNAME_" > /etc/hostname
printf '127.0.0.1 localhost\n127.0.1.1 %s\n' "$HOSTNAME_" > /etc/hosts

# ---------- fstab ----------
log "fstab"
{
  if [ "$FS" = zfs ]; then
    echo "# root is on ZFS ($ROOT_DATASET), mounted via root=zfs: and the dataset mountpoint"
  else
    btrfs_opts=""
    [ "$FS" = btrfs ] && btrfs_opts=",subvol=@,${BTRFS_OPTS:-compress=zstd:1,noatime,space_cache=v2,discard=async}"
    echo "UUID=$ROOT_UUID / $FS defaults${btrfs_opts} 0 1"
  fi
  echo "UUID=$ESP_UUID /boot/efi vfat umask=0077 0 2"
} > /etc/fstab

# ---------- apt sources (distro base) ----------
log "apt sources ($DISTRO $SUITE)"
if [ "$DISTRO" = ubuntu ]; then
  cat > /etc/apt/sources.list <<EOF
deb $MIRROR $SUITE main universe
deb $MIRROR $SUITE-updates main universe
deb http://security.ubuntu.com/ubuntu $SUITE-security main universe
EOF
else
  cat > /etc/apt/sources.list <<EOF
deb $MIRROR $SUITE main contrib
deb $MIRROR $SUITE-updates main contrib
deb http://security.debian.org/debian-security $SUITE-security main contrib
EOF
  if [ "$KERNEL" = stock ]; then
    echo "deb $MIRROR $SUITE-backports main contrib" >> /etc/apt/sources.list
  fi
fi
apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg >/dev/null

# ---------- zabbly repos (key + kernel/incus/zfs) ----------
install -d /etc/apt/keyrings
curl -fsSL https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc
ARCH=$(dpkg --print-architecture)
zabbly_src(){ # zabbly_src NAME PATH COMPONENTS
  cat > "/etc/apt/sources.list.d/zabbly-$1.sources" <<EOF
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/$2
Suites: $SUITE
Components: $3
Architectures: $ARCH
Signed-By: /etc/apt/keyrings/zabbly.asc
EOF
}
if [ "$KERNEL" = zabbly ]; then
  # kernel + (for FS=zfs) the zabbly OpenZFS packages live in the same repo.
  if [ "$FS" = zfs ]; then zabbly_src kernel kernel/stable "main zfs"; else zabbly_src kernel kernel/stable "main"; fi
elif [ "$FS" = zfs ] && [ "$DISTRO" = debian ]; then
  : # debian stock uses contrib zfs-dkms; no zabbly kernel repo
fi
if [ "$INCUS" = yes ]; then zabbly_src incus "incus/$INCUS_CHANNEL" main; fi
apt-get update -qq

# ---------- prevent service starts during chroot config ----------
# policy-rc.d stops invoke-rc.d/deb-systemd-invoke from starting services, but
# some packages (e.g. incus-base) call `systemctl enable --now` directly, and
# `--now` fails hard in a chroot ("systemd is not running"). Shadow systemctl
# with a shim on PATH (/usr/local/bin precedes /usr/bin for maintainer scripts):
# it drops --now and no-ops runtime actions, so `enable` still writes its symlink
# while nothing is started. Removed at the end, before we enable services for real.
cat > /usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x /usr/sbin/policy-rc.d
cat > /usr/local/bin/systemctl <<'EOF'
#!/bin/sh
args=""
for a in "$@"; do [ "$a" = "--now" ] && continue; args="$args $a"; done
case " $args " in
  *" start "*|*" restart "*|*" reload "*|*" try-restart "*|*" reload-or-restart "*) exit 0 ;;
esac
exec /usr/bin/systemctl $args
EOF
chmod +x /usr/local/bin/systemctl

# ---------- boot + UKI toolchain ----------
log "install boot/UKI toolchain"
apt-get install -y -qq \
  dracut systemd-boot systemd-boot-efi systemd-ukify sbsigntool shim-signed \
  cryptsetup tpm2-tools efibootmgr openssl

# ---------- durably divert competing boot hooks (now that they exist).
#            Debian/Ubuntu's systemd-boot package wires kernel-install, whose
#            zz-systemd-boot hook builds a second (competing) initrd + a loose
#            Type-1 loader entry next to our UKI. We drive the ESP + UKI ourselves
#            (systemd-boot + zz-ukify), so divert the competitors. dpkg-divert is
#            durable across upgrades; nothing is pinned. ----------
log "divert competing boot hooks (durable)"
for h in /etc/kernel/postinst.d/zz-systemd-boot /etc/kernel/postinst.d/kdump-tools \
         /etc/initramfs/post-update.d/systemd-boot; do
  [ -e "$h" ] || continue
  dpkg-divert --add --rename --divert "${h}.disabled" "$h" >/dev/null 2>&1 || true
done

# ---------- signing keys: MOK (Secure Boot + DKMS) and PCR (policy).
#            Do this BEFORE installing any DKMS module (zfs) so the build is
#            MOK-signed and loads under Secure Boot lockdown. ----------
log "generate MOK + PCR keys"
mkdir -p "$KDIR"
if [ ! -f "$KDIR/MOK.key" ]; then
  openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$KDIR/MOK.key" -out "$KDIR/MOK.crt" -subj "/CN=Incus UKI MOK/" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=digitalSignature" \
    -addext "extendedKeyUsage=codeSigning"
  openssl x509 -in "$KDIR/MOK.crt" -outform DER -out "$KDIR/MOK.cer"
fi
if [ ! -f "$KDIR/pcr.key" ]; then
  openssl genrsa -out "$KDIR/pcr.key" 2048
  openssl rsa -in "$KDIR/pcr.key" -pubout -out "$KDIR/pcr.pub"
fi
chmod 600 "$KDIR"/*.key

# DKMS modules signed with the same MOK.
log "dkms signing via MOK"
mkdir -p /etc/dkms
cat > /etc/dkms/framework.conf <<EOF
mok_signing_key=$KDIR/MOK.key
mok_certificate=$KDIR/MOK.crt
EOF

# ---------- dracut config (crypt/lvm/tpm2/zfs as needed) ----------
log "dracut config (hostonly=${HOSTONLY:-no})"
mkdir -p /etc/dracut.conf.d
{
  echo "hostonly=\"${HOSTONLY:-no}\""
  # NB: the zfs dracut module is added later (18-zfs.conf), after the OpenZFS
  # packages are installed — forcing it here would break the kernel's own initrd
  # build (zz-ukify) since the module + zpool would not yet exist.
  mods="systemd"
  [ "$USE_LUKS" = yes ] && mods="$mods crypt tpm2-tss"
  [ "$USE_LVM" = yes ] && mods="$mods lvm"
  echo "add_dracutmodules+=\" $mods \""
} > /etc/dracut.conf.d/10-uki.conf

# ---------- crypttab for TPM auto-unlock (LUKS; incl. ZFS-on-LUKS) ----------
if [ "$USE_LUKS" = yes ]; then
  log "crypttab (tpm2-device=auto)"
  echo "cryptroot UUID=${LUKS_UUID} none luks,discard,tpm2-device=auto" > /etc/crypttab
  echo 'install_items+=" /etc/crypttab "' > /etc/dracut.conf.d/15-crypttab.conf
fi

# ---------- ZFS: stable hostid so the initramfs imports the pool without -f.
#            install.sh copied the live-env hostid (the one that created the pool)
#            to /etc/hostid; generate one only if that did not happen. The dracut
#            zfs module itself is configured later, after OpenZFS is installed. ----------
if [ "$FS" = zfs ]; then
  [ -s /etc/hostid ] || zgenhostid 2>/dev/null || true
fi

# ---------- kernel cmdline (authoritative source for the UKI) ----------
echo "$CMDLINE" > /etc/kernel/cmdline

# ---------- our UKI hook: wrap+sign whatever initrd dracut built ----------
log "install zz-ukify hook"
mkdir -p /etc/kernel/postinst.d /etc/kernel/postrm.d /boot/efi/EFI/Linux
cat > /etc/kernel/postinst.d/zz-ukify <<'HOOK'
#!/bin/sh
set -e
version="$1"
[ -n "$version" ] || exit 0
KDIR=/var/lib/sbkeys
mkdir -p /boot/efi/EFI/Linux
exec /usr/lib/systemd/ukify build \
  --linux="/boot/vmlinuz-$version" \
  --initrd="/boot/initrd.img-$version" \
  --cmdline="@/etc/kernel/cmdline" \
  --uname="$version" \
  --secureboot-private-key="$KDIR/MOK.key" \
  --secureboot-certificate="$KDIR/MOK.crt" \
  --pcr-private-key="$KDIR/pcr.key" \
  --pcr-public-key="$KDIR/pcr.pub" \
  --pcrpkey="$KDIR/pcr.pub" \
  --pcr-banks=sha256 \
  --output="/boot/efi/EFI/Linux/incus-$version.efi"
HOOK
cat > /etc/kernel/postrm.d/zz-ukify <<'HOOK'
#!/bin/sh
version="$1"
[ -n "$version" ] || exit 0
rm -f "/boot/efi/EFI/Linux/incus-$version.efi"
HOOK
chmod +x /etc/kernel/postinst.d/zz-ukify /etc/kernel/postrm.d/zz-ukify

# ---------- rebuild helper (regenerate initrd + re-sign UKI after changes) ----------
log "install incus-uki-rebuild helper"
install -d /usr/local/sbin
cat > /usr/local/sbin/incus-uki-rebuild <<'HELP'
#!/bin/sh
# Rebuild and re-sign the UKI after editing /etc/kernel/cmdline or the dracut
# config, or after a DKMS module change. No argument rebuilds every installed
# kernel; pass a version to rebuild just one. Reboot afterwards.
set -e
HOOK=/etc/kernel/postinst.d/zz-ukify
[ -x "$HOOK" ] || { echo "missing $HOOK"; exit 1; }
build() {
  v="$1"
  [ -e "/boot/vmlinuz-$v" ] || { echo "no kernel /boot/vmlinuz-$v"; return 1; }
  echo "rebuilding initrd + UKI for $v"
  dracut --force "/boot/initrd.img-$v" "$v"
  "$HOOK" "$v"
}
if [ -n "$1" ]; then
  build "$1"
else
  for k in /boot/vmlinuz-*; do [ -e "$k" ] || continue; build "${k#/boot/vmlinuz-}"; done
fi
echo "done. reboot to apply."
HELP
chmod +x /usr/local/sbin/incus-uki-rebuild

# ---------- install the kernel (fires dracut + zz-ukify) ----------
log "install kernel ($KERNEL)"
case "$KERNEL" in
  zabbly)
    apt-get install -y -qq linux-zabbly
    ;;
  stock)
    if [ "$DISTRO" = ubuntu ]; then
      apt-get install -y -qq linux-generic
    elif [ "$FS" = zfs ]; then
      # Debian's contrib zfs-dkms tracks the STOCK trixie kernel; the newer
      # trixie-backports kernel can outpace it and fail to build. So a ZFS root on
      # the stock kernel uses trixie's own kernel. (For a newer kernel with ZFS on
      # Debian, use KERNEL=zabbly, which ships a matched OpenZFS.)
      apt-get install -y -qq linux-image-amd64 linux-headers-amd64
    else
      # non-ZFS: take the newer kernel from trixie-backports
      apt-get install -y -qq -t "${SUITE}-backports" linux-image-amd64 linux-headers-amd64
    fi
    ;;
esac

# ---------- ZFS packages (after the kernel + framework.conf so DKMS is signed) ----------
if [ "$FS" = zfs ]; then
  log "install ZFS"
  if [ "$KERNEL" = zabbly ]; then
    apt-get install -y -qq openzfs-zfsutils openzfs-zfs-dkms openzfs-zfs-dracut openzfs-zfs-zed
  elif [ "$DISTRO" = debian ]; then
    apt-get install -y -qq zfsutils-linux zfs-dkms zfs-dracut zfs-zed
  else
    # ubuntu stock: zfs.ko is bundled in linux-modules; only userland + dracut glue
    apt-get install -y -qq zfsutils-linux zfs-zed
    apt-get install -y -qq zfs-dracut 2>/dev/null || true
  fi
  # Now that the zfs dracut module (90zfs) + zpool exist, enable them for the
  # initramfs. The final rebuild below bakes zfs.ko + the pool import into the UKI.
  {
    echo 'add_dracutmodules+=" zfs "'
    echo 'install_items+=" /etc/hostid "'
  } > /etc/dracut.conf.d/18-zfs.conf
fi

# ---------- Incus ----------
if [ "$INCUS" = yes ]; then
  log "install incus ($INCUS_CHANNEL)"
  apt-get install -y -qq incus
fi

# ---------- filesystem tools (non-zfs mgmt + secondary disks) ----------
log "install filesystem tools"
apt-get install -y -qq btrfs-progs xfsprogs e2fsprogs

# ---------- base server bits (remote access) ----------
log "install openssh-server"
apt-get install -y -qq openssh-server
# a fresh hypervisor needs an initial way in; allow root over SSH (harden later:
# add a key + set PermitRootLogin prohibit-password). Same posture as Proxmox.
mkdir -p /etc/ssh/sshd_config.d
echo "PermitRootLogin yes" > /etc/ssh/sshd_config.d/10-root.conf
systemctl enable ssh.service >/dev/null 2>&1 || true

# ---------- FINAL rebuild: guarantee the UKI has the DKMS zfs module + final
#            cmdline/crypttab baked in (the kernel's own hook may have run before
#            zfs-dkms was built). ----------
log "final UKI rebuild"
/usr/local/sbin/incus-uki-rebuild

# ---------- place the loader in the ESP ----------
log "install loader (SECUREBOOT=$SECUREBOOT)"
mkdir -p /boot/efi/EFI/systemd /boot/efi/EFI/BOOT /boot/efi/loader/entries
sbsign --key "$KDIR/MOK.key" --cert "$KDIR/MOK.crt" \
  --output /boot/efi/EFI/systemd/systemd-bootx64.efi \
  /usr/lib/systemd/boot/efi/systemd-bootx64.efi
if [ "$SECUREBOOT" = yes ]; then
  cp /usr/lib/shim/shimx64.efi.signed /boot/efi/EFI/BOOT/BOOTX64.EFI
  cp /usr/lib/shim/mmx64.efi.signed  /boot/efi/EFI/BOOT/mmx64.efi
  cp /boot/efi/EFI/systemd/systemd-bootx64.efi /boot/efi/EFI/BOOT/grubx64.efi
  BOOT_LOADER='\EFI\BOOT\BOOTX64.EFI'
else
  cp /boot/efi/EFI/systemd/systemd-bootx64.efi /boot/efi/EFI/BOOT/BOOTX64.EFI
  BOOT_LOADER='\EFI\BOOT\BOOTX64.EFI'
fi
cat > /boot/efi/loader/loader.conf <<'EOF'
timeout 3
console-mode max
EOF

# NVRAM entry (test harness selects the disk via hypervisor boot-order, so skip)
if [ "${SKIP_NVRAM:-no}" != yes ]; then
  DISK=$(echo "$P2" | sed -E 's/p?[0-9]+$//')
  efibootmgr -c -d "$DISK" -p 1 -L "Incus UKI" -l "$BOOT_LOADER" 2>/dev/null || \
    echo "note: efibootmgr NVRAM write skipped (EFI/BOOT fallback in use)"
fi

# ---------- MOK enrollment + trust request (Secure Boot) ----------
MOKPW="${MOKPW:-12345678}"
if [ "$SECUREBOOT" = yes ]; then
  log "request MOK enrollment + trust (MokManager prompts at first boot)"
  printf '%s\n%s\n' "$MOKPW" "$MOKPW" | mokutil --import "$KDIR/MOK.cer" || \
    echo "note: mokutil --import staged (enroll at console)"
  printf '%s\n%s\n' "$MOKPW" "$MOKPW" | mokutil --trust-mok || \
    echo "note: mokutil --trust-mok staged (confirm at console)"
fi

# ---------- TPM2 LUKS auto-unlock helper (post-boot, LUKS incl. ZFS-on-LUKS) ----------
if [ "$USE_LUKS" = yes ]; then
  log "install post-boot TPM enroll helper"
  install -d /usr/local/sbin
  cat > /usr/local/sbin/incus-tpm-enroll <<EOF
#!/bin/sh
# Enroll the LUKS root for TPM2 auto-unlock. Run ONCE after the first boot
# (unlocked with the passphrase), so PCR 11 reflects the real measured boot.
set -e
DEV=\$(cryptsetup status cryptroot 2>/dev/null | sed -n 's/^ *device: *//p')
[ -n "\$DEV" ] || { echo "cryptroot not active"; exit 1; }
systemd-cryptenroll --wipe-slot=tpm2 "\$DEV" 2>/dev/null || true
systemd-cryptenroll --tpm2-device=auto \\
  --tpm2-public-key=${KDIR}/pcr.pub --tpm2-public-key-pcrs=11 "\$DEV"
echo "Enrolled. Reboot; it should unlock via TPM with no passphrase."
EOF
  chmod +x /usr/local/sbin/incus-tpm-enroll
fi

# ---------- ZFS services (import + mount at boot) ----------
if [ "$FS" = zfs ]; then
  log "enable zfs services"
  systemctl enable zfs-import-scan.service zfs-import.target zfs-mount.service \
    zfs-zed.service zfs.target >/dev/null 2>&1 || true
fi

# ---------- Incus service ----------
if [ "$INCUS" = yes ]; then
  systemctl enable incus.service incus.socket >/dev/null 2>&1 || true
fi

# ---------- root password + serial console ----------
log "root password + serial getty"
echo "root:$ROOTPW" | chpasswd
systemctl enable serial-getty@ttyS0.service >/dev/null 2>&1 || true

# ---------- remove chroot service guards ----------
rm -f /usr/sbin/policy-rc.d /usr/local/bin/systemctl

# ---------- report ----------
log "RESULT"
echo "distro: $DISTRO $SUITE   kernel: $KERNEL"
echo "kernel(s):"; ls /boot/vmlinuz-* 2>/dev/null || echo "  NONE"
echo "UKI(s):"; ls -la /boot/efi/EFI/Linux/ 2>&1
echo "UKI sections:"; for u in /boot/efi/EFI/Linux/*.efi; do objdump -h "$u" 2>/dev/null | grep -oE "\.(linux|initrd|cmdline|osrel|pcrsig|pcrpkey|sbat|uname)" | tr '\n' ' '; echo; done
echo "UKI SB-signed by MOK?"; for u in /boot/efi/EFI/Linux/*.efi; do sbverify --cert "$KDIR/MOK.crt" "$u" 2>&1 | head -1; done
if [ "$FS" = zfs ]; then
  echo "zfs dracut module configured:"; grep -h zfs /etc/dracut.conf.d/*.conf 2>/dev/null | tr '\n' ' '; echo
  echo "zfs.ko built:"; find /lib/modules -name 'zfs.ko*' 2>/dev/null | head -1 || echo "  (bundled/stock module)"
  echo "dkms:"; dkms status 2>/dev/null | grep zfs || echo "  (n/a)"
fi
echo "embedded cmdline:"; for u in /boot/efi/EFI/Linux/*.efi; do objcopy -O binary --only-section=.cmdline "$u" /dev/stdout 2>/dev/null; echo; done
echo "incus:"; command -v incus >/dev/null 2>&1 && incus --version || echo "  (not installed)"
