#!/bin/bash
# # shellcheck shell=bash
# shellcheck source=./00.common.sh
# Description: create kafka server truststore
# Usage: ./02-02.create_kafka_server_truststore.sh

set -euo pipefail
source "$(dirname "$0")/00.common.sh"

TRUSTSTORE_JKS="server.truststore.jks"
TRUSTSTORE_P12="server.truststore.p12"
OLD_CERT_DIR="broker_cert_old"
CA_DIR="CA"

CA_CERTS=(
    "cbm-root-ca:${CA_DIR}/cbm-root-ca.pem"
    "issuing:${CA_DIR}/issuing.pem"
    "mkb-rsa-root-ca:${CA_DIR}/mkb-rsa-root-ca.pem"
    "mkb-rsa-policy-ca:${CA_DIR}/mkb-rsa-policy-ca.pem"
    "mkb-rsa-issuing-ca1:${CA_DIR}/mkb-rsa-issuing-ca1.pem"
)

validate_broker_files() {
    local broker
    for broker in "${brokers[@]}"; do
        require_file "${broker}.cer"
        if [[ "$import_old_certs" == true && ! -f "${OLD_CERT_DIR}/${broker}.cer" ]]; then
            log_warn "Old broker certificate will be skipped because file not found: ${OLD_CERT_DIR}/${broker}.cer"
        fi
    done
}

validate_client_files() {
    require_file "$cert_name"
    if [[ "$import_old_certs" == true && ! -f "${OLD_CERT_DIR}/${cert_name}" ]]; then
        log_warn "Old client certificate will be skipped because file not found: ${OLD_CERT_DIR}/${cert_name}"
    fi
}

main() {
    local broker

    log_info "Starting kafka server truststore creation"

    check_command "keytool"
    require_dir "$CA_DIR"

    log_info "CA certificates should be located in ${CA_DIR} subdir"
    confirm "Continue? (Y/N): " || die "Operation cancelled by user"

    if confirm "Is this the FIRST creation of kafka server truststore? (Y/N): "; then
        import_old_certs=false
        log_info "First truststore creation selected, old certificates will not be imported"
    else
        import_old_certs=true
        require_dir "$OLD_CERT_DIR"
        log_info "Previous broker and client certificates should be located in ${OLD_CERT_DIR} subdir"
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

    validate_ca_files CA_CERTS
    validate_broker_files
    validate_client_files

    [[ ! -f "$TRUSTSTORE_JKS" ]] || { log_warn "Existing file will be overwritten/updated: $TRUSTSTORE_JKS"; rm -f "$TRUSTSTORE_JKS"; }
    [[ ! -f "$TRUSTSTORE_P12" ]] || { log_warn "Existing file will be overwritten/updated: $TRUSTSTORE_P12"; rm -f "$TRUSTSTORE_P12"; }

    for broker in "${brokers[@]}"; do
        import_cert "$TRUSTSTORE_JKS" "$storepass" "$broker" "${broker}.cer"
        import_old_cert_if_needed "$import_old_certs" "$OLD_CERT_DIR" "$TRUSTSTORE_JKS" "$storepass" "$broker" "${broker}.cer"
    done

    import_ca_certs "$TRUSTSTORE_JKS" "$storepass" CA_CERTS
    import_cert "$TRUSTSTORE_JKS" "$storepass" "$cert_alias" "$cert_name"
    import_old_cert_if_needed "$import_old_certs" "$OLD_CERT_DIR" "$TRUSTSTORE_JKS" "$storepass" "$cert_alias" "$cert_name"

    log_info "Converting JKS to PKCS12"
    keytool -importkeystore \
        -srckeystore "$TRUSTSTORE_JKS" \
        -srcstoretype JKS \
        -destkeystore "$TRUSTSTORE_P12" \
        -deststoretype PKCS12 \
        -srcstorepass "$storepass" \
        -deststorepass "$storepass" \
        -noprompt

    log_info "Kafka server truststore successfully created"
}

main "$@"
