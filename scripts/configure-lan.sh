#!/usr/bin/env bash
# Клиенты LAN (lab-pc1..3): запуск, ожидание аренды DHCP от gw, ssh_config с их адресами.
source "$(dirname "$0")/lib.sh"

for pc in "${PCS[@]}"; do
  vm_exists "$PREFIX$pc" && vm_start "$PREFIX$pc"
done

for pc in "${PCS[@]}"; do
  vm_exists "$PREFIX$pc" || continue
  log "Жду аренду DHCP для $pc"
  ip=""
  for _ in $(seq 1 60); do
    ip=$(pc_ip "$pc" || true)
    [ -n "$ip" ] && break
    sleep 5
  done
  [ -n "$ip" ] || die "$pc не получил адрес по DHCP"
  log "$pc → $ip"
done

write_ssh_config

for pc in "${PCS[@]}"; do
  vm_exists "$PREFIX$pc" || continue
  wait_ssh 300 lssh "$pc" || die "SSH на $pc недоступен"
  push lssh "$pc" -- "$LAB_ROOT/lan/netplan.yaml" /tmp/lab/10-lab-$pc.yaml 0600
  lssh "$pc" "sudo bash -s" <<EOF
set -e
if ! cmp -s /tmp/lab/10-lab-$pc.yaml /etc/netplan/10-lab-$pc.yaml; then
  install -m 0600 /tmp/lab/10-lab-$pc.yaml /etc/netplan/10-lab-$pc.yaml
  netplan apply
fi
echo "--- $pc: \$(ip -br -4 addr | grep -v '^lo')  default via \$(ip route show default | awk '{print \$3}')"
EOF
done
log "Клиенты LAN готовы"
