#!/bin/bash
# AMBER VPN - Self-signed TLS certificate on the VPS IP, valid 11 years (command: m-ssl)
#
# One certificate for everything:
#   /etc/aaa/server.crt + /etc/aaa/server.key
# gomux (ports 80/443) is the only component that reads it, and it hot-reloads
# the files when they change (it re-checks about every 30s - no restart needed).
#
# Walang domain, walang Let's Encrypt, walang renewal: self-signed ito sa IP
# at 11 taon ang bisa (4018 days).
#
# Usage:  m-ssl [ip]        (auto-detects the public IP if you don't pass one)

RED='\e[1;31m'; GRN='\e[1;32m'; YEL='\e[1;33m'; BLU='\e[1;34m'; NC='\e[0m'

[ "$(id -u)" = 0 ] || { echo -e "${RED}Run as root.${NC}"; exit 1; }

CRT="${CRT:-/etc/aaa/server.crt}"
KEY="${KEY:-/etc/aaa/server.key}"
DAYS=4018          # 11 years (11*365 + 3 leap days)

is_ip() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    local o; for o in ${1//./ }; do [ "$o" -le 255 ] 2>/dev/null || return 1; done
}
die() { echo -e "${RED} $*${NC}"; exit 1; }

command -v openssl >/dev/null 2>&1 || { apt-get install -y openssl >/dev/null 2>&1; }
command -v openssl >/dev/null 2>&1 || die "Walang openssl."

# ---- 1. IP
ip="$(printf %s "$1" | tr -d '[:space:]')"
if [ -z "$ip" ]; then
    for u in ifconfig.me ipv4.icanhazip.com api.ipify.org; do
        ip="$(curl -s4 --max-time 10 "$u" 2>/dev/null | tr -d '[:space:]')"
        is_ip "$ip" && break
        ip=""
    done
fi
is_ip "$ip" || die "Hindi makuha ang public IP. Ilagay mano-mano:  m-ssl 1.2.3.4"

# ---- 2. subjectAltName: the IP (+ the saved hostname, if one was set with 'CHANGE DOMAIN')
san="IP:$ip"
d="$(cat /etc/aaa/domain 2>/dev/null | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
if [ -n "$d" ] && ! is_ip "$d" && [[ "$d" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
    san="$san,DNS:$d"
fi

# ---- 3. generate (to temp files first, so gomux never reads a half-written pair)
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = $ip
[v3]
subjectAltName         = $san
basicConstraints       = critical,CA:FALSE
keyUsage               = critical,digitalSignature,keyEncipherment
extendedKeyUsage       = serverAuth
subjectKeyIdentifier   = hash
CNF

echo -e " ${BLU}Gumagawa ng self-signed certificate para sa $ip (11 taon) ...${NC}"
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days "$DAYS" \
    -keyout "$tmp/server.key" -out "$tmp/server.crt" \
    -config "$tmp/openssl.cnf" >/dev/null 2>&1 \
    || die "Nabigo ang paggawa ng certificate."

# ---- 4. install (key first, crt last - gomux watches the crt)
mkdir -p "$(dirname "$CRT")" "$(dirname "$KEY")"
install -m 600 "$tmp/server.key" "$KEY"
install -m 644 "$tmp/server.crt" "$CRT"

# ---- 5. use the IP everywhere the other scripts read it
if [ "$CRT" = /etc/aaa/server.crt ]; then
    mkdir -p /var/lib
    echo "$ip" > /etc/aaa/domain
    echo "$ip" > /root/domain
    echo "IP=$ip" > /var/lib/ipvps.conf
fi

# ---- 6. wait until gomux serves the new certificate (it re-checks every ~30s)
if [ "$CRT" = /etc/aaa/server.crt ] && systemctl is-active --quiet gomux 2>/dev/null; then
    echo -n " Hinihintay na gamitin ng gomux ang bagong certificate"
    ok=0
    for i in 1 2 3 4 5 6 7 8; do
        s="$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$ip" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null)"
        if echo "$s" | grep -q "$ip"; then ok=1; break; fi
        echo -n "."; sleep 5
    done
    echo
    [ $ok = 1 ] || echo -e " ${YEL}Hindi pa nakikita sa 443. Subukan: systemctl restart gomux${NC}"
fi

end="$(openssl x509 -in "$CRT" -noout -enddate 2>/dev/null | cut -d= -f2)"
echo
echo -e " ${GRN}Tapos na. Self-signed certificate sa IP, 11 taon.${NC}"
echo " IP      : $ip"
echo " SAN     : $san"
echo " Expires : $end"
echo " Cert    : $CRT (isa lang para sa lahat)"
echo " Paalala : self-signed ito - sa client/app, naka-allow insecure / walang cert verification."
exit 0
