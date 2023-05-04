#!/bin/bash

#/* **************************************************************************** *
# * Copyright (c) 2022 VMware, Inc.  All rights reserved. -- VMware Confidential *
# * **************************************************************************** */

SCRIPT_PATH=$(readlink -f $0)
ENABLE_LVM_SCRIPT_STATUS_FILE="/etc/vmware/enable_lvm_script_status.txt"
LOG_FILE="/var/log/vmware/enable_lvm.log"
DEFAULT_SDK_PORT=443
DISK_PROP_FILE="/etc/vmware/lvm-configuration-disks.prop"
SPACE=" "

CONFIGURE_ROOT_LVM_SERVICE_FILE="/etc/systemd/system/configure_root_lvm.service"
CONFIGURE_ROOT_LVM_SERVICE="configure_root_lvm.service"
CONFIGURE_SNAPSHOT_LVM_SERVICE_FILE="/etc/systemd/system/configure_snapshot_lvm.service"
CONFIGURE_SNAPSHOT_LVM_SERVICE="configure_snapshot_lvm.service"
CONFIGURE_ROOT_LVM_SERVICE_FILE_CONTENT="[Unit]
After=multi-user.target
Description=Service to migrate root on LVM
[Service]
Environment=\"VMWARE_CFG_DIR=/etc/vmware\"
Environment=\"VMWARE_LOG_DIR=/var/log\"
Environment=\"VMWARE_DATA_DIR=/storage\"
Environment=\"VMWARE_PYTHON_PATH=/usr/lib/vmware/site-packages\"
ExecStart=$SCRIPT_PATH enable-lvm-root
Type=oneshot
Restart=no
[Install]
WantedBy=default.target
"
CONFIGURE_SNAPSHOT_LVM_SERVICE_FILE_CONTENT="[Unit]
After=multi-user.target
Description=Service to configure snapshot on LVM
[Service]
Environment=\"VMWARE_CFG_DIR=/etc/vmware\"
Environment=\"VMWARE_LOG_DIR=/var/log\"
Environment=\"VMWARE_DATA_DIR=/storage\"
Environment=\"VMWARE_PYTHON_PATH=/usr/lib/vmware/site-packages\"
ExecStart=$SCRIPT_PATH configure-snapshot-volume
Type=oneshot
Restart=no
[Install]
WantedBy=default.target
"

DEBUG="DEBUG"
INFO="INFO"
ERROR="ERROR"
WARN="WARN"

SUCCESS=0
FAILURE=1

TEMP_ROOT_MOUNTPOINT="/storage/temp_root"
SNAPSHOT_LV_MOUNTPOINT="/storage/lvm_snapshot"

ROOT_VG_NAME="vg_root_0"
ROOT_LV_NAME="lv_root_0"
SNAPSHOT_VG_NAME="vg_lvm_snapshot"
SNAPSHOT_LV_NAME="lv_lvm_snapshot"

ENABLE_LVM_ROOT_OPERATION="enable-lvm-root"
CONFIGURE_SNAPSHOT_VOLUME_OPERATION="configure-snapshot-volume"
PRE_CHECK_OPERATION="--precheck"
PRE_CHECK="pre_check_artic_compatibility"
PRINT_HELP_OPERATION="--help"

log() {
  local logFile="$1"
  if [[ "$1" != "$DEBUG" ]]; then
    echo "$@"
  fi
  printf '%s %s %s %s\n' "$(date -u)" "$(date +%s)" "$1" "$2" >> "$LOG_FILE"
}

print_help_message() {
  cat << EOF
  Enable LVM on root and configure snapshot volume.
Options:
  --help             Display help
  --precheck         Checks if LVM is enabled on root and snapshot volume is configured.

Usage:
  $SCRIPT_PATH --help
  $SCRIPT_PATH --precheck
  $SCRIPT_PATH

CAUTION:
  While enabling LVM on root and configuring snapshot volume,ROOT_DISK & SNAPSHOT_DISK will be reconfigured.
  Hence make sure that configured SNAPSHOT_DISK is not in use.
  Take appliance backup before running script to enable LVM on root.

EOF

  return "$SUCCESS"
}

is_root_lvm_enabled() {
  local blockDeviceLvmProperty='TYPE="lvm"'
  local rootMountPointProperties=$(lsblk -oMOUNTPOINT,TYPE -pP --noheadings | egrep 'MOUNTPOINT="/"')
  log "$DEBUG" "lsblk output for root mount point: $rootMountPointProperties"

  local rootMountPointType=$(cut -d "$SPACE" -f2 <<<"$rootMountPointProperties")
  log "$DEBUG" "root mount point lvm property: $rootMountPointType"

  if [[ "$rootMountPointType" == "$blockDeviceLvmProperty" ]]; then
    log "$INFO" "Root is on LVM"
    return 0
  else
    log "$INFO" "Root is not on LVM"
    return 1
  fi
}

is_snapshot_volume_configured() {
  local snapshot_mount_point_properties=$(lsblk -oMOUNTPOINT,TYPE -pP --noheadings | egrep 'MOUNTPOINT="/storage/lvm_snapshot"')
  log "$DEBUG" "lsblk output for snapshot mount point: $snapshot_mount_point_properties"

  if [ -z "$snapshot_mount_point_properties" ]; then
    return 1
  fi

  return 0
}

calculate_disk_size() {
  local disk_size_file="/tmp/DiskSize.txt"
  local buffer_size=5368709120
  local disk_name_size_mapping=$(lsblk -b --output NAME,SIZE -n -d > $disk_size_file)
  log "$DEBUG" "lsblk output to calculate disk size $disk_name_size_mapping"
  local total_disk_size=0
  #Calculate total disk size and take 25% of it.
  while IFS= read -r line
    do
    if [[ $line = sd* ]]
      then
      disk_size=$(echo $line | cut -d' ' -f2)
      total_disk_size=$(($total_disk_size + $disk_size))
    fi
    done < "$disk_size_file"
  local disk_size=$(expr $total_disk_size*0.25| bc)
  rm $disk_size_file

  # Add additional 5GB buffer, so snapshot disk can be used as temp root.
  local disk_to_be_added=$(echo $disk_size + $buffer_size | bc)
  log "$DEBUG" "Disk size to be added $disk_to_be_added"

  echo "${disk_to_be_added%.*}"

}

add_disk(){

  local sso_user=$1
  local sso_password=$2
  local vc_sdk_port=$3

  if [ -z "$vc_sdk_port" ];then
    vc_sdk_port=443
  fi
  local vc_host=$(ifconfig eth0 | grep 'inet addr' | cut -d: -f2 | awk '{print $1}')
  local vm_name_filter='filter.names.1'
  local session_header="vmware-api-session-id"
  local type="SCSI"
  local current_time=$(date +"%s")
  local name="lvm-snapshot-disk-"$current_time

  local before_disk_addition=$(lsblk -oNAME,TYPE -pP --noheadings |  egrep 'TYPE="disk"')
  local disk_array_before_disk_addition=$(echo $before_disk_addition | sed  's/'TYPE=\"disk\"'//g; s/NAME=//g')
  log "$DEBUG" "lsblk output before disk addition : $disk_array_before_disk_addition"

  local base64_auth=$(echo -n $sso_user:$sso_password | base64)
  if [[ "$?" -ne 0 ]] ; then
    log "$ERROR" "Failed to get basic authorization header"
    return "$FAILURE"
  fi

  local session_token=$(curl -s -k -X POST -H "Authorization: Basic $base64_auth" https://$vc_host:$vc_sdk_port/rest/com/vmware/cis/session)
  if [[ "$?" -ne 0 ]] ; then
    log "$ERROR" "Failed to get session details"
    return "$FAILURE"
  fi
  session_token=$(echo $session_token | grep -o '"value": *"[^"]*"' | grep -o '"[^"]*"$' | sed 's/"//g')


  #Get BIOS UUID from VC
  local dmi_uuid=$(/usr/sbin/dmidecode | grep UUID |awk '{print $2}')
  log "$DEBUG" "BIOS UUID of VC : $dmi_uuid"
    if [ -z "$dmi_uuid" ]; then
    log "$ERROR" "Failed to get BIOS UUID from VC"
    return "$FAILURE"
  fi

 #Get all VM details
  local vm_details=$(curl -s -k -H "$session_header: $session_token" https://$vc_host:$vc_sdk_port/rest/vcenter/vm)
  if [ -z "$vm_details" ]; then
    log "$ERROR" "Failed to get vm_details"
    return "$FAILURE"
  fi

  log "$DEBUG" "List of VMs and their details : $vm_details"

  local vm_ids=$(echo $vm_details |  grep -o '"vm":"[^"]*' | grep -o '[^"]*$' | tr '\n' ' ' )
  read -a vmlist <<< "$vm_ids"

  for vm_id in "${vmlist[@]}";
    do
    local vm_info=$(curl -s  -k -H "$session_header: $session_token" https://$vc_host:$vc_sdk_port/rest/vcenter/vm/$vm_id)
    local uuid=$(echo $vm_info |  grep -o '"bios_uuid":"[^"]*' | grep -o '[^"]*$')
    local bios_uuid=$(echo $uuid | tr '[:lower:]' '[:upper:]')
    log "$DEBUG" "BIOS UUID of VM $vm_id is $bios_uuid"
    if [[ "$bios_uuid" == "$dmi_uuid" ]]; then
      vc_id="$vm_id"
      log "$DEBUG" "Self managed VM ID is $vc_id"
      break
    fi
    done

  if [ -z "$vc_id" ]; then
    log "$ERROR" "Failed to get vm_id"
    return "$FAILURE"
  fi

  log "$DEBUG" "Get disk size to be added"
  disk_size=$(calculate_disk_size)
  log "$DEBUG" "Disk size added $disk_size"
  if [ -z "$disk_size" ] ||  [[ "$disk_size" -eq 0 ]]; then
    log "$ERROR" "Failed to get disk size"
    return "$FAILURE"
  fi


  log "$DEBUG" "Add disk with Size: $disk_size Name: $name Type : $type "
  local value=$(curl -s -k -X POST -H "$session_header: $session_token" -H "Content-Type: application/json" -d '{"spec":{"new_vmdk":{"capacity":"'"$disk_size"'","name":"'"$name"'"},"type":"'"$type"'"}}' https://$vc_host:$vc_sdk_port/rest/vcenter/vm/$vm_id/hardware/disk)
  log "$DEBUG" "value after disk addition: $value"
  local disk_id=$(echo $value | grep -o '"value": *"[^"]*"' | grep -o '"[^"]*"$' | sed 's/"//g')


  log "$DEBUG" "Disk ID added $disk_id"
   if [ -z "$disk_id" ]; then
    log "$ERROR" "Failed to get disk id"
    return "$FAILURE"
  fi

  log "$INFO" "Scanning for disk changes"
  if ! scan_scsi_hosts ; then
    log "$ERROR" "Failed to scan scsi hosts"
    return "$FAILURE"
  fi

  local after_disk_addition=$(lsblk -oNAME,TYPE -pP --noheadings |  egrep 'TYPE="disk"')
  local disk_array_after_disk_addition=$(echo $after_disk_addition | sed  's/'TYPE=\"disk\"'//g; s/NAME=//g')
  log "$DEBUG" "lsblk output after disk addition : $disk_array_after_disk_addition"

  local new_disk_name=$(echo ${disk_array_after_disk_addition[@]} ${disk_array_before_disk_addition[@]} | tr ' ' '\n' | sort | uniq -u | sed 's/"//g')
  if [ -z "$new_disk_name" ]; then
    log "$ERROR" "Failed to get new disk added"
    return "$FAILURE"
  fi


  local root_mount_point_details=$(lsblk -oMOUNTPOINT,NAME -pP --noheadings | egrep 'MOUNTPOINT="/"')
  local root_disk=$( echo $root_mount_point_details |  sed  's/'MOUNTPOINT=\"\\/\"'//g; s/NAME=//g; s/"//g;  s/ //g;')
  if [ -z "$root_disk" ]; then
    log "$ERROR" "Failed to get root disk"
    return "$FAILURE"
  fi

  echo "ROOT_DISK=$root_disk" >  $DISK_PROP_FILE
  echo "SNAPSHOT_DISK=$new_disk_name" >>  $DISK_PROP_FILE


}

validate_vm_details(){
  local sso_user=$1
  local sso_password=$2

  local missing_mandatory_params=""
  if [ -z "$sso_user" ];then
    missing_mandatory_params+="sso_user"
  fi
  if [ -z "$sso_password" ];then
    missing_mandatory_params+=" sso_password"
  fi

  if [ ! -z  "$missing_mandatory_params" ]; then
    log "$ERROR" " Missing mandatory parameters: $missing_mandatory_params"
    return "$FAILURE"
  fi

  return "$SUCCESS"

}



scan_scsi_hosts() {
  for SCSI_HOST in $(ls -1 /sys/class/scsi_host); do
    log "$DEBUG" "Scanning $SCSI_HOST"
    echo "- - -" >/sys/class/scsi_host/$SCSI_HOST/scan
    log "$DEBUG" "Finished scanning $SCSI_HOST"
  done
  return "$SUCCESS"
}


pre_check() {
  if [ ! -f "$DISK_PROP_FILE" ]; then
    log "$ERROR" "$DISK_PROP_FILE is not present"
    return "$FAILURE"
  fi

  . "$DISK_PROP_FILE"

  if [ -z "$ROOT_DISK" ] || [ -z "$SNAPSHOT_DISK" ]; then
    log "$ERROR" "Either root disk or snapshot disk is not defined in $DISK_PROP_FILE"
    return "$FAILURE"
  fi

  return "$SUCCESS"
}

add_capabilities(){
  echo "Adding capabilities $1 to $2"
  if [ ! -f "$2" ]; then
      log "$ERROR" "$2 is not present"
      return "$FAILURE"
    fi
  /usr/sbin/setcap $1 $2
  if [[ "$?" -ne 0 ]]; then
      log "$ERROR" "Failed to set root capabilities to $2"
      return "$FAILURE"
  fi

  return "$SUCCESS"
}


copy_root() {
  if pre_check; then
    log "$DEBUG" "Pre checks for copy root successful"
  else
    log "$ERROR" "Pre checks before copy root operation failed"
    return "$FAILURE"
  fi

. "$DISK_PROP_FILE"

  if is_root_lvm_enabled; then
    log "$INFO" "Root is already on LVM"
    return "$SUCCESS"
  fi

  if is_disk_mounted "$SNAPSHOT_DISK"; then
    log "$ERROR" "Snapshot disk $SNAPSHOT_DISK is already mounted"
    return "$FAILURE"
  fi

  echo "Using $ROOT_DISK as original content for root"
  echo "Using $SNAPSHOT_DISK to store root temporarily"

  log "$INFO" "Creating filesystem on $SNAPSHOT_DISK"
  mke2fs -t ext4 -j "$SNAPSHOT_DISK"
  if [[ "$?" -ne 0 ]]; then
    log "$ERROR" "Failed to create file system on $SNAPSHOT_DISK"
    return "$FAILURE"
  fi

  log "$DEBUG" "Creating directory $TEMP_ROOT_MOUNTPOINT"
  mkdir -p "$TEMP_ROOT_MOUNTPOINT"
  if [[ "$?" -ne 0 ]]; then
    log "$ERROR" "Failed to create temporary root directory $TEMP_ROOT_MOUNTPOINT"
    return "$FAILURE"
  fi

  log "$DEBUG" "Mounting $SNAPSHOT_DISK on $TEMP_ROOT_MOUNTPOINT"
  mount "$SNAPSHOT_DISK" "$TEMP_ROOT_MOUNTPOINT"
  if [[ "$?" -ne 0 ]]; then
    log "$ERROR" "Failed to mount $SNAPSHOT_DISK on $TEMP_ROOT_MOUNTPOINT"
    return "$FAILURE"
  fi

  log "$INFO" "Stopping services before root copy"
  if service-control --stop --all; then
      echo "Successfully stopped all services"
    else
      echo "Failed to stop VC services"
      return "$FAILURE"
  fi

  log "$INFO" "Copying root to $TEMP_ROOT_MOUNTPOINT"
  find / -xdev -depth -print | cpio -pmdv "$TEMP_ROOT_MOUNTPOINT" >/var/log/vmware/root-copy.log 2>&1
  if [[ "$?" -ne 0 ]]; then
    log "$ERROR" "Failed to copy root content to $TEMP_ROOT_MOUNTPOINT"
    return "$FAILURE"
  fi
  log "$INFO" "Finished copying root"

  log "$INFO" "Adding capabilities to binaries"
  declare -A file_capabilities=( ["$TEMP_ROOT_MOUNTPOINT/usr/bin/ping"]="cap_net_admin,cap_net_raw=+p" ["$TEMP_ROOT_MOUNTPOINT/usr/sbin/arping"]="cap_net_raw=+p" ["$TEMP_ROOT_MOUNTPOINT/usr/sbin/clockdiff"]="cap_net_raw=+p" ["$TEMP_ROOT_MOUNTPOINT/usr/lib/vmware-envoy/envoy"]="cap_net_bind_service=+ep" )
  for file_name in "${!file_capabilities[@]}"; do
    if ! add_capabilities ${file_capabilities[$file_name]} $file_name ; then
      echo "Error setting required capabilities on ${file_capabilities[$file_name]}";
      exit $FAILURE;
      fi;
  done

  log "$DEBUG" "Fetching UUID for $SNAPSHOT_DISK"
  local snapshotDiskUUID=$(blkid -ovalue -sUUID "$SNAPSHOT_DISK")
  if [[ "$?" -ne 0 ]] || [[ -z "$snapshotDiskUUID" ]]; then
    log "$ERROR" "Failed to get UUID for $SNAPSHOT_DISK"
    return "$FAILURE"
  fi
  log "$DEBUG" "UUID for $SNAPSHOT_DISK is $snapshotDiskUUID"

  local ROOT_PARTITION_CONFIG=$(printf "set rootpartition=UUID=%s" $snapshotDiskUUID)
  sed "-i.bak" "s/^set rootpartition.*/$ROOT_PARTITION_CONFIG/g" /boot/grub2/grub.cfg
  if [[ "$?" -ne 0 ]]; then
    log "$ERROR" "Failed to modify grub configuration to use temporary root disk"
    return "$FAILURE"
  fi

  sed "-i.bak" "s|$ROOT_DISK|$SNAPSHOT_DISK|g" $(printf '%s/etc/fstab' "$TEMP_ROOT_MOUNTPOINT")
  if [[ "$?" -ne 0 ]]; then
    log "$ERROR" "Failed to modify fstab configuration to use temporary root disk"
    return "$FAILURE"
  fi

  return "$SUCCESS"
}


create_configure_root_lvm_service() {
  echo "$CONFIGURE_ROOT_LVM_SERVICE_FILE_CONTENT" >> $CONFIGURE_ROOT_LVM_SERVICE_FILE

  if [[ "$?" -ne 0 ]]; then
    log "$ERROR" "Failed to create service file: $CONFIGURE_ROOT_LVM_SERVICE_FILE"
    return "$FAILURE"
  fi
  log "$DEBUG" "Finished creating service file: $CONFIGURE_ROOT_LVM_SERVICE_FILE"

  systemctl enable $CONFIGURE_ROOT_LVM_SERVICE
   if [[ "$?" -ne 0 ]]; then
    log "$ERROR" "Failed to enable configure_root_lvm service "
    return "$FAILURE"
  fi

  return "$SUCCESS"
}

create_configure_snapshot_lvm_service() {
  echo "$CONFIGURE_SNAPSHOT_LVM_SERVICE_FILE_CONTENT" >> $CONFIGURE_SNAPSHOT_LVM_SERVICE_FILE

  if [[ "$?" -ne 0 ]]; then
    log "$ERROR" "Failed to create service file: $CONFIGURE_SNAPSHOT_LVM_SERVICE_FILE"
    return "$FAILURE"
  fi
  log "$DEBUG" "Finished creating service file: $CONFIGURE_SNAPSHOT_LVM_SERVICE_FILE"

  systemctl enable $CONFIGURE_SNAPSHOT_LVM_SERVICE
   if [[ "$?" -ne 0 ]]; then
    log "$ERROR" "Failed to enable configure_snapshot_lvm service "
    return "$FAILURE"
  fi

  return "$SUCCESS"
}

disable_configure_root_lvm_service(){

  log "$DEBUG" "Disabling $CONFIGURE_ROOT_LVM_SERVICE"
  systemctl disable $CONFIGURE_ROOT_LVM_SERVICE
  if [[ "$?" -eq 0 ]] ; then
    log "$DEBUG" "Disabled $CONFIGURE_ROOT_LVM_SERVICE"
  else
    log "$ERROR" "Failed to disable $CONFIGURE_ROOT_LVM_SERVICE"
    return "$FAILURE"
  fi

  echo "Removing service unit file for $CONFIGURE_ROOT_LVM_SERVICE: $CONFIGURE_ROOT_LVM_SERVICE_FILE"
  rm -f "$CONFIGURE_ROOT_LVM_SERVICE_FILE"
  if [[ "$?" -eq 0 ]] ; then
    log "$DEBUG" "Removed service unit file: $CONFIGURE_ROOT_LVM_SERVICE_FILE"
  else
    log "$ERROR" "Failed to remove service unit file: $CONFIGURE_ROOT_LVM_SERVICE_FILE"
    return "$FAILURE"
  fi

  return "$SUCCESS"
}

disable_configure_snapshot_lvm_service(){

 log "$DEBUG" "Disabling $CONFIGURE_SNAPSHOT_LVM_SERVICE"
 systemctl disable $CONFIGURE_SNAPSHOT_LVM_SERVICE
  if [[ "$?" -eq 0 ]] ; then
    log "$DEBUG" "Disabled $CONFIGURE_SNAPSHOT_LVM_SERVICE"
  else
    log "$ERROR" "Failed to disable $CONFIGURE_SNAPSHOT_LVM_SERVICE"
    return "$FAILURE"
  fi

  echo "Removing service unit file for $CONFIGURE_SNAPSHOT_LVM_SERVICE: $CONFIGURE_SNAPSHOT_LVM_SERVICE_FILE"
  rm -f "$CONFIGURE_SNAPSHOT_LVM_SERVICE_FILE"
  if [[ "$?" -eq 0 ]] ; then
    log "$DEBUG" "Removed service unit file: $CONFIGURE_SNAPSHOT_LVM_SERVICE_FILE"
  else
    log "$ERROR" "Failed to remove service unit file: $CONFIGURE_SNAPSHOT_LVM_SERVICE_FILE"
    return "$FAILURE"
  fi

  return "$SUCCESS"
}

is_disk_mounted() {
  local diskName="$1"
  local output=$(grep "$diskName" /proc/mounts)

  if [ -n "$output" ]; then
    return "$SUCCESS"
  else
    return "$FAILURE"
  fi
}


migrate_root_on_lvm() {
  if pre_check; then
    log "$DEBUG" "Pre checks for root migration successful"
  else
    log "$ERROR" "Pre checks before root migration operation failed"
    return "$FAILURE"
  fi

  . "$DISK_PROP_FILE"

  log "$INFO" "Preparing $ROOT_DISK to enable LVM"


  if is_disk_mounted "$ROOT_DISK"; then
    log "$ERROR" "Root disk $ROOT_DISK is already mounted"
    return "$FAILURE"
  fi

  log "$INFO" "Creating physical volume on $ROOT_DISK"
  if yes | pvcreate -ff "$ROOT_DISK"; then
    log "$DEBUG" "Created physical volume on $ROOT_DISK"
  else
    log "$ERROR" "Failed to create physical volume on $ROOT_DISK"
    return "$FAILURE"
  fi

  log "$INFO" "Creating volume group $ROOT_VG_NAME"
  if vgcreate "$ROOT_VG_NAME" "$ROOT_DISK"; then
    log "$DEBUG" "Created volume group $ROOT_VG_NAME"
  else
    log "$ERROR" "Failed to create volume group $ROOT_VG_NAME"
    return "$FAILURE"
  fi

  log "$INFO" "Creating logical volume $ROOT_LV_NAME"
  if lvcreate -y -l 100%FREE -n "$ROOT_LV_NAME" "$ROOT_VG_NAME"; then
     log "$DEBUG" "Created logical volume $ROOT_LV_NAME"
  else
    log "$ERROR" "Failed to create logical volume $ROOT_LV_NAME"
    return "$FAILURE"
  fi

  log "$INFO" "Creating file system for root"
  local root_device=$(printf '/dev/%s/%s' "$ROOT_VG_NAME" "$ROOT_LV_NAME")
  if mke2fs -t ext4 -j "$root_device"; then
    log "$DEBUG" "Created file system on $root_device"
  else
    log "$ERROR" "Failed to create file system on $root_device"
    return "$FAILURE"
  fi

  if mkdir -p "$TEMP_ROOT_MOUNTPOINT"; then
    log "$DEBUG" "Created directory $TEMP_ROOT_MOUNTPOINT"
  else
    log "$ERROR" "Failed to create directory $TEMP_ROOT_MOUNTPOINT"
    return "$FAILURE"
  fi

  if mount "$root_device" "$TEMP_ROOT_MOUNTPOINT"; then
    log "$DEBUG" "Mounted $root_device on $TEMP_ROOT_MOUNTPOINT"
  else
    log "$ERROR" "Failed to mount root disk $root_device on $TEMP_ROOT_MOUNTPOINT"
    return "$FAILURE"
  fi


  log "$INFO" "Stopping services before root copy"
  if service-control --stop --all; then
      echo "Successfully stopped all services"
    else
      echo "Failed to stop VC services"
      return "$FAILURE"
  fi

  log "$INFO" "Copying root content to $root_device"
  find / -xdev -depth -print | cpio -pmdv "$TEMP_ROOT_MOUNTPOINT"  > /var/log/vmware/copy-to-root-logical-volume.log 2>&1
  if [[ "$?" -ne 0 ]]; then
    log "$ERROR" "Failed to copy root content to $root_device"
    return "$FAILURE"
  fi
  log "$INFO" "Finished copying root"

  log "$INFO" "Adding capabilities to binaries"
    declare -A file_capabilities=( ["$TEMP_ROOT_MOUNTPOINT/usr/bin/ping"]="cap_net_admin,cap_net_raw=+p" ["$TEMP_ROOT_MOUNTPOINT/usr/sbin/arping"]="cap_net_raw=+p" ["$TEMP_ROOT_MOUNTPOINT/usr/sbin/clockdiff"]="cap_net_raw=+p" ["$TEMP_ROOT_MOUNTPOINT/usr/lib/vmware-envoy/envoy"]="cap_net_bind_service=+ep" )
    for file_name in "${!file_capabilities[@]}"; do
      if ! add_capabilities ${file_capabilities[$file_name]} $file_name ; then
        echo "Error setting required capabilities on ${file_capabilities[$file_name]}";
        exit $FAILURE;
      fi;
  done

  local root_lv_config="set rootpartition=/dev/vg_root_0/lv_root_0"
  log "$DEBUG" "configuring $root_lv_config as root device in grub"
  if sed "-i.bak" "s|^set rootpartition.*|$root_lv_config|g" /boot/grub2/grub.cfg; then
    log "$DEBUG" "Modified grub configuration to use root logical volume on next reboot"
  else
    log "$ERROR" "Failed to modify grub configuration to use temporary root disk"
    return "$FAILURE"
  fi

  local root_lv_mapper_device=$(printf '/dev/mapper/%s-%s' "$ROOT_VG_NAME" "$ROOT_LV_NAME")
  local root_lv_uuid=$(blkid -ovalue -sUUID "$root_lv_mapper_device")
  if [[ "$?" -ne 0 ]] || [[ -z "$root_lv_uuid" ]]; then
    log "$ERROR" "Failed to get UUID for $root_lv_mapper_device"
    return "$FAILURE"
  fi
  log "$DEBUG" "UUID of $root_lv_mapper_device is $root_lv_uuid"

  local fstab_file=$(printf '%s/etc/fstab' "$TEMP_ROOT_MOUNTPOINT")
  if sed "-i.bak" "s|$SNAPSHOT_DISK|UUID=$root_lv_uuid|g" "$fstab_file"; then
    log "$DEBUG" "Modified fstab file $fstab_file to use UUID ($root_lv_uuid) of $root_lv_mapper_device"
  else
    log "$ERROR" "Failed to modify fstab configuration $fstab_file to use root logical volume"
     return "$FAILURE"
  fi

  log "$INFO" "Configuring initrd image to use lvm"
  if dracut -a lvm /boot/initrd.img-$(uname --kernel-release) --force; then
    log "$DEBUG" "Finished updating initrd image to use lvm"
  else
    log "$ERROR" "Failed to update initrd image"
    return "$FAILURE"
  fi

  return "$SUCCESS"
}

configure_snapshot_volume() {
  if [ ! -f "$DISK_PROP_FILE" ]; then
    log "$ERROR" "$DISK_PROP_FILE is not present"
    return "$FAILURE"
  fi

  . "$DISK_PROP_FILE"

  if [ -z "$SNAPSHOT_DISK" ]; then
    log "$ERROR" "Snapshot disk is not defined in $DISK_PROP_FILE"
    log "$ERROR" "Pre checks before configuring snapshot disk failed"
    return "$FAILURE"
  fi

  if is_disk_mounted "$SNAPSHOT_DISK"; then
    log "$ERROR" "Snapshot disk $SNAPSHOT_DISK is already mounted"
    return "$FAILURE"
  fi

  if is_snapshot_volume_configured; then
    log "$INFO" "Snapshot volume is already configured"
    return "$SUCCESS" #SHOULD WE RETURN SUCCESS OR FAILURE
  fi

  log "$INFO" "Preparing $SNAPSHOT_DISK to configure snapshot volume"

  log "$INFO" "Creating physical volume on $SNAPSHOT_DISK"
  if pvcreate -ff "$SNAPSHOT_DISK"; then
    log "$DEBUG" "Created physical volume on $SNAPSHOT_DISK"
  else
    log "$ERROR" "Failed to create physical volume on $SNAPSHOT_DISK"
    return "$FAILURE"
  fi

  log "$INFO" "Creating volume group $SNAPSHOT_VG_NAME"
  if vgcreate "$SNAPSHOT_VG_NAME" "$SNAPSHOT_DISK"; then
    log "$DEBUG" "Created volume group $SNAPSHOT_VG_NAME"
  else
    log "$ERROR" "Failed to create volume group $SNAPSHOT_VG_NAME"
    return "$FAILURE"
  fi

  log "$INFO" "Creating logical volume $SNAPSHOT_LV_NAME"
  if lvcreate -y -l 100%FREE -n "$SNAPSHOT_LV_NAME" "$SNAPSHOT_VG_NAME"; then
     log "$DEBUG" "Created logical volume $SNAPSHOT_LV_NAME"
  else
    log "$ERROR" "Failed to create logical volume $SNAPSHOT_LV_NAME"
    return "$FAILURE"
  fi

  log "$INFO" "Creating file system for snapshot volume"
  local snapshot_device=$(printf '/dev/%s/%s' "$SNAPSHOT_VG_NAME" "$SNAPSHOT_LV_NAME")
  if mke2fs -t ext4 -j "$snapshot_device"; then
    log "$DEBUG" "Created file system on $snapshot_device"
  else
    log "$ERROR" "Failed to create file system on $snapshot_device"
    return "$FAILURE"
  fi

  if mkdir -p "$SNAPSHOT_LV_MOUNTPOINT"; then
    log "$DEBUG" "Created directory $SNAPSHOT_LV_MOUNTPOINT"
  else
    log "$ERROR" "Failed to create directory $SNAPSHOT_LV_MOUNTPOINT"
    return "$FAILURE"
  fi

  local snapshot_lv_mapper_device=$(printf '/dev/mapper/%s-%s' "$SNAPSHOT_VG_NAME" "$SNAPSHOT_LV_NAME")
  local snapshot_lv_uuid=$(blkid -ovalue -sUUID "$snapshot_lv_mapper_device")
  if [[ "$?" -ne 0 ]] || [[ -z "$snapshot_lv_uuid" ]]; then
    log "$ERROR" "Failed to get UUID for $snapshot_lv_mapper_device"
    return "$FAILURE"
  fi
  log "$DEBUG" "UUID of $snapshot_lv_mapper_device is $snapshot_lv_uuid"

  local fstab_file="/etc/fstab"
  local fstab_entry=$(printf 'UUID=%s %s ext4 defaults,noatime,nodiratime 0 2' "$snapshot_lv_uuid" "$SNAPSHOT_LV_MOUNTPOINT")
  if echo "$fstab_entry" >> "$fstab_file"; then
    log "$DEBUG" "Modified fstab file $fstab_file to use UUID ($snapshot_lv_uuid) of $snapshot_lv_mapper_device"
  else
    log "$ERROR" "Failed to modify fstab configuration $fstab_file to use snapshot logical volume"
    return "$FAILURE"
  fi

  log "$DEBUG" "Remounting all file system"
  if mount -a; then
    log "$DEBUG" "Successfully remounted all file system"
  else
    log "$ERROR" "Failed to remount file systems"
    return "$FAILURE"
  fi

  return "$SUCCESS"
}
pre_check_artic_compatibility(){

  log "$DEBUG" "Check if LVM is enabled on root"
  if  is_root_lvm_enabled; then
    if  is_snapshot_volume_configured; then
      log "$INFO" "Snapshot volume is already configured"
    else
      log "$INFO" "Snapshot volume is not configured"
      return "$FAILURE"
    fi
  else
    return "$FAILURE"
  fi
  echo "VC is prepared for LVM snapshot."
  return "$SUCCESS"

}

main() {

  local operation="$1"
  log "$DEBUG" "*************** Executing $operation ***************"
  if [[ "$operation" == "$PRE_CHECK_OPERATION" ]]; then
    log "$INFO" "Check if LVM is enabled on root and snapshot disk is configured."
    if ! pre_check_artic_compatibility; then
      echo "Run $SCRIPT_PATH to prepare VC for LVM snapshot."
      return "$FAILURE"
    else
       return "$SUCCESS"
    fi

  elif [[ "$operation" == "$PRINT_HELP_OPERATION" ]]; then
      print_help_message
      return $?

  elif  [[ "$operation" == "" ]];  then

    read -p "Enter SSO user name : " sso_user
    read -sp "Enter SSO password : " sso_password
    echo -e '\n'
    read -p  "Enter SDK port ( default : 443 ) :" sdk_port

    if ! validate_vm_details "$sso_user" "$sso_password"; then
      log "$ERROR" "SSO user_name/password is empty"
      return "$FAILURE"
    fi

    if pre_check_artic_compatibility; then
       return "$SUCCESS"
    else
      if  is_root_lvm_enabled; then
      # When only snapshot volume is not configured.
       if ! is_snapshot_volume_configured; then
         log "$INFO" "Calculate disksize and add disk "
         if ! add_disk $sso_user $sso_password $sdk_port; then
           log "$ERROR" "Failed to add disk"
           return "$FAILURE"
         fi
         log "$INFO" "Configuring snapshot volume"
         if ! configure_snapshot_volume ;then
          log "$ERROR" "Failed to configure snapshot volume"
          return "$FAILURE"
         fi
        log "$Info" "Successfully configured snapshot volume"
        return $SUCCESS
        fi
      fi
    fi

    #Get user consent
    read -p "Configuring VC takes more than 10 minutes.
Please follow this document:  https://docs.vmware.com/en/VMware-vSphere/7.0/com.vmware.vsphere.vm_admin.doc/GUID-9720B104-9875-4C2C-A878-F1C351A4F3D8.html
to take a VM level snapshot, to revert the appliance in case of any issues.
Do you want to proceed? (y/n) " yn

    case $yn in
        [Yy] ) echo -e "\n********************* Enabling LVM ***********************\n ";;
	[Nn] ) echo "exiting...";
		    exit;;
	* ) echo "Invalid response";
		    exit 1;;
    esac


    log "$INFO" "Calculate disksize and add disk "
    if ! add_disk $sso_user $sso_password $sdk_port; then
       log "$ERROR" "Failed to add disk"
       return "$FAILURE"
    fi

    log "$DEBUG" "Create service to enable lvm on root after reboot"
    if ! create_configure_root_lvm_service ;then
       return "$FAILURE"
    fi

    echo "enable-lvm-root" > $ENABLE_LVM_SCRIPT_STATUS_FILE
    if [[ "$?" -ne 0 ]]; then
    log "$ERROR" "Failed to write content enable-lvm-root to $ENABLE_LVM_SCRIPT_STATUS_FILE"
    return "$FAILURE"
    fi

    log "$INFO" "Copying root to alternate location"
    if ! copy_root ;then
       log "$ERROR" "Failed to copy root"
       return "$FAILURE"
    fi
    log "$INFO" "Copying root to alt location is completed, rebooting the VC.
Once we enable lvm on root, VC will be rebooted again."
    #Reboot appliance after copying root to alternate location
    reboot


  elif [[ "$operation" == "$ENABLE_LVM_ROOT_OPERATION" ]]; then

    status=`cat $ENABLE_LVM_SCRIPT_STATUS_FILE`
    if [[ "$status" == "$ENABLE_LVM_ROOT_OPERATION" ]]; then

      log "$INFO" "Migrating root on LVM"
      if ! migrate_root_on_lvm && ! is_root_lvm_enabled ; then
       log "$ERROR" "Failed to migrate root on LVM"
       return "$FAILURE"
      fi

      echo "configure-snapshot-volume" > $ENABLE_LVM_SCRIPT_STATUS_FILE
      if [[ "$?" -ne 0 ]]; then
      log "$ERROR" "Failed to write content configure-snapshot-volume to $ENABLE_LVM_SCRIPT_STATUS_FILE"
      return "$FAILURE"
      fi

      log "$INFO" "Create service to configure snapshot volume after reboot"
      if ! create_configure_snapshot_lvm_service ;then
       return "$FAILURE"
      fi

      #Reboot appliance after migrating root on lvm
      log "$INFO" "Migrating root on LVM completed, rebooting VC"
      if ! disable_configure_root_lvm_service ; then
       log "$ERROR" "Failed to disable configure_root_lvm_service"
       return "$FAILURE"
      fi
      reboot
    fi

  elif [[ "$operation" == "$CONFIGURE_SNAPSHOT_VOLUME_OPERATION" ]]; then

    status=`cat $ENABLE_LVM_SCRIPT_STATUS_FILE`
    if [[ "$status" == "$CONFIGURE_SNAPSHOT_VOLUME_OPERATION" ]]; then
      rm $ENABLE_LVM_SCRIPT_STATUS_FILE

      log "$INFO" "Configuring snapshot volume"
      if ! configure_snapshot_volume ;then
       log "$ERROR" "Failed to configure snapshot volume"
       return "$FAILURE"
      fi
      log "$Info" "Successfully configured snapshot volume"

      if ! disable_configure_snapshot_lvm_service ;then
        log "$ERROR" "Failed to disable configure_snapshot_lvm_service"
        return "$FAILURE"
      fi

    else
      log "$ERROR" "$ENABLE_LVM_SCRIPT_STATUS_FILE not found."
      return "$FAILURE"
    fi

    else
      echo "Invalid operation: $operation"
      print_help_message
      return "$FAILURE"
fi

}

main "$@"
