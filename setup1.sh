#!/bin/bash
# Install aaa-main

# Colors
Red='\e[1;31m'
Green='\e[1;32m'
Yellow='\e[1;33m'
Blue='\e[1;34m'
NC='\e[0m'

# Locale
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# Ensure the script is run as root
if [ "${EUID}" -ne 0 ]; then
    echo -e "${Red}You need to run this script as root${NC}"
    sleep 5
    exit 1
fi

# Check virtualization -- OpenVZ containers are missing capabilities
# (TUN/TAP, some netfilter modules) that this stack depends on.
if [ "$(systemd-detect-virt)" == "openvz" ]; then
    echo -e "${Red}OpenVZ is not supported${NC}"
    sleep 5
    exit 1
fi

# Swap muna bago ang lahat (pinakauna) -- para may swap na habang nagko-compile
# ng gomux/ws-go sa maliit na RAM (hal. 700 MB). Permanente ito (naka-fstab).
echo -e "${Blue}Setting up swap...${NC}"
curl -fsSL https://raw.githubusercontent.com/noelrubio143/sshonly/main/swap.sh -o /root/swap.sh \
    && sed -i 's/\r$//' /root/swap.sh && bash /root/swap.sh \
    || echo -e "${Yellow}[!] Hindi nagawa ang swap, itutuloy pa rin ang install.${NC}"
rm -f /root/swap.sh

# Prevent apt/dpkg from ever popping an interactive prompt (tzdata,
# config-file conflicts, needrestart's "which services to restart?"
# checklist, etc.) - without this, installs can silently hang forever
# waiting for input that never comes, since output is redirected away.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
echo 'APT::Get::Assume-Yes "true";' > /etc/apt/apt.conf.d/90assumeyes
if [ -d /etc/needrestart ]; then
    mkdir -p /etc/needrestart/conf.d
    echo "\$nrconf{restart} = 'a';" > /etc/needrestart/conf.d/99-noninteractive.conf
fi

# Create the config dir (domain + TLS certificate live here)
mkdir -p /etc/aaa
touch /etc/aaa/domain

# Install dependencies
echo -e "${Blue}Installing dependencies...${NC}"
apt-get update
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" software-properties-common wget curl git dos2unix

# NOTE: this used to also build Python 2.7.18 from source here. Nothing in
# this repo actually calls python2.7 or a bare "python" (ws-dropbear /
# ws-stunnel run under python3, which is installed separately by
# sshws/insshws.sh), so it was dead weight -- and it doesn't survive newer
# toolchains: Debian 13 / Ubuntu 26 ship GCC 14+, which turns
# -Wimplicit-function-declaration into a hard error by default, and
# Python 2.7's ./configure/source predate that, so the build fails outright.
# Removed rather than patched since it wasn't being used.

# IP ng VPS (walang domain) -- self-signed certificate sa IP, 11 taon.
echo -e "${Blue}Getting public IP...${NC}"
dom=""
for u in ifconfig.me ipv4.icanhazip.com api.ipify.org; do
    dom="$(curl -s4 --max-time 10 "$u" 2>/dev/null | tr -d '[:space:]')"
    [[ "$dom" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    dom=""
done
if [ -z "$dom" ]; then
    read -r -p "Hindi makuha ang public IP. Ilagay ang IP ng VPS: " dom
    dom="$(printf %s "$dom" | tr -d '[:space:]')"
fi
if ! [[ "$dom" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${Red}Hindi tamang IP: $dom${NC}"
    exit 1
fi
mkdir -p /var/lib
echo "IP=$dom" > /var/lib/ipvps.conf
echo "$dom" > /root/scdomain
echo "$dom" > /etc/aaa/domain
echo "$dom" > /root/domain

# Install SSH-VPN
echo -e "${Blue}Installing SSH-VPN...${NC}"
wget -q https://raw.githubusercontent.com/noelrubio143/sshonly/main/ssh/ssh-vpn.sh -O ssh-vpn.sh
dos2unix ssh-vpn.sh
bash ssh-vpn.sh

# Base packages + time sync (these used to come with the Xray installer)
echo -e "${Blue}Installing base packages...${NC}"
apt-get install -y iptables iptables-persistent chrony curl wget xz-utils apt-transport-https gnupg lsb-release openssl cron unzip
timedatectl set-ntp true
systemctl enable chrony
systemctl restart chrony
timedatectl set-timezone Asia/Jakarta
mkdir -p /home/vps/public_html

# Self-signed certificate sa IP, 11 taon (/etc/aaa/server.crt + server.key)
echo -e "${Blue}Creating self-signed certificate for $dom (11 years)...${NC}"
wget -q https://raw.githubusercontent.com/noelrubio143/sshonly/main/edge/get-ssl.sh -O get-ssl.sh
dos2unix get-ssl.sh
if ! bash get-ssl.sh "$dom"; then
    echo -e "${Red}[!] Hindi nagawa ang certificate para sa $dom.${NC}"
    exit 1
fi
rm -f get-ssl.sh

# Install gomux edge layer (80/443 multiplexer)
echo -e "${Blue}Installing gomux edge layer...${NC}"
wget -q https://raw.githubusercontent.com/noelrubio143/sshonly/main/edge/ins-gomux.sh -O ins-gomux.sh
dos2unix ins-gomux.sh
bash ins-gomux.sh

# Install SSH WebSocket
echo -e "${Blue}Installing SSH WebSocket...${NC}"
wget -q https://raw.githubusercontent.com/noelrubio143/sshonly/main/sshws/insshws.sh
dos2unix insshws.sh
bash insshws.sh

# Slipstream is intentionally NOT installed/configured here anymore.
# ssh-vpn.sh (run above) already downloads the script straight to its
# permanent home at /usr/local/bin/slipstream-rust-deploy, so menu
# option 5 finds it there and runs its own first-time setup interactively
# ("$0 = install path" branch -> check_for_updates + handle_menu). Running
# it a second time here, unattended, used to invoke its full
# install/get_user_input flow with no TTY to answer the prompts -- at
# best a no-op re-copy, at worst a half-configured slipstream service. If
# you ever need Slipstream configured automatically during install again,
# reintroduce this as a call to `slipstream-rust-deploy` (the installed
# path) with its non-interactive flags, not by re-downloading and running
# the raw script.

# Setup environment
ln -fs /usr/share/zoneinfo/Asia/Jakarta /etc/localtime


# FINAL VERIFICATION (BEFORE REBOOT)
echo ""
echo "════════════════════════════════════════"
echo "  FINAL SERVICE VERIFICATION"
echo "════════════════════════════════════════"
sleep 2

# Check gomux edge
systemctl is-active --quiet gomux && echo "✓ gomux: OK" || echo "✗ gomux: FAILED"

# Check SSH
systemctl is-active --quiet ssh && echo "✓ SSH: OK" || echo "✗ SSH: FAILED"

echo ""
echo -e "${Green}✓ Installation complete!${NC}"
echo ""

# Cleanup and reboot
rm -f /root/setup1.sh /root/ssh-vpn.sh /root/ins-gomux.sh /root/insshws.sh /root/get-ssl.sh
echo "All services configured. Auto reboot in 10 seconds..."
sleep 10
reboot
