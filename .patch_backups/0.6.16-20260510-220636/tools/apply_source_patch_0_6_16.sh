#!/bin/bash
# apply_source_patch_0_6_16.sh
# Run from project root. It fixes source defaults: servers=2026, routers=22, client=22.
set +e
if [ ! -f menu.sh ] && [ ! -d modules ]; then
  echo "[FAIL] Run from project root"
  exit 1
fi
backup_dir=".patch_backups/0.6.16-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup_dir"
backup(){ [ -f "$1" ] || return 0; mkdir -p "$backup_dir/$(dirname "$1")"; cp -a "$1" "$backup_dir/$1"; }
patch_file(){
  f="$1"; [ -f "$f" ] || return 0; backup "$f"
  sed -i \
    -e 's/SSH_ROUTER_PORT="${SSH_ROUTER_PORT:-2026}"/SSH_ROUTER_PORT="${SSH_ROUTER_PORT:-22}"/g' \
    -e 's/SSH_ROUTER_PORT=2026/SSH_ROUTER_PORT=22/g' \
    -e 's/Router SSH port \[2026\]/Router SSH port [22]/g' \
    -e 's/ansible_port=2026 ansible_user=net_admin/ansible_port=22 ansible_user=net_admin/g' \
    -e 's/HQ_CLI_ANSIBLE_PORT=2026/HQ_CLI_ANSIBLE_PORT=22/g' \
    "$f"
}
find . -type f \( -name "*.sh" -o -name "*.env" -o -name "*.example" -o -name "*.md" \) -not -path './.git/*' -not -path './.patch_backups/*' | while read -r f; do patch_file "${f#./}"; done
for f in config/config.env.example config/module3.isp.example.env; do
  [ -f "$f" ] || continue; backup "$f"
  grep -q '^SSH_SERVER_PORT=' "$f" && sed -i 's/^SSH_SERVER_PORT=.*/SSH_SERVER_PORT=2026/' "$f" || echo 'SSH_SERVER_PORT=2026' >> "$f"
  grep -q '^SSH_ROUTER_PORT=' "$f" && sed -i 's/^SSH_ROUTER_PORT=.*/SSH_ROUTER_PORT=22/' "$f" || echo 'SSH_ROUTER_PORT=22' >> "$f"
  grep -q '^SSH_CLI_PORT=' "$f" && sed -i 's/^SSH_CLI_PORT=.*/SSH_CLI_PORT=22/' "$f" || echo 'SSH_CLI_PORT=22' >> "$f"
  grep -q '^HQ_CLI_ANSIBLE_PORT=' "$f" && sed -i 's/^HQ_CLI_ANSIBLE_PORT=.*/HQ_CLI_ANSIBLE_PORT=22/' "$f" || echo 'HQ_CLI_ANSIBLE_PORT=22' >> "$f"
done
for mf in modules/module2.sh modules/module3.sh; do
  [ -f "$mf" ] || continue; backup "$mf"
  if ! grep -q 'ssh_ports_ansible_fix.sh' "$mf"; then
    tmp=$(mktemp)
    {
      echo 'if [ -f /opt/demo-autoconfig/modules/ssh_ports_ansible_fix.sh ]; then'
      echo '  bash /opt/demo-autoconfig/modules/ssh_ports_ansible_fix.sh'
      echo 'elif [ -f "$(dirname "$0")/ssh_ports_ansible_fix.sh" ]; then'
      echo '  bash "$(dirname "$0")/ssh_ports_ansible_fix.sh"'
      echo 'fi'
      echo
      cat "$mf"
    } > "$tmp"
    mv "$tmp" "$mf"
    chmod +x "$mf" 2>/dev/null || true
  fi
done
echo '0.6.16-ssh-ports-ansible-fix' > VERSION
echo "[OK] Source patch applied. Backups: $backup_dir"
echo "Run: git add . && git commit -m 'fix ssh ports for routers and ansible' && git push"
