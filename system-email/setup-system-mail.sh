#!/usr/bin/env bash
set -euo pipefail

# setup-system-mail.sh
#
# Configure system/root mail through msmtp using variables from .env-email.
#
# Supports:
#   - apt systems: Debian, Ubuntu, Raspberry Pi OS
#   - rpm-ostree systems: Fedora Silverblue/CoreOS-style hosts
#
# Does NOT support dnf intentionally.
#
# Expected .env-email variables:
#   SMTP_TO
#   SMTP_FROM
#   SMTP_SERVER
#   SMTP_PORT
#   SMTP_AUTH_USER
#   SMTP_PASSWORD
#   SMTP_HELO

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env-email"

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "ERROR: Run as root, for example: sudo $0" >&2
        exit 1
    fi
}

load_env() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo "Missing email env file: $ENV_FILE" >&2
        exit 1
    fi

    # shellcheck source=/dev/null
    source "$ENV_FILE"

    : "${SMTP_TO:?Missing SMTP_TO}"
    : "${SMTP_FROM:?Missing SMTP_FROM}"
    : "${SMTP_SERVER:?Missing SMTP_SERVER}"
    : "${SMTP_PORT:?Missing SMTP_PORT}"
    : "${SMTP_AUTH_USER:?Missing SMTP_AUTH_USER}"
    : "${SMTP_PASSWORD:?Missing SMTP_PASSWORD}"
    : "${SMTP_HELO:?Missing SMTP_HELO}"
}

detect_ca_bundle() {
    if [[ -f /etc/pki/tls/certs/ca-bundle.crt ]]; then
        echo "/etc/pki/tls/certs/ca-bundle.crt"
    elif [[ -f /etc/ssl/certs/ca-certificates.crt ]]; then
        echo "/etc/ssl/certs/ca-certificates.crt"
    else
        echo ""
    fi
}

detect_pkg_manager() {
    if command -v rpm-ostree >/dev/null 2>&1; then
        echo "rpm-ostree"
    elif command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    else
        echo "unsupported"
    fi
}

install_packages() {
    local pm="$1"

    if [[ "${SKIP_INSTALL:-0}" == "1" ]]; then
        echo "Skipping package installation because SKIP_INSTALL=1"
        return 0
    fi

    case "$pm" in
        rpm-ostree)
            echo "Detected rpm-ostree system."

            local need_pkgs=()

            if ! rpm -q msmtp >/dev/null 2>&1; then
                need_pkgs+=("msmtp")
            fi

            if ! rpm -q s-nail >/dev/null 2>&1; then
                need_pkgs+=("s-nail")
            fi

            if [[ "${#need_pkgs[@]}" -eq 0 ]]; then
                echo "msmtp and s-nail are already installed/layered."
                return 0
            fi

            echo "Installing missing packages: ${need_pkgs[*]}"
            rpm-ostree install -y "${need_pkgs[@]}"

            echo
            echo "IMPORTANT: rpm-ostree systems usually need a reboot before newly layered packages are active."
            echo "One may also try:"
            echo "  rpm-ostree apply-live"
            echo
            echo "After that, rerun:"
            echo "  sudo ${0}"
            exit 0
            ;;
        apt)
            echo "Detected apt system."
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y \
                msmtp \
                msmtp-mta \
                bsd-mailx \
                ca-certificates
            ;;
        unsupported)
            echo "ERROR: Only apt and rpm-ostree systems are supported by this script." >&2
            echo "Install msmtp and mail/mailx manually, then rerun with SKIP_INSTALL=1 if needed." >&2
            exit 1
            ;;
    esac
}

verify_tools() {
    local missing=0

    if ! command -v msmtp >/dev/null 2>&1; then
        echo "ERROR: msmtp not found." >&2
        missing=1
    fi

    if ! command -v mail >/dev/null 2>&1 && ! command -v mailx >/dev/null 2>&1; then
        echo "ERROR: neither mail nor mailx found." >&2
        missing=1
    fi

    if [[ "$missing" -ne 0 ]]; then
        echo
        echo "On rpm-ostree/Silverblue, reboot after package installation, then rerun this script."
        exit 1
    fi
}

backup_file() {
    local file="$1"

    if [[ -f "$file" ]]; then
        local backup="${file}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a "$file" "$backup"
        echo "Backed up $file to $backup"
    fi
}

tls_starttls_for_port() {
    case "$SMTP_PORT" in
        465)
            echo "off"
            ;;
        *)
            echo "on"
            ;;
    esac
}

write_msmtprc() {
    local ca_bundle="$1"
    local tls_starttls

    if [[ -z "$ca_bundle" ]]; then
        echo "ERROR: Could not find system CA bundle." >&2
        exit 1
    fi

    tls_starttls="$(tls_starttls_for_port)"

    backup_file /etc/msmtprc

    cat > /etc/msmtprc <<EOF
# Managed by setup-system-mail.sh
# System-wide outgoing SMTP through msmtp.

defaults
auth                 on
tls                  on
tls_starttls         ${tls_starttls}
tls_trust_file       ${ca_bundle}
syslog               LOG_MAIL
aliases              /etc/aliases.msmtp

account default
host                 ${SMTP_SERVER}
port                 ${SMTP_PORT}
from                 ${SMTP_FROM}
user                 ${SMTP_AUTH_USER}
password             ${SMTP_PASSWORD}
domain               ${SMTP_HELO}
allow_from_override  off
set_from_header      on
EOF

    chown root:root /etc/msmtprc
    chmod 600 /etc/msmtprc
}

write_aliases() {
    backup_file /etc/aliases.msmtp

    cat > /etc/aliases.msmtp <<EOF
# Managed by setup-system-mail.sh
root: ${SMTP_TO}
default: ${SMTP_TO}
EOF

    chown root:root /etc/aliases.msmtp
    chmod 644 /etc/aliases.msmtp
}

configure_mail_rc() {
    # Some mail/mailx implementations automatically find sendmail.
    # This makes s-nail/mailx more explicit when /usr/bin/msmtp exists.
    if [[ -f /etc/mail.rc ]] && command -v msmtp >/dev/null 2>&1; then
        if ! grep -q 'Managed by setup-system-mail.sh' /etc/mail.rc; then
            backup_file /etc/mail.rc
            cat >> /etc/mail.rc <<'EOF'

# Managed by setup-system-mail.sh
set sendmail="/usr/bin/msmtp"
EOF
        fi
    fi
}

test_msmtp_direct() {
    local host
    host="$(hostname -f 2>/dev/null || hostname)"

    echo
    echo "Sending direct msmtp test to root alias..."

    printf 'Subject: %s from %s\nFrom: %s\nTo: root\n\nThis is a direct msmtp test from %s at %s.\n' \
        "Test Notification" \
        "$host" \
        "$SMTP_FROM" \
        "$host" \
        "$(date -Is)" | msmtp root

    echo "Direct msmtp test submitted."
}

test_mail_command() {
    local host
    host="$(hostname -f 2>/dev/null || hostname)"

    echo
    echo "Sending mail/mailx test to root..."

    if command -v mail >/dev/null 2>&1; then
        echo "This is a mail command test from $host at $(date -Is)." \
            | mail -s "Test Notification from $host" root
    else
        echo "This is a mailx command test from $host at $(date -Is)." \
            | mailx -s "Test Notification from $host" root
    fi

    echo "mail/mailx test submitted."
}

print_summary() {
    local tls_starttls
    tls_starttls="$(tls_starttls_for_port)"

    cat <<EOF

Done.

Configured:
  /etc/msmtprc
  /etc/aliases.msmtp

SMTP:
  Server: ${SMTP_SERVER}
  Port: ${SMTP_PORT}
  STARTTLS: ${tls_starttls}
  Auth user: ${SMTP_AUTH_USER}
  From: ${SMTP_FROM}
  HELO/domain: ${SMTP_HELO}
  Root/default mail goes to: ${SMTP_TO}

Test:
  echo "hello from \$(hostname)" | mail -s "system mail test" root

Smartd example:
  DEVICESCAN -H -l error -l selftest -f -d removable -m root -n standby,10,q

Cron/script example:
  echo "backup failed" | mail -s "backup alert on \$(hostname)" root

Logs:
  journalctl -t msmtp --no-pager

EOF
}

main() {
    require_root
    load_env

    local pm
    pm="$(detect_pkg_manager)"

    install_packages "$pm"
    verify_tools

    local ca_bundle
    ca_bundle="$(detect_ca_bundle)"

    write_msmtprc "$ca_bundle"
    write_aliases
    configure_mail_rc

    test_msmtp_direct
    test_mail_command
    print_summary
}

main "$@"
