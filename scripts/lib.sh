#!/usr/bin/env bash
# Общие переменные и функции для всех скриптов лабы.
# Работает и из WSL2, и из Git Bash (MSYS) на Windows.
set -euo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="lab-"

# --- VBoxManage и перевод путей в Windows-формат --------------------------
if grep -qi microsoft /proc/version 2>/dev/null; then
  LAB_ENV=wsl
  VBOX_DEFAULT="/mnt/c/Program Files/Oracle/VirtualBox/VBoxManage.exe"
  winpath() { wslpath -w "$1"; }
  WIN_HOME="$(wslpath "$(cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')")"
else
  LAB_ENV=msys
  VBOX_DEFAULT="/c/Program Files/Oracle/VirtualBox/VBoxManage.exe"
  winpath() { cygpath -w "$1"; }
  WIN_HOME="$(cygpath "$USERPROFILE")"
fi
VBOX="${VBOXMANAGE:-$VBOX_DEFAULT}"
# MSYS_NO_PATHCONV: Git Bash не должен «переводить» аргументы вида /root.
vbox() { MSYS_NO_PATHCONV=1 "$VBOX" "$@"; }

# Рабочий каталог для сгенерированных файлов (ASCII-путь, вне репозитория).
LAB_WORK="${LAB_WORK:-$WIN_HOME/.lab-dmz}"
mkdir -p "$LAB_WORK"

# ISO Ubuntu Live Server: можно переопределить LAB_ISO=/путь/к.iso
LAB_ISO="${LAB_ISO:-$(ls "$WIN_HOME"/Downloads/ubuntu-*live-server-amd64.iso 2>/dev/null | sort | tail -1 || true)}"

# --- Учебные учётные данные ----------------------------------------------
LAB_USER=student
LAB_PASS=student

# --- SSH ------------------------------------------------------------------
SSH_KEY="$HOME/.ssh/lab-dmz_ed25519"
SSH_CFG="$LAB_WORK/ssh_config"
SSH_KNOWN="$HOME/.ssh/lab-dmz_known_hosts"

# --- Адресный план и MAC-адреса (фиксированные, на них завязан netplan) ----
GW_EXT_IP=192.168.56.10
HOST_IP=192.168.56.1
WAN_TEST_IP=192.168.56.20
LAN_NET=192.168.10.0/24
DMZ_SRV_IP=172.16.20.10

declare -A MAC=(
  [gw-wan]=080027AA0101 [gw-ext]=080027AA0102 [gw-lan]=080027AA0103 [gw-dmz]=080027AA0104
  [dmz-srv]=080027AA0201
  [pc1]=080027AA0301 [pc2]=080027AA0401 [pc3]=080027AA0501
  [wan]=080027AA0601
)
# Порт временного port forward на NAT-адаптере для первичной настройки клона.
declare -A BOOT_PORT=( [gw]=2210 [dmz-srv]=2220 [pc1]=2231 [pc2]=2232 [pc3]=2233 [wan]=2240 )

PCS=(pc1 pc2 pc3)

# Ресурсы итоговые: роль → "cpus memoryMB"
declare -A RES=( [gw]="1 1024" [dmz-srv]="1 2048" [pc1]="1 1024" [pc2]="1 1024" [pc3]="1 1024" [wan]="1 1024" )
# Роли, которые ставятся с ISO (остальные — linked clones lab-pc1)
INSTALL_ROLES=(gw dmz-srv pc1)
CLONE_ROLES=(pc2 wan)

log()  { printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '\033[1;31mОШИБКА:\033[0m %s\n' "$*" >&2; exit 1; }

mac_colon() { echo "$1" | sed 's/../&:/g;s/:$//' | tr 'A-F' 'a-f'; }

vm_exists()  { vbox showvminfo "$1" >/dev/null 2>&1; }
vm_state()   { vbox showvminfo "$1" --machinereadable 2>/dev/null | sed -n 's/^VMState="\(.*\)"/\1/p'; }
vm_running() { [ "$(vm_state "$1")" = running ]; }

vm_start() {
  vm_running "$1" || vbox startvm "$1" --type headless >/dev/null
}

# Корректное выключение через ACPI, по таймауту — жёсткое.
vm_stop() {
  local vm=$1 i
  vm_running "$vm" || return 0
  vbox controlvm "$vm" acpipowerbutton 2>/dev/null || true
  for i in $(seq 1 60); do
    vm_running "$vm" || return 0
    sleep 2
  done
  vbox controlvm "$vm" poweroff >/dev/null 2>&1 || true
  sleep 2
}


# Ждём выключения VM и освобождения её сессии (иначе modifyvm падает с "locked")
wait_poweroff() {
  local vm=$1 timeout=${2:-3600} t=0
  until [[ "$(vm_state "$vm")" =~ ^(poweroff|aborted)$ ]]; do
    sleep 5; t=$((t + 5))
    [ $t -ge "$timeout" ] && die "$vm не выключилась за ${timeout}s"
  done
  sleep 3   # VBoxSVC отпускает блокировку сессии не мгновенно
  return 0
}

# --- SSH-обёртки ------------------------------------------------------------
SSH_BOOT_OPTS=(-i "$SSH_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no
               -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5
               -o BatchMode=yes)

# ssh к клону через временный port forward 127.0.0.1:<port>
boot_ssh() { local port=$1; shift; ssh "${SSH_BOOT_OPTS[@]}" -p "$port" "$LAB_USER@127.0.0.1" "$@"; }

# ssh к хостам лабы по сгенерированному ssh_config (gw напрямую, остальные через ProxyJump gw)
lssh() { ssh -F "$SSH_CFG" "$@"; }

wait_ssh() { # wait_ssh <timeout> <команда ssh...>
  local timeout=$1; shift
  local t=0
  until "$@" true 2>/dev/null; do
    sleep 5; t=$((t + 5))
    [ $t -ge "$timeout" ] && return 1
  done
  return 0
}

# Скопировать локальный файл на хост: push <ssh-cmd...> -- <local> <remote> [mode]
push() {
  local args=()
  while [ "$1" != "--" ]; do args+=("$1"); shift; done; shift
  local src=$1 dst=$2 mode=${3:-0644}
  "${args[@]}" "sudo install -D -m $mode /dev/stdin '$dst'" < "$src"
}

# IP клиента LAN по MAC из таблицы аренд dnsmasq на gw
pc_ip() {
  local mac; mac=$(mac_colon "${MAC[$1]}")
  lssh gw "awk -v m='$mac' '\$2==m{print \$3}' /var/lib/misc/dnsmasq.leases" 2>/dev/null | tail -1
}

# Генерация ssh_config лабы (IP клиентов LAN берутся из аренд DHCP)
write_ssh_config() {
  local pc ip
  {
    cat <<EOF
# Сгенерировано scripts/lib.sh (write_ssh_config). Лаба lab-dmz.
Host gw lab-gw
  HostName $GW_EXT_IP
Host dmz-srv lab-dmz-srv
  HostName $DMZ_SRV_IP
  ProxyJump gw
Host wan lab-wan
  HostName $WAN_TEST_IP
EOF
    for pc in "${PCS[@]}"; do
      vm_exists "$PREFIX$pc" || continue
      ip=$(pc_ip "$pc" || true)
      [ -n "$ip" ] || continue
      printf 'Host %s lab-%s\n  HostName %s\n  ProxyJump gw\n' "$pc" "$pc" "$ip"
    done
    cat <<EOF
Host gw lab-gw dmz-srv lab-dmz-srv wan lab-wan pc* lab-pc*
  User $LAB_USER
  IdentityFile $SSH_KEY
  IdentitiesOnly yes
  UserKnownHostsFile $SSH_KNOWN
  StrictHostKeyChecking accept-new
  ConnectTimeout 8
  ServerAliveInterval 15
  LogLevel ERROR
EOF
  } > "$SSH_CFG.tmp"
  mv "$SSH_CFG.tmp" "$SSH_CFG"
  # Копия в ~/.ssh и Include в ~/.ssh/config, чтобы работало `ssh gw`, `ssh pc1`.
  cp "$SSH_CFG" "$HOME/.ssh/lab-dmz.conf"
  touch "$HOME/.ssh/config"
  if ! grep -q '^Include lab-dmz.conf' "$HOME/.ssh/config"; then
    { echo 'Include lab-dmz.conf'; echo; cat "$HOME/.ssh/config"; } > "$HOME/.ssh/config.lab-tmp"
    mv "$HOME/.ssh/config.lab-tmp" "$HOME/.ssh/config"
  fi
}

ensure_ssh_key() {
  [ -f "$SSH_KEY" ] || ssh-keygen -q -t ed25519 -N '' -C "lab-dmz" -f "$SSH_KEY"
}
