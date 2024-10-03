#!/bin/bash
export LC_ALL=C
readonly SELF=$0
readonly COREDIR=/opt/siliconmotion
readonly OTHERPDDIR=/opt/displaylink
readonly LOGPATH=/var/log/SMIUSBDisplay
readonly PRODUCT="Silicon Motion Linux USB Display Software"
VERSION=2.21.2.0
ACTION=install




install_evdi()
{
  TARGZ="$1"
  ERRORS="$2"
  local EVDI_DRM_DEPS
  local EVDI
  EVDI=$(mktemp -d)
  if ! tar xf "$TARGZ" -C "$EVDI"; then
    echo "Unable to extract $TARGZ to $EVDI" > "$ERRORS"
    return 1
  fi

  echo "[[ Installing EVDI DKMS module ]]"
  (
    dkms install "${EVDI}/module"
    local retval=$?

    if [ $retval == 3 ]; then
      echo "EVDI DKMS module already installed."
    elif [ $retval != 0 ] ; then
      echo "Failed to install evdi to the kernel tree." > "$ERRORS"
      make -sC "${EVDI}/module" uninstall_dkms
      return 1
    fi
  ) || return 1
  echo "[[ Installing module configuration files ]]"
  printf '%s\n' 'evdi' > /etc/modules-load.d/evdi.conf

  printf '%s\n' 'options evdi initial_device_count=4' \
        > /etc/modprobe.d/evdi.conf
  EVDI_DRM_DEPS=$(sed -n -e '/^drm_kms_helper/p' /proc/modules | awk '{print $4}' | tr ',' ' ')
  EVDI_DRM_DEPS=${EVDI_DRM_DEPS/evdi/}

  [[ "${EVDI_DRM_DEPS}" ]] && printf 'softdep %s pre: %s\n' 'evdi' "${EVDI_DRM_DEPS}" \
        >> /etc/modprobe.d/evdi.conf


  echo "[[ Backuping EVDI DKMS module ]]"
  local EVDI_VERSION
  EVDI_VERSION=$(ls -t /usr/src | grep evdi | head -n1)
  cp -rf /usr/src/$EVDI_VERSION   $COREDIR/module
  cp /etc/modprobe.d/evdi.conf $COREDIR

  echo "[[ Installing EVDI library ]]"

  (
    cd "${EVDI}/library" || return 1

    if ! make; then
      echo "Failed to build evdi library." > "$ERRORS"
      return 1
    fi

    if ! cp -f libevdi.so "$COREDIR"; then
      echo "Failed to copy evdi library to $COREDIR." > "$ERRORS"
      return 1
    fi

    chmod 0755 "$COREDIR/libevdi.so"
	
    ln -sf "$COREDIR/libevdi.so"  /usr/lib/libevdi.so.0 
    ln -sf "$COREDIR/libevdi.so"  /usr/lib/libevdi.so.1 

  ) || return 1
}

uninstall_evdi_module()
{
  TARGZ="$1"

  local EVDI
  EVDI=$(mktemp -d)
  if ! tar xf "$TARGZ" -C "$EVDI"; then
    echo "Unable to extract $TARGZ to $EVDI"
    return 1
  fi

  (
    cd "${EVDI}/module" || return 1
    make uninstall_dkms
  )
}

is_32_bit()
{
  [ "$(getconf LONG_BIT)" == "32" ]
}

add_upstart_script()
{
  cat > /etc/init/smiusbdisplay.conf <<'EOF'
description "SiliconMotion Driver Service"


start on login-session-start
stop on desktop-shutdown

# Restart if process crashes
respawn

# Only attempt to respawn 10 times in 5 seconds
respawn limit 10 5

chdir /opt/siliconmotion

pre-start script
    . /opt/siliconmotion/smi-udev.sh

    if [ "\$(get_siliconmotion_dev_count)" = "0" ]; then
        stop
        exit 0
    fi
end script
script
    [ -r /etc/default/siliconmotion ] && . /etc/default/siliconmotion
    modprobe evdi
    if [ $? != 0 ]; then
	local v=$(awk -F '=' '/PACKAGE_VERSION/{print $2}' /opt/siliconmotion/module/dkms.conf)
	dkms remove -m evdi -v $v --all
	if [ $? != 0 ]; then
    		rm –rf /var/lib/dkms/$v
	fi
	dkms install /opt/siliconmotion/module/
	if [ $? == 0 ]; then
		cp /opt/siliconmotion/evdi.conf /etc/modprobe.d 
		modprobe evdi
	fi
    fi
    exec /opt/siliconmotion/SMIUSBDisplayManager
end script
EOF

  chmod 0644 /etc/init/smiusbdisplay.conf
}

add_smi_script()
{
  MODVER="$1"
  cat > /usr/share/X11/xorg.conf.d/20-smi.conf <<'EOF'
Section "Device"
        Identifier "SiliconMotion"
        Driver "modesetting"
	Option "PageFlip" "false"
EndSection
EOF

chown root: /usr/share/X11/xorg.conf.d/20-smi.conf
chmod 644 /usr/share/X11/xorg.conf.d/20-smi.conf

}

remove_smi_script()
{
  rm -f /usr/share/X11/xorg.conf.d/20-smi.conf
}

add_wayland_script()
{
if [ "$(lsb_release -r --short)"  == "20.04" ];
then
  mkdir -p /usr/share/xsessions/hidden
  dpkg-divert --rename --divert /usr/share/xsessions/hidden/ubuntu.desktop --add /usr/share/xsessions/ubuntu.desktop
fi
}

remove_wayland_script()
{
if [ "$(lsb_release -r --short)"  == "20.04" ];
then
  dpkg-divert --rename --remove /usr/share/xsessions/ubuntu.desktop
fi
}


add_systemd_service()
{
  cat > /lib/systemd/system/smiusbdisplay.service <<'EOF'
[Unit]
Description=SiliconMotion Driver Service
After=display-manager.service
Conflicts=getty@tty7.service

[Service]
ExecStartPre=/bin/bash -c "modprobe evdi || (dkms remove -m evdi -v $(awk -F '=' '/PACKAGE_VERSION/{print $2}' /opt/siliconmotion/module/dkms.conf) --all; if [ $? != 0 ]; then rm –rf /var/lib/dkms/$(awk -F '=' '/PACKAGE_VERSION/{print $2}' /opt/siliconmotion/module/dkms.conf) ;fi; dkms install /opt/siliconmotion/module/ && cp /opt/siliconmotion/evdi.conf /etc/modprobe.d && modprobe evdi)"

ExecStart=/opt/siliconmotion/SMIUSBDisplayManager
Restart=always
WorkingDirectory=/opt/siliconmotion
RestartSec=5

EOF

  chmod 0644 /lib/systemd/system/smiusbdisplay.service
}

trigger_udev_if_devices_connected()
{
  for device in $(grep -lw 090c /sys/bus/usb/devices/*/idVendor); do
    udevadm trigger --action=add "$(dirname "$device")"
  done
}
remove_upstart_script()
{
  rm -f /etc/init/smiusbdisplay.conf
}

remove_systemd_service()
{
  driver_name="smiusbdisplay"
  echo "Stopping ${driver_name} systemd service"
  systemctl stop ${driver_name}.service
  systemctl disable ${driver_name}.service
  rm -f /lib/systemd/system/${driver_name}.service
}

add_pm_script()
{
  cat > $COREDIR/smipm.sh <<EOF
#!/bin/bash

suspend_usb()
{
# anything want to do for suspend
}

resume_usb()
{
# anything want to do for resume
}

EOF

  if [ "$1" = "upstart" ]
  then
    cat >> $COREDIR/smipm.sh <<EOF
case "\$1" in
  thaw)
    resume_usb
    ;;
  hibernate)
    suspend_usb
    ;;
  suspend)
    suspend_usb
    ;;
  resume)
    resume_usb
    ;;
esac

EOF
  elif [ "$1" = "systemd" ]
  then
    cat >> $COREDIR/smipm.sh <<EOF
case "\$1/\$2" in
  pre/*)
    suspend_usb
    ;;
  post/*)
    resume_usb
    ;;
esac

EOF
  fi

  chmod 0755 $COREDIR/smipm.sh
  if [ "$1" = "upstart" ]
  then
    ln -sf $COREDIR/smipm.sh /etc/pm/sleep.d/smipm.sh
  elif [ "$1" = "systemd" ]
  then
    ln -sf $COREDIR/smipm.sh /lib/systemd/system-sleep/smipm.sh
  fi
}

remove_pm_scripts()
{
  rm -f /etc/pm/sleep.d/smipm.sh
  rm -f /lib/systemd/system-sleep/smipm.sh
}

cleanup()
{
  rm -rf $COREDIR
  rm -rf $LOGPATH
  rm -f /usr/bin/smi-installer
  rm -f /usr/bin/SMIFWLogCapture
  rm -f /etc/modprobe.d/evdi.conf
  rm -rf /etc/modules-load.d/evdi.conf
}

binary_location()
{
    local PREFIX="x64"
    local POSTFIX="ubuntu"

    is_32_bit && PREFIX="x86"
    echo "$PREFIX-$POSTFIX"
  
}

install()
{
  echo "Installing"
  mkdir -p $COREDIR
  chmod 0755 $COREDIR
  

  cp -f "$SELF" "$COREDIR"
  ln -sf "$COREDIR/$(basename "$SELF")" /usr/bin/smi-installer
  chmod 0755 /usr/bin/smi-installer
  echo "Installing EVDI"
  local ERRORS
  ERRORS=$(mktemp)
  finish() {
    rm -f "$ERRORS"
  }
  trap finish EXIT
  
  if ! install_evdi "evdi.tar.gz" "$ERRORS"; then
    echo "ERROR: $(< "$ERRORS")" >&2
    cleanup
    exit 1
  fi

  local BINS=$(binary_location)


	
  local SMI="$BINS/SMIUSBDisplayManager"
  local LIBUSB="$BINS/libusb-1.0.so.0.2.0"
  local GETFWLOG="$BINS/SMIFWLogCapture"
  
  cp -f 'evdi.tar.gz' "$COREDIR"
  echo "Installing $SMI"
  cp -f $SMI $COREDIR
  
  echo "Installing $GETFWLOG"
  cp -f $GETFWLOG $COREDIR

  echo "Installing libraries"
  [ -f $LIBUSB ] && cp -f $LIBUSB /usr/lib/libusb-1.0.so.0
  chmod 0755 /usr/lib/libusb-1.0.so.0
  [ -f $LIBUSB ] && cp -f $LIBUSB $COREDIR
  ln -sf $COREDIR/libusb-1.0.so.0.2.0 $COREDIR/libusb-1.0.so.0
  ln -sf $COREDIR/libusb-1.0.so.0.2.0 $COREDIR/libusb-1.0.so
  
  echo "Installing firmware packages"
  local BOOTLOADER0="Bootloader0.bin"
  local BOOTLOADER1="Bootloader1.bin"
  local FIRMWARE0BIN="firmware0.bin"
  local FIRMWARE1BIN="USBDisplay.bin"



  [ -f $BOOTLOADER0 ] && cp -f $BOOTLOADER0 $COREDIR
  [ -f $BOOTLOADER1 ] && cp -f $BOOTLOADER1 $COREDIR
  [ -f $FIRMWARE0BIN ] && cp -f $FIRMWARE0BIN $COREDIR
  [ -f $FIRMWARE1BIN ] && cp -f $FIRMWARE1BIN $COREDIR
  
  chmod 0755 $COREDIR/SMIUSBDisplayManager
  chmod 0755 $COREDIR/libusb*.so*
  chmod 0755 $COREDIR/SMIFWLogCapture
  
  ln -sf $COREDIR/SMIFWLogCapture /usr/bin/SMIFWLogCapture
  chmod 0755 /usr/bin/SMIFWLogCapture

  source smi-udev-installer.sh
  siliconmotion_bootstrap_script="$COREDIR/smi-udev.sh"
  create_bootstrap_file "$SYSTEMINITDAEMON" "$siliconmotion_bootstrap_script"
  
  add_wayland_script

  echo "Adding udev rule for SiliconMotion devices"
  create_udev_rules_file /etc/udev/rules.d/99-smiusbdisplay.rules
  xorg_running || udevadm control -R
  xorg_running || udevadm trigger

  echo "Adding upstart scripts"
  if [ "upstart" == "$SYSTEMINITDAEMON" ]; then
    echo "Starting SMIUSBDisplay upstart job"
    add_upstart_script
#   add_pm_script "upstart"
  elif [ "systemd" == "$SYSTEMINITDAEMON" ]; then
    echo "Starting SMIUSBDisplay systemd service"
    add_systemd_service
#  add_pm_script "systemd"
  fi

  xorg_running || trigger_udev_if_devices_connected
  xorg_running || $siliconmotion_bootstrap_script START

  echo -e "\nInstallation complete!"
  echo -e "\nPlease reboot your computer if you're intending to use Xorg."
  xorg_running || exit 0
  read -rp 'Xorg is running. Do you want to reboot now? (Y/n)' CHOICE
  [[ ${CHOICE:-Y} =~ ^[Nn]$ ]] && exit 0
  reboot
}

uninstall()
{
  echo "Uninstalling"

  if [ "upstart" == "$SYSTEMINITDAEMON" ]; then
    echo "Stopping SMIUSBDisplay upstart job"
    stop smiusbdisplay
    remove_upstart_script
  elif [ "systemd" == "$SYSTEMINITDAEMON" ]; then
    echo "Stopping SMIUSBDisplay systemd service"
    systemctl stop smiusbdisplay.service
    remove_systemd_service

  fi

  echo "[ Removing suspend-resume hooks ]"
  #remove_pm_scripts

  echo "[ Removing udev rule ]"
  rm -f /etc/udev/rules.d/99-smiusbdisplay.rules
  udevadm control -R
  udevadm trigger
  
  remove_wayland_script

  echo "[ Removing Core folder ]"
  cleanup

  modprobe -r evdi

  if [ -d $OTHERPDDIR ]; then
	  echo "WARNING: There are other products in the system using EVDI."
  else 
	  echo "Removing EVDI from kernel tree, DKMS, and removing sources."
    	  (
    	  cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && \
	  uninstall_evdi_module "evdi.tar.gz"
    	  )
  fi

  echo -e "\nUninstallation steps complete."
  if [ -f /sys/devices/evdi/count ]; then
    echo "Please note that the evdi kernel module is still in the memory."
    echo "A reboot is required to fully complete the uninstallation process."
  fi
}

missing_requirement()
{
  echo "Unsatisfied dependencies. Missing component: $1." >&2
  echo "This is a fatal error, cannot install $PRODUCT." >&2
  exit 1
}

version_lt()
{
  local left
  left=$(echo "$1" | cut -d. -f-2)
  local right
  right=$(echo "$2" | cut -d. -f-2)

  local greater
  greater=$(echo -e "$left\n$right" | sort -Vr | head -1)

  [ "$greater" != "$left" ]
}

install_dependencies()
{
  hash apt 2>/dev/null || return
  install_dependencies_apt
}

check_libdrm()
{
  hash apt 2>/dev/null || return
  apt list -qq --installed libdrm-dev 2>/dev/null | grep -q libdrm-dev
}

apt_ask_for_dependencies()
{
  apt --simulate install dkms libdrm-dev 2>&1 |  grep  "^E: " > /dev/null && return 1
  apt --simulate install dkms libdrm-dev | grep -v '^Inst\|^Conf'
}

apt_ask_for_update()
{
  echo "Need to update package list."
  read -rp 'apt update? [Y/n] ' CHOICE
  [[ "${CHOICE:-Y}" == "${CHOICE#[Yy]}" ]] && return 1
  apt update
}

install_dependencies_apt()
{
  hash dkms 2>/dev/null
  local install_dkms=$?
  apt list -qq --installed libdrm-dev 2>/dev/null | grep -q libdrm-dev
  local install_libdrm=$?

  if [ "$install_dkms" != 0 ] || [ "$install_libdrm" != 0 ]; then
    echo "[ Installing dependencies ]"
    apt_ask_for_dependencies || (apt_ask_for_update && apt_ask_for_dependencies) || check_requirements
    read -rp 'Do you want to continue? [Y/n] ' CHOICE
    [[ "${CHOICE:-Y}" == "${CHOICE#[Yy]}" ]] && exit 0

    apt install -y dkms libdrm-dev || check_requirements
  fi
}

check_requirements()
{
  # DKMS
  hash dkms 2>/dev/null || missing_requirement "DKMS"

  # libdrm
  check_libdrm || missing_requirement "libdrm"

  # Required kernel version
  KVER=$(uname -r)
  KVER_MIN="4.15"
  version_lt "$KVER" "$KVER_MIN" && missing_requirement "Kernel version $KVER is too old. At least $KVER_MIN is required"

  # Linux headers
  [ ! -d "/lib/modules/$KVER/build" ] && missing_requirement "Linux headers for running kernel, $KVER"
}

usage()
{
  echo
  echo "Installs $PRODUCT, version $VERSION."
  echo "Usage: $SELF [ install | uninstall ]"
  echo
  echo "The default operation is install."
  echo "If unknown argument is given, a quick compatibility check is performed but nothing is installed."
  exit 1
}

detect_init_daemon()
{
    INIT=$(readlink /proc/1/exe)
    if [ "$INIT" == "/sbin/init" ]; then
        INIT=$(/sbin/init --version)
    fi

    [ -z "${INIT##*upstart*}" ] && SYSTEMINITDAEMON="upstart"
    [ -z "${INIT##*systemd*}" ] && SYSTEMINITDAEMON="systemd"

    if [ -z "$SYSTEMINITDAEMON" ]; then
        echo "ERROR: the installer script is unable to find out how to start SMIUSBDisplayManager service automatically on your system." >&2
        echo "Please set an environment variable SYSTEMINITDAEMON to 'upstart' or 'systemd' before running the installation script to force one of the options." >&2
        echo "Installation terminated." >&2
        exit 1
    fi
}

detect_distro()
{
  if hash lsb_release 2>/dev/null; then
    echo -n "Distribution discovered: "
    lsb_release -d -s
  else
    echo "WARNING: This is not an officially supported distribution." >&2
  fi
}

xorg_running()
{
  local SESSION_NO
  SESSION_NO=$(loginctl | awk "/$(logname)/ {print \$1; exit}")
  [[ $(loginctl show-session "$SESSION_NO" -p Type) == *=x11 ]]
}
check_preconditions()
{
#  local SESSION_NO=$(loginctl | awk "/$(logname)/ {print \$1; exit}")
#  XORG_RUNNING=$(loginctl show-session "$SESSION_NO" -p Type | awk -F '=' '{if ($2 == "x11") {print "true"} else {print "false"}}')
#  local SMI_CONNECTED=false
#  lsusb | grep "090c:076" > /dev/null && SMI_CONNECTED=true
#  if "$SMI_CONNECTED" && "$XORG_RUNNING"; then
#    echo "Detected running Xorg session and connected SMI USB devices" >&2
#    echo "Please disconnect the SMI USB devices before continuing" >&2
#    echo "Installation terminated." >&2
#    exit 1
#  fi


  modprobe evdi

  if [ -f /sys/devices/evdi/count ]; then

    echo "WARNING: EVDI kernel module is already running." >&2
	
	if [ -d $COREDIR ]; then
	  echo "Please uninstall all other versions of $PRODUCT before attempting to install." >&2
	  echo "Installation terminated." >&2
	  exit 1	
	elif [ -d $OTHERPDDIR ]; then
		echo "WARNING: There are other products in the system using EVDI." >&2
		echo "Removing old EVDI from kernel tree, DKMS, and removing sources."
		echo "SMI USB Display will re-install new EVDI."
		uninstall_evdi_module "evdi.tar.gz"
	else
		echo "Please reboot before attempting to re-install $PRODUCT." >&2
		echo "Installation terminated." >&2
		exit 1	
	fi
  fi
}

if [ "$(id -u)" != "0" ]; then
  echo "You need to be root to use this script." >&2
  exit 1
fi

echo "$PRODUCT $VERSION install script called: $*"
[ -z "$SYSTEMINITDAEMON" ] && detect_init_daemon || echo "Trying to use the forced init system: $SYSTEMINITDAEMON"
detect_distro

while [ -n "$1" ]; do
  case "$1" in
    install)
      ACTION="install"
      ;;

    uninstall)
      ACTION="uninstall"
      ;;
    *)
      usage
      ;;
  esac
  shift
done

if [ "$ACTION" == "install" ]; then
  install_dependencies
  check_requirements
  check_preconditions
  install
elif [ "$ACTION" == "uninstall" ]; then
  check_requirements
  uninstall
fi
