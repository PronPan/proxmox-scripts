#!/usr/bin/env bash

export LANG=en_US.UTF-8

# Enable detailed tracing for debugging
set -o errexit 
set -o errtrace
set -o nounset 
set -o pipefail
set -x  # Enable command tracing (prints commands before executing)

shopt -s expand_aliases
alias die='EXIT=$? LINE=$LINENO error_exit'
trap die ERR
trap 'die "Script interrupted."' INT

# Logging setup
DEBUG_LOG="/var/log/jdownloader2_setup_debug.log"
exec > >(tee -a "$DEBUG_LOG") 2>&1  # Redirect all output and errors to the debug log

CHECKMARK='\033[0;32m\xE2\x9C\x94\033[0m'

# Function to output error details
function error_exit() {
    trap - ERR
    local DEFAULT='Unknown failure occurred.'
    local REASON="\e[97m${1:-$DEFAULT}\e[39m"
    local FLAG="\e[91m[ERROR:LXC] \e[93m$EXIT@$LINE"
    msg "$FLAG $REASON"
    echo "Exiting with error code $EXIT at line $LINE" >> "$DEBUG_LOG"
    exit $EXIT
}

# Log general message
function msg() {
    local TEXT="$1"
    echo -e "$TEXT"
    echo "$(date): $TEXT" >> "$DEBUG_LOG"
}

# Log informational messages
function info() {
    local REASON="$1"
    local FLAG="\e[36m[INFO]\e[39m"
    msg "$FLAG $REASON"
}

# Start of the main process
info "Starting jDownloader2 setup script."

# Locale configuration
info "Uncommenting locale in /etc/locale.gen for $LANG."
sed -i "/$LANG/ s/\(^# \)//" /etc/locale.gen || die "Failed to uncomment locale."
info "Generating locale."
locale-gen >/dev/null || die "Failed to generate locale."

# Purge OpenSSH packages
info "Purging OpenSSH client and server."
apt-get purge openssh-{client,server} >/dev/null || die "Failed to purge OpenSSH client/server."

# Autoremove unnecessary packages
info "Running apt-get autoremove to clean up unnecessary packages."
apt-get autoremove >/dev/null || die "Failed to autoremove unnecessary packages."

# Updating the container OS
info "Updating package lists."
apt-get update || die "Failed to update package lists."

info "Upgrading packages to the latest versions."
apt-get upgrade || die "Failed to upgrade packages."

# Installing prerequisites
info "Installing prerequisites: wget, sudo, and openjdk-17-jre-headless."
apt-get install wget sudo openjdk-17-jre-headless || die "Failed to install prerequisites."

# Create user for jdownloader2
info "Creating user 'jdown2' with no login shell."
useradd -s /sbin/nologin jdown2 || die "Failed to create user 'jdown2'."

# Create folder for jdownloader2
info "Creating directory /opt/jdown2 for jdownloader2."
mkdir /opt/jdown2 || die "Failed to create directory /opt/jdown2."
info "Changing ownership of /opt/jdown2 to jdown2."
chown jdown2 /opt/jdown2 || die "Failed to change ownership of /opt/jdown2."

# Downloading jdownloader2
info "Downloading JDownloader.jar for jdownloader2."
sudo -u jdown2 wget http://installer.jdownloader.org/JDownloader.jar || die "Failed to download JDownloader.jar."

# Download systemd service file for jdownloader2
info "Downloading systemd service file for jdownloader2."
wget -O /etc/systemd/system/jdownloader2.service https://raw.githubusercontent.com/pronpan/proxmox-scripts/main/systemd_files/jdownloader2.service >/dev/null || die "Failed to download systemd service file."

# Enable systemd service for jdownloader2
info "Reloading systemd daemon."
systemctl daemon-reload || die "Failed to reload systemd daemon."
info "Enabling jdownloader2 systemd service."
systemctl enable jdownloader2 || die "Failed to enable jdownloader2 service."

# Customizing container
info "Customizing container: Removing MOTD and other files."
rm /etc/motd || die "Failed to remove /etc/motd."
rm /etc/update-motd.d/10-uname || die "Failed to remove /etc/update-motd.d/10-uname."
touch ~/.hushlogin || die "Failed to create ~/.hushlogin."

# Configure autologin
info "Configuring container autologin for root."
GETTY_OVERRIDE="/etc/systemd/system/container-getty@1.service.d/override.conf"
mkdir -p $(dirname $GETTY_OVERRIDE) || die "Failed to create directory for getty override."
cat << EOF > $GETTY_OVERRIDE
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 \$TERM
EOF
systemctl daemon-reload || die "Failed to reload systemd daemon after getty override."
systemctl restart $(basename $(dirname $GETTY_OVERRIDE) | sed 's/\.d//') || die "Failed to restart getty service."

# Cleanup
info "Performing cleanup tasks."
rm -rf /jdownloader2_setup.sh /var/{cache,log}/* /var/lib/apt/lists/* || die "Failed to clean up temporary files."

info "jDownloader2 setup completed successfully."
