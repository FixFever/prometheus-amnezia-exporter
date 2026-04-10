#!/bin/bash
#
# AmneziaVPN Prometheus Exporter Configuration
# Source this file to configure the exporter settings
#

# WireGuard Configuration
export WIREGUARD_INTERFACE="${WIREGUARD_INTERFACE:-}"  # Leave empty to monitor all interfaces
export WIREGUARD_DOCKER_CONTAINER="${WIREGUARD_DOCKER_CONTAINER:amnezia-awg}" # AmneziaVPN docker container name
export CLIENTS_TABLE_FILE="${CLIENTS_TABLE_FILE:/opt/amnezia/awg/clientsTable}" # Path to AmneziaVPN client table

# Prometheus Exporter Configuration
export METRICS_PREFIX="${METRICS_PREFIX:-wireguard}"

# HTTP Server Configuration
export LISTEN_PORT="${LISTEN_PORT:-9586}"
export LISTEN_ADDRESS="${LISTEN_ADDRESS:-0.0.0.0}"
export MAX_CONNECTIONS="${MAX_CONNECTIONS:-10}"
export TIMEOUT="${TIMEOUT:-30}"

# Logging Configuration
export LOG_LEVEL="${LOG_LEVEL:-info}"

# State file (for persistent data)
export STATE_FILE="${STATE_FILE:-/var/lib/wireguard-exporter/state}"
export CACHE_TTL="${CACHE_TTL:-60}"

# Advanced Configuration
export ENABLE_EXTENDED_METRICS="${ENABLE_EXTENDED_METRICS:-true}"
