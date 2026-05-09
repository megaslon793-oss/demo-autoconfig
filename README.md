# demo-autoconfig

Локальный Bash-проект для автоматической настройки учебного стенда демо-экзамена по сетевому и системному администрированию.

Проект рассчитан на запуск отдельно на каждой виртуальной машине. Все значения, которые могут меняться между вариантами задания, вводятся вручную в `Initial setup` и сохраняются в `/etc/demo-autoconfig/config.env`.

## Быстрый запуск

Запуск с GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/megaslon793-oss/demo-autoconfig/main/bootstrap.sh | sudo bash
```

Если `curl` не установлен:

```bash
wget -qO- https://raw.githubusercontent.com/megaslon793-oss/demo-autoconfig/main/bootstrap.sh | sudo bash
```

Если нужно временно указать другой репозиторий:

```bash
curl -fsSL https://raw.githubusercontent.com/megaslon793-oss/demo-autoconfig/main/bootstrap.sh | \
  sudo env DEMO_REPO_ARCHIVE_URL=https://github.com/USER/REPO/archive/refs/heads/main.tar.gz bash
```

## Меню

```text
1. Initial setup
2. Module 1
3. Module 2
4. Module 3
5. Diagnostics
6. Cleanup temporary files
0. Exit
```

## Роли

Поддерживаются роли:

- `ISP`
- `HQ-RTR`
- `BR-RTR`
- `HQ-SRV`
- `BR-SRV`
- `HQ-CLI`

## Реализовано

- `bootstrap.sh`: скачивание проекта во временный каталог и запуск меню без git-клона.
- `menu.sh`: локальное меню модулей.
- `Initial setup`: создание или пересоздание `/etc/demo-autoconfig/config.env`, hostname, `/etc/hosts`, `/etc/resolv.conf`, опциональный mount `Additional.iso`, проверки доступности.
- `Module 1`: hostname, `/etc/network/interfaces`, IPv4 forwarding, NAT через `/usr/sbin/iptables`, статические маршруты, GRE, FRR/OSPF, DHCP, bind9 base install, SSH hardening.
- `Diagnostics`: сетевые команды и проверки основных сервисов.
- `Module 2`: Chrony, nginx reverse proxy на `ISP`, DNAT на роутерах, Samba AD DC и импорт пользователей из `Users.csv` на `BR-SRV`, Docker-приложение из локальных tar-образов `Additional.iso`, NFS и Apache + MariaDB на `HQ-SRV`, подключение `HQ-CLI` к домену и проверка `http://web.au-team.irpo/` и `http://docker.au-team.irpo/`.
- `Module 3`: безопасная расширяемая заготовка под эксплуатацию и безопасность.

## Важные файлы

- Конфиг: `/etc/demo-autoconfig/config.env`
- Backups: `/etc/demo-autoconfig/backups/`
- Лог: `/var/log/demo-autoconfig.log`
- Временные файлы: `/tmp/demo-autoconfig`

## Повторный запуск

Любой модуль можно запускать повторно через меню. Скрипты стараются быть идемпотентными: существующие пакеты, сервисы, маршруты, iptables-правила и GRE-интерфейсы пропускаются или заменяются безопасно.

## Очистка временных файлов

Через меню выберите:

```text
6. Cleanup temporary files
```

Это удалит `/tmp/demo-autoconfig`. Конфиг, backup-и и лог остаются.

## Безопасность

Проект не форматирует диски, не пересоздаёт RAID, не чистит Docker и не удаляет Samba-конфиги без явного будущего блока с подтверждением. Docker-образы для задания должны загружаться из `Additional.iso` через `docker load`, а не скачиваться как `site:latest` из интернета.
