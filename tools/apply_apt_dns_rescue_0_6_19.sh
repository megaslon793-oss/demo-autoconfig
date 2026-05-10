#!/bin/bash
# apply_apt_dns_rescue_0_6_19.sh
# Run from project root.
# Injects apt_safe.sh and replaces common apt-get calls with safe helpers.

set +e

VERSION_VALUE="0.6.19-apt-dns-rescue"

if [ ! -d "modules" ] && [ ! -f "menu.sh" ]; then
  echo "[FAIL] Run from demo-autoconfig project root"
  exit 1
fi

BACKUP_DIR=".patch_backups/0.6.19-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

backup_file() {
  local f="$1"
  [ -f "$f" ] || return 0
  mkdir -p "$BACKUP_DIR/$(dirname "$f")"
  cp -a "$f" "$BACKUP_DIR/$f"
}

inject_source() {
  local f="$1"
  [ -f "$f" ] || return 0
  backup_file "$f"

  if ! grep -q 'apt_safe.sh' "$f"; then
    tmp="$(mktemp)"
    {
      echo 'if [ -f /opt/demo-autoconfig/lib/apt_safe.sh ]; then'
      echo '  . /opt/demo-autoconfig/lib/apt_safe.sh'
      echo 'elif [ -f "$(dirname "$0")/../lib/apt_safe.sh" ]; then'
      echo '  . "$(dirname "$0")/../lib/apt_safe.sh"'
      echo 'fi'
      echo
      cat "$f"
    } > "$tmp"
    mv "$tmp" "$f"
    chmod +x "$f" 2>/dev/null || true
  fi
}

patch_apt_calls() {
  local f="$1"
  [ -f "$f" ] || return 0
  backup_file "$f"

  # Replace direct apt-get update commands.
  perl -0pi -e 's/DEBIAN_FRONTEND=noninteractive[[:space:]]+apt-get[^\n;]*update[^\n;]*/apt_update_safe/g' "$f"
  perl -0pi -e 's/apt-get[[:space:]]+update[[:space:]]+-y/apt_update_safe/g' "$f"
  perl -0pi -e 's/apt-get[[:space:]]+-y[[:space:]]+update/apt_update_safe/g' "$f"
  perl -0pi -e 's/apt-get[[:space:]]+update/apt_update_safe/g' "$f"

  # Replace simple apt install commands. Keep arguments after install -y.
  perl -0pi -e 's/DEBIAN_FRONTEND=noninteractive[[:space:]]+apt-get[^\n;]*install[[:space:]]+-y[[:space:]]+/apt_install_safe /g' "$f"
  perl -0pi -e 's/apt-get[[:space:]]+install[[:space:]]+-y[[:space:]]+/apt_install_safe /g' "$f"
  perl -0pi -e 's/apt[[:space:]]+install[[:space:]]+-y[[:space:]]+/apt_install_safe /g' "$f"
}

mkdir -p lib
# apt_safe.sh is supplied by this patch archive.
# If it is already extracted, keep it.

for f in modules/*.sh lib/*.sh bootstrap.sh menu.sh; do
  [ -f "$f" ] || continue
  inject_source "$f"
  patch_apt_calls "$f"
done

echo "$VERSION_VALUE" > VERSION

echo "[OK] apt DNS rescue source patch applied"
echo "[OK] backups saved to $BACKUP_DIR"
echo
echo "Check suspicious apt calls:"
grep -R "apt-get update\\|apt update\\|apt-get install\\|apt install" -n modules lib bootstrap.sh menu.sh 2>/dev/null \
  | grep -v apt_safe.sh || true
echo
echo "Now run:"
echo "git add ."
echo "git commit -m \"fix apt dns handling\""
echo "git push"
