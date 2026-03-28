# awg-suite

Набор для установки связки:
- AmneziaWG для OpenWrt
- domain-routing-openwrt
- VPN mode switch

## Запуск одной командой

Из каталога, где лежат конфиги `awg0.conf` и/или `awg1.conf`:

```sh
sh <(wget -O - https://raw.githubusercontent.com/Brilev/awg-suite/main/bootstrap.sh)
```

## Что должно лежать в текущем каталоге

Скрипт ищет только эти файлы в **текущем каталоге**:
- `./awg0.conf`
- `./awg1.conf`

Можно положить один файл или оба.

## Формат конфигов

Используй **AmneziaWG native format (.conf)**, который экспортирует сама Amnezia.

Примеры шаблонов:
- `awg0.conf.example`
- `awg1.conf.example`

## Что делает bootstrap.sh

- скачивает весь репозиторий `Brilev/awg-suite`
- распаковывает его во временный каталог
- запускает локальный `install-all.sh`
- рабочим каталогом оставляет тот каталог, из которого был вызван bootstrap

## Что делает install-all.sh

- запускает vendor-скрипты из `vendor/`
- читает `./awg0.conf` и `./awg1.conf`
- создаёт/обновляет `awg0` и `awg1` через UCI
- в конце применяет изменения: `network reload`, `firewall restart`, `dnsmasq restart`

## Проверка обновлений upstream

Для сравнения snapshot в `vendor/` с upstream используй:

```sh
sh tools/check-upstream.sh
```

После этого можно собрать краткую сводку:

```sh
sh tools/summarize-diff.sh reports/<timestamp>
```
