# Prometheus AmneziaVPN Exporter

Форк [itefixnet/prometheus-wireguard-exporter](https://github.com/itefixnet/prometheus-wireguard-exporter) с поддержкой AmneziaVPN.

Исходный WireGuard экспортер показывает только публичные ключи клиентов. 
В AmneziaVPN имена клиентов хранятся в JSON-файле. Форк читает этот файл и добавляет в метрики лейбл `client_name`.

## Что изменено

- Чтение `clientsTable` (JSON) из Docker-контейнера AmneziaVPN
- Добавление лейбла `client_name` к метрикам peer'ов
- Готовый образ для запуска экспортера в docker-контейнере
- В примере дашборда Grafana изменено использование лейбла `public_key` на `client_name`

## Установка

### Запуск на хосте

```bash
# Клонируем репозиторий
git clone https://github.com/fixfever/prometheus-amnezia-exporter.git
cd prometheus-amnezia-exporter

# Настраиваем конфиг config.sh при необходимости

# Запускаем
chmod +x *.sh
sudo ./http-server.sh start
```

### Запуск через docker run

```
docker run -d \
  --name amnezia-exporter \
  --network host \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  fixfever/prometheus-amnezia-exporter:latest
```

### Запуск через docker-compose

```
services:
  prometheus-amnezia-exporter:
    image: fixfever/prometheus-amnezia-exporter:latest
    container_name: amnezia-exporter
    ports:
      - 9586:9586
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    restart: unless-stopped
```

Метрики доступны по адресу: http://localhost:9586/metrics

## Переменные окружения

| Переменная | По умолчанию | Описание |
|------------|--------------|----------|
| `WIREGUARD_DOCKER_CONTAINER` | `amnezia-awg` | Имя Docker-контейнера с AmneziaVPN |
| `CLIENTS_TABLE_FILE` | `/opt/amnezia/awg/clientsTable` | Путь к JSON-файлу с именами клиентов (внутри контейнера) |
| `LISTEN_PORT` | `9586` | Порт для HTTP-сервера |
| `LISTEN_ADDRESS` | `0.0.0.0` | Адрес для привязки |

## Ссылки

- Исходный репозиторий: [itefixnet/prometheus-wireguard-exporter](https://github.com/itefixnet/prometheus-wireguard-exporter)
- [AmneziaVPN](https://github.com/amnezia-vpn)
