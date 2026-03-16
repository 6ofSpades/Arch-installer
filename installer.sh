#!/usr/bin/env bash


set -e
set -u
set -o pipefail
trap 'echo "FAILED at line $LINENO"' ERR

### ========= HELPERS ========= ###
log() {
  echo -e "\n\e[1;35m==> $1\e[0m"
}

### ========= PHASE 1 ========= ###
base_system() {
  echo "Checking internet connection..."
  if ! ping -c 2 ping.archlinux.org >/dev/null 2>&1; then
    echo "Are you not connected to the internet? :("
    exit 1
  fi

  pacman -Sy --noconfirm gum || ( echo 'We cant install gum. We sad ;(' && exit 1 )

  echo
  # Gum confirmation
  gum style \
	--foreground 21 --border-foreground 54 --border double \
	--align center --width 50 --margin "1 1" --padding "2 4" \
	'Gum installed!' 'Things will be just a tiny bit fancy now B)' 'You still have to type some things though cause you need to suffer >:('

  echo "Setting timezone thingys..."
  # timedatectl set-timezone $TIMEZONE
  timedatectl set-ntp true

  log "Doing archlinux keyring stuff..."
  pacman -Sy --noconfirm archlinux-keyring

  # Disk partitioning
  prompt=$(gum style --padding "1 3" --bold --underline --border-foreground 212 "These are your disks:")
  disklist=$(gum style --padding "1 2" --border double --border-foreground 212 "$(lsblk -fo name,label,size,fstype,fsver,uuid,fsavail,fsuse%,mountpoints)")
  gum join --vertical --align center "$prompt" "$disklist"

  while true; do
    disk="/dev/$(lsblk -ndlo name | gum choose --header "In which disk should we install stuff?")"

    prompt="WARNING: This will WIPE the entire disk $disk. Are you sure?"
    gum confirm --default "$prompt" && break || continue
  done

  gum spin -s line --title "Wiping disk..." -- \
  bash -c '
    umount -R /mnt 2>/dev/null || true
    swapoff -a 2>/dev/null || true
    cryptsetup close main 2>/dev/null || true
    wipefs -a "$0"
    sgdisk --zap-all "$0"
  ' "$disk"

  log "Partitioning..."
  (
  echo g # Create a new empty GPT partition table
  echo n # Add a new partition
  echo 1 # Partition number
  echo   # First sector (Accept default: 1)
  echo +512MiB  # Last sector (Accept default: varies)
  echo t  # Change partition type
  echo 1  # Choose uefi for partition type
  echo n
  echo 2
  echo  
  echo  
  echo t
  echo 2
  echo 23
  echo w # Write changes
  ) | fdisk "$disk"

  # Partition suffix
  if [[ "$disk" =~ nvme ]]; then
    part1="${disk}p1"
    part2="${disk}p2"
  else
    part1="${disk}1"
    part2="${disk}2"
  fi

  log "Disk encryption"
  while true; do
    read -p "Do you wanna do disk encryption stuff? [y/n] " encryption
    case "$encryption" in
      y|n)
        ;;
      *)
        echo "Type y or n ^^"
        continue
        ;;
    esac
    if [[ "$encryption" =~ ^[Yy]$ ]]; then
      gum confirm || continue

      while true; do
        epassw=$(gum input --password --placeholder "Put your password here. Trust me ;)" --prompt "Encryption password: ")
        [[ $(gum input --password --placeholder "One more time" --prompt "Encryption password: ") == "$epassw" ]] && break
        echo "You have to type the same password :("
      done

      gum spin -s line --title "Encrypting..." -- bash -c "echo "$epassw" | cryptsetup luksFormat "$part2""
      echo "Encrypted!"
      gum spin -s line --title "Opening encrypted partition..." -- bash -c "echo "$epassw" | cryptsetup luksOpen "$part2" main"
      unset epassw

      CRYPT_PART="$part2"
      part2="/dev/mapper/main"
    fi
    break
  done

  log "Formatting partitions..."
  mkfs.fat -F 32 "$part1"
  mkfs.btrfs -f "$part2"

  log "Swapfile configuration"
  while true; do
    read -rp "Do you want a swapfile as a fallback to ZRAM? [y/n] " swap
    case "$swap" in
      y|n)
        break
        ;;
      *)
        echo "y or n pls >.<"
        ;;
    esac
  done
  if [[ "$swap" == "y" ]]; then
    while true; do
      swap_size=$(gum filter --header "Choose swapfile size
      Remember to pick a big enough size if you intend to setup Hibernate" {1..50}G) || continue
      gum confirm --default "Swapfile of size $swap_size?" && break || continue
    done
  fi

  log "Creating BTRFS subvolumes..."
  mount "$part2" /mnt
  cd /mnt
  btrfs subvolume create @
  btrfs subvolume create @home
  btrfs subvolume create @log
  btrfs subvolume create @cache
  btrfs subvolume create @snapshots
  # swap file needs a subvolume in BTRFS
  if [[ "$swap" == "y" ]]; then
    btrfs subvolume create @swap
  fi
  cd /
  umount /mnt

  log "Mounting the file systems..."
  # Root (the @ subvolume)
  mount -o noatime,ssd,compress=zstd,space_cache=v2,discard=async,subvol=@ "$part2" /mnt
  # Then make the other mount points:
  mkdir -p /mnt/{boot,btrfsroot,home,var/log,var/cache,.snapshots,efi,swap}
  # Home
  mount -o noatime,ssd,compress=zstd,space_cache=v2,discard=async,subvol=@home "$part2" /mnt/home
  # Log
  mount -o noatime,ssd,compress=zstd,space_cache=v2,discard=async,subvol=@log "$part2" /mnt/var/log
  # Cache
  mount -o noatime,ssd,compress=zstd,space_cache=v2,discard=async,subvol=@cache "$part2" /mnt/var/cache
  # Snapshots
  mount -o noatime,ssd,compress=zstd,space_cache=v2,discard=async,subvol=@snapshots "$part2" /mnt/.snapshots
  # Swap, if chosen
  if [[ "$swap" == "y" ]]; then
    mount -o subvol=@swap "$part2" /mnt/swap
    echo "Creating swapfile of size $swap_size..."
    btrfs filesystem mkswapfile --size "$swap_size" --uuid clear /mnt/swap/swapfile
  fi
  # Btrfsroot, important for snapper-rollback to work
  mount -o noatime,ssd,compress=zstd,space_cache=v2,discard=async,subvolid=5 "$part2" /mnt/btrfsroot
  # /efi or /boot
  mount "$part1" /mnt/efi

  log "Mirrors selection"
  while true; do
    read -rp "Select mirrors with Reflector? This often just makes things slower for some reason -_- [y/n] " mirrors
    case "$mirrors" in
      y|n)
        break
        ;;
      *)
        echo "You have to type y or n :("
        ;;
    esac
  done
  if [[ "$mirrors" == "y" ]]; then
    gum spin -s line --title "Well, this will prob take some minutes." -- reflector --latest 50 --sort rate --save /etc/pacman.d/mirrorlist
    echo "Done."
  fi

  log "Installing essential packages..."
  while true; do
    read -rp "Are you rocking Intel or AMD cpu today? [intel/amd] " cpu
    case "$cpu" in
      intel|amd)
        break
        ;;
      *)
        echo "Type intel or amd :|"
        ;;
    esac
  done
  echo "Wow :O"
  pacstrap -K /mnt base linux linux-firmware linux-headers ${cpu}-ucode networkmanager neovim man-db man-pages git base-devel grub efibootmgr btrfs-progs

  log "Generating fstab..."
  genfstab -U /mnt >> /mnt/etc/fstab

  if [[ "$swap" == "y" ]]; then
    echo "Persisting swapfile in fstab..."
    echo "/swap/swapfile none swap defaults 0 0" >> /mnt/etc/fstab
  fi

  cd
  log "Chroot-ing..."
  sleep 2
  cp "$0" /mnt/root/install.sh
  chmod +x /mnt/root/install.sh

  if [[ "$encryption" =~ ^[Yy]$ ]]; then
    arch-chroot /mnt /root/install.sh chroot encryption "$CRYPT_PART"
  else
    arch-chroot /mnt /root/install.sh chroot normal "$part2"
  fi
}

### ========= PHASE 2 ========= ###
user_environment() {
  log "Installing user environment..."

  # unmapped and encrypted root partition
  CRYPT_PART="${2:-}"
  # root partition
  part2="${2:-}"

  pacman -S --noconfirm gum

  echo "Doing time thingy..."
  while true; do
    TIMEZONE=$(gum filter --header "Choose your timezone thingy" $(timedatectl list-timezones)) || continue
    gum confirm --default "Is $TIMEZONE your timezone?" && break || continue
  done
  ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
  hwclock --systohc
  systemctl enable systemd-timesyncd

  echo "Setting localization stuff..."
  sed -i '/en_US.UTF-8/s/^#//' /etc/locale.gen
  locale-gen
  echo "LANG=en_US.UTF-8" > /etc/locale.conf
  echo "KEYMAP=br-abnt2" > /etc/vconsole.conf

  log "Hostname"
  hostname=$(gum input --prompt "Hostname: " --placeholder "What will be your hostname?")
  echo "$hostname" > /etc/hostname

  if [[ "${1:-}" == "encryption" ]]; then
    echo
    echo "Initramfs thingys cause we did disk encryption..."
    sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard keymap sd-vconsole block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf
  fi

  log "Root password"
  echo "Type the root password: "
  passwd

  log "Installing bootloader..."
  if [[ "${1:-}" == "encryption" ]]; then
    # uncomment cryptodisk in grub file so grub doesn't throw an error when installing with encryption
    sed -i 's/^#\?GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub

    CRYPT_UUID=$(blkid -s UUID -o value "$CRYPT_PART")

    if [[ -z "$CRYPT_UUID" ]]; then
      echo "ERROR: Could not determine UUID of encrypted partition"
      exit 1
    fi
    # `cryptdevice` is for udev based. If you have systemd based then it's `rd.luks.name`
    # sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"rd.luks.name=${CRYPT_UUID}=main root=/dev/mapper/main\"|" /etc/default/grub
    # append to line, without replacing stuff
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\1 rd.luks.name=${CRYPT_UUID}=main\"|" /etc/default/grub
  fi

  gum confirm --default "Do you want to setup Hibernation?" && hibernate="y" || hibernate="n"
  if [[ "$hibernate" == "y" ]]; then
    if [[ "${1:-}" == "encryption" ]]; then
      RESUME_DEV="/dev/mapper/main"
    else
      RESUME_DEV="$part2"
    fi
    SWAP_OFFSET=$(btrfs inspect-internal map-swapfile -r /swap/swapfile)

    # removing old just to avoid duplicates just in case
    sed -i 's/resume=[^ ]*//g' /etc/default/grub
    sed -i 's/resume_offset=[^ ]*//g' /etc/default/grub

    # append the resume thingys to the parameter line
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\1 resume=${RESUME_DEV} resume_offset=${SWAP_OFFSET}\"|" /etc/default/grub
  fi

  grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=ArchLinux
  grub-mkconfig -o /boot/grub/grub.cfg

  log "Username"
  while true; do
    username=$(gum input --prompt "Username: " --placeholder "Type your username")
    gum confirm --default "Is $username your username?" && break || continue
  done
  useradd -m -G wheel -s /bin/bash "$username"
  while true; do
    passw=$(gum input --password --prompt "Password: " --placeholder "Now your password")
    [[ $(gum input --password --prompt "Password: " --placeholder "Confirm password") == "$passw" ]] && break
    echo "You have to type the same password :("
  done
  echo "$passw" | passwd "$username" -s

  log "Sudoers overrides"
  echo "Enabling sudo for wheel group..."
  echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel
  chmod 440 /etc/sudoers.d/10-wheel
  echo "Overriding sudoers systemd_editor..."
  echo 'Defaults env_keep += "SYSTEMD_EDITOR"' > /etc/sudoers.d/20-systemd_editor
  chmod 440 /etc/sudoers.d/20-systemd_editor

  log "Setting IO schedulers rules thingy..."
  cat > /etc/udev/rules.d/60-ioschedulers.rules <<EOF
  # HDD
  ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"

  # SSD
  ACTION=="add|change", KERNEL=="sd[a-z]*|mmcblk[0-9]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="bfq"

  # NVMe SSD
  ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none"
EOF

  log "Setting ZRAM..."
  pacman -S --noconfirm zram-generator
  cat > /etc/systemd/zram-generator.conf <<EOF
  [zram0]
  zram-size = ram / 2
  compression-algorithm = zstd
EOF

  log "Creating btrfs-swap-resize script..."
  # Even if you choose not to swap, it doesn't hurt to keep this stored just in case
  cat > /usr/local/bin/btrfs-resize-swap <<'EOF'
  #!/bin/bash
  set -e

  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (use sudo)"
    exit 1
  fi

  SIZE="$1"

  if [[ -z "$SIZE" ]]; then
    echo "Usage: btrfs-resize-swap <size> (e.g. 8g, 16g)"
    exit 1
  fi

  swapoff /swap/swapfile 2>/dev/null || true
  rm -f /swap/swapfile

  btrfs filesystem mkswapfile --size "$SIZE" /swap/swapfile || ( echo -e "\n\e[1;31m==> Swap is off\e[0m" && exit 1 )
  swapon /swap/swapfile

  echo -e "\n\e[1;32m==> Swap resized to $SIZE\e[0m"
EOF
  chmod +x /usr/local/bin/btrfs-resize-swap

  log "Installing Reflector..."
  pacman -S --noconfirm reflector
  systemctl enable reflector.timer

  log "Installing Snapper and BTRFS stuff..."
  pacman -S --noconfirm snapper grub-btrfs


  # Now we start the installation of packages I most certainly want

  log "Trying to install a lot of things that you certainly can't live without >.< ..."
  echo "Temporarily enabling passwordless sudo for wheel..."
  cat > /etc/sudoers.d/99-wheel-nopasswd << 'EOF'
  %wheel ALL=(ALL:ALL) NOPASSWD: ALL
EOF
  chmod 440 /etc/sudoers.d/99-wheel-nopasswd

  echo "Enabling multilib repository..."
  sed -i '
  /^\s*#\s*\[multilib\]/{
    s/^#\s*//
    n
    s/^#\s*//
  }
  ' /etc/pacman.conf
  pacman -Sy

  echo "Enabling pacman eye candy which is super important..."
  sed -i '
  /^# Misc options/{
    n
    /Color/!a Color
    /ILoveCandy/!a ILoveCandy
  }
  ' /etc/pacman.conf

  log "Trying to install yay without failing miserably..."
  pacman -S --needed --noconfirm git base-devel 
  su - "$username" -c "cd /home/$username && git clone https://aur.archlinux.org/yay.git && cd yay && makepkg -si --noconfirm && cd .. && rm -rf yay"

  echo "Now the rest of things..."
  su - "$username" -c '
    yay -S --needed --noconfirm \
      snapper-rollback \
      zsh zsh-completions zsh-autosuggestions zsh-syntax-highlighting zsh-vi-mode \
      openssh inotify-tools pacman-contrib \
      yazi 7zip fd jq bc fzf zoxide ripgrep trash-cli autotrash \
      plocate gdu downgrade npm ufw tufw-git btop tlrc \
      paccache-hook yaycache yaycache-hook

    # snapper rollback script so you can do rollback super easily
    # plus a bunch of stuff that is hard to live without
    # tufw-git version cause stable version seems to be maintained by another person that not the author
  '

  clean-cache

  gum confirm --default "Install Syncthing and enable the service?" && syncthing="y" || syncthing="n"
  if [[ "$syncthing" == "y" ]]; then
    su - "$username" -c '
      yay -S --needed --noconfirm \
        syncthing
      '
    systemctl enable --now "syncthing@$username.service"
    echo "Syncthing enabled"
  fi

  # manually create the autotrash timer cause the command to auto do it doesn't work for some reason
  mkdir -p "/home/$username/.config/systemd/user"

  cat > "/home/$username/.config/systemd/user/autotrash.service" <<'EOF'
  [Unit]
  Description=Empty trash
  Documentation=https://github.com/bneijt/autotrash

  [Service]
  Type=oneshot
  ExecStart="/usr/bin/autotrash" -d 30
EOF

  cat > "/home/$username/.config/systemd/user/autotrash.timer" <<'EOF'
  [Unit]
  Description=Empty trash

  [Timer]
  OnCalendar=daily
  Persistent=true

  [Install]
  WantedBy=timers.target
EOF

  mkdir -p "/home/$username/.config/systemd/user/timers.target.wants"

  ln -sf \
    "/home/$username/.config/systemd/user/autotrash.timer" \
    "/home/$username/.config/systemd/user/timers.target.wants/autotrash.timer"

  chown -R "$username:$username" "/home/$username/.config/systemd"

  # now change the user default shell to zsh
  echo "Changing the user default shell to zsh"
  chsh -s /bin/zsh "$username"

  # always clear cache and keep 0 packages for both pacman and yay
  echo "Configuring paccache-hook and yaycache-hook"
  # paccache hook config
  cat > /etc/paccache-hook.conf <<'EOF'
  extra_args=()
  cache_dirs=()

  installed=true
  installed_keep=0
  installed_extra_args=()
  installed_move_to=

  uninstalled=true
  uninstalled_keep=0
  uninstalled_extra_args=
  uninstalled_move_to=
EOF

  # yaycache hook config
  cat > /etc/yaycache-hook.conf <<'EOF'
  extra_args=-v
  cache_dirs=()

  installed=true
  installed_keep=0
  installed_extra_args=
  installed_move_to=

  uninstalled=true
  uninstalled_keep=0
  uninstalled_extra_args=
  uninstalled_move_to=
EOF

  log "Setup"
  while true; do
    read -rp "Hyprland or full hacker TTY setup? [hypr/hacker] " setup
    case "$setup" in
      hypr|hacker)
        break
        ;;
      *)
        echo "Type 'hypr' or 'hacker' -_-"
        ;;
    esac
  done
  if [[ "$setup" == "hypr" ]]; then

    log "Installing GPU drivers..."

    # now for the GPU drivers stuff
    # I currently have Nvidia cause I chose pain
    # I also have an old card to make things worse
    # and I don't know how different this automation would be otherwise
    # this script is for personal use so I don't care -_-
    su - "$username" -c '
      set -e

      yay -S --needed --noconfirm \
        nvidia-580xx-dkms nvidia-580xx-utils lib32-nvidia-580xx-utils libva-nvidia-driver

      # These are only available on the AUR cause life is sad and my card is old ;(
    '

    clean-cache

    log "Installing Hyprland and a lot of DE-like thingys..."
    # Audio stuff first cause otherwise there's the piepwire-jack conflicting thingy
    su - "$username" -c '
      yay -S --needed --noconfirm \
        pipewire wireplumber pipewire-pulse pipewire-alsa pipewire-jack lib32-pipewire wiremix
    '
    # Now the actual stuff
    su - "$username" -c '
      yay -S --needed --noconfirm \
        qt5-wayland qt6-wayland hyprland hyprpicker hyprsunset hypridle hyprlock hyprcursor \
        xdg-desktop-portal xdg-desktop-portal-hyprland xdg-desktop-portal-gtk \
        polkit hyprpolkitagent xdg-user-dirs portmaster-bin \
        swww kitty rofi rofi-qalc-git rofimoji-git rofi-rbw dunst wlogout waybar \
        wvkbd-git wl-kbptr wl-ime-type ydotool \
        noto-fonts noto-fonts-emoji ttf-jetbrains-mono-nerd \
        clipvault wl-clipboard \
        grim flameshot swayimg \
        zen-browser-bin vesktop-bin \
        mpv resvg poppler ffmpeg imagemagick \
        proton-vpn-gtk-app proton-vpn-cli

      # Create the default user directories
      xdg-user-dirs-update
    '

    clean-cache

    gum confirm --default "Install dotfyles? :)" && dotfyles="y" || dotfyles="n"
    if [[ "$dotfyles" == "y" ]]; then
      git clone https://github.com/6ofSpades/Dotfyles.git "/home/$username/Dotfyles"

      dotfiles_mode=$(gum choose \
        --header "Choose dotfiles installation mode:" \
        --label-delimiter "=" \
        "Symlink=link" \
        "Copy=copy")

      sudo -u "$username" -i bash -c "/home/$username/Dotfyles/install.sh --$dotfiles_mode"

      clean-cache
    else
      echo ":O"
    fi

  fi

  if [[ "$setup" == "hypr" ]]; then
    log "Gamer thingys :3"
    while true; do
      read -rp "Are you feeling like a gamer? [y/n] " gamer
      case "$gamer" in
        y|n)
          break
          ;;
        *)
          echo "Stop mistyping >:("
          ;;
      esac
    done
    if [[ "$gamer" == "y" ]]; then
      log "Installing gamer thingys..."

      su - "$username" -c '
        yay -S --needed --noconfirm \
          steam \
          nsnake
      '

      pacman -S --noconfirm flatpak
      flatpak install -y --or-update flathub net.lutris.Lutris || echo "Something failed while installing the flatpak"

      clean-cache

      # Create games directory
      su - "$username" -c 'mkdir -p ~/Games'
    else
      echo "Skipping :("
    fi
  fi

  # Now regenerating initramfs after everything
  # It should be autorun after the driver thingy so this is just for safety and
  # in case the drivers aren't installed
  log "Regenerating initramfs just to make sure..."
  mkinitcpio -P || true # cause mkinitcpio is dramatic and aborts for no reason sometimes
}

### ========= OPTIONAL ========= ###
virtualization() {
  if [[ "$setup" == "hypr" ]]; then
    log "Setting up virtualization..."
    while true; do
      read -rp "Install VM / virtualization thingys? [y/n] " vm
      case "$vm" in
        y|n)
          break
          ;;
        *)
          echo "You don't know how to type -_-"
          ;;
      esac
    done
    if [[ "$vm" == "y" ]]; then
      echo "Installing virtualization stack..."
      su - "$username" -c '
        yay -S --needed --noconfirm \
          qemu-desktop virt-manager dnsmasq bridge-utils swtpm
      '

      gum confirm --default "Install VMWare?" && vmware="y" || vmware="n"
      if [[ "$vmware" == "y" ]]; then
        su - "$username" -c '
          yay -S --needed --noconfirm \
            vmware-keymaps
        ' || echo "VMWare installation failed"
        su - "$username" -c '
          yay -S --needed --noconfirm \
            vmware-workstation
        ' || echo "VMWare installation failed"
      fi

      clean-cache

      # creating directory for you to put the VM thingys
      su - "$username" -c 'mkdir -p ~/VMs'

      # Enable the libvirt service
      systemctl enable libvirtd

      # if [[ "$vmware" == "y" ]]; then
      #   systemctl enable vmware-networks-configuration.service
      #   systemctl enable vmware-networks.service
      # fi

    else
      echo "Skipping"

    fi
  fi
}

extras() {
  log "Installing optional apps..."

  OPTIONAL_PKGS="
  ### Editing stuff
  inkscape
  kolourpaint
  gimp
  krita
  blender
  kdenlive
  libreoffice-still

  ### Audio stuff
  espeak-ng
  qpwgraph
  pear-desktop-bin
  audiorelay
  tenacity

  ### Browsers
  mullvad-browser-bin
  brave-bin
  torbrowser-launcher

  ### Social
  signal-desktop
  discord-canary

  ### Networking
  nmap
  wireshark-qt
  speedtest-cli

  ### Misc thingys...?
  yt-dlp
  obs-studio
  qbittorrent
  obsidian
  scrcpy
  kiwix-desktop
  solaar
  flatseal
  upscayl-bin
  "
### Gaming?
# sunshine-bin
# sunshine installation doesn't work in chroot for some reason

  # Prompt selection
  SELECTED=$(echo "$OPTIONAL_PKGS" | gum choose --height 40 --no-limit --header "Select the packages you want installed
  Don't select the thingys with '###' that's just to categorize -_-
  Or do it cause we're gonna sanitize anyway.")

  # Convert to sanitized array
  mapfile -t OPTIONAL_PKGS < <(
    printf '%s\n' "$SELECTED" |
    grep -vE '^[[:space:]]*(#|$)'
  )

  # Mullvad needs an extra step for the installation to work
  if [[ "${OPTIONAL_PKGS[*]}" == *"mullvad"* ]]; then
    echo "Fetching Mullvad's key"
    su - "$username" -c '
      gpg --auto-key-locate nodefault,wkd --locate-keys torbrowser@torproject.org
    '
  fi

  if (( ${#OPTIONAL_PKGS[@]} > 0 )); then
    log "Installing the things you selected..."
    # Join array with spaces and install
    su - "$username" -c "yay -S --needed --noconfirm ${OPTIONAL_PKGS[*]}"
  else
    log "Nothing to install."
  fi
}

### ========= SNAPPER CONFIG ========= ###
snapper_config() {
  log "Installing snap-pac and configuring Snapper..."

  pacman -S --noconfirm snap-pac

  clean-cache

  # Now to configure snapper
  if mountpoint -q /.snapshots; then
    umount /.snapshots
  fi
  rm -rf /.snapshots
  snapper --no-dbus -c root create-config /
  mount /.snapshots
  # mount -o noatime,ssd,compress=zstd,space_cache=v2,discard=async,subvol=@snapshots "$part2" /mnt/.snapshots

  grub-mkconfig -o /boot/grub/grub.cfg  # the rebuild the grub config

  sed -i "s|^TIMELINE_CREATE=.*|TIMELINE_CREATE=\"yes\"|" /etc/snapper/configs/root
  sed -i "s|^TIMELINE_CLEANUP=.*|TIMELINE_CLEANUP=\"yes\"|" /etc/snapper/configs/root
  sed -i "s|^TIMELINE_MIN_AGE=.*|TIMELINE_MIN_AGE=\"3600\"|" /etc/snapper/configs/root
  sed -i "s|^TIMELINE_LIMIT_HOURLY=.*|TIMELINE_LIMIT_HOURLY=\"0\"|" /etc/snapper/configs/root
  sed -i "s|^TIMELINE_LIMIT_DAILY=.*|TIMELINE_LIMIT_DAILY=\"10\"|" /etc/snapper/configs/root  # Only keep 10 daily snaps
  sed -i "s|^TIMELINE_LIMIT_WEEKLY=.*|TIMELINE_LIMIT_WEEKLY=\"0\"|" /etc/snapper/configs/root
  sed -i "s|^TIMELINE_LIMIT_MONTHLY=.*|TIMELINE_LIMIT_MONTHLY=\"0\"|" /etc/snapper/configs/root
  sed -i "s|^TIMELINE_LIMIT_YEARLY=.*|TIMELINE_LIMIT_YEARLY=\"0\"|" /etc/snapper/configs/root

  sed -i "s|^NUMBER_CLEANUP=.*|NUMBER_CLEANUP=\"yes\"|" /etc/snapper/configs/root
  sed -i "s|^NUMBER_MIN_AGE=.*|NUMBER_MIN_AGE=\"3600\"|" /etc/snapper/configs/root
  sed -i "s|^NUMBER_LIMIT=.*|NUMBER_LIMIT=\"20\"|" /etc/snapper/configs/root

  # Those above are only about how many snaps to keep stored,
  # but the timer is still happening hourly by default
  # So to configure the timer we have to edit in systemd
  mkdir -p /etc/systemd/system/snapper-timeline.timer.d
  cat > /etc/systemd/system/snapper-timeline.timer.d/override.conf << 'EOF'
  [Timer]
  OnCalendar=   # this is important
  OnCalendar=daily
  Persistent=true   # trigger the service immediately if it missed last time
EOF
}

### ========= CLEANUP ========= ###
clean-cache() {
  echo "Cleaning cache..."
  # Have to remove pacman cache manually cause it's currently bugged
  # It seems the pacman dev is enjoying a holiday too much to look at it
  rm -rf /var/cache/pacman/pkg/*
  su - "$username" -c '
    (
    echo n
    echo y
    echo y
    ) | yay -Scc
  '
  # The first option needs to be an "n" otherwise buggy pacman throws an error
}  

cleanup() {
  log "Doing cleanup..."

  echo "Enabling pacman cache on /tmp..."
  sed -i 's|^#CacheDir\s*=.*|CacheDir    = /tmp/cache-pacman/pkg/|' /etc/pacman.conf

  echo
  log "Enabling essential services..."
  systemctl enable NetworkManager
  systemctl enable grub-btrfsd
  systemctl enable snapper-timeline.timer snapper-cleanup.timer

  echo "Restoring sudo to password-protected mode..."
  rm -f /etc/sudoers.d/99-wheel-nopasswd
}

### ========= SNAPSHOT ========= ###
final_snapshot() {
  log "Creating baseline snapshot..."

  snapper --no-dbus -c root create \
    --description "Baseline: fresh system install" \
    --cleanup-algorithm number

  echo "Baseline snapshot created."

  log "Done. Reboot now."
}

### ========= FLOW CONTROL ========= ###

live_main() {
  base_system
}

chroot_main() {
  shift # remove "chroot"
  user_environment "$@"
  virtualization
  extras
  snapper_config
  cleanup
  final_snapshot
}

main() {
  if [[ "${1:-}" == "chroot" ]]; then
    chroot_main "$@"
  else
    live_main
  fi
}

main "$@"

