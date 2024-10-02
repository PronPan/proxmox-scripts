#!/usr/bin/env bash

set -o errexit 
set -o errtrace
set -o nounset 
set -o pipefail 
shopt -s expand_aliases
alias die='EXIT=$? LINE=$LINENO error_exit'
trap die ERR
CHECKMARK='\033[0;32m\xE2\x9C\x94\033[0m'
trap 'die "Script interrupted."' INT

function error_exit() {
  trap - ERR
  local DEFAULT='Unknown failure occured.'
  local REASON="\e[97m${1:-$DEFAULT}\e[39m"
  local FLAG="\e[91m[ERROR:LXC] \e[93m$EXIT@$LINE"
  msg "$FLAG $REASON"
  exit $EXIT
}
function msg() {
  local TEXT="$1"
  echo -e "$TEXT"
}

echo -e "${CHECKMARK} \e[1;92m Setting up Container OS... \e[0m"
sed -i "/$LANG/ s/\(^# \)//" /etc/locale.gen
locale-gen >/dev/null
apt-get -y purge openssh-{client,server} >/dev/null
apt-get autoremove >/dev/null

echo -e "${CHECKMARK} \e[1;92m Updating Container OS... \e[0m"
apt-get update &>/dev/null
apt-get -qqy upgrade &>/dev/null

echo -e "${CHECKMARK} \e[1;92m Installing Prerequisites... \e[0m"
apt-get -qqy install \
    curl \
    sudo \
    apt-transport-https \
    at \
    libfl2 \
    gnupg \
    va-driver-all \
    ocl-icd-libopencl1 \
    beignet-opencl-icd &>/dev/null

#echo -e "${CHECKMARK} \e[1;92m Configure Hardware Acceleration... \e[0m"

# /bin/chgrp video /dev/dri
# /bin/chmod 755 /dev/dri
# /bin/chmod 660 /dev/dri/*
    
echo -e "${CHECKMARK} \e[1;92m Downloading Jellyfin Server... \e[0m"
wget https://repo.jellyfin.org/releases/server/debian/versions/stable/server/10.8.0/jellyfin-server_10.8.0-1_amd64.deb &>/dev/null
wget https://repo.jellyfin.org/releases/server/debian/versions/stable/web/10.8.0/jellyfin-web_10.8.0-1_all.deb &>/dev/null

echo -e "${CHECKMARK} \e[1;92m Adding Jellyfin Repo... \e[0m"
cat <<EOF > /etc/apt/sources.list.d/jellyfin.list
deb [arch=amd64] https://repo.jellyfin.org/debian bullseye main
EOF

curl -fsSL https://repo.jellyfin.org/debian/jellyfin_team.gpg.key | gpg --dearmor -o /etc/apt/trusted.gpg.d/debian-jellyfin.gpg &>/dev/null

echo -e "${CHECKMARK} \e[1;92m Installing Jellyfin Server... \e[0m"
dpkg -i jellyfin-server_10.8.0-1_amd64.deb jellyfin-web_10.8.0-1_all.deb &>/dev/null

mkdir -p /var/cache/jellyfin
mkdir -p /var/log/jellyfin
chown -R jellyfin:jellyfin /var/cache/jellyfin
chown -R jellyfin:jellyfin /var/log/jellyfin

echo -e "${CHECKMARK} \e[1;92m Customizing Container... \e[0m"
rm /etc/motd 
rm /etc/update-motd.d/10-uname 
touch ~/.hushlogin 
GETTY_OVERRIDE="/etc/systemd/system/container-getty@1.service.d/override.conf"
mkdir -p $(dirname $GETTY_OVERRIDE)
cat << EOF > $GETTY_OVERRIDE
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 \$TERM
EOF
systemctl daemon-reload
systemctl restart $(basename $(dirname $GETTY_OVERRIDE) | sed 's/\.d//')
echo -e "${CHECKMARK} \e[1;92m Cleanup... \e[0m"
rm -rf /jellyfin_setup.sh /var/{cache,log}/* /var/lib/apt/lists/*
