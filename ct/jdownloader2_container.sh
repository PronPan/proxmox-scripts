#!/usr/bin/env bash

# Force system messages to English and enable detailed tracing for debugging
export LANG=en_US.UTF-8
set -o errexit  
set -o errtrace
set -o nounset  
set -o pipefail
set -x  # Enable command tracing (prints commands before executing)

shopt -s expand_aliases
alias die='EXIT=$? LINE=$LINENO error_exit'
trap die ERR
trap cleanup EXIT

# Logging
DEBUG_LOG="/var/log/jdownloader2_container_debug.log"
exec > >(tee -a "$DEBUG_LOG") 2>&1  # Redirect all output and errors to the debug log

CHECKMARK='\033[0;32m\xE2\x9C\x94\033[0m'

# Function to output error details
function error_exit() {
    trap - ERR
    local DEFAULT='Unknown failure occurred.'
    local REASON="\e[97m${1:-$DEFAULT}\e[39m"
    local FLAG="\e[91m[ERROR] \e[93m$EXIT@$LINE"
    msg "$FLAG $REASON"
    [ ! -z ${CTID-} ] && cleanup_ctid
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

# Log warnings
function warn() {
    local REASON="\e[97m$1\e[39m"
    local FLAG="\e[93m[WARNING]\e[39m"
    msg "$FLAG $REASON"
}

# Clean up the container ID if an error occurs
function cleanup_ctid() {
    if [ ! -z ${MOUNT+x} ]; then
        info "Unmounting the LXC container."
        pct unmount $CTID
    fi
    if $(pct status $CTID &>/dev/null); then
        if [ "$(pct status $CTID | awk '{print $2}')" == "running" ]; then
            info "Stopping the LXC container."
            pct stop $CTID
        fi
        info "Destroying the LXC container."
        pct destroy $CTID
    elif [ "$(pvesm list $STORAGE --vmid $CTID)" != "" ]; then
        info "Freeing up storage for the container."
        pvesm free $ROOTFS
    fi
}

# General clean up function
function cleanup() {
    info "Cleaning up temporary files."
    popd >/dev/null
    rm -rf $TEMP_DIR
}

# Load kernel module function with debugging
function load_module() {
    info "Loading kernel module: $1"
    if ! $(lsmod | grep -Fq $1); then
        modprobe $1 &>/dev/null || \
            die "Failed to load '$1' kernel module."
    fi
    MODULES_PATH=/etc/modules
    if ! $(grep -Fxq "$1" $MODULES_PATH); then
        echo "$1" >> $MODULES_PATH || \
            die "Failed to add '$1' kernel module to load at boot."
    fi
}

# Start of the main process
info "Starting jDownloader2 LXC Container creation script."

# Create a temporary directory
TEMP_DIR=$(mktemp -d)
info "Temporary directory created: $TEMP_DIR"
pushd $TEMP_DIR >/dev/null

# Download the setup script
info "Downloading the jdownloader2_setup.sh script."
wget -qL https://raw.githubusercontent.com/pronpan/proxmox-scripts/main/setup_files/jdownloader2_setup.sh || die "Failed to download jdownloader2_setup.sh"

# Load overlay module
load_module overlay

# List available storage options and capture detailed information
info "Fetching storage options for LXC containers."
while read -r line; do
    TAG=$(echo $line | awk '{print $1}')
    TYPE=$(echo $line | awk '{printf "%-10s", $2}')
    FREE=$(echo $line | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf( "%9sB", $6)}')
    ITEM="  Type: $TYPE Free: $FREE "
    OFFSET=2
    if [[ $((${#ITEM} + $OFFSET)) -gt ${MSG_MAX_LENGTH:-} ]]; then
        MSG_MAX_LENGTH=$((${#ITEM} + $OFFSET))
    fi
    STORAGE_MENU+=( "$TAG" "$ITEM" "OFF" )
done < <(pvesm status -content rootdir | awk 'NR>1')

# Check storage options
if [ $((${#STORAGE_MENU[@]}/3)) -eq 0 ]; then
    warn "'Container' needs to be selected for at least one storage location."
    die "Unable to detect valid storage location."
elif [ $((${#STORAGE_MENU[@]}/3)) -eq 1 ]; then
    STORAGE=${STORAGE_MENU[0]}
else
    info "Prompting user to select storage pool."
    STORAGE=$(whiptail --title "Storage Pools" --radiolist \
    "Which storage pool would you like to use for the container?\n\n" \
    16 $(($MSG_MAX_LENGTH + 23)) 6 \
    "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3) || exit
fi
info "Using '$STORAGE' for storage location."

# Create a container ID and print info
CTID=$(pvesh get /cluster/nextid)
info "Generated container ID: $CTID"

# Update template list and download the Debian 12 template
info "Updating the LXC template list."
pveam update >/dev/null || die "Failed to update LXC template list."

info "Downloading the Debian 12 LXC template."
OSTYPE=debian
OSVERSION=${OSTYPE}-12
mapfile -t TEMPLATES < <(pveam available -section system | sed -n "s/.*\($OSVERSION.*\)/\1/p" | sort -t - -k 2 -V)
TEMPLATE="${TEMPLATES[-1]}"
pveam download local $TEMPLATE >/dev/null || die "Failed to download LXC template: $TEMPLATE"

# Check storage type and allocate storage
STORAGE_TYPE=$(pvesm status -storage $STORAGE | awk 'NR>1 {print $2}')
case $STORAGE_TYPE in
  dir|nfs)
    DISK_EXT=".raw"
    DISK_REF="$CTID/"
    ;;
  zfspool)
    DISK_PREFIX="subvol"
    DISK_FORMAT="subvol"
    ;;
esac
DISK=${DISK_PREFIX:-vm}-${CTID}-disk-0${DISK_EXT-}
ROOTFS=${STORAGE}:${DISK_REF-}${DISK}

info "Allocating storage for the container: $DISK"
DISK_SIZE=32G
pvesm alloc $STORAGE $CTID $DISK $DISK_SIZE --format ${DISK_FORMAT:-raw} >/dev/null || die "Failed to allocate storage for the container."

# Check if ZFS has potential issues with fallocate
if [ "$STORAGE_TYPE" == "zfspool" ]; then
    warn "Some containers may not work properly due to ZFS not supporting 'fallocate'."
else
    info "Formatting disk as ext4."
    mkfs.ext4 $(pvesm path $ROOTFS) &>/dev/null || die "Failed to format the disk."
fi

# Create the LXC container
ARCH=$(dpkg --print-architecture)
HOSTNAME=jdownloader2
TEMPLATE_STRING="local:vztmpl/${TEMPLATE}"
info "Creating the LXC container with ID $CTID."
pct create $CTID $TEMPLATE_STRING -arch $ARCH -features nesting=1 \
  -hostname $HOSTNAME -net0 name=eth0,bridge=vmbr1,ip=10.0.0.16/24,gw=10.0.0.1 -onboot 1 -cores 2 -memory 1024\
  -ostype $OSTYPE -rootfs $ROOTFS,size=$DISK_SIZE -storage $STORAGE >/dev/null

# Mount and link localtime
info "Mounting the LXC container to link localtime."
MOUNT=$(pct mount $CTID | cut -d"'" -f 2)
ln -fs $(readlink /etc/localtime) ${MOUNT}/etc/localtime
pct unmount $CTID && unset MOUNT

# Start the container
info "Starting the LXC container."
pct start $CTID || die "Failed to start the LXC container."

# Push and execute the setup script inside the container
info "Pushing and executing jdownloader2_setup.sh inside the container."
pct push $CTID jdownloader2_setup.sh /jdownloader2_setup.sh -perms 755
pct exec $CTID /jdownloader2_setup.sh || die "Failed to execute jdownloader2_setup.sh inside the container."

# Fetch and log the container IP address
IP=$(pct exec $CTID ip a s dev eth0 | sed -n '/inet / s/\// /p' | awk '{print $2}')
info "Successfully created a jdownloader2 LXC container with ID $CTID at IP address ${IP}"
