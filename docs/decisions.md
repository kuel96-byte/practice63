# Принятые решения и обходные пути

Каждое решение — что выбрано и почему. Порядок примерно соответствует ходу работы.

## 1. Окружение: Git Bash на Windows, а не WSL2

**Факт.** Агент фактически работал в Git Bash (MSYS2) на самом Windows-хосте, а не внутри WSL2
(в WSL есть дистрибутив `Ubuntu`, но он был остановлен).

**Решение.** Все скрипты — bash и работают в обоих окружениях. `scripts/lib.sh` определяет среду:

| | WSL2 | Git Bash |
|---|---|---|
| VBoxManage | `/mnt/c/Program Files/Oracle/VirtualBox/VBoxManage.exe` | `/c/Program Files/Oracle/VirtualBox/VBoxManage.exe` |
| перевод путей для VBoxManage | `wslpath -w` | `cygpath -w` |
| домашний каталог Windows | `wslpath "$(cmd.exe /c echo %USERPROFILE%)"` | `cygpath "$USERPROFILE"` |

Путь к VBoxManage можно переопределить переменной `VBOXMANAGE`. Для Git Bash все вызовы идут с
`MSYS_NO_PATHCONV=1`, иначе MSYS «переводит» аргументы вида `/root/...`.

## 2. Доступ к VM: host-only напрямую; про WSL2

Из Git Bash сеть host-only `192.168.56.0/24` доступна напрямую (это сеть самого Windows),
поэтому SSH на gw идёт на `192.168.56.10`, к остальным — `ProxyJump gw`.

**Проверено из WSL2** (дистрибутив `Ubuntu`, режим NAT, сетевые настройки не менялись):
`curl http://192.168.56.10/` возвращает `DMZ web server (dmz-srv)`, SSH-баннер gw на :22 читается.
Windows транслирует трафик WSL, и на gw он приходит с адреса хоста 192.168.56.1 — поэтому
работает и учебное правило SSH (`LAB-EXCEPTION`). Обходной путь (временный port forward или
`guestcontrol`) для постоянного доступа не понадобился; port forward на NAT используется только
при первичной настройке VM (п. 6).

## 2a. VPN на хосте: ICMP наружу и «ложные» TCP-соединения

На хосте работает VPN-клиент с TUN-интерфейсом `happ-default-tun` (маршруты 0/1 и 128/1). Следствия:
* **ICMP в интернет не проходит даже с самого Windows** (`ping 8.8.8.8` — 100% потерь). VirtualBox NAT
  отправляет ping гостей от имени хоста, поэтому `ping 8.8.8.8` из VM в этом окружении невозможен
  при любом firewall. В `tests/check.sh` эта проверка выполняется, только если хост сам пингует 8.8.8.8,
  иначе помечается `SKIP` с причиной. SNAT для ICMP проверяется пингом шлюза VirtualBox NAT `10.0.2.2`
  (пакет уходит через `wan0` с masquerade), выход в интернет — TCP-соединением `8.8.8.8:53` и HTTPS.
* TUN-клиент сам «принимает» любое TCP-соединение (handshake завершается локально), поэтому проверка
  «хост → 172.16.20.10:22» по одному TCP connect давала ложный OK. Проверка переписана на SSH-баннер;
  настоящая проверка WAN → DMZ — с `lab-wan`, где маршрут в DMZ идёт через gw (п. 8).

## 3. Hyper-V (NEM) под VirtualBox

В `VBox.log`: `HM: HMR3Init: Attempting fall back to NEM: AMD-V is not available` — на хосте активен
Hyper-V (WSL2, Docker Desktop), и VirtualBox работает через Windows Hypervisor Platform (NEM).
Это заметно медленнее и менее стабильно, особенно с несколькими vCPU. Отключать Hyper-V нельзя
(это сломает WSL2 и противоречит условию «не менять настройки Windows»). Следствия:
* все VM — 1 vCPU (так и по заданию);
* щедрые таймауты ожидания в скриптах;
* базовая установка — без GUI (см. п. 4).

## 4. Установка ОС: Ubuntu 26.04 Live Server, `VBoxManage unattended install`

**Попытка 1 — Desktop ISO** (`ubuntu-26.04.1-desktop-amd64.iso`, другого сначала не было).
`unattended detect` его распознаёт, но десктопный установщик (`ubuntu-desktop-bootstrap`, snap)
запускается только из графической сессии GNOME. Под NEM live-сессия зависла на инициализации
snap-пакетов (в `VBox.log`: *Guest seems to be unresponsive*), за ~30 минут на диск не записано
ни байта. К тому же результатом была бы десктопная система, а нужна серверная.

**Попытка 2 — debootstrap из live-сессии Desktop ISO** (своими шаблонами `unattended`:
live грузится в multi-user без snapd, cloud-init из seed VirtualBox запускает скрипт с `debootstrap`).
Работало, но `wget` в debootstrap без таймаутов один раз «подвис» на NAT под NEM; в итоге решили
не изобретать установщик.

**Итог — Ubuntu 26.04.1 Live Server ISO** (`ubuntu-26.04.1-live-server-amd64.iso`, скачан пользователем).
`scripts/create-vms.sh` вызывает штатный `VBoxManage unattended install` со своим
`--script-template=scripts/autoinstall/user-data.tmpl` (autoinstall subiquity, основан на шаблоне
VirtualBox): без GUI, `ssh.install-server: true` + ключ лабы, пакеты `curl netcat-openbsd nftables tcpdump python3`,
sudo без пароля, отключённые apt-таймеры, `shutdown: poweroff`. Отдельный seed ISO не понадобился:
seed (user-data на вспомогательном ISO, `ds=nocloud;s=/cdrom/`) формирует сам VirtualBox.
Три установки идут **параллельно** (по 1 vCPU / 3 GB на время установки).

## 5. Свои VM пользователя вместо base + linked clones для всех

Пользователь сам создал `lab-gw`, `lab-dmz-srv`, `lab-pc1` (адаптеры уже были выставлены верно)
и попросил поставить ОС на них. Поэтому:
* ОС ставится на эти три VM (скрипт создаёт их сам, если их нет — сценарий «с нуля» сохраняется);
* **linked clones** используются там, где они реально экономят время: `lab-pc1` → снапшот `clean` →
  `lab-pc2` (второй клиент LAN) и `lab-wan` (тестовый внешний хост). pc3 не делали — по заданию
  LAN можно представить даже одной VM, двух клиентов достаточно для проверки DHCP и трафика внутри LAN;
* в каждой VM (и особенно в клонах) явно: `hostnamectl set-hostname`, новый `machine-id`
  (`systemd-machine-id-setup`), новые SSH host keys (`ssh-keygen -A`).

## 6. Первичная настройка: временный port forward на NAT

У dmz-srv и pc* в итоговой схеме нет прямого доступа с хоста, Guest Additions (для `guestcontrol`)
не ставились. Поэтому каждая VM в `bootstrap-vms.sh` грузится с **одним NAT-адаптером**
(с итоговым MAC nic1) и правилом `natpf1 boot,tcp,127.0.0.1,22xx,,22`. Через него: hostname,
machine-id, host keys, netplan роли, `cloud-init.disabled` (cloud-init отработал первую загрузку —
создал пользователя и ключ — и больше не должен трогать сеть). Затем VM выключается, правило
удаляется, выставляются итоговые адаптеры и ресурсы. Порт-форвард слушает только `127.0.0.1`.

## 7. Имена интерфейсов на gw по MAC

MAC-адреса всех адаптеров заданы явно (`080027AA....`, см. `lib.sh`). netplan на gw находит
интерфейсы по MAC и переименовывает: `wan0` (NAT), `ext0` (host-only), `lan0`, `dmz0`.
Правила nftables читаются как политика зон и не зависят от порядка PCI-устройств.

## 8. Тестовый «внешний» хост lab-wan

Хост Windows не знает маршрутов в 192.168.10.0/24 и 172.16.20.0/24, поэтому проверка
«WAN → ssh dmz-srv» с хоста проходит тривиально (нет маршрута) и ничего не доказывает про firewall.
Добавлена маленькая VM `lab-wan` (192.168.56.20, host-only) с маршрутами в LAN и DMZ **через gw** —
так ведёт себя атакующий в сегменте провайдера. С неё проверяется, что gw режет WAN → LAN/DMZ,
пропускает только DNAT на :80 и что прямой доступ к 172.16.20.10:80 (без DNAT) закрыт.
Проверка с хоста тоже оставлена (как в задании).

## 9. Учебное послабление: SSH на gw с хоста

Правило `iifname "ext0" ip saddr 192.168.56.1 tcp dport 22 accept` помечено
`comment "LAB-EXCEPTION: ..."`. Разрешён **только** адрес хоста Windows, не вся host-only сеть:
`lab-wan` (тоже в host-only) на SSH gw не пускается — это проверяется тестом.

## 10. DNS: LAN через dnsmasq на gw, DMZ — напрямую к публичным резолверам

* LAN получает по DHCP DNS = 192.168.10.1 (dnsmasq на gw, апстрим — то, что gw получил по DHCP на wan0,
  через `/run/systemd/resolve/resolv.conf`; петли нет, т.к. на lan0 DNS не задан).
* dmz-srv использует 1.1.1.1 / 8.8.8.8 через разрешённый «DMZ → интернет: DNS». Так сервер DMZ
  вообще не обращается к сервисам gw (к gw из DMZ разрешён только ping) — меньше поверхность атаки.

## 11. dnsmasq, а не isc-dhcp-server/kea

Один лёгкий демон даёт DHCP и кеширующий DNS для LAN, конфиг на 15 строк. `interface=lan0` +
`bind-dynamic` — слушает только LAN, не конфликтует с systemd-resolved (127.0.0.53) и переживает
появление интерфейса после старта. isc-dhcp-server снят с поддержки, kea избыточен для лабы.
Важно: dnsmasq использует обычный UDP-сокет, поэтому правило input `udp dport 67` на lan0
действительно нужно (isc-dhcpd читал бы raw-сокетом в обход netfilter).

## 12. rp_filter: маска `*`

`/usr/lib/sysctl.d/50-default.conf` (systemd) ставит `net.ipv4.conf.*.rp_filter = 2` для каждого
интерфейса, а ядро применяет `max(all, iface)`. Поэтому одного `all.rp_filter=1` мало — в
`/etc/sysctl.d/99-lab-gw.conf` добавлено `net.ipv4.conf.*.rp_filter = 1` (файл читается позже).
Дополнительно anti-spoofing в nftables (цепочка `antispoof`, hook prerouting, priority raw).

## 13. IPv6

Лаба IPv4-only: на gw `disable_ipv6=1`, во всех netplan `link-local: []`. Таблица `inet filter`
всё равно имеет policy drop и для IPv6.

## 14. Docker на dmz-srv из репозитория Ubuntu

`docker.io` + `docker-compose-v2` из universe: ставятся по HTTP(S) с archive.ubuntu.com
(то есть по тем же правилам «DMZ → интернет»), без добавления стороннего репозитория и ключей.
Образ `nginx:stable-alpine` тянется с Docker Hub по HTTPS.

## 15. Ресурсы

Хост: 16 логических CPU, 32 GB RAM, >800 GB свободно. Итоговые ресурсы по заданию:
gw 1 vCPU / 1 GB, dmz-srv 1 / 2 GB, pc1, pc2, lab-wan по 1 / 1 GB — итого ~6 GB RAM.
Диски 15 GB (dynamic) у установленных VM, у клонов — дифференциальные.
