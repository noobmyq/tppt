#!/bin/bash

# --- PART 1: SYSTEM SETUP (Run these commands immediately) ---
echo "Starting System Setup..."


# Install needed lib
sudo apt update
sudo apt install ca-certificates -y
sudo update-ca-certificates
sudo apt install python3 python3-pip python3-venv ninja-build python3-sphinx pkg-config libglib2.0-dev libpixman-1-dev build-essential libncurses-dev bison flex libssl-dev libelf-dev cmake texlive-latex-extra texlive-fonts-recommended dvipng cm-super bear debootstrap -y
# install gcc-7 and g++-7 for dynamorio, temporarily add 20.04 sources
echo "deb [trusted=yes] http://archive.ubuntu.com/ubuntu/ focal main universe" | sudo tee /etc/apt/sources.list.d/focal.list
sudo apt update
sudo apt install gcc-7 g++-7 -y
sudo rm /etc/apt/sources.list.d/focal.list
# install python packages
pip3 install numpy matplotlib pandas scienceplots


# 1. Install RAID tools
sudo apt update
sudo apt install mdadm -y

# 2. Create the RAID 0 Array (combining 8 drives)
# We check if /dev/md0 already exists to prevent errors on re-running
if [ ! -e /dev/md0 ]; then
    sudo mdadm --create --verbose /dev/md0 --level=0 --raid-devices=8 \
        /dev/nvme0n1 /dev/nvme1n1 /dev/nvme2n1 /dev/nvme3n1 \
        /dev/nvme4n1 /dev/nvme5n1 /dev/nvme6n1 /dev/nvme7n1
else
    echo "RAID device /dev/md0 already exists. Skipping creation."
fi

# 3. Format and Mount
# Check if it is already mounted
if ! grep -qs '/mnt/storage' /proc/mounts; then
    echo "Formatting and mounting storage..."
    sudo mkfs.ext4 /dev/md0
    sudo mkdir -p /mnt/storage
    sudo mount /dev/md0 /mnt/storage
    # Fix permissions so you (the current user) own it
    sudo chown $USER /mnt/storage
else
    echo "/mnt/storage is already mounted."
fi

# --- PART 2: TMUX CONFIGURATION (Write these to the file) ---
echo "Configuring .tmux.conf..."

# We use 'cat <<EOF' to write multiple lines to the file easily
cat <<EOF > ~/.tmux.conf
# Set foreground (text) to white
set -g status-fg white

# Enable True Color support
set -g default-terminal "tmux-256color"
set-option -g terminal-overrides ",xterm*:Tc"
EOF

echo "Setup complete! Storage is at /mnt/storage and tmux is configured."


# part 3: clone
ssh -T git@github.com

cd /mnt/storage
git clone git@github.com:noobmyq/tppt.git
cd tppt 
git submodule init
git config submodule.huge-page-sim.update none
git submodule update --recursive --remote

git clone --recursive git@github.com:noobmyq/OSv-tp.git osv


