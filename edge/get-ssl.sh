#!/bin/bash
# AMBER VPN - Let's Encrypt for the whole stack (command: m-ssl)
#
# One certificate for everything:
#   /etc/aaa/server.crt + /etc/aaa/server.key
# gomux (ports 80/443) is the only component that deals with the certificate:
#   - it answers the Let's Encrypt HTTP-01 challenge on port 80 (nothing is stopped)
#   - it hot-reloads the files after every renewal (no restart)
#
# Usage:  m-ssl [domain]        (asks for the domain if you don't pass one)

RED='\e[1;31m'; GRN='\e[1;32m'; YEL='\e[1;33m'; BLU='\e[1;34m'; NC='\e[0m'

[ "$(id -u)" = 0 ] || { echo -e "${RED}Run as root.${NC}"; exit 1; }

ACME_ROOT=/var/www/acme
CRT=/etc/aaa/server.crt
KEY=/etc/aaa/server.key
GOMUX_URL="https://gitlab.com/babayega143/sshonly/-/raw/main/edge/ins-gomux.sh"

is_ip() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
die() { echo -e "${RED} $*${NC}"; exit 1; }

# ---- 1. domain
dom="$(printf %s "$1" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
if [ -z "$dom" ]; then
    def="$(cat /etc/aaa/domain 2>/dev/null)"
    is_ip "$def" && def=""
    read -r -p " Domain ng VPS na ito${def:+ [$def]} : " dom
    dom="$(printf %s "${dom:-$def}" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
fi
[ -n "$dom" ] || die "Kailangan ng domain."
is_ip "$dom" && die "IP ito, hindi domain. Ang Let's Encrypt ay para sa domain lang."
[[ "$dom" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] && [[ "$dom" == *.* ]] || die "Hindi tamang domain: $dom"

# ---- 2. does the domain point to this VPS?
ip="$(curl -s4 --max-time 10 ifconfig.me 2>/dev/null)"
dip="$(getent ahostsv4 "$dom" 2>/dev/null | awk '{print $1; exit}')"
if [ -z "$dip" ] || [ -z "$ip" ] || [ "$dip" != "$ip" ]; then
    echo -e "${RED} Ang $dom ay nakaturo sa '${dip:-wala}', pero ang IP ng VPS ay '${ip:-?}'.${NC}"
    echo " Ituro muna ang A record ng domain sa IP na ito (Cloudflare: DNS only / grey cloud), saka ulitin."
    exit 1
fi

# ---- 3. mode: gomux (webroot) if it is already running, else standalone on port 80 (first install)
MODE=webroot
if ! systemctl is-active --quiet gomux 2>/dev/null; then
    MODE=standalone
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE '[:.]80$'; then
        die "May gumagamit na ng port 80 at hindi ito gomux. Patayin muna, saka ulitin."
    fi
else
    mkdir -p "$ACME_ROOT/.well-known/acme-challenge"
    chmod -R 755 "$ACME_ROOT"
    check_gomux() {
        local t="_t$$"
        echo ok > "$ACME_ROOT/.well-known/acme-challenge/$t"
        local code
        code="$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1/.well-known/acme-challenge/$t")"
        rm -f "$ACME_ROOT/.well-known/acme-challenge/$t"
        [ "$code" = "200" ]
    }
    if ! check_gomux; then
        echo -e "${YEL} Luma pa ang gomux (hindi pa nito kayang sagutin ang Let's Encrypt).${NC}"
        echo " Ia-update ito ngayon (sandaling mawawala ang koneksyon sa port 80/443)."
        read -r -p " Ituloy? [Y/n] : " yn
        case "$yn" in n|N) exit 1 ;; esac
        wget -qO /tmp/ins-gomux.sh "$GOMUX_URL" && sed -i 's/\r$//' /tmp/ins-gomux.sh && bash /tmp/ins-gomux.sh
        rm -f /tmp/ins-gomux.sh
        sleep 2
        check_gomux || die "Hindi pa rin sumasagot ang gomux sa port 80. Tingnan: journalctl -u gomux -e"
    fi
fi

# ---- 4. acme.sh
ACME="$HOME/.acme.sh/acme.sh"
if [ ! -x "$ACME" ]; then
    echo " Ini-install ang acme.sh..."
    command -v apt-get >/dev/null 2>&1 && apt-get install -y curl cron ca-certificates >/dev/null 2>&1
    : > /tmp/acme-err.txt; : > /tmp/acme-install.txt
    curl -fsSL https://get.acme.sh 2>>/tmp/acme-err.txt | sh >>/tmp/acme-install.txt 2>&1
    if [ ! -x "$ACME" ]; then
        rm -rf /tmp/acme-src && mkdir -p /tmp/acme-src
        if curl -fsSL https://github.com/acmesh-official/acme.sh/archive/refs/heads/master.tar.gz -o /tmp/acme-src/a.tgz 2>>/tmp/acme-err.txt \
           && tar -xzf /tmp/acme-src/a.tgz -C /tmp/acme-src; then
            (cd /tmp/acme-src/acme.sh-master && sh ./acme.sh --install >>/tmp/acme-install.txt 2>&1)
        fi
        rm -rf /tmp/acme-src
    fi
fi
if [ ! -x "$ACME" ]; then
    echo -e "${RED} Hindi ma-install ang acme.sh.${NC}"
    echo " Detalye:"; tail -n 5 /tmp/acme-err.txt /tmp/acme-install.txt 2>/dev/null
    exit 1
fi
"$ACME" --set-default-ca --server letsencrypt >/dev/null 2>&1

# ---- 5. issue (webroot -> gomux, or standalone on first install) and install
echo -e " ${BLU}Kumukuha ng certificate para sa $dom ...${NC}"
if [ "$MODE" = standalone ]; then
    "$ACME" --issue -d "$dom" --standalone --httpport 80 --server letsencrypt --keylength ec-256
else
    "$ACME" --issue -d "$dom" -w "$ACME_ROOT" --server letsencrypt --keylength ec-256
fi
rc=$?
# rc 2 = "not due for renewal yet": the certificate already exists, that's fine
if [ $rc -ne 0 ] && [ $rc -ne 2 ]; then
    die "Nabigo ang pagkuha ng certificate. Siguraduhing bukas ang port 80 sa firewall/security group at tama ang domain."
fi

# Renewals must NOT use standalone (gomux owns port 80): switch the saved mode to webroot,
# which gomux answers from /var/www/acme without stopping anything.
mkdir -p "$ACME_ROOT/.well-known/acme-challenge"; chmod -R 755 "$ACME_ROOT"
for f in "$HOME/.acme.sh/${dom}_ecc/${dom}.conf" "$HOME/.acme.sh/${dom}/${dom}.conf"; do
    [ -f "$f" ] && sed -i "s|^Le_Webroot=.*|Le_Webroot='$ACME_ROOT'|" "$f"
done

mkdir -p /etc/aaa
"$ACME" --install-cert -d "$dom" --ecc \
    --fullchain-file "$CRT" --key-file "$KEY" \
    --reloadcmd "chmod 644 $CRT; chmod 600 $KEY" \
    || die "Hindi ma-install ang certificate sa $CRT."
chmod 644 "$CRT"; chmod 600 "$KEY"

# ---- 6. use the domain everywhere the other scripts read it
mkdir -p /var/lib
echo "$dom" > /etc/aaa/domain
echo "$dom" > /root/domain
echo "IP=$dom" > /var/lib/ipvps.conf

# ---- 7. wait until gomux serves the new certificate (it re-checks every ~30s)
if ! systemctl is-active --quiet gomux 2>/dev/null; then
    echo -e " ${GRN}Nakuha na ang certificate para sa $dom. Ia-install pa ang gomux.${NC}"
    exit 0
fi
echo -n " Hinihintay na gamitin ng gomux ang bagong certificate"
ok=0
for i in 1 2 3 4 5 6 7 8; do
    iss="$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$dom" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null)"
    if echo "$iss" | grep -qi "Let's Encrypt"; then ok=1; break; fi
    echo -n "."; sleep 5
done
echo
echo
if [ $ok = 1 ]; then
    echo -e " ${GRN}Tapos na. Trusted na ang certificate para sa $dom (auto-renew).${NC}"
else
    echo -e " ${YEL}Nakuha na ang certificate pero hindi pa ito nakikita sa 443.${NC}"
    echo "   Subukan: systemctl restart gomux"
fi
echo " Domain  : $dom"
echo " Cert    : $CRT (isa lang para sa lahat)"
echo " Paalala: ang mga bagong account ay gagamit na ng domain na ito. Ang mga lumang account ay IP pa rin."
exit 0
