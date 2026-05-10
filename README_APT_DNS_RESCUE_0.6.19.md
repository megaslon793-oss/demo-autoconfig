# Patch 0.6.19-apt-dns-rescue

Чинит проблему:

```text
Temporary failure resolving deb.debian.org
Temporary failure resolving security.debian.org
```

И главное: больше не считает такой `apt-get update` нормальным `[OK]`.

## Что добавлено

```text
lib/apt_safe.sh
tools/apply_apt_dns_rescue_0_6_19.sh
VERSION
README_APT_DNS_RESCUE_0.6.19.md
```

## Что делает

Перед любым `apt`:
- пишет рабочий `/etc/resolv.conf` без `127.0.0.1`;
- ставит DNS:
  - `8.8.8.8`
  - `1.1.1.1`
  - `77.88.8.8`
  - `77.88.8.1`
  - потом внутренний `192.168.100.2`
- проверяет, что `deb.debian.org` реально резолвится;
- делает retry;
- если `apt-get update` содержит `Temporary failure resolving` или `Failed to fetch`, не пишет ложный `[OK]`.

## Применение

Распакуй ZIP в корень проекта и выполни:

```bash
bash tools/apply_apt_dns_rescue_0_6_19.sh
git add .
git commit -m "fix apt dns handling"
git push
```

## После этого

На ВМ запускаешь обычный bootstrap.  
Первый модуль перед установкой пакетов должен сначала чинить DNS, потом ставить пакеты.
