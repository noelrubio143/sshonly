#!/bin/bash

# slipstream-rust Server Setup Script
# Supports Fedora, Rocky, CentOS, Debian, Ubuntu

set -e

# Menu (menu.sh) calls this script directly with no "Press Enter" pause
# and immediately clear()s the screen for the next redraw - so on any
# early exit() (root check, dnstt conflict, etc.) or even after a
# successful run, the message flashes and disappears before it can be
# read. Pause on exit, success or failure, so it's actually visible.
trap 'echo ""; read -rp "Pindutin ang Enter para bumalik sa menu... " _' EXIT

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo -e "\033[0;31m[ERROR]\033[0m This script must be run as root"
    exit 1
fi

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
SCRIPT_URL="https://gitlab.com/babayega143/sshonly/-/raw/main/slip/slipstream-rust-deploy.sh"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/slipstream-rust"
SYSTEMD_DIR="/etc/systemd/system"
SLIPSTREAM_USER="slipstream"
SCRIPT_INSTALL_PATH="/usr/local/bin/slipstream-rust-deploy"
BUILD_DIR="/opt/slipstream-rust"
SLIPSTREAM_PORT="5300"

# Single slipstream instance:
#   ssh -> slipstream-rust-server (UDP 5300) -> local SSH port
ALL_COMPS=(ssh)
SSH_PORT_SLIP="5300"
SSH_SERVICE="slipstream-rust-server"
SSH_CONFIG_FILE="${CONFIG_DIR}/slipstream-rust-server.conf"
NAT_APPLY_SCRIPT="/usr/local/bin/slipstream-nat-apply"
COMP="ssh"

comp_service() { echo "$SSH_SERVICE"; }
comp_conf()    { echo "$SSH_CONFIG_FILE"; }
comp_port()    { echo "$SSH_PORT_SLIP"; }
comp_label()   { echo "SSH"; }
comp_domain()  { local f; f=$(comp_conf "$1"); if [ -f "$f" ]; then grep '^DOMAIN=' "$f" | cut -d'"' -f2; fi; return 0; }

# Select which instance (ssh only) the following functions operate on.
set_component() {
    COMP="$1"
    COMP="ssh"
    SLIPSTREAM_PORT=$(comp_port "$COMP")
    SERVICE_NAME=$(comp_service "$COMP")
    CONFIG_FILE=$(comp_conf "$COMP")
    TUNNEL_MODE="$COMP"
}

# Global variable to track if update is available

# Print functions
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_question() {
    echo -ne "${BLUE}[QUESTION]${NC} $1"
}

# Replace the systemd-resolved stub resolv.conf with a real file
fix_resolv_conf() {
    if [ -L /etc/resolv.conf ] || ! grep -q '^nameserver' /etc/resolv.conf 2>/dev/null \
        || grep -q '^nameserver 127\.0\.0\.53' /etc/resolv.conf 2>/dev/null; then
        print_warning "Fixing /etc/resolv.conf (setting 8.8.8.8 / 1.1.1.1)..."
        chattr -i /etc/resolv.conf 2>/dev/null || true
        rm -f /etc/resolv.conf
        printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
        chattr +i /etc/resolv.conf 2>/dev/null || true
    fi
}

# Clean up DNS service conflicts (systemd-resolved, dnsmasq, etc)
cleanup_dns_conflicts() {
    print_status "Checking for DNS service conflicts..."
    
    # Disable systemd-resolved
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        print_warning "Disabling systemd-resolved..."
        systemctl stop systemd-resolved 2>/dev/null || true
        systemctl disable systemd-resolved 2>/dev/null || true
        systemctl mask systemd-resolved 2>/dev/null || true
    fi

    # Always make sure the VPS keeps a working DNS (resolv.conf may still be a
    # symlink to the systemd-resolved stub 127.0.0.53, which breaks curl/wget)
    fix_resolv_conf
    
    # Kill conflicting DNS services
    for dns_srv in dnsmasq pdnsd unbound; do
        if pgrep -x "$dns_srv" > /dev/null 2>&1; then
            print_warning "Stopping $dns_srv..."
            killall "$dns_srv" 2>/dev/null || true
        fi
    done
}

# Function to install/update the script itself
install_script() {
    print_status "Installing/updating slipstream-rust-deploy script..."

    # Download the latest version
    local temp_script="/tmp/slipstream-rust-deploy-new.sh"
    curl -Ls "$SCRIPT_URL" -o "$temp_script"

    # Make it executable
    chmod +x "$temp_script"

    # Check if we're updating an existing installation
    if [ -f "$SCRIPT_INSTALL_PATH" ]; then
        # Compare checksums to see if update is needed
        local current_checksum
        local new_checksum
        current_checksum=$(sha256sum "$SCRIPT_INSTALL_PATH" | cut -d' ' -f1)
        new_checksum=$(sha256sum "$temp_script" | cut -d' ' -f1)

        if [ "$current_checksum" = "$new_checksum" ]; then
            print_status "Script is already up to date"
            rm "$temp_script"
            return 0
        else
            print_status "Updating existing script installation..."
        fi
    else
        print_status "Installing script for the first time..."
    fi

    # Copy to installation directory
    cp "$temp_script" "$SCRIPT_INSTALL_PATH"
    rm "$temp_script"

    print_status "Script installed to $SCRIPT_INSTALL_PATH"
    print_status "You can now run 'slipstream-rust-deploy' from anywhere"
}

# Remove the old slipstream-rust-xray instance left by earlier versions
remove_legacy_xray_instance() {
    systemctl stop slipstream-rust-xray 2>/dev/null || true
    systemctl disable slipstream-rust-xray 2>/dev/null || true
    rm -f "${SYSTEMD_DIR}/slipstream-rust-xray.service" "${CONFIG_DIR}/slipstream-rust-xray.conf"
    systemctl daemon-reload 2>/dev/null || true
}

# Function to show main menu
show_menu() {
    echo ""
    print_status "slipstream-rust Server Management"
    print_status "=================================="

    echo "1) Install/Reconfigure SSH slipstream        (UDP 5300)"
    echo "0) Exit"
    echo ""
    print_question "Please select an option (0-1): "
}

# Function to handle menu selection
handle_menu() {
    while true; do
        show_menu
        read -r choice

        case $choice in
            1)
                set_component ssh
                print_status "Starting SSH slipstream installation/reconfiguration..."
                return 0
                ;;
            0)
                print_status "Goodbye!"
                exit 0
                ;;
            *)
                print_error "Invalid choice. Please enter 0-1."
                ;;
        esac

        if [ "$choice" != "6" ]; then
            echo ""
            print_question "Press Enter to continue..."
            read -r
        fi
    done
}

# Function to load existing configuration
load_existing_config() {
    if [ -f "$CONFIG_FILE" ]; then
        print_status "Loading existing configuration..."
        # Source the config file to load variables
        # shellcheck source=/dev/null
        . "$CONFIG_FILE"
        return 0
    fi
    return 1
}

# Function to save configuration
save_config() {
    print_status "Saving configuration..."

    cat > "$CONFIG_FILE" << EOF
# slipstream-rust Server Configuration
# Generated on $(date)

DOMAIN="$DOMAIN"
TUNNEL_MODE="$TUNNEL_MODE"
CERT_FILE="$CERT_FILE"
KEY_FILE="$KEY_FILE"
EOF

    chmod 640 "$CONFIG_FILE"
    chown root:"$SLIPSTREAM_USER" "$CONFIG_FILE"
    print_status "Configuration saved to $CONFIG_FILE"
}

# Function to detect OS and package manager
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
    else
        print_error "Cannot detect OS"
        exit 1
    fi

    # Determine package manager
    if command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
    elif command -v apt &> /dev/null; then
        PKG_MANAGER="apt"
    else
        print_error "Unsupported package manager"
        exit 1
    fi

    print_status "Detected OS: $OS"
    print_status "Package manager: $PKG_MANAGER"
}

# Function to check and install required tools
check_required_tools() {
    print_status "Checking required tools..."

    local required_tools=("curl" "git" "rustc" "cargo" "cmake" "pkg-config")
    local missing_tools=()

    # Check which tools are missing
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done

    # Check for iptables separately since it might need special handling
    if ! command -v "iptables" &> /dev/null; then
        missing_tools+=("iptables")
    fi

    # Check for OpenSSL development headers
    if ! pkg-config --exists openssl 2>/dev/null; then
        missing_tools+=("openssl-dev")
    fi

    if [ ${#missing_tools[@]} -gt 0 ]; then
        print_status "Installing missing tools: ${missing_tools[*]}"
        install_dependencies "${missing_tools[@]}"
    else
        print_status "All required tools are available"
    fi

    # Verify iptables installation after potential installation
    verify_iptables_installation
}

# Function to verify iptables installation and capabilities
verify_iptables_installation() {
    print_status "Verifying iptables installation..."

    if ! command -v iptables &> /dev/null; then
        print_error "iptables is not available after installation attempt"
        exit 1
    fi

    # Check if ip6tables is available (should be part of iptables package)
    if command -v ip6tables &> /dev/null; then
        print_status "Both iptables and ip6tables are available"
    else
        print_warning "ip6tables not found, IPv6 rules will be skipped"
    fi

    # Check if IPv6 is supported and configured on the system
    if [ -f /proc/net/if_inet6 ]; then
        print_status "IPv6 kernel support detected (/proc/net/if_inet6 exists)"
        # Check if IPv6 addresses are actually configured (with timeout to prevent hanging)
        local ipv6_addrs
        if command -v timeout &> /dev/null; then
            ipv6_addrs=$(timeout 2 ip -6 addr show 2>/dev/null | grep -E "inet6 [0-9a-fA-F:]+" | grep -v "::1" | grep -v "fe80:" | head -3 || true)
        else
            ipv6_addrs=$(ip -6 addr show 2>/dev/null | grep -E "inet6 [0-9a-fA-F:]+" | grep -v "::1" | grep -v "fe80:" | head -3 || true)
        fi
        if [ -n "$ipv6_addrs" ]; then
            local addr_count
            addr_count=$(echo "$ipv6_addrs" | wc -l)
            print_status "IPv6 addresses configured: $addr_count (excluding loopback and link-local)"
        else
            print_warning "IPv6 kernel support available but no IPv6 addresses configured"
        fi
    else
        print_warning "IPv6 not supported on this system (/proc/net/if_inet6 not found)"
    fi
}

# Function to install dependencies
install_dependencies() {
    local tools=("$@")
    print_status "Installing dependencies: ${tools[*]}"

    # Safety check for PKG_MANAGER
    if [[ -z "$PKG_MANAGER" ]]; then
        print_error "Package manager not detected. Make sure detect_os() is called first."
        exit 1
    fi

    case $PKG_MANAGER in
        dnf|yum)
            # For RHEL-based systems
            local packages_to_install=()

            # Always install gcc-c++ for building picoquic (CMake requires C++ compiler)
            if ! command -v g++ &> /dev/null; then
                packages_to_install+=("gcc-c++")
            fi

            for tool in "${tools[@]}"; do
                case $tool in
                    "rustc"|"cargo")
                        # Rust toolchain - install via rustup if not available
                        if ! command -v rustc &> /dev/null; then
                            print_status "Installing Rust toolchain via rustup..."
                            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
                            source "$HOME/.cargo/env" || source /root/.cargo/env
                        fi
                        ;;
                    "iptables")
                        packages_to_install+=("iptables" "iptables-services")
                        ;;
                    "openssl-dev")
                        packages_to_install+=("openssl-devel")
                        ;;
                    "cmake")
                        packages_to_install+=("cmake")
                        ;;
                    "pkg-config")
                        packages_to_install+=("pkgconfig")
                        ;;
                    *)
                        packages_to_install+=("$tool")
                        ;;
                esac
            done

            if [ ${#packages_to_install[@]} -gt 0 ]; then
                if ! $PKG_MANAGER install -y "${packages_to_install[@]}"; then
                    print_error "Failed to install packages: ${packages_to_install[*]}"
                    exit 1
                fi
            fi
            ;;
        apt)
            # For Debian-based systems
            if ! apt update; then
                print_error "Failed to update package lists"
                exit 1
            fi

            local packages_to_install=()

            # Always install g++ for building picoquic (CMake requires C++ compiler)
            if ! command -v g++ &> /dev/null; then
                packages_to_install+=("g++")
            fi

            for tool in "${tools[@]}"; do
                case $tool in
                    "rustc"|"cargo")
                        # Rust toolchain - install via rustup if not available
                        if ! command -v rustc &> /dev/null; then
                            print_status "Installing Rust toolchain via rustup..."
                            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
                            source "$HOME/.cargo/env" || source /root/.cargo/env
                        fi
                        ;;
                    "iptables")
                        packages_to_install+=("iptables")
                        if is_ufw_installed; then
                            print_status "UFW detected; skipping iptables-persistent to preserve UFW"
                        else
                            packages_to_install+=("iptables-persistent")
                        fi
                        ;;
                    "openssl-dev")
                        packages_to_install+=("libssl-dev")
                        ;;
                    "cmake")
                        packages_to_install+=("cmake")
                        ;;
                    "pkg-config")
                        packages_to_install+=("pkg-config")
                        ;;
                    *)
                        packages_to_install+=("$tool")
                        ;;
                esac
            done

            if [ ${#packages_to_install[@]} -gt 0 ]; then
                if ! apt install -y "${packages_to_install[@]}"; then
                    print_error "Failed to install packages: ${packages_to_install[*]}"
                    exit 1
                fi
            fi
            ;;
        *)
            print_error "Unsupported package manager: $PKG_MANAGER"
            exit 1
            ;;
    esac

    print_status "Dependencies installed successfully"
}

# Function to get user input
get_user_input() {
    local existing_domain=""
    local x

    if load_existing_config; then
        existing_domain="$DOMAIN"
        print_status "Found existing configuration for domain: $existing_domain"
    fi

    while true; do
        if [[ -n "$existing_domain" ]]; then
            print_question "Enter the domain for $(comp_label "$COMP") slipstream (current: $existing_domain): "
        else
            print_question "Enter the domain for $(comp_label "$COMP") slipstream (e.g., ns1.example.com): "
        fi
        read -r DOMAIN
        DOMAIN="${DOMAIN,,}"

        if [[ -z "$DOMAIN" && -n "$existing_domain" ]]; then
            DOMAIN="$existing_domain"
        fi

        if [[ -z "$DOMAIN" ]]; then
            print_error "Please enter a valid domain"
            continue
        fi
        if [[ ! "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
            print_error "That does not look like a valid domain"
            continue
        fi
        local clash=""
        for x in "${ALL_COMPS[@]}"; do
            [ "$x" = "$COMP" ] && continue
            [ "$(comp_domain "$x")" = "$DOMAIN" ] && clash="$x"
        done
        if [[ -n "$clash" ]]; then
            print_error "That domain is already used by the $(comp_label "$clash") slipstream instance."
            print_error "UDP 53 is split by domain, so every slipstream instance needs its own domain."
            continue
        fi
        break
    done

    TUNNEL_MODE="$COMP"
    print_status "Configuration:"
    print_status "  Instance: $COMP"
    print_status "  Domain: $DOMAIN"
}

# Function to detect architecture and get asset name
get_asset_name() {
    local arch
    arch=$(uname -m)
    local os
    os=$(uname -s | tr '[:upper:]' '[:lower:]')

    case "$os" in
        linux)
            case "$arch" in
                x86_64|amd64)
                    echo "linux-amd64"
                    return 0
                    ;;
                arm64|aarch64)
                    echo "linux-arm64"
                    return 0
                    ;;
                armv7l|armhf)
                    echo "linux-armv7"
                    return 0
                    ;;
                riscv64)
                    echo "linux-riscv64"
                    return 0
                    ;;
                mips64)
                    echo "linux-mips64"
                    return 0
                    ;;
                mips64el)
                    echo "linux-mips64le"
                    return 0
                    ;;
                mips)
                    echo "linux-mips"
                    return 0
                    ;;
                mipsel)
                    echo "linux-mipsle"
                    return 0
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
        darwin)
            case "$arch" in
                arm64|aarch64)
                    echo "darwin-arm64"
                    return 0
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
        *)
            return 1
            ;;
    esac
}

# Our own GitLab-hosted mirror of the prebuilt binaries (project 84844354).
declare -A GITLAB_BINARY_URLS=(
    ["linux-amd64"]="https://gitlab.com/-/project/84844354/uploads/e7059c370a6ecc64a2a2082057013bca/slipstream-server-linux-amd64"
    ["linux-arm64"]="https://gitlab.com/-/project/84844354/uploads/49c00ea457efda6e318a0fbdebcf9386/slipstream-server-linux-arm64"
)

# Function to download prebuilt binary
download_prebuilt_binary() {
    # Check if 'file' utility is available, install if missing
	if ! command -v file >/dev/null 2>&1; then
	    print_status "'file' utility not found. Installing..."

	    case "$PKG_MANAGER" in
	        apt)
	            sudo apt update && sudo apt install -y file
	            ;;
	        dnf|yum)
	            sudo "$PKG_MANAGER" install -y file
	            ;;
	        *)
	            print_error "Unsupported package manager. Please install 'file' manually."
	            exit 1
	            ;;
	    esac
	fi

    local asset_name
    if ! asset_name=$(get_asset_name); then
        print_warning "No prebuilt binary available for this architecture"
        return 1
    fi

    print_status "Attempting to download prebuilt binary for $asset_name..."

    local binary_name="slipstream-server-${asset_name}"
    local temp_binary="/tmp/${binary_name}"

    local gitlab_url="${GITLAB_BINARY_URLS[$asset_name]:-}"
    if [ -z "$gitlab_url" ]; then
        print_warning "No GitLab mirror URL for this architecture"
        return 1
    fi

    print_status "Trying GitLab mirror: $gitlab_url"
    if curl -fsSL "$gitlab_url" -o "$temp_binary" 2>/dev/null; then
        if file "$temp_binary" | grep -qE "(executable|ELF|Mach-O)"; then
            chmod +x "$temp_binary"
            cp "$temp_binary" "$INSTALL_DIR/slipstream-server"
            rm -f "$temp_binary"
            print_status "Successfully downloaded prebuilt binary from GitLab mirror"
            return 0
        else
            print_warning "GitLab mirror returned a non-binary file"
            rm -f "$temp_binary"
            return 1
        fi
    else
        print_warning "GitLab mirror unavailable"
        return 1
    fi
}

# Function to install slipstream-server (prebuilt binary from GitLab mirror)
install_slipstream_server() {
    print_status "Installing slipstream-server..."

    # Both instances share the binary: stop them so the copy doesn't fail with
    # "Text file busy", and remember which ones to bring back afterwards.
    RESTART_AFTER_INSTALL=()
    local svc x
    for x in "${ALL_COMPS[@]}"; do
        svc=$(comp_service "$x")
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            print_status "Stopping $svc for binary update..."
            systemctl stop "$svc"
            RESTART_AFTER_INSTALL+=("$svc")
        fi
    done

    if download_prebuilt_binary; then
        print_status "Using prebuilt binary - skipping build dependencies"
        return 0
    fi

    print_error "Failed to download slipstream-server from GitLab mirror"
    exit 1
}

# Function to create slipstream user
create_slipstream_user() {
    print_status "Creating slipstream user..."

    if ! id "$SLIPSTREAM_USER" &>/dev/null; then
        useradd -r -s /bin/false -d /nonexistent -c "slipstream service user" "$SLIPSTREAM_USER"
        print_status "Created user: $SLIPSTREAM_USER"
    else
        print_status "User $SLIPSTREAM_USER already exists"
    fi

    # Create config directory first
    mkdir -p "$CONFIG_DIR"

    # Set ownership of config directory (slipstream instance)
    chown -R "$SLIPSTREAM_USER":"$SLIPSTREAM_USER" "$CONFIG_DIR"
    chmod 750 "$CONFIG_DIR"
}

# Function to generate TLS certificates
generate_certificates() {
    # Generate certificate file names based on domain
    local cert_prefix
    # shellcheck disable=SC2001
    cert_prefix=$(echo "$DOMAIN" | sed 's/\./_/g')
    CERT_FILE="${CONFIG_DIR}/${cert_prefix}_cert.pem"
    KEY_FILE="${CONFIG_DIR}/${cert_prefix}_key.pem"

    # Check if certificates already exist for this domain
    if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
        print_status "Found existing certificates for domain: $DOMAIN"
        print_status "  Certificate: $CERT_FILE"
        print_status "  Key: $KEY_FILE"

        # Verify certificate ownership and permissions
        chown "$SLIPSTREAM_USER":"$SLIPSTREAM_USER" "$CERT_FILE" "$KEY_FILE"
        chmod 644 "$CERT_FILE"
        chmod 600 "$KEY_FILE"

        print_status "Using existing certificates (verified ownership and permissions)"
    else
        print_status "Generating new TLS certificates for domain: $DOMAIN"

        # Generate certificates (run as root, then change ownership)
        openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout "$KEY_FILE" \
            -out "$CERT_FILE" \
            -days 365 \
            -subj "/CN=slipstream"

        # Set proper ownership and permissions
        chown "$SLIPSTREAM_USER":"$SLIPSTREAM_USER" "$CERT_FILE" "$KEY_FILE"
        chmod 644 "$CERT_FILE"
        chmod 600 "$KEY_FILE"

        print_status "New certificates generated:"
        print_status "  Certificate: $CERT_FILE"
        print_status "  Key: $KEY_FILE"
    fi
}

# Encode a domain as DNS wire format (length-prefixed labels + root) in the
# |hex| notation iptables' string match expects.
domain_to_hex() {
    local d="${1,,}" out="" label i h c
    local IFS=.
    local -a labels
    read -ra labels <<< "$d"
    for label in "${labels[@]}"; do
        printf -v h '%02x' "${#label}"
        out+="$h"
        for ((i = 0; i < ${#label}; i++)); do
            printf -v c '%02x' "'${label:i:1}"
            out+="$c"
        done
    done
    echo "|${out}00|"
}

# Print one "<hex> <port>" line per installed instance, longest domain first
# (so a domain that is a suffix of another can never shadow it).
collect_nat_rules() {
    local c d
    for c in "${ALL_COMPS[@]}"; do
        d=$(comp_domain "$c")
        [ -n "$d" ] || continue
        echo "${#d} $(domain_to_hex "$d") $(comp_port "$c")"
    done | sort -rn | cut -d' ' -f2-
}

# Ports of the instances that are currently installed.
installed_slip_ports() {
    local c
    for c in "${ALL_COMPS[@]}"; do
        [ -f "$(comp_conf "$c")" ] && comp_port "$c"
    done
    return 0
}

# Return true when the ufw command is available.
is_ufw_installed() {
    command -v ufw &> /dev/null
}

# Return true when UFW is enabled and managing the firewall.
is_ufw_active() {
    is_ufw_installed && ufw status 2>/dev/null | grep -q "Status: active"
}

# Detect the primary network interface used for default routing.
detect_network_interface() {
    local interface
    interface=$(ip route | grep default | awk '{print $5}' | head -1)
    if [[ -z "$interface" ]]; then
        interface=$(ip link show | grep -E "^[0-9]+: (eth|ens|enp)" | head -1 | cut -d':' -f2 | awk '{print $1}')
        if [[ -z "$interface" ]]; then
            interface="eth0"
            print_warning "Could not detect network interface, using eth0 as fallback" >&2
        else
            print_status "Detected network interface: $interface" >&2
        fi
    else
        print_status "Using network interface: $interface" >&2
    fi
    echo "$interface"
}

# Remove slipstream-rust NAT redirect markers from a UFW before.rules file.
remove_ufw_nat_rules_from_file() {
    local file="$1"
    if [ -f "$file" ] && grep -q "# BEGIN slipstream-rust" "$file"; then
        sed -i '/# BEGIN slipstream-rust/,/# END slipstream-rust/d' "$file"
    fi
}

# Ensure a UFW rules file has a minimal *nat table (required for DNS port redirect).
ensure_ufw_nat_section() {
    local file="$1"

    if grep -q '^\*nat' "$file"; then
        return 0
    fi

    print_status "$file has no *nat section; adding minimal NAT table..."

    if grep -q '^\*filter' "$file"; then
        awk '
            /^\*filter$/ && !done {
                print "# NAT table (added by slipstream-rust-deploy)"
                print "*nat"
                print ":PREROUTING ACCEPT [0:0]"
                print ":POSTROUTING ACCEPT [0:0]"
                print "COMMIT"
                print ""
                done=1
            }
            { print }
        ' "$file" > "${file}.slipstream.tmp" && mv "${file}.slipstream.tmp" "$file"
    else
        {
            echo ""
            echo "# NAT table (added by slipstream-rust-deploy)"
            echo "*nat"
            echo ":PREROUTING ACCEPT [0:0]"
            echo ":POSTROUTING ACCEPT [0:0]"
            echo "COMMIT"
        } >> "$file"
    fi
}

# Insert DNS NAT redirect rules into a UFW before.rules file.
add_ufw_nat_rules_to_file() {
    local file="$1"
    local interface="$2"

    if [ ! -f "$file" ]; then
        print_warning "$file not found, skipping NAT redirect rules"
        return 1
    fi

    ensure_ufw_nat_section "$file"
    remove_ufw_nat_rules_from_file "$file"

    local icase=""
    if iptables -m string --help 2>&1 | grep -q -- '--icase'; then icase="--icase"; fi

    local block
    block=$(mktemp)
    {
        echo "# BEGIN slipstream-rust"
        local hex port
        while read -r hex port; do
            [ -n "$hex" ] || continue
            echo "-A PREROUTING -i ${interface} -p udp --dport 53 -m string --algo bm ${icase} --hex-string \"${hex}\" -j REDIRECT --to-ports ${port}"
        done < <(collect_nat_rules)
        echo "# END slipstream-rust"
    } > "$block"

    if ! awk -v blockfile="$block" '
        /^\*nat$/ { in_nat=1 }
        in_nat && /^COMMIT$/ {
            while ((getline line < blockfile) > 0) print line
            in_nat=0
        }
        { print }
    ' "$file" > "${file}.slipstream.tmp"; then
        print_warning "Failed to update $file with NAT redirect rules"
        rm -f "${file}.slipstream.tmp" "$block"
        return 1
    fi
    rm -f "$block"

    mv "${file}.slipstream.tmp" "$file"

    if ! grep -q "# BEGIN slipstream-rust" "$file"; then
        print_warning "NAT redirect rules were not written to $file"
        return 1
    fi

    print_status "NAT redirect rules added to $file"
    return 0
}

# Configure UFW port allows and NAT redirect via before.rules.
configure_ufw() {
    local interface
    interface=$(detect_network_interface)

    print_status "Configuring UFW for slipstream-rust..."

    # UFW owns the rules here; drop our own iptables chain / boot service
    remove_iptables_rules_only

    ufw allow 53/udp
    local p
    for p in "$SSH_PORT_SLIP"; do
        if installed_slip_ports | grep -qx "$p"; then
            ufw allow "$p"/udp
        else
            ufw delete allow "$p"/udp 2>/dev/null || true
        fi
    done

    local nat_v4_ok=false

    if add_ufw_nat_rules_to_file "/etc/ufw/before.rules" "$interface"; then
        nat_v4_ok=true
    else
        print_error "Failed to configure IPv4 DNS NAT redirect in UFW"
    fi

    if command -v ip6tables &> /dev/null && [ -f /proc/net/if_inet6 ]; then
        if has_ipv6_addresses; then
            if ! add_ufw_nat_rules_to_file "/etc/ufw/before6.rules" "$interface"; then
                print_warning "Failed to configure IPv6 DNS NAT redirect in UFW"
            fi
        fi
    fi

    ufw reload

    if [ "$nat_v4_ok" = true ]; then
        print_status "UFW configured successfully"
    else
        print_error "UFW port allows were added but the DNS redirect (53 -> slipstream) is not configured"
        exit 1
    fi
}

# Function to configure iptables rules
write_nat_apply_script() {
    cat > "$NAT_APPLY_SCRIPT" << 'NAT_APPLY_EOF'
#!/bin/bash
# slipstream-nat-apply: (re)build the UDP/53 redirect rules for slipstream-rust.
# UDP/53 is split between the installed instances by the domain found inside
# the DNS query (iptables string match on the wire-format QNAME).
# Generated by slipstream-rust-deploy - safe to run repeatedly.

CONF_DIR="/etc/slipstream-rust"
CHAIN="SLIPSTREAM_DNS"
SSH_PORT_SLIP=5300

domain_to_hex() {
    local d="${1,,}" out="" label i h c
    local IFS=.
    local -a labels
    read -ra labels <<< "$d"
    for label in "${labels[@]}"; do
        printf -v h '%02x' "${#label}"
        out+="$h"
        for ((i = 0; i < ${#label}; i++)); do
            printf -v c '%02x' "'${label:i:1}"
            out+="$c"
        done
    done
    echo "|${out}00|"
}

# "<len> <hex> <port>" per installed instance, longest domain first
rules=()
ports=()
while read -r hex port; do
    [ -n "$hex" ] || continue
    rules+=("$hex $port")
    ports+=("$port")
done < <(
    for pair in "server:$SSH_PORT_SLIP"; do
        name="${pair%%:*}"; port="${pair##*:}"
        conf="$CONF_DIR/slipstream-rust-${name}.conf"
        [ -f "$conf" ] || continue
        d=$(grep '^DOMAIN=' "$conf" | cut -d'"' -f2)
        [ -n "$d" ] || continue
        echo "${#d} $(domain_to_hex "$d") $port"
    done | sort -rn | cut -d' ' -f2-
)

IFACE=$(ip route | awk '/default/ {print $5; exit}')
[ -n "$IFACE" ] || IFACE="eth0"

modprobe xt_string 2>/dev/null || true
ICASE=""
if iptables -m string --help 2>&1 | grep -q -- '--icase'; then ICASE="--icase"; fi

rc=0
for ipt in iptables ip6tables; do
    command -v "$ipt" &>/dev/null || continue
    if [ "$ipt" = "ip6tables" ] && [ ! -f /proc/net/if_inet6 ]; then continue; fi

    # --- cleanup: current chain + the legacy catch-all rule of older versions
    while $ipt -t nat -D PREROUTING -i "$IFACE" -p udp --dport 53 -j "$CHAIN" 2>/dev/null; do :; done
    $ipt -t nat -F "$CHAIN" 2>/dev/null
    $ipt -t nat -X "$CHAIN" 2>/dev/null
    while $ipt -t nat -D PREROUTING -i "$IFACE" -p udp --dport 53 -j REDIRECT --to-ports "$SSH_PORT_SLIP" 2>/dev/null; do :; done
    for p in "$SSH_PORT_SLIP"; do
        while $ipt -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null; do :; done
    done

    [ "${#rules[@]}" -gt 0 ] || continue

    # --- rebuild
    if ! $ipt -t nat -N "$CHAIN" 2>/dev/null; then
        [ "$ipt" = "iptables" ] && { echo "cannot create nat chain $CHAIN" >&2; rc=1; }
        continue
    fi
    for r in "${rules[@]}"; do
        hex="${r% *}"; port="${r##* }"
        if ! $ipt -t nat -A "$CHAIN" -p udp -m string --algo bm $ICASE --hex-string "$hex" -j REDIRECT --to-ports "$port" 2>/dev/null; then
            [ "$ipt" = "iptables" ] && { echo "iptables string match not supported by this kernel (xt_string)" >&2; rc=1; }
        fi
    done
    $ipt -t nat -I PREROUTING -i "$IFACE" -p udp --dport 53 -j "$CHAIN" 2>/dev/null || rc=1
    for p in "${ports[@]}"; do
        $ipt -I INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null
    done
done
exit $rc
NAT_APPLY_EOF
    chmod +x "$NAT_APPLY_SCRIPT"
}

configure_iptables() {
    print_status "Configuring iptables rules for DNS redirection (split by domain)..."

    if ! command -v iptables &> /dev/null; then
        print_error "iptables command not found. Cannot configure firewall rules."
        exit 1
    fi

    write_nat_apply_script

    if ! "$NAT_APPLY_SCRIPT"; then
        print_error "Failed to apply the DNS redirect rules."
        print_error "Your kernel may lack the xt_string module (common on OpenVZ/LXC)."
        exit 1
    fi

    local hex port
    while read -r hex port; do
        [ -n "$hex" ] || continue
        print_status "UDP 53 with domain match $hex -> port $port"
    done < <(collect_nat_rules)

    create_iptables_restore_service
}

# Remove only our iptables chain / boot service (used when UFW manages the rules)
remove_iptables_rules_only() {
    if [ -x "$NAT_APPLY_SCRIPT" ]; then
        # Run with no instances visible so it just cleans up
        for ipt in iptables ip6tables; do
            command -v "$ipt" &>/dev/null || continue
            local iface
            iface=$(ip route | awk '/default/ {print $5; exit}')
            [ -n "$iface" ] || iface="eth0"
            while $ipt -t nat -D PREROUTING -i "$iface" -p udp --dport 53 -j SLIPSTREAM_DNS 2>/dev/null; do :; done
            $ipt -t nat -F SLIPSTREAM_DNS 2>/dev/null || true
            $ipt -t nat -X SLIPSTREAM_DNS 2>/dev/null || true
            local p
            for p in "$SSH_PORT_SLIP"; do
                while $ipt -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null; do :; done
            done
        done
    fi
    systemctl stop slipstream-restore-iptables 2>/dev/null || true
    systemctl disable slipstream-restore-iptables 2>/dev/null || true
    rm -f "${SYSTEMD_DIR}/slipstream-restore-iptables.service" "/usr/local/bin/slipstream-restore-iptables.sh"
    systemctl daemon-reload 2>/dev/null || true
}

# Function to create a systemd service to restore iptables rules at boot
create_iptables_restore_service() {
    print_status "Creating boot service to restore the DNS redirect rules..."

    # legacy restore script from older versions
    rm -f "/usr/local/bin/slipstream-restore-iptables.sh"

    cat > "${SYSTEMD_DIR}/slipstream-restore-iptables.service" << EOF
[Unit]
Description=Restore slipstream-rust DNS redirect rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${NAT_APPLY_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable slipstream-restore-iptables.service 2>/dev/null || print_warning "Could not enable the restore service"
    print_status "Boot restore service created"
}

# Function to configure firewall
configure_firewall() {
    print_status "Configuring firewall..."

    if is_ufw_active; then
        configure_ufw
        return 0
    fi

    if command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
        print_status "Configuring active firewalld..."
        local p
        for p in "$SSH_PORT_SLIP"; do
            if installed_slip_ports | grep -qx "$p"; then
                firewall-cmd --permanent --add-port="$p"/udp
            else
                firewall-cmd --permanent --remove-port="$p"/udp 2>/dev/null || true
            fi
        done
        firewall-cmd --permanent --add-port=53/udp
        firewall-cmd --reload
        print_status "Firewalld configured successfully"
    else
        print_status "No active firewall service detected"
        if is_ufw_installed; then
            print_status "UFW is installed but inactive; using plain iptables rules"
        fi
        print_status "If you have a firewall active, manually allow the slipstream ports and 53/udp"
    fi

    configure_iptables
}

# Function to detect SSH port
detect_ssh_port() {
    local ssh_port
    ssh_port=$(ss -tlnp | grep sshd | awk '{print $4}' | cut -d':' -f2 | head -1)
    if [[ -z "$ssh_port" ]]; then
        # Fallback to default SSH port
        ssh_port="22"
    fi
    echo "$ssh_port"
}

# Return true when the system has non-loopback IPv6 addresses configured.
has_ipv6_addresses() {
    if [ ! -f /proc/net/if_inet6 ]; then
        return 1
    fi

    local ipv6_addrs
    if command -v timeout &> /dev/null; then
        ipv6_addrs=$(timeout 2 ip -6 addr show 2>/dev/null | grep -E "inet6 [0-9a-fA-F:]+" | grep -v "::1" | grep -v "fe80:" || true)
    else
        ipv6_addrs=$(ip -6 addr show 2>/dev/null | grep -E "inet6 [0-9a-fA-F:]+" | grep -v "::1" | grep -v "fe80:" || true)
    fi

    [ -n "$ipv6_addrs" ]
}

# Function to install and configure Dante SOCKS proxy
# SSH mode only - no additional tunnel setup needed

# Function to create systemd service
create_systemd_service() {
    print_status "Creating systemd service..."

    local service_name="$SERVICE_NAME"
    local service_file="${SYSTEMD_DIR}/${service_name}.service"
    local target_port

    local unit_desc="slipstream-rust DNS Tunnel Server ($(comp_label "$COMP"))"
    local unit_after="After=network.target"
    target_port=$(detect_ssh_port)
    print_status "Detected SSH port: $target_port"

    # Stop service if it's running to allow reconfiguration
    if systemctl is-active --quiet "$service_name"; then
        print_status "Stopping existing $service_name service for reconfiguration..."
        systemctl stop "$service_name"
    fi

    local dns_listen_host="0.0.0.0"
    local ipv6_support=false
    local ipv6_configured=false
    local ipv6_info=""
    
    # Check IPv6 support
    if command -v ip6tables &> /dev/null; then
        ipv6_support=true
        ipv6_info="ip6tables: available"
    else
        ipv6_info="ip6tables: not available"
    fi
    
    if [ -f /proc/net/if_inet6 ]; then
        if [ "$ipv6_support" = true ]; then
            ipv6_info="$ipv6_info, /proc/net/if_inet6: exists"
        else
            ipv6_info="$ipv6_info, /proc/net/if_inet6: exists"
        fi
    else
        ipv6_info="$ipv6_info, /proc/net/if_inet6: not found"
    fi
    
    # Check if IPv6 addresses are actually configured (with timeout to prevent hanging)
    if [ "$ipv6_support" = true ] && [ -f /proc/net/if_inet6 ]; then
        local ipv6_addrs
        if command -v timeout &> /dev/null; then
            ipv6_addrs=$(timeout 2 ip -6 addr show 2>/dev/null | grep -E "inet6 [0-9a-fA-F:]+" | grep -v "::1" | grep -v "fe80:" | head -3 || true)
        else
            ipv6_addrs=$(ip -6 addr show 2>/dev/null | grep -E "inet6 [0-9a-fA-F:]+" | grep -v "::1" | grep -v "fe80:" | head -3 || true)
        fi
        if [ -n "$ipv6_addrs" ]; then
            ipv6_configured=true
            local addr_count
            addr_count=$(echo "$ipv6_addrs" | wc -l)
            ipv6_info="$ipv6_info, IPv6 addresses: $addr_count configured"
            print_status "IPv6 detection details:"
            print_status "  $ipv6_info"
            echo "$ipv6_addrs" | while read -r line; do
                print_status "    - $line"
            done
            dns_listen_host="::"
            print_status "IPv6 detected and configured, using :: for dual-stack support"
        else
            ipv6_info="$ipv6_info, IPv6 addresses: none configured"
            print_status "IPv6 detection details:"
            print_status "  $ipv6_info"
            print_status "IPv6 support available but no addresses configured, using 0.0.0.0 for IPv4 only"
        fi
    else
        print_status "IPv6 detection details:"
        print_status "  $ipv6_info"
        print_status "IPv6 not available, using 0.0.0.0 for IPv4 only"
    fi

    # Create systemd service file
    cat > "$service_file" << EOF
[Unit]
Description=${unit_desc}
${unit_after}
Wants=network.target
# Never give up restarting, however many times it crashes
StartLimitIntervalSec=0

[Service]
Type=simple
User=$SLIPSTREAM_USER
Group=$SLIPSTREAM_USER
ExecStart=${INSTALL_DIR}/slipstream-server --dns-listen-host ${dns_listen_host} --dns-listen-port ${SLIPSTREAM_PORT} --target-address 127.0.0.1:${target_port} --domain ${DOMAIN} --cert ${CERT_FILE} --key ${KEY_FILE}
Restart=always
RestartSec=1
# Make the kernel OOM-killer avoid this service
OOMScoreAdjust=-500
KillMode=mixed
TimeoutStopSec=5

# Security settings
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/
ReadWritePaths=${CONFIG_DIR}
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF

    # Reload systemd and enable service
    systemctl daemon-reload
    systemctl enable "$service_name"

    print_status "Systemd service created: $service_name"
    print_status "Service will run as user: $SLIPSTREAM_USER"
    print_status "Service will listen on port: $SLIPSTREAM_PORT (redirected from port 53)"
    print_status "Service will tunnel to 127.0.0.1:$target_port"
    print_status "Instance: $COMP"
}

# Function to start services
start_services() {
    print_status "Starting services..."

    systemctl restart "$SERVICE_NAME"
    print_status "$SERVICE_NAME service started"

    # bring back the other instance if we stopped it for the binary update
    local svc
    for svc in "${RESTART_AFTER_INSTALL[@]}"; do
        if [ "$svc" != "$SERVICE_NAME" ]; then
            systemctl start "$svc" 2>/dev/null && print_status "$svc service started again"
        fi
    done

    systemctl status "$SERVICE_NAME" --no-pager -l
}

# Function to print success box without [INFO] prefix
print_success_box() {
    local border_color='\033[1;32m'  # Bright green
    local text_color='\033[1;37m'    # Bright white text
    local key_color='\033[1;33m'     # Yellow for key
    local header_color='\033[1;36m'  # Cyan for headers
    local reset='\033[0m'

    echo ""
    # Top border
    echo -e "${border_color}+================================================================================${reset}"
    echo -e "${border_color}|                          SETUP COMPLETED SUCCESSFULLY!                       |${reset}"
    echo -e "${border_color}+================================================================================${reset}"
    echo ""

    # Configuration Details
    echo -e "${header_color}Configuration Details:${reset}"
    echo -e "  ${text_color}Domain: $DOMAIN${reset}"
    echo -e "  ${text_color}Instance: $(comp_label "$COMP")${reset}"
    echo -e "  ${text_color}Service user: $SLIPSTREAM_USER${reset}"
    echo -e "  ${text_color}Listen port: $SLIPSTREAM_PORT (UDP 53 for this domain is redirected here)${reset}"
    echo ""

    # Script Location
    echo -e "${text_color}Script installed at: $SCRIPT_INSTALL_PATH${reset}"
    echo ""

    # Management Commands
    echo -e "${header_color}Management Commands:${reset}"
    echo -e "  ${text_color}Run menu:           slipstream-rust-deploy${reset}"
    echo -e "  ${text_color}Start service:      systemctl start $SERVICE_NAME${reset}"
    echo -e "  ${text_color}Stop service:       systemctl stop $SERVICE_NAME${reset}"
    echo -e "  ${text_color}Service status:     systemctl status $SERVICE_NAME${reset}"
    echo -e "  ${text_color}View logs:          journalctl -u $SERVICE_NAME -f${reset}"



    # Bottom border
    echo ""
    echo -e "${border_color}+================================================================================${reset}"
    echo ""
}

# Function to display final information
display_final_info() {
    print_success_box
}

# Function to detect dnstt installation
detect_dnstt() {
    local dnstt_detected=false
    local detection_reasons=()

    # Check for dnstt-server binary
    if [ -f "/usr/local/bin/dnstt-server" ]; then
        dnstt_detected=true
        detection_reasons+=("dnstt-server binary found at /usr/local/bin/dnstt-server")
    fi

    # Check for dnstt-server systemd service
    if systemctl list-unit-files | grep -q "^dnstt-server.service"; then
        dnstt_detected=true
        detection_reasons+=("dnstt-server systemd service found")
    fi

    # Check for dnstt user
    if id "dnstt" &>/dev/null; then
        dnstt_detected=true
        detection_reasons+=("dnstt user found")
    fi

    # Check for dnstt config directory
    if [ -d "/etc/dnstt" ]; then
        dnstt_detected=true
        detection_reasons+=("dnstt config directory found at /etc/dnstt")
    fi

    # Check for dnstt-deploy script
    if [ -f "/usr/local/bin/dnstt-deploy" ]; then
        dnstt_detected=true
        detection_reasons+=("dnstt-deploy script found")
    fi

    if [ "$dnstt_detected" = true ]; then
        echo ""
        print_error "dnstt installation detected on this system!"
        echo ""
        print_warning "The following dnstt components were found:"
        for reason in "${detection_reasons[@]}"; do
            echo -e "  ${YELLOW}- $reason${NC}"
        done
        echo ""
        print_warning "dnstt must be uninstalled before installing slipstream-rust."
        print_warning "Both services use port 5300 and will conflict."
        echo ""
        print_status "To uninstall dnstt, run the following command:"
        echo -e "${GREEN}  bash <(curl -Ls https://raw.githubusercontent.com/AliRezaBeigy/dnstt-deploy/main/dnstt-deploy.sh) uninstall${NC}"
        echo ""
        print_question "Press Enter after uninstalling dnstt to continue, or Ctrl+C to exit: "
        read -r
        echo ""
        
        # Verify dnstt is actually uninstalled
        local still_installed=false
        if [ -f "/usr/local/bin/dnstt-server" ] || \
           systemctl list-unit-files | grep -q "^dnstt-server.service" || \
           id "dnstt" &>/dev/null || \
           [ -d "/etc/dnstt" ]; then
            still_installed=true
        fi
        
        if [ "$still_installed" = true ]; then
            print_error "dnstt is still detected on the system. Please uninstall it completely before proceeding."
            exit 1
        else
            print_status "dnstt has been successfully removed. Continuing with slipstream-rust installation..."
        fi
    fi
}

# Main function
main() {
    RESTART_AFTER_INSTALL=()
    set_component ssh

    # If not running from installed location (curl/GitLab), install the script first
    if [ "$0" != "$SCRIPT_INSTALL_PATH" ]; then
        print_status "Installing slipstream-rust-deploy script..."
        install_script
        print_status "Starting slipstream-rust server setup..."
    else
        # Running from installed location - show menu
        handle_menu
        # handle_menu returned: user picked an install/reconfigure option (COMP is set)
    fi

    # Detect OS and architecture
    detect_os

    # Remove the old Xray slipstream instance if a previous version installed it
    remove_legacy_xray_instance

    # Clean up DNS conflicts before installation
    cleanup_dns_conflicts

    # Check for dnstt installation and notify user if found
    detect_dnstt

    # Get user input
    get_user_input

    # Install slipstream-server (prebuilt binary from GitLab mirror)
    install_slipstream_server

    # Create slipstream user
    create_slipstream_user

    # Generate certificates
    generate_certificates

    # Save configuration after certificates are generated
    save_config

    # Configure firewall and iptables (redirect rules cover every installed instance)
    configure_firewall

    # Create systemd service
    create_systemd_service

    # Start services
    start_services

    # Display final information
    display_final_info
}

# Run main function
main "$@"
