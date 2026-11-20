#!/bin/bash
# Diagnostic script for SSH WS / SSL-SNI:
#   Client -> gomux (443/80) -> ws-stunnel (127.0.0.1:700) -> OpenSSH (22)
#   Client -> gomux (443/80) /dropbear-ws -> ws-dropbear (127.0.0.1:2095) -> SSH
#   Client -> gomux (443/80, SSH payload) -> OpenSSH (22) directly
#   Any-SNI TLS -> gomux terminates TLS itself (no separate internal ports)
#
# Usage: bash check-sshws.sh

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

line() { echo "------------------------------------------------------------"; }

echo -e "\n=== 1. Service status ===\n"
for svc in gomux ws-stunnel ws-dropbear ssh; do
    state=$(systemctl is-active "$svc" 2>/dev/null)
    if [ "$state" = "active" ]; then
        echo -e "${GREEN}[OK]${NC} $svc is active"
    else
        echo -e "${RED}[FAIL]${NC} $svc is '$state'"
    fi
done

line
echo -e "\n=== 2. Ports listening ===\n"
for p in "80:gomux" "443:gomux" "700:ws-stunnel" "2095:ws-dropbear" "22:openssh"; do
    port="${p%%:*}"
    label="${p#*:}"
    result=$(ss -tlnp 2>/dev/null | grep -E "[:.]$port\s")
    if [ -n "$result" ]; then
        echo -e "${GREEN}[OK]${NC} port $port ($label)"
    else
        echo -e "${RED}[FAIL]${NC} port $port ($label) is NOT listening"
    fi
done

line
echo -e "\n=== 3. Certificates ===\n"
for c in /etc/aaa/server.crt; do
    if [ -f "$c" ]; then
        echo "$c:"
        openssl x509 -in "$c" -noout -dates 2>/dev/null | grep -E "notBefore|notAfter"
    else
        echo -e "${RED}[FAIL]${NC} $c not found"
    fi
done
if [ -f /etc/aaa/server.key ]; then
    echo -e "${GREEN}[OK]${NC} /etc/aaa/server.key exists"
else
    echo -e "${RED}[FAIL]${NC} /etc/aaa/server.key not found"
fi

line
echo -e "\n=== 4. TLS handshake test (via gomux 443) ===\n"
if command -v openssl >/dev/null; then
    # No ALPN -> any-SNI path (gomux terminates TLS, then routes)
    out=$(echo | timeout 5 openssl s_client -connect 127.0.0.1:443 2>/dev/null | grep -E "Protocol|Cipher is" | head -2)
    if [ -n "$out" ]; then
        echo -e "${GREEN}[OK]${NC} any-SNI TLS (no ALPN):"; echo "$out" | sed 's/^/     /'
    else
        echo -e "${RED}[FAIL]${NC} any-SNI TLS handshake failed"
    fi
    # http/1.1 ALPN -> gomux router
    out=$(echo | timeout 5 openssl s_client -connect 127.0.0.1:443 -alpn http/1.1 2>/dev/null | grep -E "Protocol|Cipher is" | head -2)
    if [ -n "$out" ]; then
        echo -e "${GREEN}[OK]${NC} http/1.1-ALPN TLS:"; echo "$out" | sed 's/^/     /'
    else
        echo -e "${RED}[FAIL]${NC} web-ALPN TLS handshake failed"
    fi
else
    echo "openssl not installed, skipping"
fi

line
echo -e "\n=== 5. Recent logs (last 15 lines each) ===\n"
for svc in gomux ws-stunnel ws-dropbear; do
    echo "--- $svc ---"
    journalctl -u "$svc" -n 15 --no-pager 2>/dev/null
done

line
echo -e "\nDone. I-paste ang buong output na ito para ma-check kung saan nagfa-fail.\n"
