#!/bin/bash
#
# AmneziaVPN Prometheus Exporter
# A bash-based exporter for WireGuard VPN statistics
# With client name support from JSON config
#

# Set strict error handling
set -euo pipefail

# Source configuration if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.sh"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# Default configuration
WIREGUARD_INTERFACE="${WIREGUARD_INTERFACE:-}"
WIREGUARD_DOCKER_CONTAINER="${WIREGUARD_DOCKER_CONTAINER:-}" # AmneziaVPN docker container name
METRICS_PREFIX="${METRICS_PREFIX:-wireguard}"
CLIENTS_TABLE_FILE="${CLIENTS_TABLE_FILE:-}"  # Path to clients table JSON file

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

# Helper function to execute wg commands (supports Docker containers)
wg_exec() {
    if [[ -n "$WIREGUARD_DOCKER_CONTAINER" ]]; then
        docker exec "$WIREGUARD_DOCKER_CONTAINER" wg "$@" 2>/dev/null
    else
        wg "$@" 2>/dev/null
    fi
}

# Helper function to execute ip commands (supports Docker containers)
ip_exec() {
    if [[ -n "$WIREGUARD_DOCKER_CONTAINER" ]]; then
        docker exec "$WIREGUARD_DOCKER_CONTAINER" ip "$@" 2>/dev/null
    else
        ip "$@" 2>/dev/null
    fi
}

# Helper function to read file from Docker container or local filesystem
read_file_from_container() {
    local file_path="$1"
    
    if [[ -z "$file_path" ]]; then
        return 1
    fi
    
    if [[ -n "$WIREGUARD_DOCKER_CONTAINER" ]]; then
        docker exec "$WIREGUARD_DOCKER_CONTAINER" cat "$file_path" 2>/dev/null
    else
        cat "$file_path" 2>/dev/null
    fi
}

# Declare associative array for client names
declare -A CLIENT_NAMES

# Function to load client names from JSON file
load_client_names() {
    # Clear existing mappings
    CLIENT_NAMES=()
    
    if [[ -z "$CLIENTS_TABLE_FILE" ]]; then
        return 0
    fi
    
    local json_content
    json_content=$(read_file_from_container "$CLIENTS_TABLE_FILE")
    
    if [[ -z "$json_content" ]]; then
        log "WARNING: Clients table file not found or empty: $CLIENTS_TABLE_FILE"
        return 0
    fi
    
    # Parse JSON using python (more reliable than bash-only for complex JSON)
    # Fallback to jq if available, otherwise use python
    local parsed_data=""
    
    if command -v jq &>/dev/null; then
        parsed_data=$(echo "$json_content" | jq -r '.[] | "\(.clientId)|\(.userData.clientName // "")"' 2>/dev/null)
    elif command -v python3 &>/dev/null; then
        parsed_data=$(echo "$json_content" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for item in data:
        client_id = item.get('clientId', '')
        client_name = item.get('userData', {}).get('clientName', '')
        if client_id and client_name:
            print(f'{client_id}|{client_name}')
except:
    pass
" 2>/dev/null)
    else
        log "WARNING: Neither jq nor python3 available. Cannot parse JSON clients table"
        return 0
    fi
    
    if [[ -z "$parsed_data" ]]; then
        log "WARNING: No client mappings found in $CLIENTS_TABLE_FILE"
        return 0
    fi
    
    # Populate the associative array
    while IFS='|' read -r client_id client_name; do
        if [[ -n "$client_id" && -n "$client_name" ]]; then
            CLIENT_NAMES["$client_id"]="$client_name"
        fi
    done <<< "$parsed_data"
    
    log "Loaded ${#CLIENT_NAMES[@]} client mappings from $CLIENTS_TABLE_FILE"
}

# Function to get client name by public key
get_client_name() {
    local public_key="$1"
    
    if [[ -n "${CLIENT_NAMES[$public_key]:-}" ]]; then
        echo "${CLIENT_NAMES[$public_key]}"
    else
        # Return empty string if no mapping found
        echo ""
    fi
}

# Array to track metrics that have been defined
declare -A METRIC_DEFINED

# Function to format Prometheus metric
format_metric() {
    local metric_name="$1"
    local value="$2"
    local labels="$3"
    local help="$4"
    local type="${5:-gauge}"
    
    local full_name="${METRICS_PREFIX}_${metric_name}"

    # Only output HELP and TYPE once per metric name
    if [[ -z "${METRIC_DEFINED[$full_name]:-}" ]]; then
        echo "# HELP ${full_name} ${help}"
        echo "# TYPE ${full_name} ${type}"
        METRIC_DEFINED[$full_name]=1
    fi
    
    if [[ -n "$labels" ]]; then
        echo "${full_name}{${labels}} ${value}"
    else
        echo "${full_name} ${value}"
    fi
}

# Get list of WireGuard interfaces
get_interfaces() {
    if [[ -n "$WIREGUARD_INTERFACE" ]]; then
        echo "$WIREGUARD_INTERFACE"
    else
        # Auto-detect all WireGuard interfaces
        wg_exec show interfaces | tr ' ' '\n' || echo ""
    fi
}

# Function to collect interface metrics
collect_interface_metrics() {
    local interface="$1"
    
    # Get interface info
    local listen_port
    listen_port=$(wg_exec show "$interface" listen-port || echo "0")
    
    local public_key
    public_key=$(wg_exec show "$interface" public-key || echo "")
    
    local peers_count
    peers_count=$(wg_exec show "$interface" peers | wc -l || echo "0")
    
    # Interface up status
    if ip_exec link show "$interface" &>/dev/null; then
        format_metric "interface_up" "1" "interface=\"${interface}\"" "WireGuard interface status (1=up, 0=down)"
    else
        format_metric "interface_up" "0" "interface=\"${interface}\"" "WireGuard interface status (1=up, 0=down)"
    fi
    
    # Listen port
    format_metric "interface_listen_port" "$listen_port" "interface=\"${interface}\"" "WireGuard interface listen port"
    
    # Number of peers
    format_metric "interface_peers" "$peers_count" "interface=\"${interface}\"" "Number of peers configured on interface"
}

# Function to collect peer metrics
collect_peer_metrics() {
    local interface="$1"
    
    # Get all peer public keys
    local peers
    peers=$(wg_exec show "$interface" peers || echo "")
    
    if [[ -z "$peers" ]]; then
        return 0
    fi
    
    # For each peer, collect detailed metrics
    while read -r peer_pubkey; do
        [[ -z "$peer_pubkey" ]] && continue
        
        # Get peer info using wg show dump format for better parsing
        local peer_info
        peer_info=$(wg_exec show "$interface" dump | grep "^${peer_pubkey}" || echo "")
        
        if [[ -z "$peer_info" ]]; then
            continue
        fi
        
        # Parse dump format: public-key preshared-key endpoint allowed-ips latest-handshake transfer-rx transfer-tx persistent-keepalive
        local endpoint allowed_ips latest_handshake transfer_rx transfer_tx persistent_keepalive
        
        endpoint=$(echo "$peer_info" | awk '{print $3}')
        allowed_ips=$(echo "$peer_info" | awk '{print $4}')
        latest_handshake=$(echo "$peer_info" | awk '{print $5}')
        transfer_rx=$(echo "$peer_info" | awk '{print $6}')
        transfer_tx=$(echo "$peer_info" | awk '{print $7}')
        persistent_keepalive=$(echo "$peer_info" | awk '{print $8}')
        
        # Get client name from mapping
        local client_name
        client_name=$(get_client_name "$peer_pubkey")
        
        # Use short version of public key for labels (first 8 chars)
        local peer_short="${peer_pubkey:0:8}"
        
        # Escape double quotes and backslashes in client name for Prometheus
        local safe_client_name=""
        if [[ -n "$client_name" ]]; then
            safe_client_name=$(echo "$client_name" | sed 's/\\/\\\\/g; s/"/\\"/g')
        fi
        
        # Build labels string
        local base_labels="interface=\"${interface}\",public_key=\"${peer_short}\""
        if [[ -n "$safe_client_name" ]]; then
            base_labels="${base_labels},client_name=\"${safe_client_name}\""
        fi
        if [[ -n "$endpoint" && "$endpoint" != "(none)" ]]; then
            base_labels="${base_labels},endpoint=\"${endpoint}\""
        fi
        
        # Peer connected status (handshake within last 3 minutes = 180 seconds)
        local current_time
        current_time=$(date +%s)
        local time_since_handshake=$((current_time - latest_handshake))
        
        if [[ "$latest_handshake" != "0" ]] && [[ $time_since_handshake -lt 180 ]]; then
            format_metric "peer_connected" "1" "$base_labels" "Peer connection status (1=connected, 0=disconnected)"
        else
            format_metric "peer_connected" "0" "$base_labels" "Peer connection status (1=connected, 0=disconnected)"
        fi
        
        # Latest handshake timestamp
        format_metric "peer_latest_handshake_seconds" "$latest_handshake" "$base_labels" "UNIX timestamp of the last handshake" "gauge"
        
        # Bytes received
        format_metric "peer_receive_bytes_total" "$transfer_rx" "$base_labels" "Total bytes received from peer" "counter"
        
        # Bytes transmitted
        format_metric "peer_transmit_bytes_total" "$transfer_tx" "$base_labels" "Total bytes transmitted to peer" "counter"
        
        # Persistent keepalive interval
        if [[ "$persistent_keepalive" != "off" ]] && [[ "$persistent_keepalive" != "0" ]]; then
            format_metric "peer_persistent_keepalive_interval" "$persistent_keepalive" "$base_labels" "Persistent keepalive interval in seconds"
        else
            format_metric "peer_persistent_keepalive_interval" "0" "$base_labels" "Persistent keepalive interval in seconds"
        fi
        
        # Number of allowed IPs
        local allowed_ips_count
        allowed_ips_count=$(echo "$allowed_ips" | tr ',' '\n' | wc -l)
        format_metric "peer_allowed_ips_count" "$allowed_ips_count" "$base_labels" "Number of allowed IP ranges for peer"
        
    done <<< "$peers"
}

# Function to get WireGuard version
get_version_info() {
    local version

    if [[ -n "$WIREGUARD_DOCKER_CONTAINER" ]]; then
        if command -v docker >/dev/null 2>&1; then
            version=$(docker exec "$WIREGUARD_DOCKER_CONTAINER" wg --version 2>&1 | head -1 | awk '{print $2}' || echo "unknown")
            format_metric "version_info" "1" "version=\"${version}\"" "WireGuard version information"
        fi
    elif command -v wg >/dev/null 2>&1; then
        version=$(wg --version 2>&1 | head -1 | awk '{print $2}' || echo "unknown")
        format_metric "version_info" "1" "version=\"${version}\"" "WireGuard version information"
    fi
}

# Main function to collect and output all metrics
collect_metrics() {
    # Load client names from JSON file (reloads on every scrape)
    load_client_names
    
    # Output metrics header
    echo "# AmneziaVPN Metrics"
    echo "# Generated at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo ""
    
    # Collect version info
    get_version_info
    echo ""
    
    # Get all interfaces
    local interfaces
    interfaces=$(get_interfaces)
    
    if [[ -z "$interfaces" ]]; then
        log "WARNING: No WireGuard interfaces found"
        format_metric "interfaces_total" "0" "" "Total number of WireGuard interfaces"
        return 0
    fi
    
    # Count total interfaces
    local interface_count
    interface_count=$(echo "$interfaces" | wc -l)
    format_metric "interfaces_total" "$interface_count" "" "Total number of WireGuard interfaces"
    echo ""
    
    # Collect metrics for each interface
    while read -r interface; do
        [[ -z "$interface" ]] && continue
        
        log "Collecting metrics for interface: $interface"
        
        # Collect interface metrics
        collect_interface_metrics "$interface"
        echo ""
        
        # Collect peer metrics
        collect_peer_metrics "$interface"
        echo ""
        
    done <<< "$interfaces"
}

# Function to test connectivity
test_connection() {
    log "Testing WireGuard exporter configuration..."
    
    local errors=0
    
    # Check if Docker container is specified
    if [[ -n "$WIREGUARD_DOCKER_CONTAINER" ]]; then
        log "Docker mode enabled: monitoring container '$WIREGUARD_DOCKER_CONTAINER'"
        
        # Check if docker command is available
        if ! command -v docker >/dev/null 2>&1; then
            log "ERROR: docker command not found. Please install Docker"
            errors=$((errors + 1))
        else
            log "SUCCESS: docker command is available"
        fi
        
        # Check if container exists and is running
        if ! docker ps --format '{{.Names}}' | grep -q "^${WIREGUARD_DOCKER_CONTAINER}$"; then
            log "ERROR: Container '$WIREGUARD_DOCKER_CONTAINER' is not running"
            log "Running containers: $(docker ps --format '{{.Names}}' | tr '\n' ' ')"
            errors=$((errors + 1))
        else
            log "SUCCESS: Container '$WIREGUARD_DOCKER_CONTAINER' is running"
        fi
        
        # Check if wg command is available in container
        if ! docker exec "$WIREGUARD_DOCKER_CONTAINER" which wg &>/dev/null; then
            log "ERROR: wg command not found in container"
            errors=$((errors + 1))
        else
            log "SUCCESS: wg command is available in container"
            
            # Check wg version in container
            local version
            version=$(docker exec "$WIREGUARD_DOCKER_CONTAINER" wg --version 2>&1 | head -1 || echo "unknown")
            log "WireGuard version (in container): $version"
        fi
    else
        log "Host mode: monitoring WireGuard on local system"
        
        # Check if wg command is available
        if ! command -v wg >/dev/null 2>&1; then
            log "ERROR: wg command not found. Please install wireguard-tools"
            errors=$((errors + 1))
        else
            log "SUCCESS: wg command is available"
            
            # Check wg version
            local version
            version=$(wg --version 2>&1 | head -1 || echo "unknown")
            log "WireGuard version: $version"
        fi
        
        # Check if we have permission to run wg
        if ! wg show &>/dev/null; then
            log "WARNING: Cannot execute 'wg show'. You may need to run as root or with CAP_NET_ADMIN"
            log "Try: sudo -E $0 test"
            errors=$((errors + 1))
        else
            log "SUCCESS: Can execute 'wg show'"
        fi
    fi
    
    # Test client table loading
    if [[ -n "$CLIENTS_TABLE_FILE" ]]; then
        log "Testing clients table loading from: $CLIENTS_TABLE_FILE"
        load_client_names
        if [[ ${#CLIENT_NAMES[@]} -gt 0 ]]; then
            log "SUCCESS: Loaded ${#CLIENT_NAMES[@]} client mappings"
            # Show first few mappings
            local count=0
            for key in "${!CLIENT_NAMES[@]}"; do
                if [[ $count -lt 5 ]]; then
                    log "  ${key:0:16}... -> ${CLIENT_NAMES[$key]}"
                    ((count++))
                fi
            done
        else
            log "WARNING: No client mappings loaded from $CLIENTS_TABLE_FILE"
            errors=$((errors + 1))
        fi
    else
        log "INFO: CLIENTS_TABLE_FILE not set - client name mapping disabled"
    fi
    
    # Check for interfaces
    local interfaces
    interfaces=$(get_interfaces)
    
    if [[ -z "$interfaces" ]]; then
        log "WARNING: No WireGuard interfaces found"
        log "Make sure WireGuard is configured and interfaces are up"
        errors=$((errors + 1))
    else
        log "SUCCESS: Found WireGuard interface(s): $(echo $interfaces | tr '\n' ' ')"
        
        # Show interface details
        while read -r interface; do
            [[ -z "$interface" ]] && continue
            
            local peers_count
            peers_count=$(wg_exec show "$interface" peers | wc -l || echo "0")
            log "Interface $interface has $peers_count peer(s)"
        done <<< "$interfaces"
    fi
    
    if [[ $errors -eq 0 ]]; then
        log "Configuration test completed successfully"
        return 0
    else
        log "Configuration test completed with $errors errors/warnings"
        return 1
    fi
}

# Handle command line arguments
case "${1:-collect}" in
    "collect"|"metrics"|"")
        # Collect and output metrics
        collect_metrics
        ;;
    "test")
        test_connection
        ;;
    "version")
        echo "AmneziaVPN Exporter v1.0.0"
        ;;
    "help"|"-h"|"--help")
        echo "Usage: $0 [collect|test|version|help]"
        echo ""
        echo "Commands:"
        echo "  collect  - Collect and output Prometheus metrics (default)"
        echo "  test     - Test configuration and WireGuard accessibility"
        echo "  version  - Show exporter version"
        echo "  help     - Show this help message"
        echo ""
        echo "Environment variables:"
        echo "  WIREGUARD_INTERFACE        - Specific interface to monitor (default: all interfaces)"
        echo "  WIREGUARD_DOCKER_CONTAINER - Docker container name running WireGuard (optional)"
        echo "  METRICS_PREFIX             - Metrics prefix (default: wireguard)"
        echo "  CLIENTS_TABLE_FILE         - Path to JSON file with client names mapping (optional)"
        ;;
    *)
        log "ERROR: Unknown command: $1"
        echo "Use '$0 help' for usage information"
        exit 1
        ;;
esac