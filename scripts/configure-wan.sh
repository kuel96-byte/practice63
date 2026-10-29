#!/usr/bin/env bash
# lab-wan: тестовый внешний хост в host-only сети (192.168.56.20) с маршрутами в LAN/DMZ через gw.
source "$(dirname "$0")/lib.sh"
VM=${PREFIX}wan

vm_exists "$VM" || { log "$VM нет — пропускаю"; exit 0; }
vm_start "$VM"
write_ssh_config
wait_ssh 600 lssh wan || die "SSH на wan недоступен"
push lssh wan -- "$LAB_ROOT/wan/netplan.yaml" /tmp/lab/10-lab-wan.yaml 0600
lssh wan 'sudo bash -s' <<'EOF'
set -e
if ! cmp -s /tmp/lab/10-lab-wan.yaml /etc/netplan/10-lab-wan.yaml; then
  install -m 0600 /tmp/lab/10-lab-wan.yaml /etc/netplan/10-lab-wan.yaml
  netplan apply
fi
ip -br -4 addr | grep -v '^lo'; ip route
EOF
log "wan настроен"
