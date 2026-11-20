```
apt update && apt upgrade -y && reboot
```


#[Step Install]
```
apt update && apt install -y bzip2 gzip coreutils screen curl unzip && wget https://gitlab.com/babayega143/sshonly/-/raw/main/setup1.sh && chmod +x setup1.sh && sed -i -e 's/\r$//' setup1.sh && screen -S setup ./setup1.sh
```
