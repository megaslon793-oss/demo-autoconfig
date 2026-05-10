if [ -f /opt/demo-autoconfig/lib/apt_safe.sh ]; then
  . /opt/demo-autoconfig/lib/apt_safe.sh
elif [ -f "$(dirname "$0")/../lib/apt_safe.sh" ]; then
  . "$(dirname "$0")/../lib/apt_safe.sh"
fi

#!/bin/bash
# backup_fix.sh
# Version 0.6.13

set +e

BACKUP_DIR="/etc/demo-autoconfig/backups"
EXTRA_BACKUP_DIR="/backup"

mkdir -p "$BACKUP_DIR"

timestamp="$(date +%Y%m%d-%H%M%S)"

for file in \
  /etc/demo-autoconfig/config.env \
  /opt/demo-autoconfig/VERSION \
  /etc/hosts \
  /etc/resolv.conf
do
  [ -f "$file" ] || continue

  name="$(basename "$file")"
  cp -f "$file" "$BACKUP_DIR/${name}.${timestamp}.bak"
done

if [ -d "$EXTRA_BACKUP_DIR" ]; then
  cp -rf "$BACKUP_DIR/"* "$EXTRA_BACKUP_DIR/" 2>/dev/null || true
fi

echo "[OK] backup created in $BACKUP_DIR"
