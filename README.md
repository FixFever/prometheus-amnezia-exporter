# Prometheus AmneziaVPN Exporter

Форк [itefixnet/prometheus-wireguard-exporter](https://github.com/itefixnet/prometheus-wireguard-exporter) с поддержкой AmneziaVPN.

Исходный WireGuard экспортер показывает только публичные ключи клиентов. 
В AmneziaVPN имена клиентов хранятся в JSON-файле. Форк читает этот файл и добавляет в метрики лейбл `client_name`.

## Что изменено

- Чтение `clientsTable` (JSON) из Docker-контейнера AmneziaVPN
- Добавление лейбла `client_name` к метрикам peer'ов
- В примере дашборда Grafana изменено использование лейбла `public_key` на `client_name`

## Конфигурация

В `config.sh`:

```bash
export WIREGUARD_DOCKER_CONTAINER="amnezia-awg"
export CLIENTS_TABLE_FILE="/opt/amnezia/awg/clientsTable"
```

## Установка

```bash
# Клонируем репозиторий
git clone https://github.com/fixfever/prometheus-amnezia-exporter.git
cd prometheus-amnezia-exporter

# Настраиваем конфиг config.sh при необходимости

# Запускаем
chmod +x *.sh
sudo ./http-server.sh start
```

Метрики доступны по адресу: http://localhost:9586/metrics

## Ссылки

- Исходный репозиторий: [itefixnet/prometheus-wireguard-exporter](https://github.com/itefixnet/prometheus-wireguard-exporter)
- [AmneziaVPN](https://github.com/amnezia-vpn)
