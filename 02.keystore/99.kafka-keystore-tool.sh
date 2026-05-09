#!/bin/bash
# shellcheck shell=bash
# Description: Unified Kafka keystore/truststore management tool
# Usage: ./kafka-keystore-tool.sh <command>

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
    case "${answer,,}" in
        y|yes) return 0 ;;
        *) return 1 ;;
    esac
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

validate_cert_key_match() {
    local cert_file="$1"
    local key_file="$2"
    local cert_mod key_mod

    cert_mod="$(openssl x509 -noout -modulus -in "$cert_file" | openssl md5)"
    key_mod="$(openssl rsa -noout -modulus -in "$key_file" | openssl md5)"

    [[ "$cert_mod" == "$key_mod" ]] || die "Certificate and private key do not match"
}

validate_ca_files() {
    local item file_path
    for item in "${CA_CERTS[@]}"; do
        file_path="${item#*:}"
        require_file "$file_path"
    done
}

import_ca_certs() {
    local keystore="$1"
    local storepass="$2"
    local item alias_name file_path

    for item in "${CA_CERTS[@]}"; do
        alias_name="${item%%:*}"
        file_path="${item#*:}"
        import_cert "$keystore" "$storepass" "$alias_name" "$file_path"
    done
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

get_ca_certs() {
    local ca_dir="$1"
    CA_CERTS=(
        "cbm-root-ca:${ca_dir}/cbm-root-ca.pem"
        "issuing:${ca_dir}/issuing.pem"
        "mkb-rsa-root-ca:${ca_dir}/mkb-rsa-root-ca.pem"
        "mkb-rsa-policy-ca:${ca_dir}/mkb-rsa-policy-ca.pem"
        "mkb-rsa-issuing-ca1:${ca_dir}/mkb-rsa-issuing-ca1.pem"
    )
}

usage() {
    cat <<'EOF'
Unified Kafka keystore/truststore management tool.

Usage:
  ./kafka-keystore-tool.sh <command>

Commands:
  server-keystore      Create server.keystore.p12 and server.keystore.jks
  server-truststore    Create server.truststore.jks and server.truststore.p12
  client-keystore      Create client.keystore.p12 and client.keystore.jks
  client-truststore    Create client.truststore.jks and client.truststore.p12
  help                 Show this help
EOF
}

create_server_keystore() {
    local cert_name key_name cert_alias storepass
    local keystore_p12="server.keystore.p12"
    local keystore_jks="server.keystore.jks"

    log_info "Starting kafka server keystore creation"
    check_command "openssl"
    check_command "keytool"

    read_nonempty "Enter cert_name (for example kfk-tst-pci.cer): " cert_name
    require_file "$cert_name"
    log_info "Certificate file provided: $cert_name"
    confirm "Continue? (Y/N): " || die "Operation cancelled by user"

    read_nonempty "Enter key_name (for example kfk-tst-pci.key): " key_name
    require_file "$key_name"
    log_info "Private key file provided: $key_name"
    confirm "Continue? (Y/N): " || die "Operation cancelled by user"

    read_nonempty "Enter cert_alias_name (for example kfk-tst-pci): " cert_alias
    log_info "Certificate alias provided: $cert_alias"
    confirm "Continue? (Y/N): " || die "Operation cancelled by user"

    read_secret "Enter storepass: " storepass

    validate_cert_key_match "$cert_name" "$key_name"
    log_info "Certificate and private key match"

    [[ ! -f "$keystore_p12" ]] || { log_warn "Existing file will be overwritten: $keystore_p12"; rm -f "$keystore_p12"; }
    [[ ! -f "$keystore_jks" ]] || { log_warn "Existing file will be overwritten: $keystore_jks"; rm -f "$keystore_jks"; }

    log_info "Creating PKCS12 keystore"
    openssl pkcs12 -export \
        -out "$keystore_p12" \
        -in "$cert_name" \
        -inkey "$key_name" \
        -name "$cert_alias" \
        -passout pass:"$storepass"

    log_info "Creating JKS keystore from PKCS12"
    keytool -importkeystore \
        -srckeystore "$keystore_p12" \
        -srcstoretype PKCS12 \
        -srcstorepass "$storepass" \
        -destkeystore "$keystore_jks" \
        -deststoretype JKS \
        -deststorepass "$storepass" \
        -noprompt

    show_keystore_verbose "$keystore_jks" "$storepass"
    log_info "Kafka server keystore successfully created"
}

create_client_keystore() {
    local cert_name key_name cert_alias storepass
    local keystore_p12="client.keystore.p12"
    local keystore_jks="client.keystore.jks"

    log_info "Starting kafka client keystore creation"
    check_command "openssl"
    check_command "keytool"

    read_nonempty "Enter cert_name (for example kfk-tst-pci.cer): " cert_name
    require_file "$cert_name"
    log_info "Certificate file provided: $cert_name"
    confirm "Continue? (Y/N): " || die "Operation cancelled by user"

    read_nonempty "Enter key_name (for example kfk-tst-pci.key): " key_name
    require_file "$key_name"
    log_info "Private key file provided: $key_name"
    confirm "Continue? (Y/N): " || die "Operation cancelled by user"

    read_nonempty "Enter cert_alias_name (for example kfk-tst-pci): " cert_alias
    log_info "Certificate alias provided: $cert_alias"
    confirm "Continue? (Y/N): " || die "Operation cancelled by user"

    read_secret "Enter storepass: " storepass

    validate_cert_key_match "$cert_name" "$key_name"
    log_info "Certificate and private key match"

    [[ ! -f "$keystore_p12" ]] || { log_warn "Existing file will be overwritten: $keystore_p12"; rm -f "$keystore_p12"; }
    [[ ! -f "$keystore_jks" ]] || { log_warn "Existing file will be overwritten: $keystore_jks"; rm -f "$keystore_jks"; }

    log_info "Creating PKCS12 keystore"
    openssl pkcs12 -export \
        -out "$keystore_p12" \
        -in "$cert_name" \
        -inkey "$key_name" \
        -name "$cert_alias" \
        -passout pass:"$storepass"

    log_info "Creating JKS keystore from PKCS12"
    keytool -importkeystore \
        -srckeystore "$keystore_p12" \
        -srcstoretype PKCS12 \
        -srcstorepass "$storepass" \
        -destkeystore "$keystore_jks" \
        -deststoretype JKS \
        -deststorepass "$storepass" \
        -noprompt

    show_keystore_verbose "$keystore_jks" "$storepass"
    log_info "Kafka client keystore successfully created"
}

create_server_truststore() {
    local cert_name cert_alias storepass broker_counter broker
    local import_old_certs
    local truststore_jks="server.truststore.jks"
    local truststore_p12="server.truststore.p12"
    local old_cert_dir="broker_cert_old"
    local ca_dir="CA"

    get_ca_certs "$ca_dir"

    log_info "Starting kafka server truststore creation"
    check_command "keytool"
    require_dir "$ca_dir"

    log_info "CA certificates should be located in ${ca_dir} subdir"
    confirm "Continue? (Y/N): " || die "Operation cancelled by user"

    if confirm "Is this the FIRST creation of kafka server truststore? (Y/N): "; then
        import_old_certs=false
        log_info "First truststore creation selected, old certificates will not be imported"
    else
        import_old_certs=true
        require_dir "$old_cert_dir"
        log_info "Previous broker and client certificates should be located in ${old_cert_dir} subdir"
        confirm "Continue? (Y/N): " || die "Operation cancelled by user"
    fi

    read_nonempty "Enter client cert full name (for example kfk-tst-pci-clnt.cer): " cert_name
    log_info "Client certificate file provided: $cert_name"
    confirm "Continue? (Y/N): " || die "Operation cancelled by user"

    read_nonempty "Enter client cert alias name (for example kfk-tst-pci-clnt): " cert_alias
    log_info "Client certificate alias provided: $cert_alias"
    confirm "Continue? (Y/N): " || die "Operation cancelled by user"

    read_secret "Enter storepass: " storepass
    read_nonempty "Enter number of brokers, it MUST be 1, 3 or 5: " broker_counter
    validate_broker_count "$broker_counter"
    read_brokers "$broker_counter"

    validate_ca_files
    for broker in "${brokers[@]}"; do
        require_file "${broker}.cer"
        if [[ "$import_old_certs" == true && ! -f "${old_cert_dir}/${broker}.cer" ]]; then
            log_warn "Old broker certificate will be skipped because file not found: ${old_cert_dir}/${broker}.cer"
        fi
    done
    require_file "$cert_name"
    if [[ "$import_old_certs" == true && ! -f "${old_cert_dir}/${cert_name}" ]]; then
        log_warn "Old client certificate will be skipped because file not found: ${old_cert_dir}/${cert_name}"
    fi

    [[ ! -f "$truststore_jks" ]] || { log_warn "Existing file will be overwritten/updated: $truststore_jks"; rm -f "$truststore_jks"; }
    [[ ! -f "$truststore_p12" ]] || { log_warn "Existing file will be overwritten/updated: $truststore_p12"; rm -f "$truststore_p12"; }

    for broker in "${brokers[@]}"; do
        import_cert "$truststore_jks" "$storepass" "$broker" "${broker}.cer"
        import_old_cert_if_needed "$import_old_certs" "$old_cert_dir" "$truststore_jks" "$storepass" "$broker" "${broker}.cer"
    done

    import_ca_certs "$truststore_jks" "$storepass"
    import_cert "$truststore_jks" "$storepass" "$cert_alias" "$cert_name"
    import_old_cert_if_needed "$import_old_certs" "$old_cert_dir" "$truststore_jks" "$storepass" "$cert_alias" "$cert_name"

    log_info "Converting JKS to PKCS12"
    keytool -importkeystore \
        -srckeystore "$truststore_jks" \
        -srcstoretype JKS \
        -destkeystore "$truststore_p12" \
        -deststoretype PKCS12 \
        -srcstorepass "$storepass" \
        -deststorepass "$storepass" \
        -noprompt

    log_info "Kafka server truststore successfully created"
}

create_client_truststore() {
    local storepass broker_counter broker
    local import_old_certs
    local truststore_jks="client.truststore.jks"
    local truststore_p12="client.truststore.p12"
    local old_cert_dir="broker_cert_old"
    local ca_dir="CA"
    local temp_jks

    get_ca_certs "$ca_dir"

    log_info "Starting kafka client truststore creation"
    check_command "keytool"
    require_dir "$ca_dir"

    log_info "CA certificates should be located in ${ca_dir} subdir"
    confirm "Continue? (Y/N): " || die "Operation cancelled by user"

    if confirm "Is this the FIRST creation of kafka client truststore? (Y/N): "; then
        import_old_certs=false
        log_info "First truststore creation selected, old certificates will not be imported"
    else
        import_old_certs=true
        require_dir "$old_cert_dir"
        log_info "Previous broker certificates should be located in ${old_cert_dir} subdir"
        confirm "Continue? (Y/N): " || die "Operation cancelled by user"
    fi

    read_secret "Enter storepass: " storepass
    read_nonempty "Enter number of brokers, it MUST be 1, 3 or 5: " broker_counter
    validate_broker_count "$broker_counter"
    read_brokers "$broker_counter"

    validate_ca_files
    for broker in "${brokers[@]}"; do
        require_file "${broker}.cer"
        if [[ "$import_old_certs" == true && ! -f "${old_cert_dir}/${broker}.cer" ]]; then
            log_warn "Old broker certificate will be skipped because file not found: ${old_cert_dir}/${broker}.cer"
        fi
    done

    [[ ! -f "$truststore_jks" ]] || { log_warn "Existing file will be overwritten/updated: $truststore_jks"; rm -f "$truststore_jks"; }
    [[ ! -f "$truststore_p12" ]] || { log_warn "Existing file will be overwritten/updated: $truststore_p12"; rm -f "$truststore_p12"; }

    for broker in "${brokers[@]}"; do
        import_cert "$truststore_jks" "$storepass" "$broker" "${broker}.cer"
        import_old_cert_if_needed "$import_old_certs" "$old_cert_dir" "$truststore_jks" "$storepass" "$broker" "${broker}.cer"
    done

    import_ca_certs "$truststore_jks" "$storepass"

    log_info "Converting JKS to PKCS12"
    keytool -importkeystore \
        -srckeystore "$truststore_jks" \
        -srcstoretype JKS \
        -destkeystore "$truststore_p12" \
        -deststoretype PKCS12 \
        -srcstorepass "$storepass" \
        -deststorepass "$storepass" \
        -noprompt

    temp_jks="${truststore_jks}.tmp"
    log_info "Rebuilding truststore explicitly as JKS"
    rm -f "$temp_jks"
    keytool -importkeystore \
        -srckeystore "$truststore_p12" \
        -srcstoretype PKCS12 \
        -destkeystore "$temp_jks" \
        -deststoretype JKS \
        -srcstorepass "$storepass" \
        -deststorepass "$storepass" \
        -noprompt
    mv -f "$temp_jks" "$truststore_jks"

    show_keystore_type_info "$truststore_jks" "$storepass"
    log_info "Kafka client truststore successfully created"
}

main() {
    local command="${1:-help}"

    case "$command" in
        server-keystore)
            create_server_keystore
            ;;
        server-truststore)
            create_server_truststore
            ;;
        client-keystore)
            create_client_keystore
            ;;
        client-truststore)
            create_client_truststore
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            die "Unknown command: $command. Run './$SCRIPT_NAME help'"
            ;;
    esac
}

main "$@"
