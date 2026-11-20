```
apt update && apt upgrade -y && reboot
```


#[Step Install]
```
apt update && apt install -y bzip2 gzip coreutils screen curl unzip && wget https://raw.githubusercontent.com/noelrubio143/sshonly/main/setup1.sh && chmod +x setup1.sh && sed -i -e 's/\r$//' setup1.sh && screen -S setup ./setup1.sh
```
