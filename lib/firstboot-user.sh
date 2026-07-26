#!/bin/sh
# Minimal first-boot user creation wizard for images without a
# graphical initial-setup (KDE Plasma). Runs once on tty1 before the
# display manager, then never again.
set -eu

marker=/var/lib/firstboot-user.done

# already done, or a regular user already exists
[ -e "$marker" ] && exit 0
if awk -F: '$3 >= 1000 && $3 < 65534 { exit 1 }' /etc/passwd; then
  :
else
  touch "$marker"
  exit 0
fi

admin_group=wheel
grep -q '^sudo:' /etc/group && admin_group=sudo

printf '\n===== First boot: create your user account =====\n\n'

user=""
while [ -z "$user" ]; do
  printf 'Username: '
  read -r user
  case "$user" in
    ''|*[!a-z0-9_-]*)
      printf 'Invalid username (use a-z, 0-9, -, _).\n'
      user=""
      ;;
  esac
done

useradd -m -s /bin/bash -G "$admin_group" "$user"

until passwd "$user"; do
  printf 'Please try again.\n'
done

touch "$marker"
printf '\nUser %s created. Continuing boot...\n' "$user"
