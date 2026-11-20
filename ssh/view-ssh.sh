#!/bin/bash
###############################################################################
# View an existing SSH account again.
#
# The account list comes from /etc/passwd (accounts made by usernew use the
# /bin/false shell). The expiry is read live with chage. The password can only
# be shown for accounts made after this feature: usernew saves "user:password"
# in /etc/ssh-accounts (root only); older accounts show "not saved".
###############################################################################

PASSWD_FILE="${PASSWD_FILE:-/etc/passwd}"
DB_FILE="${DB_FILE:-/etc/ssh-accounts}"
DOMAIN_FILE="${DOMAIN_FILE:-/etc/aaa/domain}"
L="\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"

domen=$(cat "$DOMAIN_FILE")
portsshws=80
wsssl=443
opensh="22,200,500,53,666,40000,51443,58080"
ssl=443

# usernames of the SSH accounts (uid >= 1000, shell /bin/false)
mapfile -t users < <(awk -F: '$3 >= 1000 && $1 != "nobody" && $7 == "/bin/false" {print $1}' "$PASSWD_FILE")

clear
echo -e "$L"
echo -e "\E[44;1;39m         View AMBERVPN SSH Account         \E[0m"
echo -e "$L"

if [[ ${#users[@]} -eq 0 ]]; then
    echo ""
    echo "No SSH account found."
    echo ""
    read -n 1 -s -r -p "Press any key to back on menu"
    m-sshovpn
    exit 0
fi

echo ""
printf " %-4s %-18s %s\n" "No" "Username" "Expired"
echo -e "$L"
n=1
for u in "${users[@]}"; do
    e=$(chage -l "$u" 2>/dev/null | grep "Account expires" | awk -F": " '{print $2}')
    printf " %-4s %-18s %s\n" "$n" "$u" "$e"
    n=$((n + 1))
done
echo -e "$L"
echo ""
read -rp "Select number (0 = back): " pick

if ! [[ "$pick" =~ ^[0-9]+$ ]] || (( pick < 1 || pick > ${#users[@]} )); then
    m-sshovpn
    exit 0
fi

Login="${users[$((pick - 1))]}"
exp=$(chage -l "$Login" 2>/dev/null | grep "Account expires" | awk -F": " '{print $2}')
Pass=""
[ -f "$DB_FILE" ] && Pass=$(awk -F: -v u="$Login" '$1 == u {sub(/^[^:]*:/, ""); print; exit}' "$DB_FILE")
[[ -z "$Pass" ]] && Pass="(not saved - account made before this feature)"
IP=$(curl -sS ifconfig.me)

clear
echo -e "$L"
echo -e "\E[0;41;36m           SENSI SSH Account            \E[0m"
echo -e "$L"
echo -e "Username    : $Login"
echo -e "Password    : $Pass"
echo -e "Expired On  : $exp"
echo -e "$L"
echo -e "IP          : $IP"
echo -e "Host        : $domen"
echo -e "OpenSSH     : $opensh"
echo -e "SSH WS      : $portsshws"
echo -e "SSH SSL WS  : $wsssl"
echo -e "SSL/TLS     : $ssl"
echo -e "UDPGW       : 7100-7900"
echo -e "$L"
echo -e "$L"
echo -e "$L"
echo -e "
GET / HTTP/1.1[crlf]Host: ${domen}[crlf]Upgrade: websocket[crlf]X-Real-Host: 127.0.0.1:1194[crlf][crlf]
"
echo -e "$L"
echo -e "Payload WSS"
echo -e "
GET wss://isi_bug_disini HTTP/1.1[crlf]Host: ${domen}[crlf]Upgrade: websocket[crlf][crlf]
"
echo -e "$L"
echo -e "Payload WS"
echo -e "
GET / HTTP/1.1[crlf]Host: $domen[crlf]Upgrade: websocket[crlf][crlf]
"
echo -e "$L"

# Slipstream (DNS Tunnel) - shown only when it has been deployed (Menu > 5)
SLIPSTREAM_CONF="/etc/slipstream-rust/slipstream-rust-server.conf"
if [ -f "$SLIPSTREAM_CONF" ]; then
    . "$SLIPSTREAM_CONF"
    echo -e "\E[0;41;36m         CONFIG SLIPSTREAM (DNS)        \E[0m"
    echo -e "$L"
    echo -e "Domain      : ${DOMAIN:-$domen}"
    echo -e "Note        : pick Slipstream (DNS Tunnel) in the client app"
    echo -e "              and use this domain as the Nameserver/Domain."
    echo -e "$L"
fi

echo ""
read -n 1 -s -r -p "Press any key to back on menu"

m-sshovpn
