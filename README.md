# awg-suite

Репозиторий для воспроизводимой установки связки:
- AmneziaWG для OpenWrt
- переключатель vpn-mode
- локальная конфигурация `awg0` и `awg1` из нативных `*.conf` файлов AmneziaWG

## Как использовать

Положи в текущий каталог один или оба файла:
- `./awg0.conf`
- `./awg1.conf`

Потом запускай bootstrap одной командой:

```sh
sh <(wget -O - https://raw.githubusercontent.com/Brilev/awg-suite/main/bootstrap.sh)
```

Bootstrap скачивает весь репозиторий во временный каталог и запускает локальный `install-all.sh`,
но рабочим каталогом оставляет именно тот, из которого команда была вызвана.

Поэтому входные файлы читаются **только из текущего каталога**.

Если репозиторий нужно брать не из `Brilev/awg-suite` или не из ветки `main`, можно переопределить:

```sh
AWG_BOOTSTRAP_REPO='Brilev/awg-suite' AWG_BOOTSTRAP_REF='main' \
sh <(wget -O - https://raw.githubusercontent.com/Brilev/awg-suite/main/bootstrap.sh)
```

## Формат входных файлов

Используется родной экспорт AmneziaWG native format (`.conf`).
Примеры:
- `awg0.conf.example`
- `awg1.conf.example`

## Что делает install-all.sh

1. Запускает локальный snapshot `vendor/amneziawg-install.sh`
2. Запускает локальный snapshot `vendor/vpn-mode-install.sh`
3. Читает `./awg0.conf` и `./awg1.conf`
4. Создаёт UCI-конфиг `network.awg0` / `network.awg1` и peer-секции
5. Создаёт firewall zone/forwarding при отсутствии
6. Делает один финальный apply в конце

## Обновление snapshot upstream

```sh
sh tools/check-upstream.sh
sh tools/summarize-diff.sh reports/<timestamp>
```

## Важно

- `getdomains-install.sh` хранится в `vendor/` и участвует в diff-проверке, но автоматически не запускается.
- Для полного сценария через архив/репозиторий рядом с `install-all.sh` должны лежать `vendor/`, `tools/` и остальные файлы.
- Для one-liner запуска используй именно `bootstrap.sh`, а не прямой вызов `install-all.sh`.
- `install-all.sh` рассчитан на запуск из уже скачанного репозитория, когда рядом есть `vendor/`.
