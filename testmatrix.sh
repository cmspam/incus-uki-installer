#!/bin/bash
# Test-matrix driver for the incus-uki-installer. Runs a set of DISTRO/KERNEL/FS
# combinations against the target disk (auto-detected as the whole disk NOT
# holding the live root; device names swap across reboots, so never hardcode),
# then inspects the on-disk result. Writes a consolidated report to RESULTS.txt.
#
# Meant for a disposable VM with two disks, not a real system. Each install runs
# in a PRIVATE mount namespace so its /mnt/target binds cannot leak into systemd
# and hold the target (or its ZFS pool) busy for the next run. All tests use
# SECUREBOOT=no (MokManager cannot be driven unattended); the SB build path is
# identical to the proxmox-uki-installer, which is validated separately.
set -u
INS=/mnt/insp
RES=/root/RESULTS.txt
: > "$RES"
say(){ printf '%s\n' "$*" | tee -a "$RES"; }

LIVEDISK=$(findmnt -nro SOURCE / | sed -E 's/p?[0-9]+$//')
DISK=$(lsblk -dpno NAME | grep -vE '/dev/(loop|sr|zram)' | grep -v "^${LIVEDISK}$" | head -1)
say "live root disk: $LIVEDISK ; TARGET disk: $DISK"
{ [ -n "$DISK" ] && [ "$DISK" != "$LIVEDISK" ] && [ -b "$DISK" ]; } || { echo "REFUSING: bad target ($DISK) vs live ($LIVEDISK)"; exit 1; }

cleanup_disk(){
  umount -R "$INS" 2>/dev/null
  umount -R /mnt/target 2>/dev/null
  swapoff -a 2>/dev/null
  # release any ZFS pool sitting on the target disk (and stop auto-import racing us)
  systemctl stop zfs-zed 2>/dev/null
  for p in $(zpool list -H -o name 2>/dev/null); do
    zpool status -P "$p" 2>/dev/null | grep -q "$DISK" && { zpool destroy -f "$p" 2>/dev/null || zpool export -f "$p" 2>/dev/null; }
  done
  cryptsetup close insp 2>/dev/null; cryptsetup close cryptroot 2>/dev/null
  for vg in $(vgs --noheadings -o vg_name 2>/dev/null | tr -d ' '); do
    vgchange -an "$vg" 2>/dev/null; vgremove -ff "$vg" 2>/dev/null
  done
  for p in ${DISK}*; do
    [ "$p" = "$DISK" ] && continue
    [ -b "$p" ] && { zpool labelclear -f "$p" 2>/dev/null; btrfs device scan --forget "$p" 2>/dev/null; wipefs -a "$p" 2>/dev/null; }
  done
  wipefs -a "$DISK" 2>/dev/null
  sgdisk --zap-all "$DISK" >/dev/null 2>&1
  partprobe "$DISK" 2>/dev/null; udevadm settle 2>/dev/null; sleep 1
}

# inspect the installed target and emit fstab/cmdline (and crypttab/zpool) lines
inspect(){
  local fs="$1" luks="$2" rp="$3" base dev
  mkdir -p "$INS"; base="$rp"
  if [ "$luks" = yes ]; then printf 'incus' | cryptsetup open "$rp" insp - 2>/dev/null; base=/dev/mapper/insp; fi
  if [ "$fs" = zfs ]; then
    zpool import -f -N -R "$INS" rpool 2>/dev/null
    zfs mount rpool/ROOT/debian 2>/dev/null || zfs mount rpool/ROOT/ubuntu 2>/dev/null
    say "  cmdline: $(cat "$INS"/etc/kernel/cmdline 2>/dev/null)"
    say "  datasets: $(zfs list -H -o name,mountpoint 2>/dev/null | grep -E 'rpool' | tr '\n' ' ')"
    say "  UKI: $(ls "$INS"/boot/efi/EFI/Linux/ 2>/dev/null | tr '\n' ' ')"
    umount -R "$INS" 2>/dev/null; zpool export rpool 2>/dev/null
    return
  fi
  if [ "$fs" = btrfs ]; then mount -o subvol=@ "$base" "$INS" 2>/dev/null; else mount "$base" "$INS" 2>/dev/null; fi
  say "  fstab  : $(grep -E ' / ' "$INS"/etc/fstab 2>/dev/null | tr -s ' ')"
  say "  cmdline: $(cat "$INS"/etc/kernel/cmdline 2>/dev/null)"
  [ "$luks" = yes ] && say "  crypttab: $(cat "$INS"/etc/crypttab 2>/dev/null)"
  umount -R "$INS" 2>/dev/null
  [ "$luks" = yes ] && cryptsetup close insp 2>/dev/null
}

# run_test NAME "ENV=v ..." FS LUKS
run_test(){
  local name="$1" envs="$2" fs="$3" luks="$4"
  say ""; say "======================================================================"
  say "TEST: $name"; say "  env: $envs"
  local log="/root/t_${name}.log"
  ( export NONINTERACTIVE=yes SECUREBOOT=no TARGET_DISK=$DISK SKIP_NVRAM=yes; eval "export $envs"
    unshare --mount --propagation private bash /root/install.sh ) > "$log" 2>&1
  local rc=$?
  say "  EXIT: $rc"
  say "  layout:"; lsblk -pno NAME,SIZE,PARTLABEL,FSTYPE "$DISK" 2>/dev/null | sed 's/^/    /' | tee -a "$RES" >/dev/null
  grep -E "UKI SB-signed|incus-.*\.efi|zfs.ko in initrd|diverted|INSTALL COMPLETE" "$log" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g; s/^/    /' | tee -a "$RES" >/dev/null
  if [ "$rc" = 0 ]; then inspect "$fs" "$luks" "${DISK}2"; else say "  (install failed; see $log)"; grep -iE "error|fail|busy|cannot" "$log" | tail -4 | sed 's/^/    /' | tee -a "$RES" >/dev/null; fi
}

########## the matrix ##########
cleanup_disk
run_test "debian_zabbly_zfs"        "DISTRO=debian KERNEL=zabbly FS=zfs ZFS_ENC=none  INCUS=yes" zfs no
cleanup_disk
run_test "debian_zabbly_zfs_native" "DISTRO=debian KERNEL=zabbly FS=zfs ZFS_ENC=native ZFSPW=incuspass INCUS=yes" zfs no
cleanup_disk
run_test "debian_zabbly_zfs_luks"   "DISTRO=debian KERNEL=zabbly FS=zfs ZFS_ENC=luks LUKSPW=incus INCUS=yes" zfs yes
cleanup_disk
run_test "debian_zabbly_ext4"       "DISTRO=debian KERNEL=zabbly FS=ext4 INCUS=yes" ext4 no
cleanup_disk
run_test "debian_stock_zfs"         "DISTRO=debian KERNEL=stock  FS=zfs ZFS_ENC=none INCUS=yes" zfs no
cleanup_disk
run_test "ubuntu_zabbly_zfs"        "DISTRO=ubuntu KERNEL=zabbly FS=zfs ZFS_ENC=none INCUS=yes" zfs no

say ""; say "======================================================================"
say "MATRIX COMPLETE"
