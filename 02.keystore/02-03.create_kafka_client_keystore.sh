#!/bin/bash
# shellcheck shell=bash
# shellcheck source=./00.common.sh
# Description: Create kafka client keystore
# Usage: ./02-03.create_kafka_client_keystore.sh

set -euo pipefail
source "$(dirname "$0")/00.common.sh"

KEYSTORE_P12="client.keystore.p12"
KEYSTORE_JKS="client.keystore.jks"

main() {
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

    [[ ! -f "$KEYSTORE_P12" ]] || { log_warn "Existing file will be overwritten: $KEYSTORE_P12"; rm -f "$KEYSTORE_P12"; }
    [[ ! -f "$KEYSTORE_JKS" ]] || { log_warn "Existing file will be overwritten: $KEYSTORE_JKS"; rm -f "$KEYSTORE_JKS"; }

    log_info "Creating PKCS12 keystore"
    openssl pkcs12 -export \
        -out "$KEYSTORE_P12" \
        -in "$cert_name" \
        -inkey "$key_name" \
        -name "$cert_alias" \
        -passout pass:"$storepass"

    log_info "Creating JKS keystore from PKCS12"
    keytool -importkeystore \
        -srckeystore "$KEYSTORE_P12" \
        -srcstoretype PKCS12 \
        -srcstorepass "$storepass" \
        -destkeystore "$KEYSTORE_JKS" \
        -deststoretype JKS \
        -deststorepass "$storepass" \
        -noprompt

    show_keystore_verbose "$KEYSTORE_JKS" "$storepass"
    log_info "Kafka client keystore successfully created"
}

main "$@"
