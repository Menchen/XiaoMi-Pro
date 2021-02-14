#!/bin/bash

PLEDIT=/usr/libexec/PlistBuddy
RELEASE_Dir=""

# Display style setting
BOLD=$'\033[1m'
RED=$'\033[1;31m'
GREEN=$'\033[1;32m'
BLUE=$'\033[1;34m'
OFF=$'\033[m'


# Tools
jq='jq'

# Exit in case of network failure
function networkWarn() {
  echo -e "[ ${RED}ERROR${OFF} ]: Failed to download resources, please check your connection!"
  exit 1
}

function errMsg(){
  echo -e "${RED}${*}${OFF}"
}
# Mount EFI by using mount_efi.sh, credits Rehabman
function mountEFI() {
  local repoURL="https://raw.githubusercontent.com/RehabMan/hack-tools/master/mount_efi.sh"
  curl --silent -O "${repoURL}" || networkWarn
  echo
  echo "Mounting EFI partition..."
  EFI_DIR="$(sh "mount_efi.sh")"

  # check whether EFI partition exists
  if [[ -z "${EFI_DIR}" ]]; then
    echo -e "[ ${RED}ERROR${OFF} ]: Failed to detect EFI partition"
    unmountEFI
    exit 1

  # check whether EFI/OC exists
  elif [[ ! -e "${EFI_DIR}/EFI/OC" ]]; then
    echo -e "[ ${RED}ERROR${OFF} ]: Failed to detect OC folder"
    unmountEFI
    exit 1
  fi

  echo -e "[ ${GREEN}OK${OFF} ]Mounted EFI at ${EFI_DIR} (credits RehabMan)"
}

# Unmount EFI for safety
function unmountEFI() {
  echo
  echo "Unmounting EFI partition..."
  diskutil unmount "$EFI_DIR" &>/dev/null
  echo -e "[ ${GREEN}OK${OFF} ]Unmount complete"

  # "Unset EFI_DIR"
  EFI_DIR=''
}

function setupEnviroment() {
  # create temp folder
  #tempFolder=$(mktemp -d)
  tempFolder=debug
  cd $tempFolder
  if ! command -v jq &>/dev/null;then
    echo Downloading jq for json parsing
    curl -o 'jq' -L 'https://github.com/stedolan/jq/releases/download/jq-1.6/jq-osx-amd64' || networkWarn
    jq='.jq'
    chmod +x $jq
    echo Done!
  fi
  echo "The work directory is: "
  echo $tempFolder
}

function getGitHubLatestRelease() {
  local _jsonData=$(curl --silent 'https://api.github.com/repos/daliansky/XiaoMi-Pro-Hackintosh/releases/latest')
  [[ $? == 0 ]] || networkWarn
  # Parse JSON to OC only
  echo -n -E "$_jsonData" | $jq '.assets | map(select(.name|test("-OC-"))) | .[].browser_download_url'
}

function readInteger() {
  local _input
  while :; do
    read -p "${BLUE}${1} ${GREEN}[$2-$3]:${OFF} "  _input
    if [[ "$_input" =~ ^[0-9]+$ ]] && [[ "$_input" -ge "$2" ]] && [[ "$_input" -le "$3" ]] ;then
      return "$_input"
    #else
      #echo -e "${RED} Enter a integer between [$2 - $3]${OFF}"
    fi
  done
}

function downloadEFI() {
  setupEnviroment
  local _downloadList=($(getGitHubLatestRelease | tr -d '"'))
  
  # Select download
  echo "Select your version:"
  local _downloadListLen=${#_downloadList[@]}
  for _i in $(seq 0 $((${_downloadListLen}-1)));do
    echo "$_i:"
    echo "     ${_downloadList[$_i]}"
  done
  readInteger "Select a version" 0 $((${_downloadListLen}-1))
  local _version=$?
  #echo $_version

  # Download and extract
  curl -L -# -o "XiaoMi_EFI.zip" ${_downloadList[$_version]}
  unzip -qu "XiaoMi_EFI.zip"
  local _dirname=$(echo ${_downloadList[$_version]}|grep -o '[^/]*\.zip'|sed -e 's/\.zip//g')
  if ![[ -d "./${_dirname}" ]];then
    echo "${RED} Downloaded folder not found! Open a issue for a script update. ${OFF}"
  fi
  cd "${_dirname}"
  efi_work_dir="${PWD}/${_dirname}/EFI"
  cd ..
}

function backupEFI() {
  [[ -z "$EFI_DIR" ]] && mount_efi

  # Backuping to same partition as EFI so it's faster to recover using Linux/LiveISO
  local _backupDir="${EFI_DIR}/$(date +%Y%m%d_%H_%M_%S)/"
  echo -e "Backuping current efi to ${BLUE}${_backupDir}${OFF}"
  mkdir -p "$_backupDir" || errMsg "Error creating backup folder, exiting..." && exit 1
  cp -r "${EFI_DIR}/EFI/OC/*" "$_backupDir" || errMsg "Error backuping EFI... aborting."&&exit 1
  echo -e "${GREEN}Done!${OFF}"

}

function installEFI() {
  echo "Installing EFI..."
  [[ -z "$efi_work_dir" ]] && errMsg "No work directory found. Try to download firts?"&&exit 1
  #[[ -z "$EFI_DIR" ]] && mount_efi
  backupEFI
  # -i flag for safer debug
  rm -r -i "${EFI_DIR}/EFI/OC/"
  rm -r -i "${EFI_DIR}/EFI/BOOT/"
  cp -r "$efi_work_dir/*" "${EFI_DIR}/EFI/"
  echo -e "${GREEN}Done!${OFF}"
}

function searchPlistArray(){
  # Return first index of array that match the pattern passed as $1
  # Ouptut to stdout, you should capture it using $()
  # !!! The input is stdin and "should" be array output from PlistBuddy
  # !!! The script find the first match and calculate the index of array of most upper level that contain it
  # !!! You should add indent to regex patter if the input contain nested structure!
  # !!! The regex match to Print of PlistBuddy, not the original file. The formats are differents.
  perl -n -e 'BEGIN{$n=0}' -e 'if(/^( *)Array \{$/){if($n==0){$a=$1}else{exit 1}}' -e 'if(/^$a    \}$/){$n++}' -e 'if(/^$a\}$/){exit 0}' -e '{if(/'"${1}"'/){print $n;exit 0}}' -
  return $?
}

function getPlistHelper(){
  # Helper function for search plist array
  # $1 File path
  # $2 Plist path, use ":" for root
  # $3+ Can be Plist path or array regex search
  # Ouptut to stdout, you should capture it using $()
  # Plist path need to be starting with ':'
  # Anything else is used as regex for array search
  # see searchPlistArray() for regex pattern info
  if [[ $# -le 1 ]];then
    # Invalid, no pattern...
    return 1
  fi
  if [[ $# -eq 2 ]];then
    # Base case
    #$PLEDIT "$1" -c "Print $2"
    echo -n "$2"
    return 0
  fi
  if [[ "$(echo $3|cut -c1)" == ":" ]];then
    # Plist Path
    getPlistHelper "$1" "${2}${3}" "${@:4}"
  else
    # Array regex search
    local _index=$($PLEDIT "$1" -c "Print ${2}" | searchPlistArray "${3}") || return 1
    getPlistHelper "$1" "${2}:${_index}" "${@:4}"
  fi
}

function restorePlist() {
  # $! Old EFI file
  # $2 New EFI file
  # $3+ Plist path or array regex


  while :; do
    local _path=$(getPlistHelper "$1" "${@:3}") || break
    local _oldVar=$("$PLEDIT" "$1" -c "Print $_path") || break
    if [[ -z "$_oldVar" ]];then
      errMsg "Properties not found: $_path"
      errMsg "Skiping!!!..."
      break;
    fi
    "$PLEDIT" "$2" -c "Set $_path $_oldVar" || break
    echo -e "${GREEN}Restored ${BLUE}${_path}${GREEN} to ${BLUE}${_oldVar}${GREEN} !${OFF}"
    return 0
  done
  errMsg "Failed to restore ${*:3}..."
  return 1
}

function editBluetooth() {
  echo "Detecting Bluetooth..."
  [[ -z "$efi_work_dir" ]] && errMsg "No work directory found. Try to download firts?"&&exit 1
  [[ -z "$EFI_DIR" ]] && mount_efi

  restorePlist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ":ACPI:Add" "Path = SSDT-USB.aml" ":Enabled"
  restorePlist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ":ACPI:Add" "Path = SSDT-USB-USBBT.aml" ":Enabled"
  restorePlist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ":ACPI:Add" "Path = SSDT-USB-WLAN-LTEBT.aml" ":Enabled"
  restorePlist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ":ACPI:Add" "Path = SSDT-USB-FingerBT.aml" ":Enabled"
}


function 
#installEFI
#downloadEFI
editBluetooth

#getPlistHelper 'config.plist' ":ACPI" ":Add" 'Path = SSDT-USB-USBBT.aml' ':Path'

#$PLEDIT "config.plist" -c "Print :ACPI:Add" | searchPlistArray 'Path = SSDT-USB-USBBT.aml'
#echo $?
#echo $tempFolder
#rm -r "$tempFolder"

