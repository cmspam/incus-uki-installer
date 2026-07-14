#!/usr/bin/env bash
#
# Debian/Ubuntu fresh-install with the Zabbly kernel, Incus and ZFS, booted by a
# signed UKI + systemd-boot + dracut. Optional ZFS root (native or LUKS-backed
# encryption), or ext4/xfs/btrfs with optional LVM/LUKS. Runs from any Linux live
# environment that has (or can install) the tools listed in check_tools.
#
# Interactive by default: any setting below not supplied in the environment is
# prompted for when stdin is a TTY (target disk from a menu; passwords twice,
# hidden). A value passed via the environment is used as-is and never prompted.
# Set NONINTERACTIVE=yes (or pipe a non-TTY) to take the defaults, which is how
# the automated tests drive it. Settings:
#
#   DISTRO        debian | ubuntu                                   [debian]
#                   debian -> trixie ; ubuntu -> resolute (26.04)
#   KERNEL        zabbly | stock                                    [zabbly]
#                   zabbly -> linux-zabbly + zabbly OpenZFS (DKMS)
#                   stock  -> debian: trixie-backports kernel + contrib zfs-dkms
#                             ubuntu: linux-generic + in-archive zfs (no DKMS)
#   FS            root filesystem: zfs | ext4 | xfs | btrfs         [zfs]
#   ZPOOL         ZFS pool name (FS=zfs)                            [rpool]
#   ZFS_ENC       none | native | luks   (FS=zfs encryption)        [none]
#                   native = OpenZFS native encryption (passphrase at boot)
#                   luks   = LUKS on the partition, pool inside it (TPM2 later)
#   INCUS         yes | no  (install Incus from the zabbly repo)    [yes]
#   INCUS_CHANNEL stable | daily | lts-6.0 | lts-7.0                [stable]
#
#   PART_MODE     auto | freespace | custom                         [auto]
#   TARGET_DISK   block device to install onto (auto/freespace)     [prompt]
#   ESP_PART      existing ESP partition (custom; reuse in freespace)  []
#   ROOT_PART     existing root partition (custom mode)             []
#   FORMAT_ESP    yes | no  (no = reuse/share an existing ESP)  [custom:no,else:yes]
#   ESP_SIZE      EFI partition size (auto/freespace)                [1GiB]
#   ROOT_PART_SIZE root partition size, e.g. 200G, or 'rest'        [rest]
#   BTRFS_OPTS    btrfs mount options (btrfs only)  [compress=zstd:1,noatime,space_cache=v2,discard=async]
#   USE_LVM       yes | no  (ext4/xfs/btrfs only)                   [no]
#   LVM_THIN      yes | no  (thin-provision the root LV; LVM only)  [no]
#   ROOT_SIZE     root LV size, e.g. 64GiB, or 100%FREE (LVM only)  [100%FREE]
#   USE_LUKS      yes | no  (ext4/xfs/btrfs only; zfs uses ZFS_ENC) [no]
#   SECUREBOOT    yes | no (shim+MOK chain; no = plain systemd-boot)[yes]
#   HOSTONLY      yes | no  (host-specific initramfs vs generic)    [no]
#   HOSTNAME_     target hostname                                   [incus]
#   ROOTPW        root password on the target                       [incus]
#   LUKSPW        LUKS passphrase (ZFS_ENC=luks or USE_LUKS)         [incus]
#   ZFSPW         ZFS native-encryption passphrase (ZFS_ENC=native) [incus]
#   MOKPW         one-time MokManager password (enroll+trust, 8..16) [12345678]
#   MIRROR        Debian/Ubuntu mirror                    [distro default]
#   EXTRA_CMDLINE extra kernel cmdline appended verbatim             []
#
set -euo pipefail

# Minimal live environments (Debian/Ubuntu install CDs) do not wire up /dev/fd,
# which bash process substitution needs. Ensure /proc and /dev/fd exist.
[ -e /proc/self/fd ] || mount -t proc proc /proc 2>/dev/null || true
[ -e /dev/fd ] || ln -sf /proc/self/fd /dev/fd 2>/dev/null || true

# ---------------- config ----------------
NONINTERACTIVE="${NONINTERACTIVE:-no}"
if [ "$NONINTERACTIVE" = yes ] || [ ! -t 0 ]; then INTERACTIVE=no; else INTERACTIVE=yes; fi

_set(){ [ -n "${!1+x}" ]; }   # true if the named variable came from the environment

ask(){ # ask VAR "question" "default" [choice ...]
  local var="$1" q="$2" def="$3"; shift 3
  _set "$var" && return 0
  if [ "$INTERACTIVE" != yes ]; then printf -v "$var" '%s' "$def"; return 0; fi
  local opts=("$@") i=1 o ans
  for o in "${opts[@]}"; do printf '  %d) %s\n' "$i" "$o"; i=$((i+1)); done
  read -r -p "$q [$def] > " ans
  [ -z "$ans" ] && ans="$def"
  if [ "${#opts[@]}" -gt 0 ] && [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "${#opts[@]}" ]; then
    ans="${opts[ans-1]}"
  fi
  printf -v "$var" '%s' "$ans"
}

ask_secret(){ # ask_secret VAR "label" DEFAULT MIN MAX(0=unbounded)
  local var="$1" label="$2" def="$3" min="${4:-1}" max="${5:-0}" p1 p2
  _set "$var" && return 0
  if [ "$INTERACTIVE" != yes ]; then printf -v "$var" '%s' "$def"; return 0; fi
  while :; do
    read -r -s -p "$label > " p1; printf '\n'
    [ "${#p1}" -lt "$min" ] && { echo "  must be at least $min characters"; continue; }
    [ "$max" -gt 0 ] && [ "${#p1}" -gt "$max" ] && { echo "  must be at most $max characters"; continue; }
    read -r -s -p "confirm $label > " p2; printf '\n'
    [ "$p1" != "$p2" ] && { echo "  does not match, try again"; continue; }
    printf -v "$var" '%s' "$p1"; break
  done
}

pick_disk(){ # interactive target-disk selection (command substitution; no /dev/fd)
  local disks=() line n ans d _ifs="$IFS"
  set -f; IFS='
'
  for line in $(lsblk -dpno NAME 2>/dev/null | grep -vE '/dev/(loop|sr|zram)'); do
    [ -n "$line" ] && disks+=("$line")
  done
  set +f; IFS="$_ifs"
  [ "${#disks[@]}" -eq 0 ] && { echo "no disks found"; exit 1; }
  echo "Available disks:"
  n=1; for d in "${disks[@]}"; do
    printf '  %d) %s\n' "$n" "$(lsblk -dpno NAME,SIZE,MODEL "$d" 2>/dev/null)"; n=$((n+1))
  done
  read -r -p "Select target disk (number or /dev path) > " ans
  if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "${#disks[@]}" ]; then
    printf -v TARGET_DISK '%s' "${disks[ans-1]}"
  else
    printf -v TARGET_DISK '%s' "$ans"
  fi
}

pick_part(){ # pick_part VAR "question" — choose an existing partition
  local var="$1" q="$2" parts=() p n ans _ifs="$IFS"
  set -f; IFS='
'
  for p in $(lsblk -pno NAME,TYPE 2>/dev/null | awk '$2=="part"{print $1}'); do
    [ -n "$p" ] && parts+=("$p")
  done
  set +f; IFS="$_ifs"
  if [ "${#parts[@]}" -gt 0 ]; then
    echo "Existing partitions:"
    n=1; for p in "${parts[@]}"; do printf '  %d) %s\n' "$n" "$(lsblk -pno NAME,SIZE,FSTYPE,PARTLABEL "$p" 2>/dev/null)"; n=$((n+1)); done
  fi
  read -r -p "$q (number or /dev path) > " ans
  if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "${#parts[@]}" ]; then
    printf -v "$var" '%s' "${parts[ans-1]}"
  else
    printf -v "$var" '%s' "$ans"
  fi
}

# ---- base distro + kernel ----
ask DISTRO "Base distribution" debian  debian ubuntu
ask KERNEL "Kernel"            zabbly  zabbly stock
case "$DISTRO" in
  debian) SUITE=trixie;   DEF_MIRROR=http://deb.debian.org/debian ;;
  ubuntu) SUITE=resolute; DEF_MIRROR=http://archive.ubuntu.com/ubuntu ;;
  *) echo "DISTRO must be debian or ubuntu"; exit 1 ;;
esac
MIRROR="${MIRROR:-$DEF_MIRROR}"

# ---- partitioning mode ----
ask PART_MODE "Partitioning mode" auto  auto freespace custom
if [ "$PART_MODE" = custom ]; then
  if ! _set ESP_PART; then
    [ "$INTERACTIVE" = yes ] || { echo "custom mode needs ESP_PART and ROOT_PART"; exit 1; }
    pick_part ESP_PART  "ESP partition (existing)"
  fi
  if ! _set ROOT_PART; then
    [ "$INTERACTIVE" = yes ] || { echo "custom mode needs ROOT_PART"; exit 1; }
    pick_part ROOT_PART "Root partition (existing)"
  fi
  ESP_PART="$(readlink -f "$ESP_PART")"; ROOT_PART="$(readlink -f "$ROOT_PART")"
  { [ -b "$ESP_PART" ] && [ -b "$ROOT_PART" ]; } || { echo "ESP_PART/ROOT_PART must be block devices"; exit 1; }
  ask FORMAT_ESP "Format the ESP? (no = reuse/share an existing one)" no  no yes
  TARGET_DISK="${TARGET_DISK:-$ROOT_PART}"   # for logging/summary only
else
  if ! _set TARGET_DISK; then
    [ "$INTERACTIVE" = yes ] || { echo "set TARGET_DISK, e.g. /dev/disk/by-id/..."; exit 1; }
    pick_disk
  fi
  TARGET_DISK="$(readlink -f "$TARGET_DISK")"
  [ -b "$TARGET_DISK" ] || { echo "TARGET_DISK $TARGET_DISK is not a block device"; exit 1; }
fi

# ---- filesystem + encryption ----
ask FS "Root filesystem" zfs  zfs ext4 btrfs xfs
if [ "$FS" = zfs ]; then
  ask ZPOOL   "ZFS pool name" rpool
  ask ZFS_ENC "ZFS encryption" none  none native luks
  USE_LVM=no; LVM_THIN=no; ROOT_SIZE=100%FREE
  case "$ZFS_ENC" in
    luks) USE_LUKS=yes ;;
    none|native) USE_LUKS=no ;;
    *) echo "ZFS_ENC must be none, native or luks"; exit 1 ;;
  esac
else
  ZPOOL="${ZPOOL:-rpool}"; ZFS_ENC=none
  ask USE_LVM "Use LVM?" no  no yes
  if [ "$USE_LVM" = yes ]; then
    ask LVM_THIN  "LVM thin provisioning?" no  no yes
    ask ROOT_SIZE "Root LV size (e.g. 100G, 100%FREE)" 100%FREE
  else
    LVM_THIN="${LVM_THIN:-no}"; ROOT_SIZE="${ROOT_SIZE:-100%FREE}"
  fi
  ask USE_LUKS "Encrypt root with LUKS?" no  no yes
fi

ask INCUS "Install Incus?" yes  yes no
if [ "$INCUS" = yes ]; then ask INCUS_CHANNEL "Incus channel" stable  stable daily lts-6.0 lts-7.0
else INCUS_CHANNEL="${INCUS_CHANNEL:-stable}"; fi

ask SECUREBOOT "Secure Boot (shim + MOK)?"   yes   yes no
ask HOSTONLY   "Host-specific initramfs (vs generic)?" no  no yes
ask HOSTNAME_  "Hostname"                    incus

ask_secret ROOTPW "root password" incus 1 0
if [ "$USE_LUKS" = yes ]; then ask_secret LUKSPW "LUKS passphrase" incus 1 0; else LUKSPW="${LUKSPW:-incus}"; fi
if [ "$ZFS_ENC" = native ]; then ask_secret ZFSPW "ZFS encryption passphrase (min 8)" incus 8 0; else ZFSPW="${ZFSPW:-incus}"; fi
if [ "$SECUREBOOT" = yes ]; then ask_secret MOKPW "MokManager password (8..16 chars)" 12345678 8 16; else MOKPW="${MOKPW:-12345678}"; fi
case "${#MOKPW}" in 8|9|10|11|12|13|14|15|16) ;; *) echo "MOKPW must be 8..16 characters (mokutil limit); got ${#MOKPW}"; exit 1 ;; esac

if [ "$PART_MODE" != custom ]; then
  ask ESP_SIZE       "ESP size"  1GiB
  ask ROOT_PART_SIZE "Root partition size (e.g. 200G, or 'rest' for the remainder)"  rest
fi

BTRFS_OPTS="${BTRFS_OPTS:-compress=zstd:1,noatime,space_cache=v2,discard=async}"
ESP_SIZE="${ESP_SIZE:-1GiB}"
ROOT_PART_SIZE="${ROOT_PART_SIZE:-rest}"
ESP_PART="${ESP_PART:-}"
ROOT_PART="${ROOT_PART:-}"
SKIP_NVRAM="${SKIP_NVRAM:-no}"
EXTRA_CMDLINE="${EXTRA_CMDLINE:-}"
VG=incus
MNT=/mnt/target

log(){ printf '\n\033[1;36m### %s\033[0m\n' "$*"; }

part(){ # partition device name for a disk + index (handles nvme/mmc p-suffix)
  case "$TARGET_DISK" in
    *nvme*|*mmcblk*|*loop*) echo "${TARGET_DISK}p$1" ;;
    *) echo "${TARGET_DISK}$1" ;;
  esac
}

zap_pools_on(){ # export/destroy any imported zpool whose vdevs live on this disk
  command -v zpool >/dev/null 2>&1 || return 0
  local disk="$1" p
  for p in $(zpool list -H -o name 2>/dev/null); do
    if zpool status -P "$p" 2>/dev/null | grep -q "${disk}"; then
      zpool destroy -f "$p" 2>/dev/null || zpool export -f "$p" 2>/dev/null || true
    fi
  done
}

teardown(){ # release all mounts / LVM / LUKS / zpool this script may hold (idempotent)
  set +e
  # a cleanly EXPORTED pool imports on any host with no -f; always try to export.
  if [ "$FS" = zfs ] && command -v zpool >/dev/null 2>&1; then
    zfs unmount -a 2>/dev/null
    zpool export "$ZPOOL" 2>/dev/null
  fi
  umount -R "$MNT" 2>/dev/null || umount -Rl "$MNT" 2>/dev/null
  swapoff -a 2>/dev/null
  for vg in $(vgs --noheadings -o vg_name 2>/dev/null | tr -d ' '); do
    vgchange -an "$vg" 2>/dev/null
  done
  cryptsetup close cryptroot 2>/dev/null
  set -e
}
trap teardown EXIT

# ---------------- 0a. ensure the live-env front-half tools exist ----------------
need="debootstrap cryptsetup gdisk dosfstools parted"
[ "$FS" = btrfs ] && need="$need btrfs-progs"
[ "$FS" = xfs ] && need="$need xfsprogs"
[ "$FS" = zfs ] && need="$need zfsutils-linux"
[ "$USE_LVM" = yes ] && need="$need lvm2"
[ "$LVM_THIN" = yes ] && need="$need thin-provisioning-tools"
missing=""
for t in $need; do
  case "$t" in
    zfsutils-linux) command -v zpool >/dev/null 2>&1 || missing="$missing $t" ;;
    *) dpkg -s "$t" >/dev/null 2>&1 || missing="$missing $t" ;;
  esac
done
if [ -n "$missing" ]; then
  log "installing live-env tools:$missing"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get install -y -qq $missing || true
fi
# ZFS needs the kernel module loaded in the LIVE environment to create the pool.
if [ "$FS" = zfs ]; then
  modprobe zfs 2>/dev/null || true
  if ! zpool version >/dev/null 2>&1; then
    echo "ERROR: ZFS is not available in this live environment (zpool/zfs.ko missing)."
    echo "Run the installer from a live image that has working ZFS (zpool status must run),"
    echo "or install zfsutils-linux + the matching zfs module and 'modprobe zfs' first."
    exit 1
  fi
fi

# debootstrap needs the target distro's archive keyring to verify the Release
# file. A same-family live env (Debian ISO for Debian, Ubuntu ISO for Ubuntu)
# already has it; a cross-family live env may not, so try to add it and, failing
# that, fall back to an unverified bootstrap (--no-check-gpg) rather than abort.
DEBOOTSTRAP_ARGS=""
if [ "$DISTRO" = ubuntu ]; then
  KR=/usr/share/keyrings/ubuntu-archive-keyring.gpg
  [ -f "$KR" ] || apt-get install -y -qq ubuntu-keyring 2>/dev/null || true
  # debootstrap ships Ubuntu suites as symlinks to the 'gutsy' script; create it
  # if this suite is unknown to the local debootstrap.
  SCR=/usr/share/debootstrap/scripts
  if [ -d "$SCR" ] && [ ! -e "$SCR/$SUITE" ] && [ -e "$SCR/gutsy" ]; then
    ln -sf gutsy "$SCR/$SUITE" 2>/dev/null || true
  fi
else
  KR=/usr/share/keyrings/debian-archive-keyring.gpg
  [ -f "$KR" ] || apt-get install -y -qq debian-archive-keyring 2>/dev/null || true
fi
if [ -f "$KR" ]; then DEBOOTSTRAP_ARGS="--keyring=$KR"; else DEBOOTSTRAP_ARGS="--no-check-gpg"; fi

# ---------------- 0b. summary + destructive confirmation ----------------
case "$PART_MODE" in
  auto)      _tgt="$TARGET_DISK  (WHOLE DISK WILL BE WIPED)"; _sz="ESP $ESP_SIZE + root $ROOT_PART_SIZE" ;;
  freespace) _tgt="$TARGET_DISK  (new partitions in free space; others kept)"; _sz="ESP $ESP_SIZE + root $ROOT_PART_SIZE" ;;
  custom)    if [ "$FORMAT_ESP" = yes ]; then _en=", ESP too"; else _en=""; fi
             _tgt="ESP=$ESP_PART root=$ROOT_PART  (existing; root will be formatted${_en})"; _sz="existing partitions" ;;
esac
if [ "$FS" = zfs ]; then
  _fsline="zfs (pool $ZPOOL, enc=$ZFS_ENC)"
else
  _fsline="$FS$( [ "$FS" = btrfs ] && echo " (subvol @, $BTRFS_OPTS)" )$( [ "$USE_LVM" = yes ] && echo "  on LVM$( [ "$LVM_THIN" = yes ] && echo " (thin)" ), root LV=$ROOT_SIZE" )$( [ "$USE_LUKS" = yes ] && echo "  LUKS" )"
fi
cat <<SUMMARY

  Distro      : $DISTRO ($SUITE)   kernel: $KERNEL
  Mode        : $PART_MODE
  Target      : $_tgt
  Layout      : $_sz
  Filesystem  : $_fsline
  Incus       : $INCUS$( [ "$INCUS" = yes ] && echo " ($INCUS_CHANNEL)" )
  Secure Boot : $SECUREBOOT$( [ "$SECUREBOOT" = yes ] && echo "  (shim + MOK, confirm at MokManager)" )
  Initramfs   : $( [ "$HOSTONLY" = yes ] && echo host-specific || echo generic )
  Hostname    : $HOSTNAME_

SUMMARY
if [ "$INTERACTIVE" = yes ]; then
  read -r -p "Type YES (uppercase) to proceed (this formats the root partition): " _ok
  [ "$_ok" = YES ] || { echo "aborted."; exit 1; }
fi

# ---------------- 0c. cleanup ----------------
teardown

# ---------------- 1. partition / locate ESP + root ----------------
esp_label=incusuki-esp; root_label=incusuki-root
esp_end=$( case "$ESP_SIZE" in rest|max|100%*|"") echo 0 ;; *) echo "+${ESP_SIZE}" ;; esac )
case "$PART_MODE" in
  auto)
    log "partitioning $TARGET_DISK (auto wipe; ESP ${ESP_SIZE} + root ${ROOT_PART_SIZE})"
    zap_pools_on "$TARGET_DISK"   # release any imported ZFS pool on this disk
    dd if=/dev/zero of="$TARGET_DISK" bs=1M count=16 conv=fsync 2>/dev/null || true
    dsz=$(blockdev --getsize64 "$TARGET_DISK" 2>/dev/null || echo 0)
    if [ "$dsz" -gt 33554432 ]; then
      dd if=/dev/zero of="$TARGET_DISK" bs=1M count=16 seek=$(( dsz/1048576 - 16 )) conv=fsync 2>/dev/null || true
    fi
    wipefs -a "$TARGET_DISK" 2>/dev/null || true
    sgdisk --zap-all "$TARGET_DISK" >/dev/null 2>&1 || true
    partprobe "$TARGET_DISK" 2>/dev/null || true; sleep 1
    sgdisk -n1:0:"${esp_end}" -t1:ef00 -c1:"$esp_label" "$TARGET_DISK"
    case "$ROOT_PART_SIZE" in
      rest|max|100%|100%FREE|"") sgdisk -n2:0:0 -t2:8304 -c2:"$root_label" "$TARGET_DISK" ;;
      *)                         sgdisk -n2:0:+"${ROOT_PART_SIZE}" -t2:8304 -c2:"$root_label" "$TARGET_DISK" ;;
    esac
    partprobe "$TARGET_DISK"; udevadm settle 2>/dev/null || sleep 1
    ESP=$(readlink -f "/dev/disk/by-partlabel/$esp_label")
    P2=$(readlink -f "/dev/disk/by-partlabel/$root_label")
    ;;
  freespace)
    log "partitioning $TARGET_DISK (freespace; keeping existing partitions)"
    if [ -n "$ESP_PART" ]; then
      ESP="$(readlink -f "$ESP_PART")"
      [ "${FORMAT_ESP:-}" = yes ] || FORMAT_ESP=no
    else
      sgdisk -n0:0:"${esp_end}" -t0:ef00 -c0:"$esp_label" "$TARGET_DISK"
    fi
    case "$ROOT_PART_SIZE" in
      rest|max|100%|100%FREE|"") sgdisk --largest-new=0 -t0:8304 -c0:"$root_label" "$TARGET_DISK" ;;
      *)                         sgdisk -n0:0:+"${ROOT_PART_SIZE}" -t0:8304 -c0:"$root_label" "$TARGET_DISK" ;;
    esac
    partprobe "$TARGET_DISK"; udevadm settle 2>/dev/null || sleep 1
    [ -n "$ESP_PART" ] || ESP=$(readlink -f "/dev/disk/by-partlabel/$esp_label")
    P2=$(readlink -f "/dev/disk/by-partlabel/$root_label")
    ;;
  custom)
    log "using existing partitions (custom): ESP=$ESP_PART root=$ROOT_PART"
    ESP="$ESP_PART"; P2="$ROOT_PART"
    ;;
esac
{ [ -b "$ESP" ] && [ -b "$P2" ]; } || { echo "failed to resolve ESP ($ESP) / root ($P2)"; exit 1; }

# safety: never touch the live root; unmount any target-partition holders.
for _d in "$P2" "$ESP"; do
  if [ "$(findmnt -nro TARGET --source "$_d" 2>/dev/null | head -1)" = / ]; then
    echo "refusing: $_d is mounted at / (the live root)"; exit 1
  fi
  for _mp in $(findmnt -nro TARGET --source "$_d" 2>/dev/null); do
    umount -R "$_mp" 2>/dev/null || umount -l "$_mp" 2>/dev/null || true
  done
done
if [ "$PART_MODE" != auto ]; then
  zap_pools_on "$TARGET_DISK" 2>/dev/null || true
  zpool labelclear -f "$P2" 2>/dev/null || true
  btrfs device scan --forget "$P2" 2>/dev/null || true
  wipefs -a "$P2" 2>/dev/null || true
fi

# ---------------- 2. ESP filesystem ----------------
if [ "${FORMAT_ESP:-yes}" = yes ]; then
  log "mkfs ESP $ESP"
  mkfs.vfat -F32 -n ESP "$ESP"
else
  log "reusing existing ESP $ESP (not formatting)"
fi

# ---------------- 3. LUKS (optional; used by non-zfs, and by ZFS_ENC=luks) ----------------
LUKS_UUID=""
BASE="$P2"
if [ "$USE_LUKS" = yes ]; then
  log "LUKS2 format+open on $P2"
  printf '%s' "$LUKSPW" | cryptsetup luksFormat --type luks2 --batch-mode "$P2" -
  printf '%s' "$LUKSPW" | cryptsetup open "$P2" cryptroot -
  LUKS_UUID=$(blkid -s UUID -o value "$P2")
  BASE=/dev/mapper/cryptroot
fi

# ---------------- 4. LVM (optional; ext4/xfs/btrfs only) ----------------
if [ "$USE_LVM" = yes ]; then
  pvcreate -ff -y "$BASE"
  vgcreate "$VG" "$BASE"
  if [ "$LVM_THIN" = yes ]; then
    log "LVM thin: pool ${VG}/thinpool, thin root LV (size ${ROOT_SIZE})"
    lvcreate -y --type thin-pool -l 100%FREE -n thinpool "$VG"
    local_vsize="$ROOT_SIZE"; [ "$ROOT_SIZE" = "100%FREE" ] && local_vsize="$(lvs --noheadings -o lv_size --units b --nosuffix ${VG}/thinpool | tr -d ' ')b"
    lvcreate -y --type thin -V "$local_vsize" --thinpool "${VG}/thinpool" -n root "$VG"
  else
    log "LVM thick: root LV (size ${ROOT_SIZE})"
    if [ "$ROOT_SIZE" = "100%FREE" ]; then lvcreate -y -l 100%FREE -n root "$VG"; else lvcreate -y -L "$ROOT_SIZE" -n root "$VG"; fi
  fi
  ROOTDEV=/dev/$VG/root
else
  ROOTDEV="$BASE"
fi

# ---------------- 5. root filesystem ----------------
ROOT_DATASET=""
ROOT_UUID=""
if [ "$FS" = zfs ]; then
  ROOT_DATASET="${ZPOOL}/ROOT/${DISTRO}"
  # The pool is created by the LIVE environment's ZFS but must be importable by
  # the TARGET's ZFS at boot. All supported targets are OpenZFS 2.4.x (zabbly,
  # proxmox, ubuntu, and debian via trixie-backports), so the full feature set is
  # fine with a current live image. If you run from a live image whose ZFS is
  # newer than the target's, cap the pool with ZPOOL_COMPAT (a name from
  # /usr/share/zfs/compatibility.d, e.g. openzfs-2.2-linux; "off" = all features).
  ZPOOL_COMPAT="${ZPOOL_COMPAT:-off}"
  compat_opt=""
  [ "$ZPOOL_COMPAT" != off ] && [ -n "$ZPOOL_COMPAT" ] && compat_opt="-o compatibility=$ZPOOL_COMPAT"
  log "create zpool $ZPOOL on $ROOTDEV (enc=$ZFS_ENC, compat=${ZPOOL_COMPAT})"
  # single-disk root pool; posix ACL + sa xattr are Incus/systemd friendly.
  zpool create -f $compat_opt \
    -o ashift=12 -o autotrim=on \
    -O compression=zstd -O acltype=posixacl -O xattr=sa -O dnodesize=auto \
    -O atime=off -O relatime=on -O normalization=formD -O mountpoint=none -O canmount=off \
    -R "$MNT" "$ZPOOL" "$ROOTDEV"
  if [ "$ZFS_ENC" = native ]; then
    printf '%s\n%s\n' "$ZFSPW" "$ZFSPW" | zfs create \
      -o canmount=off -o mountpoint=none \
      -o encryption=aes-256-gcm -o keyformat=passphrase -o keylocation=prompt "${ZPOOL}/ROOT"
  else
    zfs create -o canmount=off -o mountpoint=none "${ZPOOL}/ROOT"
  fi
  zfs create -o canmount=noauto -o mountpoint=/ "$ROOT_DATASET"
  zfs mount "$ROOT_DATASET"
  zpool set bootfs="$ROOT_DATASET" "$ZPOOL"
else
  log "mkfs root ($FS) on $ROOTDEV"
  case "$FS" in
    ext4)  mkfs.ext4 -F -L incusroot "$ROOTDEV" ;;
    xfs)   mkfs.xfs  -f -L incusroot "$ROOTDEV" ;;
    btrfs) mkfs.btrfs -f -L incusroot "$ROOTDEV" ;;
    *) echo "unknown FS=$FS"; exit 1 ;;
  esac
  ROOT_UUID=$(blkid -s UUID -o value "$ROOTDEV")
fi
ESP_UUID=$(blkid -s UUID -o value "$ESP")

# ---------------- 6. mount target ----------------
log "mount target at $MNT"
if [ "$FS" = zfs ]; then
  : # pool already mounted at $MNT via altroot
elif [ "$FS" = btrfs ]; then
  mkdir -p "$MNT"; mount "$ROOTDEV" "$MNT"
  btrfs subvolume create "$MNT/@" >/dev/null
  umount "$MNT"
  mount -o "subvol=@,$BTRFS_OPTS" "$ROOTDEV" "$MNT"
else
  mkdir -p "$MNT"; mount "$ROOTDEV" "$MNT"
fi
mkdir -p "$MNT/boot/efi"
mount "$ESP" "$MNT/boot/efi"

# ---------------- 7. debootstrap ----------------
log "debootstrap $DISTRO $SUITE"
_comp=$( [ "$DISTRO" = ubuntu ] && echo "main,universe" || echo "main,contrib" )
debootstrap --arch=amd64 --components="$_comp" $DEBOOTSTRAP_ARGS "$SUITE" "$MNT" "$MIRROR"

# ---------------- 8. build kernel cmdline ----------------
if [ "$FS" = zfs ]; then
  CMDLINE="root=zfs:${ROOT_DATASET} ro"
else
  CMDLINE="root=UUID=${ROOT_UUID} ro rootfstype=${FS}"
  [ "$FS" = btrfs ] && CMDLINE="$CMDLINE rootflags=subvol=@,$BTRFS_OPTS"
  [ "$USE_LVM" = yes ] && CMDLINE="$CMDLINE rd.lvm.lv=${VG}/root"
fi
# LUKS is driven by /etc/crypttab (tpm2-device=auto), NOT rd.luks.uuid.
CMDLINE="$CMDLINE $EXTRA_CMDLINE"
CMDLINE=$(echo "$CMDLINE" | tr -s ' ')

# ---------------- 9. write env + stage2 into target ----------------
log "writing stage2 config"
cat > "$MNT/root/install.env" <<EOF
DISTRO="${DISTRO}"
SUITE="${SUITE}"
KERNEL="${KERNEL}"
MIRROR="${MIRROR}"
FS="${FS}"
ZPOOL="${ZPOOL}"
ZFS_ENC="${ZFS_ENC}"
ROOT_DATASET="${ROOT_DATASET}"
USE_LVM="${USE_LVM}"
LVM_THIN="${LVM_THIN}"
USE_LUKS="${USE_LUKS}"
INCUS="${INCUS}"
INCUS_CHANNEL="${INCUS_CHANNEL}"
SECUREBOOT="${SECUREBOOT}"
HOSTONLY="${HOSTONLY}"
SKIP_NVRAM="${SKIP_NVRAM}"
HOSTNAME_="${HOSTNAME_}"
ROOTPW="${ROOTPW}"
LUKSPW="${LUKSPW}"
ZFSPW="${ZFSPW}"
MOKPW="${MOKPW}"
BTRFS_OPTS="${BTRFS_OPTS}"
ROOT_UUID="${ROOT_UUID}"
ESP_UUID="${ESP_UUID}"
LUKS_UUID="${LUKS_UUID}"
P2="${P2}"
CMDLINE="${CMDLINE}"
EOF

cp "$(dirname "$0")/stage2.sh" "$MNT/root/stage2.sh"
chmod +x "$MNT/root/stage2.sh"

# ---------------- 10. bind mounts + chroot ----------------
log "entering chroot for stage2"
# A debootstrapped Ubuntu ships an nsswitch 'hosts:' line that uses nss-resolve,
# which errors inside the chroot (systemd-resolved is not running and our /run is
# a fresh tmpfs), so glibc fails before ever reading resolv.conf and apt cannot
# resolve hostnames. Point host resolution straight at DNS for the install; the
# running system still resolves via its own resolver (resolv.conf) afterwards.
if [ -f "$MNT/etc/nsswitch.conf" ]; then
  sed -i 's/^\(hosts:[[:space:]]*\).*/\1files dns/' "$MNT/etc/nsswitch.conf"
fi
# Copy the live environment's resolver into the chroot. It is often a symlink to
# a stub under /run (Ubuntu points /etc/resolv.conf at the systemd-resolved stub),
# which would dangle in our fresh tmpfs /run, so dereference it into a real file.
rm -f "$MNT/etc/resolv.conf"
cp -L /etc/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null \
  || cp /run/systemd/resolve/resolv.conf "$MNT/etc/resolv.conf" 2>/dev/null \
  || true
for d in proc sys dev dev/pts; do
  mkdir -p "$MNT/$d"
  mount --rbind "/$d" "$MNT/$d"
  mount --make-rslave "$MNT/$d" 2>/dev/null || true
done
# Fresh tmpfs /run (NOT a bind of the host's /run): a bound host /run exposes
# /run/systemd/system, which makes maintainer scripts believe systemd is running
# and call `systemctl enable --now` (fails in a chroot; e.g. zabbly incus-base).
mkdir -p "$MNT/run"
mount -t tmpfs tmpfs "$MNT/run"
mount -t efivarfs efivarfs "$MNT/sys/firmware/efi/efivars" 2>/dev/null || true
# ZFS needs a stable hostid shared between the live-created pool and the target
# initramfs so the pool imports at boot without an -f override.
if [ "$FS" = zfs ] && [ -f /etc/hostid ]; then cp /etc/hostid "$MNT/etc/hostid"; fi

chroot "$MNT" /bin/bash /root/stage2.sh

# ---------------- 11. remove installer artifacts (plaintext secrets) ----------------
for f in "$MNT/root/install.env" "$MNT/root/stage2.sh"; do
  [ -e "$f" ] && { shred -u "$f" 2>/dev/null || rm -f "$f"; }
done

# ---------------- 12. done ----------------
log "unmounting"
umount -R "$MNT/boot/efi" 2>/dev/null || true
if [ "$FS" = zfs ]; then
  umount -R "$MNT" 2>/dev/null || true
  zfs unmount -a 2>/dev/null || true
  zpool export "$ZPOOL" 2>/dev/null || true   # clean export => boots without -f
else
  umount -R "$MNT" 2>/dev/null || true
  [ "$USE_LVM" = yes ] && vgchange -an "$VG" 2>/dev/null || true
  [ "$USE_LUKS" = yes ] && cryptsetup close cryptroot 2>/dev/null || true
fi
log "INSTALL COMPLETE (distro=$DISTRO kernel=$KERNEL FS=$FS enc=${ZFS_ENC}/LUKS=$USE_LUKS SB=$SECUREBOOT incus=$INCUS)"
echo "cmdline was: $CMDLINE"
