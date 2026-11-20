#!/bin/bash
GREEN='\033[0;32m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BGreen='\e[1;32m'
BYellow='\e[1;33m'
BBlue='\e[1;34m'
BPurple='\e[1;35m'
NC='\033[0m'
yl='\e[32;1m'
bl='\e[36;1m'
gl='\e[32;1m'
rd='\e[31;1m'
mg='\e[0;95m'
blu='\e[34m'
op='\e[35m'
or='\033[1;33m'
bd='\e[1m'
color1='\e[031;1m'
color2='\e[34;1m'
color3='\e[0m'
# Getting
# IP Validation
dateFromServer=$(curl -v --insecure --silent https://google.com/ 2>&1 | grep Date | sed -e 's/< Date: //')
biji=`date +"%Y-%m-%d" -d "$dateFromServer"`
#########################

red='\e[1;31m'
green='\e[1;32m'
NC='\e[0m'
green() { echo -e "\\033[32;1m${*}\\033[0m"; }
red() { echo -e "\\033[31;1m${*}\\033[0m"; }
clear

# GETTING OS INFORMATION
source /etc/os-release
Versi_OS=$VERSION
ver=$VERSION_ID
Tipe=$NAME
URL_SUPPORT=$HOME_URL
basedong=$ID

# VPS ISP INFORMATION
MYIP=$(curl -s ifconfig.me )

# CHEK STATUS
ssh_service=$(/etc/init.d/ssh status | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
vnstat_service=$(/etc/init.d/vnstat status | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
cron_service=$(/etc/init.d/cron status | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
wstls=$(systemctl status ws-stunnel.service | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
wsdrop=$(systemctl status ws-dropbear.service | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
gomux_status=$(systemctl status gomux.service | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)

# COLOR VALIDATION
RED='\033[0;31m'
NC='\033[0m'
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
LIGHT='\033[0;37m'
clear

# STATUS SERVICE  SSH 
if [[ $ssh_service == "running" ]]; then 
   status_ssh=" ${GREEN}Running ${NC}( No Error )"
else
   status_ssh="${RED}  Not Running ${NC}  ( Error )"
fi

# STATUS SERVICE  VNSTAT 
if [[ $vnstat_service == "running" ]]; then 
   status_vnstat=" ${GREEN}Running ${NC}( No Error )"
else
   status_vnstat="${RED}  Not Running ${NC}  ( Error )"
fi

# STATUS SERVICE  CRONS 
if [[ $cron_service == "running" ]]; then 
   status_cron=" ${GREEN}Running ${NC}( No Error )"
else
   status_cron="${RED}  Not Running ${NC}  ( Error )"
fi

# STATUS SERVICE WEBSOCKET TLS
if [[ $wstls == "running" ]]; then 
   swstls=" ${GREEN}Running ${NC}( No Error )${NC}"
else
   swstls="${RED}  Not Running ${NC}  ( Error )${NC}"
fi

# STATUS SERVICE WEBSOCKET DROPBEAR
if [[ $wsdrop == "running" ]]; then 
   swsdrop=" ${GREEN}Running ${NC}( No Error )${NC}"
else
   swsdrop="${RED}  Not Running ${NC}  ( Error )${NC}"
fi

# STATUS SERVICE GOMUX (public 80/443 edge)
if [[ $gomux_status == "running" ]]; then 
   status_gomux=" ${GREEN}Running ${NC}( No Error )${NC}"
else
   status_gomux="${RED}  Not Running ${NC}  ( Error )${NC}"
fi



# TOTAL RAM
total_ram=` grep "MemTotal: " /proc/meminfo | awk '{ print $2}'`
totalram=$(($total_ram/1024))

# KERNEL TERBARU
kernelku=$(uname -r)

# DNS PATCH
#tipeos2=$(uname -m)
Name=$"AMBER VPN "
Exp=$"LIFETIME FREE"
# GETTING DOMAIN NAME
Domen="$(cat /etc/aaa/domain)"
echo -e ""
echo -e "\e[1;33m -------------------------------------------------\e[0m"
echo -e "\e[1;34m                SENSI SYSTEM INFORMATION               \e[0m"
echo -e "\e[1;33m -------------------------------------------------\e[0m"
echo -e "\e[1;32m Hostname  \e[0m: $HOSTNAME"
echo -e "\e[1;32m OS Name   \e[0m: $Tipe"
echo -e "\e[1;32m Total RAM \e[0m: ${totalram} MB"
echo -e "\e[1;32m Public IP \e[0m: $MYIP"
echo -e "\e[1;32m Domain    \e[0m: $Domen"
echo -e "\e[1;33m -------------------------------------------------\e[0m"
echo -e "\e[1;34m             SENSI SUBSCRIPTION INFORMATION            \e[0m"
echo -e "\e[1;33m -------------------------------------------------\e[0m"
echo -e "\e[1;32m Client Name \e[0m: $Name"
echo -e "\e[1;32m Exp Script  \e[0m: $Exp"
echo -e "\e[1;32m Version     \e[0m: 1.0"
echo -e "\e[1;33m -------------------------------------------------\e[0m"
echo -e "\e[1;34m               SENSI SERVICE INFORMATION               \e[0m"
echo -e "\e[1;33m -------------------------------------------------\e[0m"
echo -e "\e[1;32m SSH / TUN            \e[0m: $status_ssh"
echo -e "\e[1;32m Crons                \e[0m: $status_cron"
echo -e "\e[1;32m Vnstat               \e[0m: $status_vnstat"
echo -e "\e[1;32m Websocket TLS        \e[0m: $swstls"
echo -e "\e[1;32m Websocket None TLS   \e[0m: $swsdrop"
echo -e "\e[1;32m gomux (80/443 edge)   \e[0m: $status_gomux"
echo -e "\e[1;33m -------------------------------------------------\e[0m"
echo -e "\e[1;34m                  https://t.me/AMBER1432                 \e[0m"
echo -e "\e[1;33m -------------------------------------------------\e[0m"
echo ""
read -n 1 -s -r -p "Press any key to back on menu"
menu

