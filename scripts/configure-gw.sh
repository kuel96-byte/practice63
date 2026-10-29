#!/usr/bin/env bash
# Настройка lab-gw: netplan, sysctl (forwarding, rp_filter), nftables (NAT + firewall), dnsmasq (DHCP/DNS в LAN).
source "$(dirname "$0")/lib.sh"
VM=${PREFIX}gw

ensure_ssh_key
vm_start "$VM"
write_ssh_config
log "Жду SSH на gw ($GW_EXT_IP)"
wait_ssh 600 lssh gw || die "SSH на gw недоступен"

log "Копирую конфиги на gw"
push lssh gw -- "$LAB_ROOT/gateway/netplan.yaml"   /tmp/lab/10-lab-gw.yaml 0600
push lssh gw -- "$LAB_ROOT/gateway/sysctl.conf"    /etc/sysctl.d/99-lab-gw.conf
push lssh gw -- "$LAB_ROOT/gateway/nftables.conf"  /etc/nftables.conf 0755
push lssh gw -- "$LAB_ROOT/gateway/dnsmasq.conf"   /etc/dnsmasq.d/lab.conf

lssh gw 'sudo bash -s' <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# netplan: применяем, только если файл изменился
if ! cmp -s /tmp/lab/10-lab-gw.yaml /etc/netplan/10-lab-gw.yaml; then
  install -m 0600 /tmp/lab/10-lab-gw.yaml /etc/netplan/10-lab-gw.yaml
  netplan apply
fi

sysctl --system >/dev/null

# ufw из образа не нужен — firewall только nftables
systemctl disable --now ufw.service 2>/dev/null || true

apt-get update -qq
apt-get install -y -qq nftables dnsmasq >/dev/null

# nftables: проверка синтаксиса, затем загрузка и автозапуск
nft -c -f /etc/nftables.conf
systemctl enable nftables.service >/dev/null 2>&1
systemctl restart nftables.service

# dnsmasq: только наш конфиг
systemctl enable dnsmasq.service >/dev/null 2>&1
systemctl restart dnsmasq.service

echo "--- gw: адреса"; ip -br -4 addr
echo "--- gw: forwarding=$(sysctl -n net.ipv4.ip_forward) rp_filter(all)=$(sysctl -n net.ipv4.conf.all.rp_filter)"
echo "--- gw: nftables $(systemctl is-active nftables) / dnsmasq $(systemctl is-active dnsmasq)"
EOF
log "gw настроен"
