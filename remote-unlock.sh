#!/bin/bash
#
# Remotely unlock LUKS-encrypted disks.
#
# Meant for use together with dropbear-initramfs which spawns an SSH server in
# initramfs which can be used to unlock disks. This script reads passwords with
# `pass` (password-store) from paths in the form of `hardware/disks/$UUID`.
#
# UUIDs are automatically extraced from the crypttab, so it should be pretty
# simple to set up.
#
# It's adviced to set up SSH to use `ControlMaster auto` and `ControlPersist 2m`
# to avoid having to re-open the SSH connection on evey call. Alternatively this
# script could be improved to use the same SSH connection for all commands.
#
# Tested and working on Ubuntu 18.04 (remote) and Debian 9 (local).

function usage() {
  cat >&2 <<EOF
Usage: ${0} [-p|--partial] user@host.tld
EOF
}

partial=0

while [[ $1 =~ ^- ]]; do
  case $1 in
    --partial|-p)
      partial=1
      ;;
    *)
      usage
      exit 255
      ;;
  esac

  shift
done

host=$1
disks=$(ssh "$host" "cat /conf/conf.d/cryptroot")
targets=()

for crypt in $disks; do
  # extrance target and UUID
  [[ "$crypt" =~ ^target=([^,]+),source=UUID=([^,]+), ]]
  target="${BASH_REMATCH[1]}"
  uuid="${BASH_REMATCH[2]}"

  if ssh "$host" "test -b '/dev/mapper/$target'"; then
    # disk already unlocked, continue
    continue
  fi

  targets=("$target")

  echo "Unlocking target: ${target} (${uuid})"
  pass show "hardware/disks/$uuid" | head -n1 | head -c -1 | \
    ssh "$host" "/sbin/cryptsetup --key-file - luksOpen /dev/disk/by-uuid/$uuid $target"
done

# ensure disks did get unlocked before killing cryptsetup and resuming boot
for target in ${targets[*]}; do
  test -b "/dev/mapper/$target"
  if [[ $? != 0 ]]; then
    >&2 echo "Failed to unlock disk '$target'"
    [[ $partial -eq 0 ]] && exit 1
  fi
done

# find the pid for cryptroot so we can kill it and continue booting
cryptroot_pid=$(ssh "$host" ps | grep '{cryptroot} /bin/sh /scripts/local-top/cryptroot' | grep -v grep | sed -r 's/^ *([0-9]+) .*?/\1/')

ssh "$host" kill "$cryptroot_pid"
