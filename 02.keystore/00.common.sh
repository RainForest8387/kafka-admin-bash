#!/bin/bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

log() {
    local level="$1"
    shift
    printf '%s [%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$SCRIPT_NAME" "$*"
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@" >&2; }

die() {
    log_error "$@"
    exit 1
}

confirm() {
    local answer
    read -r -p "${1:-Continue? (Y/N): }" answer
    [[ "$answer" =~ ^([yY]|[yY][eE][sS])$ ]]
}

check_command() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found in PATH: $cmd"
}

require_file() {
    local file_path="$1"
    [[ -f "$file_path" ]] || die "Required file not found: $file_path"
}

require_dir() {
    local dir_path="$1"
    [[ -d "$dir_path" ]] || die "Required directory not found: $dir_path"
}

read_nonempty() {
    local prompt="$1"
    local __var_name="$2"
    local value
    read -r -p "$prompt" value
    [[ -n "$value" ]] || die "Input cannot be empty"
    printf -v "$__var_name" '%s' "$value"
}

read_secret() {
    local prompt="$1"
    local __var_name="$2"
    local value
    read -r -s -p "$prompt" value
    echo
    [[ -n "$value" ]] || die "Secret value cannot be empty"
    printf -v "$__var_name" '%s' "$value"
}

read_brokers() {
    local count="$1"
    local i broker_name
    brokers=()
    for ((i=1; i<=count; i++)); do
        read -r -p "Enter broker #$i cert filename without .cer (example: kfk-lt-int0$i): " broker_name
        [[ -n "$broker_name" ]] || die "Broker #$i name cannot be empty"
        brokers+=("$broker_name")
    done
}

validate_broker_count() {
    case "$1" in
        1|3|5) ;;
        *) die "Number of brokers is wrong, it MUST be 1, 3 or 5" ;;
    esac
}

import_cert() {
    local keystore="$1"
    local storepass="$2"
    local alias_name="$3"
    local file_path="$4"

    require_file "$file_path"
    log_info "Importing certificate: alias=$alias_name, file=$file_path, keystore=$keystore"

    keytool -importcert -trustcacerts \
        -keystore "$keystore" \
        -storepass "$storepass" \
        -noprompt \
        -alias "$alias_name" \
        -file "$file_path"
}

import_old_cert_if_needed() {
    local enabled="$1"
    local old_dir="$2"
    local keystore="$3"
    local storepass="$4"
    local alias_name="$5"
    local file_name="$6"
    local old_file="${old_dir}/${file_name}"

    [[ "$enabled" == true ]] || return 0

    if [[ -f "$old_file" ]]; then
        import_cert "$keystore" "$storepass" "${alias_name}_old" "$old_file"
    else
        log_warn "Old certificate not found, skipping: $old_file"
    fi
}

validate_ca_files() {
    local item file_path
    local -n ca_array_ref="$1"

    for item in "${ca_array_ref[@]}"; do
        file_path="${item#*:}"
        require_file "$file_path"
    done
}

import_ca_certs() {
    local keystore="$1"
    local storepass="$2"
    local -n ca_array_ref="$3"
    local item alias_name file_path

    for item in "${ca_array_ref[@]}"; do
        alias_name="${item%%:*}"
        file_path="${item#*:}"
        import_cert "$keystore" "$storepass" "$alias_name" "$file_path"
    done
}

validate_cert_key_match() {
    local cert_file="$1"
    local key_file="$2"
    local cert_mod key_mod

    cert_mod="$(openssl x509 -noout -modulus -in "$cert_file" | openssl md5)"
    key_mod="$(openssl rsa -noout -modulus -in "$key_file" | openssl md5)"

    [[ "$cert_mod" == "$key_mod" ]] || die "Certificate and private key do not match"
}

show_keystore_type_info() {
    local keystore="$1"
    local storepass="$2"
    log_info "Checking resulting keystore type and provider"
    keytool -list -keystore "$keystore" -storepass "$storepass" | grep -E 'Keystore type|Keystore provider'
}

show_keystore_verbose() {
    local keystore="$1"
    local storepass="$2"
    log_info "Checking created keystore: $keystore"
    keytool -list -v -keystore "$keystore" -storepass "$storepass"
}
