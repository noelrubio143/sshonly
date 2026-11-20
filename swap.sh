#!/bin/bash

# Kung walang sudo (minimal Debian/Ubuntu), tumakbo nang direkta bilang root
command -v sudo >/dev/null 2>&1 || sudo() { "$@"; }

# Define swap file size and location
SWAPFILE=/swapfile
SWAPSIZE=6G
SWAPMB=$(( ${SWAPSIZE%G} * 1024 ))   # para sa dd fallback (sumusunod sa SWAPSIZE)
ZRAM_PERCENT=50   # laki ng zram bilang % ng RAM (compressed swap sa loob ng RAM)

# I-off at tanggalin muna ang existing swapfile kung meron
if sudo swapon --show | grep -q "$SWAPFILE"; then
    sudo swapoff "$SWAPFILE"
fi
sudo rm -f "$SWAPFILE"

# Create a swap file
sudo fallocate -l $SWAPSIZE $SWAPFILE || sudo dd if=/dev/zero of=$SWAPFILE bs=1M count=$SWAPMB status=none

# Set the correct permissions
sudo chmod 600 $SWAPFILE

# Set up a Linux swap area
sudo mkswap $SWAPFILE

# Enable the swap file
sudo swapon $SWAPFILE

# Make the swap file permanent (iwas duplicate entry sa fstab)
if ! grep -q "^$SWAPFILE " /etc/fstab; then
    echo "$SWAPFILE none swap sw 0 0" | sudo tee -a /etc/fstab
fi

# Verify the swap is active
sudo swapon --show

# Display the current swap usage
free -h

# ===== zram (compressed swap sa RAM) =====
# Mas mabilis kaysa disk swap. Mas mataas ang priority (100) kaysa /swapfile (-2),
# kaya zram muna ang gagamitin at ang /swapfile ang magiging backup.
# Hindi ito kailangan para gumana ang swap: kung mag-fail, tuloy pa rin ang disk swap.
echo ""
echo "Setting up zram..."
(
    case "$(systemd-detect-virt 2>/dev/null)" in
        lxc|openvz|docker|podman) echo "[!] Container ito, laktawan ang zram."; exit 0 ;;
    esac
    export DEBIAN_FRONTEND=noninteractive
    if ! dpkg -s zram-tools >/dev/null 2>&1; then
        sudo apt-get update -qq >/dev/null 2>&1
        sudo apt-get install -y -qq zram-tools >/dev/null 2>&1 || { echo "[!] Hindi ma-install ang zram-tools."; exit 1; }
    fi
    sudo modprobe zram 2>/dev/null
    printf 'ALGO=zstd\nPERCENT=%s\nPRIORITY=100\n' "$ZRAM_PERCENT" | sudo tee /etc/default/zramswap >/dev/null
    sudo systemctl enable zramswap >/dev/null 2>&1
    sudo systemctl restart zramswap || { echo "[!] Hindi nag-start ang zramswap."; exit 1; }
) || echo "[!] Hindi nagawa ang zram. Tuloy pa rin ang disk swap."

sudo swapon --show
free -h

# ===== vm.swappiness =====
# Mataas para zram ang unang gamitin bago ang disk swap. Permanent via sysctl.d
# Alisin ang ibang vm.swappiness na nag-o-override (hal. Alibaba image: /etc/sysctl.conf,
# binabasa ito huli kaya nananalo laban sa sysctl.d). Kino-comment lang, hindi binubura.
sudo sed -i '/^[[:space:]]*vm\.swappiness/s/^/#swap.sh# /' /etc/sysctl.conf 2>/dev/null
echo 'vm.swappiness=100' | sudo tee /etc/sysctl.d/99-swap.conf >/dev/null
sudo sysctl -p /etc/sysctl.d/99-swap.conf

# Tiyakin na 100 ang aktibong value
echo "vm.swappiness ngayon: $(cat /proc/sys/vm/swappiness)"
