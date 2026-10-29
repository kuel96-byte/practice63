#!/usr/bin/env bash
# Создаёт (или берёт существующие) VM lab-gw, lab-dmz-srv, lab-pc1 и параллельно ставит на них
# Ubuntu Live Server через `VBoxManage unattended install` (autoinstall, без GUI, openssh-server).
# На время установки у каждой VM один адаптер NAT (с итоговым MAC nic1) — для пакетов из сети.
# Итоговые адаптеры выставляет scripts/bootstrap-vms.sh.
source "$(dirname "$0")/lib.sh"

DISK_MB=15360
"$VBOX" --version >/dev/null || die "VBoxManage не найден: $VBOX"
log "VirtualBox $("$VBOX" --version | tr -d '\r')"
[ -f "$LAB_ISO" ] || die "ISO Ubuntu Live Server не найден (~/Downloads/ubuntu-*live-server-amd64.iso или LAB_ISO)"
log "ISO: $LAB_ISO"

ensure_ssh_key
PUBKEY=$(cat "$SSH_KEY.pub")
sed "s|__LAB_PUBKEY__|$PUBKEY|g" "$LAB_ROOT/scripts/autoinstall/user-data.tmpl" > "$LAB_WORK/user-data.tmpl"

declare -A NIC1_MAC=( [gw]=${MAC[gw-wan]} [dmz-srv]=${MAC[dmz-srv]} [pc1]=${MAC[pc1]} )

vm_dir() { # каталог VM по пути к .vbox
  local cfg
  cfg=$(vbox showvminfo "$1" --machinereadable | sed -n 's/^CfgFile="\(.*\)"\r*$/\1/p' | sed 's/\\\\/\\/g')
  echo "${cfg%\\*}"
}

# Установка идёт: подключён вспомогательный ISO unattended
installing() { vbox showvminfo "$1" --machinereadable | grep -q '^"IDE-[0-9]-[0-9]"=".*Unattended-'; }

# ОС уже стоит: диск не пустой и носители установки отключены
installed() {
  local f
  installing "$1" && return 1
  f=$(vbox showvminfo "$1" --machinereadable | sed -n 's/^"SATA-0-0"="\(.*\)"\r*$/\1/p' | sed 's/\\\\/\\/g')
  [ -n "$f" ] || return 1
  [ "$(stat -c %s "$(if [ $LAB_ENV = wsl ]; then wslpath "$f"; else cygpath "$f"; fi)")" -gt 500000000 ]
}

prepare() { # prepare <role>
  local role=$1 vm=$PREFIX$1 dir
  if ! vm_exists "$vm"; then
    log "Создаю $vm"
    vbox createvm --name "$vm" --ostype Ubuntu_64 --register --default >/dev/null
    dir=$(vm_dir "$vm")
    vbox createmedium disk --filename "$dir\\$vm.vdi" --size $DISK_MB --format VDI >/dev/null
    vbox storagectl "$vm" --name SATA --remove 2>/dev/null || true
    vbox storagectl "$vm" --name SATA --add sata --controller IntelAhci --portcount 1
    vbox storageattach "$vm" --storagectl SATA --port 0 --device 0 --type hdd --medium "$dir\\$vm.vdi"
    vbox storagectl "$vm" --name IDE --add ide 2>/dev/null || true
  else
    log "$vm уже есть — использую её"
    [ "$(vm_state "$vm")" = running ] && vbox controlvm "$vm" poweroff >/dev/null 2>&1 && sleep 2
  fi
  # старые носители установки (ISO/aux ISO) — отключить
  for port in 0 1; do for dev in 0 1; do
    vbox storageattach "$vm" --storagectl IDE --port $port --device $dev --medium none 2>/dev/null || true
  done; done
  # На время установки: 1 vCPU (под Hyper-V/NEM стабильнее), 3 GB RAM, только NAT
  vbox modifyvm "$vm" --cpus 1 --memory 3072 --vram 16 --graphicscontroller vmsvga \
    --audio-enabled off --usb-ohci off --usb-ehci off --usb-xhci off --rtc-use-utc on \
    --boot1 dvd --boot2 disk --boot3 none --boot4 none \
    --nic1 nat --nictype1 82540EM --macaddress1 "${NIC1_MAC[$role]}" --cableconnected1 on \
    --nic2 none --nic3 none --nic4 none
}

todo=()
for role in "${INSTALL_ROLES[@]}"; do
  vm=$PREFIX$role
  if vm_exists "$vm" && installed "$vm"; then log "$vm: ОС уже установлена — пропускаю"; continue; fi
  if vm_exists "$vm" && vm_running "$vm" && installing "$vm"; then
    log "$vm: установка уже идёт — жду"; todo+=("$vm"); continue
  fi
  prepare "$role"
  log "$vm: запускаю unattended install"
  vbox unattended install "$vm" \
    --iso="$(winpath "$LAB_ISO")" \
    --user="$LAB_USER" --user-password="$LAB_PASS" --full-user-name="Lab Student" \
    --hostname="$role.lab.local" --locale=en_US --country=US --time-zone=UTC \
    --script-template="$(winpath "$LAB_WORK/user-data.tmpl")" \
    --start-vm=headless >/dev/null
  todo+=("$vm")
done

for vm in "${todo[@]}"; do
  log "Жду окончания установки $vm (autoinstall выключит VM)"
  wait_poweroff "$vm" 5400
  for port in 0 1; do for dev in 0 1; do
    vbox storageattach "$vm" --storagectl IDE --port $port --device $dev --medium none 2>/dev/null || true
  done; done
  vbox modifyvm "$vm" --boot1 disk --boot2 none
  log "$vm: установка завершена"
done
log "Установка ОС на ${INSTALL_ROLES[*]} завершена"
