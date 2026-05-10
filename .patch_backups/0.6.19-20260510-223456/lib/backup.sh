if [ -f /opt/demo-autoconfig/lib/apt_safe.sh ]; then
  . /opt/demo-autoconfig/lib/apt_safe.sh
elif [ -f "$(dirname "$0")/../lib/apt_safe.sh" ]; then
  . "$(dirname "$0")/../lib/apt_safe.sh"
fi

#!/usr/bin/env bash

backup_file() {
  local path="$1"
  if [ ! -e "$path" ]; then
    log_skip "No backup needed, file does not exist: $path"
    return 0
  fi
  local backup_dir="/etc/demo-autoconfig/backups$(dirname "$path")"
  local stamp
  stamp="$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$backup_dir"
  cp -a "$path" "$backup_dir/$(basename "$path").$stamp.bak"
  log_ok "Backup created: $backup_dir/$(basename "$path").$stamp.bak"
}
