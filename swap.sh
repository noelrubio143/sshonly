#!/bin/bash

# Kung walang sudo (minimal Debian/Ubuntu), tumakbo nang direkta bilang root
command -v sudo >/dev/null 2>&1 || sudo() { "$@"; }

# Define swap file size and location
SWAPFILE=/swapfile
SWAPSIZE=6G
SWAPMB=$(( ${SWAPSIZE%G} * 1024 ))   # para sa dd fallback (sumusunod sa SWAPSIZE)

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
