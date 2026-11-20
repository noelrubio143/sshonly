#!/bin/bash
MYIP=$(wget -qO- ipv4.icanhazip.com);
echo "Checking VPS"
clear
domen=$(cat /etc/aaa/domain)
portsshws=80
wsssl=443

echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "\E[0;41;36m          SENSI SSH Account            \E[0m"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
read -p "Username : " Login
read -p "Password : " Pass
read -p "Expired (hari): " masaaktif

IP=$(curl -sS ifconfig.me);
opensh="22,200,500,53,666,40000,51443,58080"
ssl=443

sleep 1
clear
useradd -e `date -d "$masaaktif days" +"%Y-%m-%d"` -s /bin/false -M $Login
exp="$(chage -l $Login | grep "Account expires" | awk -F": " '{print $2}')"
echo -e "$Pass\n$Pass\n"|passwd $Login &> /dev/null
# save the password so the account can be viewed again later (root only)
touch /etc/ssh-accounts; chmod 600 /etc/ssh-accounts
( umask 077; awk -F: -v u="$Login" '$1 != u' /etc/ssh-accounts > /etc/ssh-accounts.tmp ) && mv /etc/ssh-accounts.tmp /etc/ssh-accounts
echo "${Login}:${Pass}" >> /etc/ssh-accounts
chmod 600 /etc/ssh-accounts
PID=`ps -ef |grep -v grep | grep sshws |awk '{print $2}'`

if [[ ! -z "${PID}" ]]; then
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "\E[0;41;36m           SENSI SSH Account            \E[0m"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "Username    : $Login"
echo -e "Password    : $Pass"
echo -e "Expired On  : $exp"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "IP          : $IP"
echo -e "Host        : $domen"
echo -e "OpenSSH     : $opensh"
echo -e "SSH WS      : $portsshws"
echo -e "SSH SSL WS  : $wsssl"
echo -e "SSL/TLS     : $ssl"
echo -e "UDPGW       : 7100-7900"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "
GET / HTTP/1.1[crlf]Host: ${domen}[crlf]Upgrade: websocket[crlf]X-Real-Host: 127.0.0.1:1194[crlf][crlf]
"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "Payload WSS"
echo -e "
GET wss://isi_bug_disini HTTP/1.1[crlf]Host: ${domen}[crlf]Upgrade: websocket[crlf][crlf]
"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "Payload WS"
echo -e "
GET / HTTP/1.1[crlf]Host: $domen[crlf]Upgrade: websocket[crlf][crlf]
"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
else

echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "\E[0;41;36m           SENSI SSH Account            \E[0m"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "Username    : $Login"
echo -e "Password    : $Pass"
echo -e "Expired On  : $exp"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "IP          : $IP"
echo -e "Host        : $domen"
echo -e "OpenSSH     : $opensh"
echo -e "SSH WS      : $portsshws"
echo -e "SSH SSL WS  : $wsssl"
echo -e "SSL/TLS     : $ssl"
echo -e "UDPGW       : 7100-7900"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "
GET / HTTP/1.1[crlf]Host: ${domen}[crlf]Upgrade: websocket[crlf]X-Real-Host: 127.0.0.1:1194[crlf][crlf]
"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "Expired On  : $exp"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "Payload WSS"
echo -e "
GET wss://isi_bug_disini HTTP/1.1[crlf]Host: ${domen}[crlf]Upgrade: websocket[crlf][crlf]
"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
echo -e "Payload WS"
echo -e "
GET / HTTP/1.1[crlf]Host: $domen[crlf]Upgrade: websocket[crlf][crlf]
"
echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
fi

# Slipstream (DNS Tunnel) - same VPS/domain as above. Only shown when the
# Slipstream server has actually been deployed (Menu > option 5). Slipstream
# is SSH-only now (no SOCKS/Shadowsocks mode), so all it needs from the
# deploy config is the domain.
SLIPSTREAM_CONF="/etc/slipstream-rust/slipstream-rust-server.conf"
if [ -f "$SLIPSTREAM_CONF" ]; then
    . "$SLIPSTREAM_CONF"
    echo -e "\E[0;41;36m         CONFIG SLIPSTREAM (DNS)        \E[0m"
    echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    echo -e "Domain      : ${DOMAIN:-$domen}"
    echo -e "Note        : pick Slipstream (DNS Tunnel) in the client app"
    echo -e "              and use this domain as the Nameserver/Domain."
    echo -e "\033[0;34m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
fi

echo ""
read -n 1 -s -r -p "Press any key to back on menu"
