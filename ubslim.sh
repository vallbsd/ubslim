#!/bin/bash

export LC_ALL=C
export LANG=C
export LANGUAGE=C

if [ "$(id -u)" != "0" ]
then
  echo 'You must have root privileges to use this.'
  exit
fi

ping -c 1 8.8.8.8 > /dev/null 2>&1
if [ $? != 0 ]
then
  echo 'No connection to Internet. Can not continue.'
  exit
fi

echo ''
echo 'This is a script to install slimmed Ubuntu LTS.'

### CREATE PARTITIONS

echo ''
echo 'List of found disks:'
for D in $(ls /dev/sd[a-z])
do
  fdisk -l $D | head -2 | sed 's/^Disk //' | sed -z 's/sectors\n/sectors, /'
done
echo ''
echo 'Select a disk to install Ubuntu on, for example sda, sdb or sdc:'
read -i sd -e ROOTDISK
if [ ! -e /dev/$ROOTDISK ]
then
  echo "Device $ROOTDISK does not exist."
  exit
fi
echo ''
echo 'Would you like to create totally new partition table on this disk?'
echo 'If so, print yes. Print no to use existing partitions.'
read -i "yes" -e FDISK;
if [ "$FDISK" = "yes" ]
then
  MAXSIZE="$(fdisk -l /dev/$ROOTDISK | head -1 | cut -d ' ' -f 3,4 | sed 's/ //g; s/iB,$//')"
  echo ''
  echo "Full disk size of $ROOTDISK is $MAXSIZE."
  echo 'Print size for root partition, for example 32G or 1500M.'
  echo 'The rest of disk will be used for swap partition.'
  read -i $MAXSIZE -e ROOTSIZE
  ROOTPART="$ROOTDISK"1
  if [ "$ROOTSIZE" != "$MAXSIZE" ]
  then
    SWAPPART="$ROOTDISK"2
  fi
  echo ''
  (echo o;
   if [ "$ROOTSIZE" = "$MAXSIZE" ]
   then
     echo n; echo p; echo 1; echo ""; echo ""; echo a;
   else
     echo n; echo p; echo 1; echo ""; echo "+$ROOTSIZE"; echo a;
     echo n; echo p; echo 2; echo ""; echo "";
     echo t; echo 2; echo 82;
   fi
   echo p; echo w) | fdisk /dev/$ROOTDISK
else
  EXIST="$(fdisk -l /dev/$ROOTDISK | grep --color=never -E '^Device|^\/dev')"
  if [ "$EXIST" ]
  then
    echo ''
    echo 'Here are existing partitions on this disk:'
    echo "$EXIST"
    echo ''
    echo "Choose partition for / , for example "$ROOTDISK"1 or "$ROOTDISK"2:"
    ROOTPART="$ROOTDISK"1
    read -i $ROOTPART -e ROOTPART
    SWAPPART="$(fdisk -l /dev/$ROOTDISK | grep 'Linux swap' | cut -d ' ' -f 1 | cut -d '/' -f 3)"
    if [ "$SWAPPART" ]
    then
      echo ''
      echo "It seems that $SWAPPART is a swap partition."
      echo 'Do you want to use it as swap? If so, print yes.'
      read -i "yes" -e ANS;
      if [ "$ANS" != "yes" ]
      then
        echo ''
        echo 'You can set swap manually after installation.'
        SWAPPART=""
      fi
    fi
  else
    echo ''
    echo 'Partitions on disk '$ROOTDISK' was not found.'
    echo 'You need to create them to continue unstallation.'
    echo 'Use cfdisk or rerun this installer.'
    exit
  fi
fi

### FORMAT ROOT

yes | mkfs.ext4 "/dev/$ROOTPART"
mount "/dev/$ROOTPART" /mnt

### DOWNLOAD AND UNPACK UBUNTU BASE

cd /tmp
wget -r --no-parent --no-directories -A "ubuntu-base-*-amd64.tar.gz" \
     http://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/
tar -xf ubuntu-base-*-amd64.tar.gz -C /mnt
if [ $? -ne 0 ]
then
  echo 'Error: Can not download Ubuntu base archive.'
  umount "/dev/$ROOTPART"
  exit
fi

### WRITE FSTAB AND RESOLV.CONF

echo "/dev/$ROOTPART / ext4 defaults 0 1" > /mnt/etc/fstab
if [ "$SWAPPART" ]
then
  mkswap "/dev/$SWAPPART"
  echo "/dev/$SWAPPART none swap defaults 0 0" >> /mnt/etc/fstab
fi

echo 'nameserver 8.8.8.8' > /mnt/etc/resolv.conf

### PREPARE TO CHROOT

mount --bind /dev /mnt/dev
mount --bind /tmp /mnt/tmp
mount --bind /run /mnt/run
mount -t proc proc /mnt/proc
mount -t sysfs none /mnt/sys
mount -t devpts -o noexec,nosuid devpts /mnt/dev/pts

### WRITE CHROOT SCRIPT
# What happens here:
#  unminimize base system
#  install minimal set of desktop needed packages
#  configure grub2
#  set hostname
#  add user
#  add a couple of sane fixes
#  add nonsnap firefox repository

cat << 'EOF' > /mnt/continue_install
rm /etc/dpkg/dpkg.cfg.d/excludes
rm /etc/update-motd.d/60-unminimize
rm /usr/local/sbin/unminimize
rm /usr/bin/man
dpkg-divert --remove --no-rename /usr/bin/man

apt update
apt install --reinstall -y $(dpkg-query -S /usr/share/man | tr -d ',' | sed 's/\: \/usr.*$//')
apt upgrade -y

DEBIAN_FRONTEND=noninteractive apt install -y \
  apt-utils dialog locales man-db keyboard-configuration systemd init grub2 \
  initramfs-tools linux-base linux-generic linux-image-generic zstd tzdata  \
  fdisk iproute2 inetutils-ping network-manager wget pulseaudio alsa-utils  \
  bc less nvi ncal sed pciutils xserver-xorg xinit x11-utils xterm fluxbox

dpkg-reconfigure tzdata

echo ''
echo 'Would you like to set specific boot options for GRUB?'
echo 'If so, print them here. Leave the line blank if no specific options needed.'
read GRUBOPTS

sed -i -e 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*$/GRUB_CMDLINE_LINUX_DEFAULT="'"$GRUBOPTS"'"/' \
       -e 's/^GRUB_TIMEOUT_STYLE=.*$/GRUB_TIMEOUT_STYLE=menu/' \
       -e 's/^GRUB_TIMEOUT=0/GRUB_TIMEOUT=1/' \
       -e 's/^\#GRUB_TERMINAL=.*$/GRUB_TERMINAL=console/' /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg
grub-install $(head -1 /etc/fstab | cut -d '1' -f 1)

echo ''
echo 'Set hostname:'
read -i "ubuntu" -e HOSTNAME
echo "$HOSTNAME" > /etc/hostname

locale-gen en_US.UTF-8 ru_RU.UTF-8
localectl set-locale en_US.UTF-8

echo ''
echo 'Set root password:'
passwd
echo ''
echo 'Choose name for regular user:'
read USER
if [ -z $USER ]
then
  echo 'Empty name. User will not be created.'
  echo ''
else
  useradd -g root -G operator,sudo -s /bin/bash -m $USER
  passwd -d $USER 1> /dev/null
  echo ''
  echo 'Add tty autologin for this user?'
  read -i "yes" -e ANS
  if [ "$ANS" = "yes" ]
  then
    mkdir /etc/systemd/system/getty\@.service.d
    (echo '[Service]'
     echo 'ExecStart='
     grep '^ExecStart=' /usr/lib/systemd/system/getty\@.service | sed "s/--noclear/--noclear --autologin $USER/" ) \
          > /etc/systemd/system/getty\@.service.d/autologin.conf
  fi
fi

rmdir /*.usr-is-merged
echo 'APT::AutoRemove::SuggestsImportant "false";' > /etc/apt/apt.conf.d/99autoremove # fix autoremoving
echo 'kernel.dmesg_restrict=0' >> /etc/sysctl.conf # allow user to read dmesg

echo 'network:
 renderer: NetworkManager' > /etc/netplan/config.yaml

wget -O /etc/apt/keyrings/packages.mozilla.org.asc https://packages.mozilla.org/apt/repo-signing-key.gpg
echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
     > /etc/apt/sources.list.d/mozilla.list
echo -e 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000' > /etc/apt/preferences.d/mozilla
apt update

echo 'Section "InputClass"
        Identifier "libinput touchpad catchall"
        Option "Tapping" "on"
EndSection' > /etc/X11/xorg.conf.d/20-touchpad.conf

echo 'set ruler'      >> /etc/vi.exrc
echo 'set autoindent' >> /etc/vi.exrc
echo 'set noflash'    >> /etc/vi.exrc

EOF

### RUN INSTALLATION INSIDE CHROOT

chroot /mnt /bin/bash -c "/bin/bash /continue_install"

rm /mnt/continue_install

echo ''
echo 'Installation done.'
echo 'Now you can reboot to installed system or continue by chroot /mnt .'
echo 'Use nmtui to set network and apt to install desired window manager.'
