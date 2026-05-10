# Patch 0.6.18-router-ssh-22-bruteforce

Это более жёсткий патч, потому что предыдущий у тебя не добил строку.

Он проходит по проекту и меняет:

```text
Router SSH port [2026]
```

на:

```text
Router SSH port [22]
```

Также меняет все найденные дефолты:

```text
SSH_ROUTER_PORT=2026
SSH_ROUTER_PORT="${SSH_ROUTER_PORT:-2026}"
```

на `22`.

## Применение

Распакуй ZIP в корень проекта и запусти:

```bash
bash tools/apply_router_ssh_22_bruteforce_0_6_18.sh
git add .
git commit -m "force router ssh port to 22 everywhere"
git push
```

## Проверка

После применения команда в конце сама покажет остатки.

Можно вручную:

```bash
grep -R "Router SSH port.*2026\|SSH_ROUTER_PORT.*2026" -n . --exclude-dir=.git --exclude-dir=.patch_backups
```

Если вывод пустой — старого дефолта больше нет.
