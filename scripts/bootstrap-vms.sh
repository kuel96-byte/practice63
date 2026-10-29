#!/usr/bin/env bash
# Первичная настройка VM после установки ОС и linked clones lab-pc2, lab-wan (от снапшота lab-pc1/clean).
#
# Каждая VM грузится с одним NAT-адаптером и ВРЕМЕННЫМ port forward 127.0.0.1:<порт> → 22.
# Через него: hostname, новый machine-id, новые SSH host keys, netplan роли, отключение cloud-init.
# Затем VM выключается, правило удаляется, выставляются итоговые адаптеры и ресурсы.
source "$(dirname "$0")/lib.sh"

HOSTONLY_IF=$(vbox list hostonlyifs | tr -d '\r' | grep -B10 "IPAddress: *$HOST_IP\$" | sed -n 's/^Name: *//p' | head -1)
if [ -z "$HOSTONLY_IF" ]; then
  log "Host-only сеть 192.168.56.0/24 не найдена — создаю"
  out=$(vbox hostonlyif create | tr -d '\r')
  HOSTONLY_IF=$(echo "$out" | sed -n "s/.*Interface '\(.*\)' was successfully created.*/\1/p")
  vbox hostonlyif ipconfig "$HOSTONLY_IF" --ip "$HOST_IP" --netmask 255.255.255.0
fi
log "Host-only адаптер: $HOSTONLY_IF"

declare -A NIC1_MAC=( [gw]=${MAC[gw-wan]} [dmz-srv]=${MAC[dmz-srv]} [pc1]=${MAC[pc1]} [pc2]=${MAC[pc2]} [pc3]=${MAC[pc3]} [wan]=${MAC[wan]} )
declare -A NETPLAN=( [gw]=gateway/netplan.yaml [dmz-srv]=dmz/netplan.yaml [pc1]=lan/netplan.yaml
                     [pc2]=lan/netplan.yaml [pc3]=lan/netplan.yaml [wan]=wan/netplan.yaml )

# VM уже прошла bootstrap, если у неё выставлены итоговые адаптеры (не NAT на nic1, кроме gw)
done_already() {
  local role=$1 vm=$PREFIX$1 info
  info=$(vbox showvminfo "$vm" --machinereadable | tr -d '\r')
  case $role in
    gw) grep -q '^nic4="intnet"' <<<"$info" ;;
    *)  ! grep -q '^nic1="nat"' <<<"$info" ;;
  esac
}

bootstrap() { # bootstrap <role>
  local role=$1 vm=$PREFIX$1 port=${BOOT_PORT[$1]}
  log "$vm: первичная настройка через 127.0.0.1:$port"
  vm_stop "$vm"
  vbox modifyvm "$vm" --nic1 nat --nictype1 82540EM --macaddress1 "${NIC1_MAC[$role]}" --cableconnected1 on \
    --nic2 none --nic3 none --nic4 none
  vbox modifyvm "$vm" --natpf1 delete boot 2>/dev/null || true
  vbox modifyvm "$vm" --natpf1 "boot,tcp,127.0.0.1,$port,,22"
  vm_start "$vm"
  wait_ssh 900 boot_ssh "$port" || die "$vm: SSH через port forward не поднялся"
  push boot_ssh "$port" -- "$LAB_ROOT/${NETPLAN[$role]}" "/etc/netplan/10-lab-$role.yaml" 0600
  boot_ssh "$port" "sudo bash -s" <<EOF
set -e
hostnamectl set-hostname $role
sed -i '/^127\.0\.1\.1/d' /etc/hosts
echo "127.0.1.1 $role.lab.local $role" >> /etc/hosts
# новый machine-id (важно для клонов: DHCP DUID, journald)
rm -f /etc/machine-id /var/lib/dbus/machine-id
systemd-machine-id-setup >/dev/null
ln -sf /etc/machine-id /var/lib/dbus/machine-id
# новые SSH host keys
rm -f /etc/ssh/ssh_host_*
ssh-keygen -A >/dev/null
# cloud-init своё отработал при первой загрузке; дальше сеть — только наш netplan
touch /etc/cloud/cloud-init.disabled
find /etc/netplan -name '*.yaml' ! -name '10-lab-$role.yaml' -delete
netplan generate
EOF
  boot_ssh "$port" "sudo systemctl poweroff" >/dev/null 2>&1 || true
  wait_poweroff "$vm" 300
  vbox modifyvm "$vm" --natpf1 delete boot
}

final_nics() { # final_nics <role> — итоговые адаптеры и ресурсы
  local role=$1 vm=$PREFIX$1 cpus mem
  read -r cpus mem <<<"${RES[$role]}"
  vbox modifyvm "$vm" --cpus "$cpus" --memory "$mem"
  case $role in
    gw)
      vbox modifyvm "$vm" \
        --nic1 nat      --macaddress1 "${MAC[gw-wan]}" \
        --nic2 hostonly --macaddress2 "${MAC[gw-ext]}" --host-only-adapter2 "$HOSTONLY_IF" \
        --nic3 intnet   --macaddress3 "${MAC[gw-lan]}" --intnet3 lan \
        --nic4 intnet   --macaddress4 "${MAC[gw-dmz]}" --intnet4 dmz
      for i in 2 3 4; do vbox modifyvm "$vm" --nictype$i 82540EM --cableconnected$i on; done ;;
    dmz-srv) vbox modifyvm "$vm" --nic1 intnet --intnet1 dmz --macaddress1 "${MAC[dmz-srv]}" ;;
    pc*)     vbox modifyvm "$vm" --nic1 intnet --intnet1 lan --macaddress1 "${MAC[$role]}" ;;
    wan)     vbox modifyvm "$vm" --nic1 hostonly --host-only-adapter1 "$HOSTONLY_IF" --macaddress1 "${MAC[wan]}" ;;
  esac
  log "$vm: итоговые адаптеры, $cpus vCPU / $mem MB"
}

# Аргументы — роли для bootstrap (например: gw). Без аргументов — все + клоны.
ROLES=("$@")
[ $# -gt 0 ] || ROLES=("${INSTALL_ROLES[@]}" "${CLONE_ROLES[@]}")
want() { [[ " ${ROLES[*]} " == *" $1 "* ]]; }

for role in "${INSTALL_ROLES[@]}"; do
  want "$role" || continue
  vm_exists "$PREFIX$role" || die "Нет $PREFIX$role — сначала scripts/create-vms.sh"
  if done_already "$role"; then log "$PREFIX$role: bootstrap уже выполнен"; continue; fi
  bootstrap "$role"
  if [ "$role" = pc1 ]; then
    vbox snapshot "${PREFIX}pc1" delete clean >/dev/null 2>&1 || true
    vbox snapshot "${PREFIX}pc1" take clean --description "pc1 после первичной настройки (источник linked clones)" >/dev/null
  fi
  final_nics "$role"
done

# linked clones от lab-pc1/clean: второй клиент LAN и тестовый «внешний» хост
for role in "${CLONE_ROLES[@]}"; do
  want "$role" || continue
  vm=$PREFIX$role
  if vm_exists "$vm"; then
    done_already "$role" && { log "$vm: уже готова"; continue; }
  else
    log "Клонирую $vm из lab-pc1/clean (linked clone)"
    vbox clonevm "${PREFIX}pc1" --snapshot clean --options link --name "$vm" --register >/dev/null
  fi
  bootstrap "$role"
  final_nics "$role"
done

log "VM готовы: $(vbox list vms | tr -d '\r' | grep -o "\"$PREFIX[^\"]*\"" | tr '\n' ' ')"
