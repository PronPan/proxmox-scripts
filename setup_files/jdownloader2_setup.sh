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
  local DEFAULT='Unknown failure occurred.'
  local REASON="\e[97m${1:-$DEFAULT}\e[39m"
  local FLAG="\e[91m[ERROR:LXC] \e[93m$EXIT@$LINE"
  msg "$FLAG $REASON"
  exit $EXIT
}
function msg() {
  local TEXT="$1"
  echo -e "$TEXT"
}

echo -e "${CHECKMARK} \e[1;92m Setting up container OS... \e[0m"
sed -i "/$LANG/ s/\(^# \)//" /etc/locale.gen
locale-gen >/dev/null
apt-get purge openssh-{client,server} >/dev/null
apt-get autoremove >/dev/null

echo -e "${CHECKMARK} \e[1;92m Updating container OS... \e[0m"
apt-get update &>/dev/null
apt-get -qq upgrade &>/dev/null

echo -e "${CHECKMARK} \e[1;92m Installing prerequisites... \e[0m"
apt-get -qq install \
    wget \
    sudo \
    openjdk-17-jre-headless &>/dev/null

echo -e "${CHECKMARK} \e[1;92m Creating user for jdownloader2... \e[0m"
useradd -s /sbin/nologin jdown2

echo -e "${CHECKMARK} \e[1;92m Creating folder for jdownloader2... \e[0m"
mkdir /opt/jdown2
chown jdown2 /opt/jdown2
cd /opt/jdown2

echo -e "${CHECKMARK} \e[1;92m Downloading jdownloader2... \e[0m"
sudo -u jdown2 wget http://installer.jdownloader.org/JDownloader.jar
wget -O /etc/systemd/system/jdownloader2.service https://raw.githubusercontent.com/pronpan/proxmox-scripts/main/systemd_files/jdownloader2.service &>/dev/null

echo -e "${CHECKMARK} \e[1;92m Enabling systemd service for jdownloader2... \e[0m"
systemctl daemon-reload &>/dev/null
systemctl enable jdownloader2 &>/dev/null

#echo -e "${CHECKMARK} \e[1;92m Setting up NFS share for the jdownloader2 Downloads folder... \e[0m"
#wget -O /etc/exports https://raw.githubusercontent.com/pronpan/proxmox-scripts/main/config_files/exports &>/dev/null
#systemctl restart nfs-kernel-server &>/dev/null

#echo -e "${CHECKMARK} \e[1;92m Disabling NFS server... \e[0m"
#systemctl disable --now nfs-kernel-server &>/dev/null

echo -e "${CHECKMARK} \e[1;92m Customizing container... \e[0m"
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
rm -rf /jdownloader2_setup.sh /var/{cache,log}/* /var/lib/apt/lists/*
