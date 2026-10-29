#!/usr/bin/env bash
# Настройка lab-dmz-srv: статический IP, Docker + docker compose, nginx в контейнере.
# Всё ставится из DMZ через gw — это заодно проверка правила DMZ → интернет (DNS/HTTP/HTTPS).
source "$(dirname "$0")/lib.sh"
VM=${PREFIX}dmz-srv

vm_start "$VM"
write_ssh_config
log "Жду SSH на dmz-srv (через gw)"
wait_ssh 600 lssh dmz-srv || die "SSH на dmz-srv недоступен"

push lssh dmz-srv -- "$LAB_ROOT/dmz/netplan.yaml"        /tmp/lab/10-lab-dmz-srv.yaml 0600
push lssh dmz-srv -- "$LAB_ROOT/dmz/docker-compose.yml"  /opt/dmz-web/docker-compose.yml
push lssh dmz-srv -- "$LAB_ROOT/dmz/index.html"          /opt/dmz-web/html/index.html

lssh dmz-srv 'sudo bash -s' <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if ! cmp -s /tmp/lab/10-lab-dmz-srv.yaml /etc/netplan/10-lab-dmz-srv.yaml; then
  install -m 0600 /tmp/lab/10-lab-dmz-srv.yaml /etc/netplan/10-lab-dmz-srv.yaml
  netplan apply
fi

if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  apt-get update -qq
  # Docker из репозитория Ubuntu (docker.io + плагин compose v2)
  apt-get install -y -qq docker.io docker-compose-v2 >/dev/null
fi
systemctl enable --now docker.service >/dev/null 2>&1
usermod -aG docker student

cd /opt/dmz-web
docker compose pull -q
docker compose up -d
sleep 2
docker compose ps
curl -fsS http://127.0.0.1/ | grep -o 'DMZ web server (dmz-srv)'
EOF
log "dmz-srv настроен"
