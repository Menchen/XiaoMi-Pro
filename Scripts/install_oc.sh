#!/bin/bash

PLEDIT='/usr/libexec/PlistBuddy'

# Should be at PATH, but in case PATH is messed up
PLUTIL='/usr/bin/plutil'
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
  echo -e "${RED}${*}${OFF} ${BLUE}${LINENO}${OFF}"
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
	#$1 Github repo name, 'daliansky/XiaoMi-Pro-Hackintosh'
	#$2 Download filter
  local _jsonData=$(curl --silent 'https://api.github.com/repos/'"${1}"'/releases/latest')
  [[ $? == 0 ]] || networkWarn
  # Parse JSON to OC only
  echo -n -E "$_jsonData" | $jq '.assets | map(select(.name|test("'"${2}"'"))) | .[].browser_download_url' | tr -d '"'
}

function readInteger() {
  local _input
  while :; do
    read -p "${BLUE}${1} ${GREEN}[$2-$3]:${OFF} "  _input
    if [[ "$_input" =~ ^[0-9]+$ ]] && [[ "$_input" -ge "$2" ]] && [[ "$_input" -le "$3" ]] ;then
      echo "$_input"
      #else
      #echo -e "${RED} Enter a integer between [$2 - $3]${OFF}"
    fi
  done
}

function downloadEFI() {
  setupEnviroment
  local _downloadList=($(getGitHubLatestRelease "daliansky/XiaoMi-Pro-Hackintosh" '-OC-'))

  # Select download
  echo "Select your version:"
  local _downloadListLen=${#_downloadList[@]}
  for _i in $(seq 0 $((${_downloadListLen}-1)));do
    echo "$_i:"
    echo "     ${_downloadList[$_i]}"
  done
  local _version=$(readInteger "Select a version" 0 $((${_downloadListLen}-1)))
  #echo $_version

  # Download and extract
  curl -L -# -o "XiaoMi_EFI.zip" ${_downloadList[$_version]}
  unzip -qu "XiaoMi_EFI.zip"
  local _dirname=$(echo ${_downloadList[$_version]}|grep -o '[^/]*\.zip'|sed -e 's/\.zip//g')
  if ! [[ -d "./${_dirname}" ]];then
    errMsg "Downloaded folder not found! Open a issue for a script update."
  fi
  efi_work_dir="${PWD}/${_dirname}/EFI"
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
  if [[ "$(echo "$3"|cut -c1)" == ":" ]];then
    # Plist Path
    getPlistHelper "$1" "${2}${3}" "${@:4}"
  else
    # Array regex search
    local _index=$($PLEDIT "$1" -c "Print ${2}" | searchPlistArray "${3}") || return 1
    getPlistHelper "$1" "${2}:${_index}" "${@:4}"
  fi
}

function deletePlistIfNotExist() {
  # Check if a path exist in old efi file
  # And delete in new file if not exist
  # $! Old EFI file
  # $2 New EFI file
  # $3+ Plist path or array regex
  while :; do
    local _path=$(getPlistHelper "$1" "${@:3}") || return 0
    local _oldVarXml=$("$PLEDIT" "$1" -x -c "Print $_path") || return 0
    if [[ -z "$_oldVarXml" ]];then
      # Path missing in old config
      "$PLEDIT" "$2" -c "Delete ${_path}" || return 1
    fi
    echo -e "${GREEN}Detected and deleted ${BLUE}${_path}${GREEN}!${OFF}"
    return 0
  done
  errMsg "Error deleting ${*:3}!"
  return 1

}

function getBinaryDataInBase64() {
  # Parse PlistBuddy xml format and filter data in base64
  # The input is PlistBuddy with -x flag
  # Return the data in base64 to stdout
  perl -0777 -ne 'if(/<data>\n(.*)\n<\/data>/s){print "$1";exit 0}else{exit 1}'
}

function getPlist() {
	# $1 PList file
	# $2+ Plist path or array regex
    local _path=$(getPlistHelper "$1" "${@:2}") || break
	"$PLEDIT" "$1" -c "Print $_path"
}

function restorePlist() {
  # Set Old efi file value to new efi file
  # $! Old PList file
  # $2 New PList file
  # $3+ Plist path or array regex


  while :; do
    local _path=$(getPlistHelper "$1" "${@:3}") || break
    local _newPath=$(getPlistHelper "$2" "${@:3}") || break
    local _oldVar=$("$PLEDIT" "$1" -c "Print $_path") || break
    local _oldVarXml=$("$PLEDIT" "$1" -x -c "Print $_path" | getBinaryDataInBase64)
    if [[ -z "$_oldVarXml" ]];then
      errMsg "Properties not found: $_path"
      errMsg "Skiping!!!..."
      return 0
    fi
    if [[ -n "$_oldVarXml" ]];then
      # Binary data
      # Switch to plutil as PlistBuddy expect binary input that bash cannot pass as parameters
      # And plutil take base64 for data.

      # Change path format, plutil use '.' as separetor and eliminate the starting ':' as well
      local _fixedNewPath=$(echo -n "$_path" | perl -pe 's/^://;' -e 's/:/\./g') 

      #plutil should be at PATH
      "$PLUTIL" -replace "$_fixedNewPath" -data "$_oldVarXml" "$2" || break
    else
      "$PLEDIT" "$2" -c "Set $_newPath $_oldVar" || break

    # Save the change, maybe it's better to commit the change after
    # But for better consistency with plutil we save at every change.
    #"$PLEDIT" "$2" -c "Save" || break

    fi
    echo -e "${GREEN}Restored ${BLUE}${_path}${GREEN} to ${BLUE}${_oldVar}${GREEN} !${OFF}"
    return 0
  done
  errMsg "Failed to restore ${*:3}..."
  return 1
}

function restoreBootArgs() {
	echo -e "${GREEN}Restoring boot args...${OFF}"
	[[ -z "$efi_work_dir" ]] && errMsg "No work directory found. Try to download firts?"&&exit 1
	[[ -z "$EFI_DIR" ]] && mount_efi
	while :;do
		local _old_config="${EFI_DIR}/EFI/OC/config.plist"
		local _new_config="${efi_work_dir}/OC/config.plist"
		local _path=$(getPlistHelper "_old_config" ':NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args') || break
		local _newPath=$(getPlistHelper "_new_config" ':NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args') || break
		local _oldVar=$("$PLEDIT" "_old_config" -c "Print $_path") || break
		local _newVar=$("$PLEDIT" "_new_config" -c "Print $_newPath") || break


		echo -e "${BLUE}1:${OFF} Old boot args"
		echo -e "<${_oldVar}>\n"
		echo -e "${BLUE}2:${OFF}"
		echo -e "<${_newVar}>\n"
		echo -e "${BLUE}3:${OFF} Custom boot args ${RED}ADVANCED USER ONLY${OFF}\n"
		local _selection=$(readInteger "Select a version" 1 3)
		# TODO Better selection menu with ability to go back
		if [[ ${_selection} -eq 1 ]];then
			restorePlist "${_old_config}" "${_new_config}" ":NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args"
		else
			if [[${_selection} -eq 3]];then
				echo -e "${GREEN}Input a custom boot args:"
				local _readVar
				read _readVar
				"$PLEDIT" "${_new_config}" -c "Set $_newPath ${_readVar}" || break
			fi
		fi
		return 0
	done
	errMsg "Error reading boot args... Aborting"
	exit 1
}



function restoreBluetooth() {
  echo -e "${GREEN}Restoring Bluetooth...${OFF}"
  [[ -z "$efi_work_dir" ]] && errMsg "No work directory found. Try to download firts?"&&exit 1
  [[ -z "$EFI_DIR" ]] && mount_efi

  # SSDT
  restorePlist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ":ACPI:Add" "Path = SSDT-USB.aml" ":Enabled"
  restorePlist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ":ACPI:Add" "Path = SSDT-USB-USBBT.aml" ":Enabled"
  restorePlist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ":ACPI:Add" "Path = SSDT-USB-WLAN-LTEBT.aml" ":Enabled"
  restorePlist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ":ACPI:Add" "Path = SSDT-USB-FingerBT.aml" ":Enabled"

  # Kext
  restorePlist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ":ACPI:Add" "BundlePath = IntelBluetoothFirmware.kext" ":Enabled"
  restorePlist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ":ACPI:Add" "BundlePath = IntelBluetoothInjector.kext" ":Enabled"

  # TODO AirportBrcmFixup and BrcmBluetoothInjector...

}


function restoreDVMT() {
  echo -e "${GREEN}Restoring DVMT...${OFF}"
  [[ -z "$efi_work_dir" ]] && errMsg "No work directory found. Try to download firts?"&&exit 1
  [[ -z "$EFI_DIR" ]] && mount_efi

  restorePlist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ':DeviceProperties:Add:PciRoot(0x0)/Pci(0x2,0x0):AAPL,ig-platform-id'
  restorePlist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ':DeviceProperties:Add:PciRoot(0x0)/Pci(0x2,0x0):framebuffer-flags'
  restorePlist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ':DeviceProperties:Add:PciRoot(0x0)/Pci(0x2,0x0):framebuffer-flags'

  deletePlistIfNotExist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ':DeviceProperties:Add:PciRoot(0x0)/Pci(0x2,0x0):framebuffer-fbmem'
  deletePlistIfNotExist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ':DeviceProperties:Add:PciRoot(0x0)/Pci(0x2,0x0):framebuffer-stolenmem'
  deletePlistIfNotExist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ':DeviceProperties:Add:PciRoot(0x0)/Pci(0x2,0x0):framebuffer-con0-enable'
  deletePlistIfNotExist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ':DeviceProperties:Add:PciRoot(0x0)/Pci(0x2,0x0):framebuffer-con0-flags'
  deletePlistIfNotExist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ':DeviceProperties:Add:PciRoot(0x0)/Pci(0x2,0x0):framebuffer-con1-flags'
  deletePlistIfNotExist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ':DeviceProperties:Add:PciRoot(0x0)/Pci(0x2,0x0):framebuffer-con2-flags'
  echo -e "${GREEN}Done!${OFF}"
}

function restore0xE2() {
  echo -e "${GREEN}Restoring DVMT...${OFF}"
  [[ -z "$efi_work_dir" ]] && errMsg "No work directory found. Try to download firts?"&&exit 1
  [[ -z "$EFI_DIR" ]] && mount_efi

  restorePlist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ':Kernel:Quirks:AppleXcpmCfgLock'

  echo -e "${GREEN}Done!${OFF}"
}

function restorePlatformInfo() {
  echo -e "${GREEN}Restoring DVMT...${OFF}"
  [[ -z "$efi_work_dir" ]] && errMsg "No work directory found. Try to download firts?"&&exit 1
  [[ -z "$EFI_DIR" ]] && mount_efi


  restorePlist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ':PlatformInfo:Generic:ROM'
  restorePlist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ':PlatformInfo:Generic:SystemSerialNumber'
  restorePlist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ':PlatformInfo:Generic:SystemProductName'
  restorePlist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ':PlatformInfo:Generic:SystemUUID'
  restorePlist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ':PlatformInfo:Generic:MLB'

  echo -e "${GREEN}Done!${OFF}"
}

function restoreMiscPreference() {
  echo -e "${GREEN}Restoring DVMT...${OFF}"
  [[ -z "$efi_work_dir" ]] && errMsg "No work directory found. Try to download firts?"&&exit 1
  [[ -z "$EFI_DIR" ]] && mount_efi

  restorePlist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ':Misc:Boot:PickerMode'
  restorePlist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ':Misc:Boot:Timeout'
  restorePlist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ':Misc:Boot:ShowPicker'
  restorePlist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ':Misc:Boot:TakeoffDelay'

  # For intel wifi
  restorePlist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ':Misc:Security:DmgLoading'
  restorePlist "${EFI_DIR}/EFI/OC/config.plist" "${efi_work_dir}/OC/config.plist" ':Misc:Security:SecureBootModel'
  echo -e "${GREEN}Done!${OFF}"
}

function restoreBrcmPatchRAM() {
	[[ -z "$efi_work_dir" ]] && errMsg "No work directory found. Try to download firts?"&&exit 1
	[[ -z "$EFI_DIR" ]] && mount_efi
	local _old_config="${EFI_DIR}/EFI/OC/config.plist"
	local _new_config="${efi_work_dir}/OC/config.plist"


	local _flag
	local _brcmInjector=$(getPlist "${_old_config}" ':Kernel:Add' 'BundlePath = BrcmBluetoothInjector.kext' ':Enabled')||_flag=1
	local _brcmFirmwareData=$(getPlist "${_old_config}" ':Kernel:Add' 'BundlePath = BrcmFirmwareData.kext' ':Enabled')||_flag=1
	local _brcmRAM3=$(getPlist "${_old_config}" ':Kernel:Add' 'BundlePath = BrcmPatchRAM3.kext' ':Enabled')||_flag=1


	if [[ -n "$_flag" ]];then
		echo -e "${GREEN}Downloading BrcmPatchRAM...${OFF}"

		local _patchRAMLink=$(getGitHubLatestRelease "acidanthera/BrcmPatchRAM" 'RELEASE')

		curl -L -# -o "BrcmPatchRAM.zip" "${_patchRAMLink}"
		ditto -x -k "./BrcmPatchRAM.zip" .

		local _dirname=$(echo ${_patchRAMLink}|grep -o '[^/]*\.zip'|sed -e 's/\.zip//g')

		if ! [[ -d "./${_dirname}" ]];then
			errMsg "Downloaded folder not found! Open a issue for a script update."
			return 1
		fi
		local _patchRAMDir="${PWD}/${_dirname}/"

		[[ "$_brcmInjector" == "true" ]] && cp -r "${_patchRAMDir}/BrcmBluetoothInjector.kext" "${efi_work_dir}/OC/Kexts/" && ${PLEDIT} -x -c "Merge ./patch/BrcmBluetoothInjector.plist :Kernel:Add" "${_new_config}" && echo -e "${GREEN}Restored BrcmBluetoothInjector${OFF}"
		[[ "$_brcmFirmwareData" == "true" ]] && cp -r "${_patchRAMDir}/BrcmFirmwareData.kext" "${efi_work_dir}/OC/Kexts/" && ${PLEDIT} -x -c "Merge ./patch/BrcmFirmwareData.plist :Kernel:Add" "${_new_config}" && echo -e "${GREEN}Restored BrcmFirmwareData${OFF}"
		[[ "$_brcmRAM3" == "true" ]] && cp -r "${_patchRAMDir}/BrcmPatchRAM3.kext" "${efi_work_dir}/OC/Kexts/" && ${PLEDIT} -x -c "Merge ./patch/BrcmPatchRAM3.plist :Kernel:Add" "${_new_config}" && echo -e "${GREEN}Restored BrcmPatchRAM3${OFF}"
	fi

}

function restoreAirportFixup(){
  local _brcmAirport=$(getPlist "${_old_config}" ':Kernel:Add' 'BundlePath = AirportBrcmFixup.kext' ':Enabled')
  if [[ "$_brcmAirport" == "true" ]];then
	  echo -e "${GREEN}Downloading BrcmPatchRAM...${OFF}"
	  local _airportBrcmLink=$(getGitHubLatestRelease "acidanthera/AirportBrcmFixup" 'RELEASE')

	  curl -L -# -o "AirportBrcmFixup.zip" "${_airportBrcmLink}"
	  ditto -x -k "./AirportBrcmFixup.zip" .
	local _dirname=$(echo ${_airportBrcmLink}|grep -o '[^/]*\.zip'|sed -e 's/\.zip//g')


	  if ! [[ -d "./${_dirname}" ]];then
		  errMsg "Downloaded folder not found! Open a issue for a script update."
		  return 1
	  fi
	  local _patchRAMDir="${PWD}/${_dirname}/"

	  cp -r "${_airportBrcmLink}/AirportBrcmFixup.kext" "${efi_work_dir}/OC/Kexts/" && ${PLEDIT} -x -c "Merge ./patch/AirportBrcmFixup.plist :Kernel:Add" "${_new_config}" && echo -e "${GREEN}Restored AirportBrcmFixup${OFF}"

  fi

}

function restoreOptionalKext() {
	echo -e "${GREEN}Restoring DVMT...${OFF}"
	[[ -z "$efi_work_dir" ]] && errMsg "No work directory found. Try to download firts?"&&exit 1
	[[ -z "$EFI_DIR" ]] && mount_efi
	local _old_config="${EFI_DIR}/EFI/OC/config.plist"
	local _new_config="${efi_work_dir}/OC/config.plist"

  # Intel Wifi Force load kext
  restorePlist "${_old_config}" "${_new_config}" ':Kernel:Force' 'BundlePath = System/Library/Extensions/corecapture.kext' ':Enabled'
  restorePlist "${_old_config}" "${_new_config}" ':Kernel:Force' 'BundlePath = System/Library/Extensions/IO80211Family.kext' ':Enabled'

  restorePlist "${_old_config}" "${_new_config}" ':Kernel:Add' 'BundlePath = AirportItlwm_Big_Sur.kext' ':Enabled'
  restorePlist "${_old_config}" "${_new_config}" ':Kernel:Add' 'BundlePath = AirportItlwm_Catalina.kext' ':Enabled'
  restorePlist "${_old_config}" "${_new_config}" ':Kernel:Add' 'BundlePath = AirportItlwm_High_Sierra.kext' ':Enabled'
  restorePlist "${_old_config}" "${_new_config}" ':Kernel:Add' 'BundlePath = AirportItlwm_Mojave.kext' ':Enabled'

  restorePlist "${_old_config}" "${_new_config}" ':Kernel:Add' 'BundlePath = NullEthernet.kext' ':Enabled'
  restorePlist "${_old_config}" "${_new_config}" ':Kernel:Add' 'BundlePath = NullEthernet.kext' ':Enabled'


  restorePlist "${_old_config}" "${_new_config}" ':Kernel:Add' 'BundlePath = NVMeFix.kext' ':Enabled'
  restorePlist "${_old_config}" "${_new_config}" ':Kernel:Add' 'BundlePath = HibernationFixup.kext' ':Enabled'

  echo -e "${GREEN}Checking optional Kext's${OFF}"

  local _flag
  local _brcmInjector=$(getPlist "${_old_config}" ':Kernel:Add' 'BundlePath = BrcmBluetoothInjector.kext' ':Enabled')||_flag=1
  local _brcmFirmwareData=$(getPlist "${_old_config}" ':Kernel:Add' 'BundlePath = BrcmFirmwareData.kext' ':Enabled')||_flag=1
  local _brcmRAM3=$(getPlist "${_old_config}" ':Kernel:Add' 'BundlePath = BrcmPatchRAM3.kext' ':Enabled')||_flag=1
  local _brcmAirport=$(getPlist "${_old_config}" ':Kernel:Add' 'BundlePath = AirportBrcmFixup.kext' ':Enabled')

  if [[ -n "$_flag" ]];then
	  echo -e "${GREEN}Downloading BrcmPatchRAM...${OFF}"

	  local _patchRAMLink=$(getGitHubLatestRelease "acidanthera/BrcmPatchRAM" 'RELEASE')

	  curl -L -# -o "BrcmPatchRAM.zip" "${_patchRAMLink}"
	  ditto -x -k "./BrcmPatchRAM.zip" .
	  

	  if ! [[ -d "./${_dirname}" ]];then
		errMsg "Downloaded folder not found! Open a issue for a script update."
	  fi
	  local _patchRAMDir="${PWD}/$(echo ${_patchRAMLink}|grep -o '[^/]*\.zip'|sed -e 's/\.zip//g')/"

	  [[ "$_brcmInjector" == "true" ]] && cp -r "${_patchRAMDir}/BrcmBluetoothInjector.kext" "${efi_work_dir}/OC/Kexts/" && ${PLEDIT} -x -c "Merge ./patch/BrcmBluetoothInjector.plist :Kernel:Add" "${_new_config}" && echo -e "${GREEN}Restored BrcmBluetoothInjector${OFF}"
	  [[ "$_brcmFirmwareData" == "true" ]] && cp -r "${_patchRAMDir}/BrcmFirmwareData.kext" "${efi_work_dir}/OC/Kexts/" && ${PLEDIT} -x -c "Merge ./patch/BrcmFirmwareData.plist :Kernel:Add" "${_new_config}" && echo -e "${GREEN}Restored BrcmFirmwareData${OFF}"
	  [[ "$_brcmRAM3" == "true" ]] && cp -r "${_patchRAMDir}/BrcmPatchRAM3.kext" "${efi_work_dir}/OC/Kexts/" && ${PLEDIT} -x -c "Merge ./patch/BrcmPatchRAM3.plist :Kernel:Add" "${_new_config}" && echo -e "${GREEN}Restored BrcmPatchRAM3${OFF}"
  fi
  restoreBrcmPatchRAM
  restoreAirportFixup


  echo -e "${GREEN}Done!${OFF}"
}


#installEFI
#downloadEFI
editBluetooth

#getPlistHelper 'config.plist' ":ACPI" ":Add" 'Path = SSDT-USB-USBBT.aml' ':Path'

#$PLEDIT "config.plist" -c "Print :ACPI:Add" | searchPlistArray 'Path = SSDT-USB-USBBT.aml'
#echo $?
#echo $tempFolder
#rm -r "$tempFolder"

