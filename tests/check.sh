#!/usr/bin/env bash
# Проверка матрицы доступа лабы. Запускается с хоста (WSL или Git Bash), ходит по VM через SSH.
#   tests/check.sh              — один прогон
#   tests/check.sh --reboot-gw  — прогон, перезагрузка gw, повторный прогон
# Код возврата 0 — все проверки PASS.
source "$(dirname "$0")/../scripts/lib.sh"
set +e

REBOOT=0
[ "${1:-}" = "--reboot-gw" ] && REBOOT=1

PASS=0; FAIL=0
ROWS=()

# t "<описание>" <ожидание OK|DENY> <где выполнить: host|gw|pc1|...> <команда>
# Команда должна вернуть 0, если доступ/функция есть, и не 0, если нет.
t() {
  local desc=$1 exp=$2 where=$3 cmd=$4 got res
  if [ "$where" = host ]; then
    bash -c "$cmd" >/dev/null 2>&1
  else
    lssh "$where" "$cmd" >/dev/null 2>&1 </dev/null
  fi
  [ $? -eq 0 ] && got=OK || got=DENY
  if [ "$got" = "$exp" ]; then res=PASS; PASS=$((PASS+1)); else res=FAIL; FAIL=$((FAIL+1)); fi
  ROWS+=("$(printf '%-3s|%-62s|%-5s|%-5s|%s' "${#ROWS[@]}" "$desc" "$exp" "$got" "$res")")
  printf '  %-62s ожидалось %-5s получено %-5s %s\n' "$desc" "$exp" "$got" \
    "$([ $res = PASS ] && printf '\033[32mPASS\033[0m' || printf '\033[31mFAIL\033[0m')"
}

# Баннер SSH на ip:22 (сам SSH-логин не нужен — проверяем, что TCP/22 доступен и отвечает sshd)
ssh_banner() { echo "timeout 6 bash -c 'exec 3<>/dev/tcp/$1/22; head -c4 <&3' | grep -q '^SSH-'"; }
tcp_open()   { echo "nc -z -w4 $1 $2"; }
http_ok()    { echo "curl -fsS -m6 http://$1/ | grep -q 'DMZ web server (dmz-srv)'"; }
pingc()      { echo "ping -c2 -W2 $1"; }

# Пропускает ли ICMP в интернет сам хост
host_icmp_ok() {
  if [ "$LAB_ENV" = msys ]; then ping -n 2 -w 2000 8.8.8.8 | grep -q 'TTL='; else ping -c2 -W2 8.8.8.8 >/dev/null 2>&1; fi
}

# Проверка, которую в этом окружении выполнить нельзя (не считается ни PASS, ни FAIL)
skip() {
  ROWS+=("$(printf '%-3s|%-62s|%-5s|%-5s|%s' "${#ROWS[@]}" "$1" "OK" "—" "SKIP: $2")")
  printf '  %-62s \033[33mSKIP\033[0m (%s)\n' "$1" "$2"
}

run_suite() {
  local title=$1
  PASS=0; FAIL=0; ROWS=()
  echo
  echo "=================== $title ==================="

  write_ssh_config
  PC1=$(pc_ip pc1); PC2=$(pc_ip pc2)
  echo "  pc1=$PC1  pc2=${PC2:-нет}"

  echo "--- gw: сервисы и ядро"
  t "gw: nftables.service enabled+active"                OK gw "systemctl is-enabled nftables && systemctl is-active nftables"
  t "gw: ruleset загружен (policy drop, лог nft-drop:)"  OK gw "sudo nft list chain inet filter forward | grep -q 'policy drop' && sudo nft list ruleset | grep -q 'nft-drop:'"
  t "gw: ip_forward=1 (sysctl.d)"                        OK gw "[ \$(sysctl -n net.ipv4.ip_forward) = 1 ]"
  t "gw: rp_filter strict на всех интерфейсах"           OK gw "for f in /proc/sys/net/ipv4/conf/{all,wan0,ext0,lan0,dmz0}/rp_filter; do [ \$(cat \$f) = 1 ] || exit 1; done"
  t "gw: DHCP (dnsmasq) слушает только lan0"             OK gw "systemctl is-active dnsmasq && sudo ss -ulpn 'sport = :67' | grep dnsmasq | grep -q '%lan0' && ! sudo ss -ulpn 'sport = :67' | grep dnsmasq | grep -vq '%lan0'"

  echo "--- LAN: DHCP, интернет, DNS"
  t "pc1: адрес по DHCP из пула .100-.200"               OK pc1 "ip -4 -o addr show scope global | grep -q dynamic && ip -4 -o addr show scope global | grep -Eq 'inet 192\.168\.10\.(1[0-9][0-9]|200)/24'"
  t "pc1: шлюз и DNS получены по DHCP (192.168.10.1)"    OK pc1 "ip route show default | grep -q 'via 192.168.10.1' && resolvectl dns | grep -q 192.168.10.1"
  # ICMP в интернет из VM возможен, только если его пропускает сам хост (VirtualBox NAT шлёт ping от имени хоста)
  if host_icmp_ok; then
    t "pc1 -> ping 8.8.8.8 (SNAT)"                       OK pc1 "$(pingc 8.8.8.8)"
  else
    skip "pc1 -> ping 8.8.8.8 (SNAT)" "сам хост не пингует 8.8.8.8 (ICMP режет VPN/сеть хоста)"
  fi
  t "pc1 -> ping 10.0.2.2 (шлюз VirtualBox NAT, ICMP через SNAT)" OK pc1 "$(pingc 10.0.2.2)"
  t "pc1 -> 8.8.8.8 tcp/53 (интернет через SNAT)"        OK pc1 "$(tcp_open 8.8.8.8 53)"
  t "pc1 -> DNS: резолв ubuntu.com"                      OK pc1 "getent hosts ubuntu.com"
  t "pc1 -> https://ubuntu.com (интернет)"               OK pc1 "curl -fsS -m10 -o /dev/null https://ubuntu.com"

  echo "--- LAN -> DMZ / gw"
  t "pc1 -> http://172.16.20.10"                         OK pc1 "$(http_ok 172.16.20.10)"
  t "pc1 -> http://192.168.56.10 (DNAT + hairpin)"       OK pc1 "$(http_ok 192.168.56.10)"
  t "pc1 -> ssh dmz-srv (172.16.20.10:22)"               OK pc1 "$(ssh_banner 172.16.20.10)"
  t "pc1 -> ping dmz-srv"                                OK pc1 "$(pingc 172.16.20.10)"
  t "pc1 -> ssh gw (192.168.10.1:22)"                    OK pc1 "$(ssh_banner 192.168.10.1)"
  t "pc1 -> dmz-srv tcp/443 (не разрешён)"               DENY pc1 "$(tcp_open 172.16.20.10 443)"

  echo "--- DMZ -> LAN (всё запрещено)"
  # слушатель на pc1:8080, чтобы отличить «закрыт порт» от «режет firewall»
  lssh pc1 "sudo systemd-run --quiet --collect --unit=lab-listener timeout 300 python3 -m http.server 8080 --bind 0.0.0.0" >/dev/null 2>&1
  sleep 2
  [ -n "$PC2" ] && t "контроль: pc2 -> pc1 tcp/8080 (внутри LAN)" OK pc2 "$(tcp_open "$PC1" 8080)"
  t "dmz-srv -> ping pc1"                                DENY dmz-srv "$(pingc "$PC1")"
  t "dmz-srv -> ssh pc1"                                 DENY dmz-srv "$(ssh_banner "$PC1")"
  t "dmz-srv -> pc1 tcp/8080 (слушатель запущен)"        DENY dmz-srv "$(tcp_open "$PC1" 8080)"
  t "dmz-srv -> pc1 tcp/80,443,3389,445"                 DENY dmz-srv "for p in 80 443 3389 445; do nc -z -w2 $PC1 \$p && exit 0; done; exit 1"
  t "dmz-srv -> ssh gw (172.16.20.1:22)"                 DENY dmz-srv "$(ssh_banner 172.16.20.1)"
  lssh pc1 "sudo systemctl stop lab-listener" >/dev/null 2>&1
  t "gw: в журнале есть nft-drop: dmz->lan"              OK gw "sudo journalctl -k --since '-15min' | grep -q 'nft-drop: dmz->lan'"

  echo "--- DMZ -> интернет (только DNS/HTTP/HTTPS)"
  t "dmz-srv -> DNS: резолв archive.ubuntu.com"          OK dmz-srv "getent hosts archive.ubuntu.com"
  t "dmz-srv -> apt-get update (HTTP/HTTPS)"             OK dmz-srv "sudo timeout 120 apt-get update -qq"
  t "dmz-srv -> https://registry-1.docker.io"            OK dmz-srv "curl -sS -m10 -o /dev/null https://registry-1.docker.io/v2/"
  t "dmz-srv -> github.com:22 (не разрешён)"             DENY dmz-srv "$(tcp_open github.com 22)"
  t "dmz-srv -> ping 8.8.8.8 (не разрешён)"              DENY dmz-srv "$(pingc 8.8.8.8)"
  t "dmz-srv -> http://192.168.56.10 (hairpin в DMZ)"    OK dmz-srv "$(http_ok 192.168.56.10)"
  t "dmz-srv: контейнер nginx unless-stopped, Up"        OK dmz-srv "[ \"\$(sudo docker inspect -f '{{.HostConfig.RestartPolicy.Name}} {{.State.Running}}' dmz-web)\" = 'unless-stopped true' ]"

  echo "--- WAN (хост Windows и lab-wan) -> внутрь"
  t "host -> http://192.168.56.10 (DNAT)"                OK host "$(http_ok 192.168.56.10)"
  t "host -> ssh gw 192.168.56.10 [LAB-EXCEPTION]"       OK host "ssh -F '$SSH_CFG' gw true </dev/null"
  # По SSH-баннеру, а не по TCP connect: VPN-клиент хоста (TUN) сам принимает любые TCP-соединения
  t "host -> ssh dmz-srv 172.16.20.10 (WAN -> DMZ)"      DENY host "$(ssh_banner 172.16.20.10)"
  if vm_exists "${PREFIX}wan"; then
    t "wan -> http://192.168.56.10 (DNAT)"               OK wan "$(http_ok 192.168.56.10)"
    t "wan -> ssh dmz-srv 172.16.20.10 (маршрут через gw)" DENY wan "$(ssh_banner 172.16.20.10)"
    t "wan -> http://172.16.20.10 напрямую, без DNAT"    DENY wan "$(http_ok 172.16.20.10)"
    t "wan -> ssh pc1"                                   DENY wan "$(ssh_banner "$PC1")"
    t "wan -> ping pc1"                                  DENY wan "$(pingc "$PC1")"
    t "wan -> ssh gw (послабление только для 192.168.56.1)" DENY wan "$(ssh_banner 192.168.56.10)"
    t "wan -> ping gw"                                   DENY wan "$(pingc 192.168.56.10)"
    t "wan -> DNS на gw 192.168.56.10:53"                DENY wan "$(tcp_open 192.168.56.10 53)"
  fi

  echo
  echo "| # | Проверка | Ожидалось | Получено | Итог |"
  echo "|---|---|---|---|---|"
  local r
  for r in "${ROWS[@]}"; do
    IFS='|' read -r n d e g s <<<"$r"
    echo "| $((n+1)) | $(echo "$d" | sed 's/ *$//') | $(echo "$e" | xargs) | $(echo "$g" | xargs) | $(echo "$s" | xargs) |"
  done
  echo
  echo "ИТОГ ($title): PASS=$PASS FAIL=$FAIL"
  [ $FAIL -eq 0 ]
}

run_suite "прогон 1"
rc1=$?
rc2=0
if [ $REBOOT -eq 1 ]; then
  echo
  log "Перезагружаю gw и жду SSH"
  lssh gw "sudo systemctl reboot" >/dev/null 2>&1
  sleep 15
  wait_ssh 300 lssh gw || die "gw не вернулся после перезагрузки"
  log "gw снова доступен: $(lssh gw 'uptime -p')"
  sleep 10   # даём клиентам LAN продлить аренды
  run_suite "после перезагрузки gw"
  rc2=$?
fi
[ $rc1 -eq 0 ] && [ $rc2 -eq 0 ] && { echo "ВСЕ ПРОВЕРКИ ЗЕЛЁНЫЕ"; exit 0; }
echo "ЕСТЬ FAIL"; exit 1
