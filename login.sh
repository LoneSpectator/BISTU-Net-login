#!/bin/sh

# BISTU campus network auto-login daemon.
# Designed for BusyBox/embedded Linux containers.

set -u
umask 077

DATA_DIR="${DATA_DIR:-/data}"
CONFIG_FILE="$DATA_DIR/login.conf"
LOG_DIR="$DATA_DIR/log"
LAST_RESPONSE_FILE="$DATA_DIR/last_response.txt"
LAST_WGET_STDERR_FILE="$DATA_DIR/last_wget_stderr.txt"

# Defaults. Any of these can be overridden by /data/login.conf.
USERNAME=""
PASSWORD=""
AUTH_SERVER_IP="10.144.49.2"
AUTH_SERVER_PORT="802"
LOOP_INTERVAL_SECONDS="60"
PING_IP="223.6.6.6"
LOG_RETENTION_DAYS="7"
DEBUG="false"
CLIENT_IP=""
CLIENT_MAC=""

DEBUG_ENABLED=0
RUNNING=1
SLEEP_PID=""
LAST_STATE="unknown"
LAST_CLEANUP_DATE=""
PING_CHECK_ATTEMPTS=3
PING_ATTEMPTS_USED=0

log_message() {
    level="$1"
    shift
    now="$(date '+%Y-%m-%d %H:%M:%S')"
    log_file="$LOG_DIR/${now%% *}.log"

    # Write the same log line to the container console and the daily log file.
    # Avoid tee so embedded systems do not need an extra process per log entry.
    printf '%s [%s] %s\n' "$now" "$level" "$*"
    printf '%s [%s] %s\n' "$now" "$level" "$*" >> "$log_file"
}

debug_message() {
    if [ "$DEBUG_ENABLED" -eq 1 ]; then
        log_message "DEBUG" "$*"
    fi
}

fatal() {
    log_message "ERROR" "$*"
    exit 1
}

normalize_bool() {
    value_lc="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$value_lc" in
        1|true|yes|on)
            printf '1'
            ;;
        *)
            printf '0'
            ;;
    esac
}

strip_optional_quotes() {
    quoted_value="$1"
    case "$quoted_value" in
        \"*\")
            quoted_value=${quoted_value#\"}
            quoted_value=${quoted_value%\"}
            ;;
        \'*\')
            quoted_value=${quoted_value#\'}
            quoted_value=${quoted_value%\'}
            ;;
    esac
    printf '%s' "$quoted_value"
}

load_config() {
    if [ ! -r "$CONFIG_FILE" ]; then
        fatal "Cannot read config file: $CONFIG_FILE"
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        line="$(printf '%s' "$line" | tr -d '\r')"

        case "$line" in
            ''|'#'*)
                continue
                ;;
            *=*)
                ;;
            *)
                continue
                ;;
        esac

        key=${line%%=*}
        value=${line#*=}
        key="$(printf '%s' "$key" | tr -d ' \t')"
        value="$(strip_optional_quotes "$value")"

        case "$key" in
            USERNAME)
                USERNAME="$value"
                ;;
            PASSWORD)
                PASSWORD="$value"
                ;;
            AUTH_SERVER_IP|AUTH_SERVER)
                AUTH_SERVER_IP="$value"
                ;;
            AUTH_SERVER_PORT)
                AUTH_SERVER_PORT="$value"
                ;;
            LOOP_INTERVAL_SECONDS|INTERVAL_SECONDS)
                LOOP_INTERVAL_SECONDS="$value"
                ;;
            PING_IP|PING_TARGET)
                PING_IP="$value"
                ;;
            LOG_RETENTION_DAYS)
                LOG_RETENTION_DAYS="$value"
                ;;
            DEBUG)
                DEBUG="$value"
                ;;
            CLIENT_IP)
                CLIENT_IP="$value"
                ;;
            CLIENT_MAC)
                CLIENT_MAC="$value"
                ;;
        esac
    done < "$CONFIG_FILE"

    DEBUG_ENABLED="$(normalize_bool "$DEBUG")"
}

validate_positive_integer() {
    number="$1"
    field_name="$2"
    case "$number" in
        ''|*[!0-9]*)
            fatal "$field_name must be a positive integer."
            ;;
    esac
    if [ "$number" -le 0 ]; then
        fatal "$field_name must be greater than 0."
    fi
}

validate_config() {
    [ -n "$USERNAME" ] || fatal "USERNAME is required."
    [ -n "$PASSWORD" ] || fatal "PASSWORD is required."
    [ -n "$AUTH_SERVER_IP" ] || fatal "AUTH_SERVER_IP cannot be empty."
    [ -n "$PING_IP" ] || fatal "PING_IP cannot be empty."

    validate_positive_integer "$AUTH_SERVER_PORT" "AUTH_SERVER_PORT"
    if [ "$AUTH_SERVER_PORT" -gt 65535 ]; then
        fatal "AUTH_SERVER_PORT must be between 1 and 65535."
    fi
    validate_positive_integer "$LOOP_INTERVAL_SECONDS" "LOOP_INTERVAL_SECONDS"
    validate_positive_integer "$LOG_RETENTION_DAYS" "LOG_RETENTION_DAYS"
}

normalize_mac() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[.:-]//g'
}

validate_mac() {
    mac_value="$1"
    case "$mac_value" in
        *[!0-9a-f]*|'')
            return 1
            ;;
    esac
    [ "${#mac_value}" -eq 12 ]
}

# Percent-encode every byte. This is deliberately simple and handles UTF-8,
# spaces, &, =, # and other characters safely without Python/Perl/curl.
url_encode() {
    raw_value="$1"
    hex_value="$(printf '%s' "$raw_value" | od -An -tx1 | tr -d ' \n')"
    encoded_value=""

    while [ -n "$hex_value" ]; do
        byte=${hex_value%"${hex_value#??}"}
        hex_value=${hex_value#??}
        encoded_value="${encoded_value}%${byte}"
    done

    printf '%s' "$encoded_value"
}

detect_client_network() {
    DETECTED_INTERFACE=""
    DETECTED_IP=""
    DETECTED_MAC=""

    route_line="$(ip route get "$AUTH_SERVER_IP" 2>/dev/null | sed -n '1p')"
    if [ -n "$route_line" ]; then
        DETECTED_INTERFACE="$(printf '%s\n' "$route_line" | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')"
        DETECTED_IP="$(printf '%s\n' "$route_line" | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')"
    fi

    if [ -n "$CLIENT_IP" ]; then
        DETECTED_IP="$CLIENT_IP"
    elif [ -z "$DETECTED_IP" ] && [ -n "$DETECTED_INTERFACE" ]; then
        DETECTED_IP="$(ip -4 addr show dev "$DETECTED_INTERFACE" 2>/dev/null | awk '/inet / {sub(/\/.*/, "", $2); print $2; exit}')"
    fi

    if [ -n "$CLIENT_MAC" ]; then
        DETECTED_MAC="$(normalize_mac "$CLIENT_MAC")"
    elif [ -n "$DETECTED_INTERFACE" ]; then
        DETECTED_MAC="$(ip link show dev "$DETECTED_INTERFACE" 2>/dev/null | awk '/link\/ether/ {print $2; exit}')"
        DETECTED_MAC="$(normalize_mac "$DETECTED_MAC")"
    fi

    [ -n "$DETECTED_IP" ] || return 1
    validate_mac "$DETECTED_MAC" || return 1

    return 0
}

build_login_url() {
    encoded_username="$(url_encode "$USERNAME")"
    encoded_password="$(url_encode "$PASSWORD")"

    LOGIN_URL="https://${AUTH_SERVER_IP}:${AUTH_SERVER_PORT}/eportal/portal/login?callback=dr1004&login_method=1&user_account=%2C0%2C${encoded_username}&user_password=${encoded_password}&wlan_user_ip=${DETECTED_IP}&wlan_user_mac=${DETECTED_MAC}&wlan_vlan_id=0&wlan_ac_ip=&wlan_ac_name=&authex_enable=undefined&jsVersion=4.2.1&terminal_type=1&lang=zh-cn&v=1907&lang=zh"
}

check_online() {
    ping_attempt=1
    PING_ATTEMPTS_USED=0

    while [ "$ping_attempt" -le "$PING_CHECK_ATTEMPTS" ]; do
        PING_ATTEMPTS_USED="$ping_attempt"

        if ping -c 1 -W 2 "$PING_IP" >/dev/null 2>&1; then
            return 0
        fi

        ping_attempt=$((ping_attempt + 1))
    done

    return 1
}

cleanup_old_logs() {
    current_date="$(date '+%Y-%m-%d')"
    [ "$current_date" = "$LAST_CLEANUP_DATE" ] && return 0

    # Keep today's log plus the previous N-1 daily logs under normal clock behavior.
    retention_mtime=$((LOG_RETENTION_DAYS - 1))
    find "$LOG_DIR" -type f -name '*.log' -mtime "+$retention_mtime" -exec rm -f {} \; 2>/dev/null || true
    LAST_CLEANUP_DATE="$current_date"
    debug_message "Log retention cleanup completed; keep_days=$LOG_RETENTION_DAYS"
}

attempt_login() {
    if ! detect_client_network; then
        log_message "ERROR" "Cannot determine client IP/MAC for authentication. Set CLIENT_IP and/or CLIENT_MAC in $CONFIG_FILE if auto-detection is not suitable."
        return 1
    fi

    debug_message "Network detection: interface=${DETECTED_INTERFACE:-unknown}, client_ip=$DETECTED_IP, client_mac=$DETECTED_MAC, ip_override=$([ -n "$CLIENT_IP" ] && printf yes || printf no), mac_override=$([ -n "$CLIENT_MAC" ] && printf yes || printf no)"

    build_login_url

    response_tmp="/tmp/bistu-login-response.$$"
    wget_log_tmp="/tmp/bistu-login-wget.$$"
    rm -f "$response_tmp" "$wget_log_tmp"

    debug_message "Portal request: server=${AUTH_SERVER_IP}:${AUTH_SERVER_PORT}, username=$USERNAME, client_ip=$DETECTED_IP, client_mac=$DETECTED_MAC"

    wget --no-check-certificate -T 30 -O "$response_tmp" "$LOGIN_URL" > /dev/null 2> "$wget_log_tmp"
    wget_status=$?

    if [ "$DEBUG_ENABLED" -eq 1 ]; then
        # Retain the raw response body and wget stderr from the most recent authentication request for troubleshooting.

        if [ -f "$response_tmp" ]; then
            cp "$response_tmp" "$LAST_RESPONSE_FILE"
        else
            : > "$LAST_RESPONSE_FILE"
        fi

        if [ -f "$wget_log_tmp" ]; then
            cp "$wget_log_tmp" "$LAST_WGET_STDERR_FILE"
        else
            : > "$LAST_WGET_STDERR_FILE"
        fi

        response_bytes="$(wc -c < "$LAST_RESPONSE_FILE" | tr -d ' ')"
        wget_stderr_bytes="$(wc -c < "$LAST_WGET_STDERR_FILE" | tr -d ' ')"

        debug_message "Portal response saved: file=$LAST_RESPONSE_FILE, bytes=${response_bytes:-0}, wget_exit=$wget_status"
        debug_message "wget stderr saved: file=$LAST_WGET_STDERR_FILE, bytes=${wget_stderr_bytes:-0}"
    fi

    rm -f "$response_tmp" "$wget_log_tmp"

    if [ "$wget_status" -ne 0 ]; then
        log_message "ERROR" "Portal request failed; wget exit code: $wget_status"
        return 1
    fi

    log_message "INFO" "Portal request completed."

    sleep 5
    if check_online; then
        log_message "INFO" "Internet connection restored."
        LAST_STATE="online"
        return 0
    fi

    log_message "WARN" "Internet is still unavailable after portal login."
    LAST_STATE="offline"
    return 1
}

stop_service() {
    RUNNING=0
    if [ -n "$SLEEP_PID" ]; then
        kill "$SLEEP_PID" 2>/dev/null || true
    fi
}

trap stop_service TERM INT HUP

mkdir -p "$LOG_DIR" || exit 1

load_config
validate_config

if [ "$DEBUG_ENABLED" -eq 0 ]; then
    # Avoid leaving stale response data after debug mode has been disabled.
    rm -f "$LAST_RESPONSE_FILE" "$LAST_WGET_STDERR_FILE"
fi

log_message "INFO" "BISTU login service started."
debug_message "Configuration: auth_server=${AUTH_SERVER_IP}:${AUTH_SERVER_PORT}, interval=${LOOP_INTERVAL_SECONDS}s, ping_ip=$PING_IP, log_retention=${LOG_RETENTION_DAYS}d, debug=$DEBUG, client_ip=${CLIENT_IP:-auto}, client_mac=${CLIENT_MAC:-auto}"

while [ "$RUNNING" -eq 1 ]; do
    cleanup_old_logs

    if check_online; then
        debug_message "Connectivity check succeeded: ping_ip=$PING_IP, attempts=$PING_ATTEMPTS_USED/$PING_CHECK_ATTEMPTS"
        if [ "$LAST_STATE" != "online" ]; then
            log_message "INFO" "Internet connection is available."
        fi
        LAST_STATE="online"
    else
        debug_message "Connectivity check failed: ping_ip=$PING_IP, attempts=$PING_ATTEMPTS_USED/$PING_CHECK_ATTEMPTS"
        if [ "$LAST_STATE" != "offline" ]; then
            log_message "WARN" "Internet connection is unavailable; starting portal login."
        fi
        LAST_STATE="offline"
        attempt_login || true
    fi

    [ "$RUNNING" -eq 1 ] || break

    sleep "$LOOP_INTERVAL_SECONDS" &
    SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null || true
    SLEEP_PID=""
done

log_message "INFO" "BISTU login service stopped."
exit 0
