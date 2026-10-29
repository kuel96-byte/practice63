# lab-dmz — сеть с DMZ, NAT и firewall в Oracle VirtualBox

Маршрутизатор `lab-gw` (nftables: SNAT/DNAT/hairpin + firewall, dnsmasq: DHCP/DNS) разделяет
WAN, LAN (`192.168.10.0/24`) и DMZ (`172.16.20.0/24`). В DMZ — `lab-dmz-srv` с nginx в Docker,
опубликованный наружу через DNAT `192.168.56.10:80`. В LAN — клиенты `lab-pc1`, `lab-pc2` по DHCP.
Для проверок со стороны WAN — тестовый внешний хост `lab-wan` (192.168.56.20).

Подробности: [отчёт](docs/report.md) · [топология и адресный план](docs/topology.md) ·
[решения и обходные пути](docs/decisions.md).

## Учётные данные (учебные)

| Где | Логин | Пароль |
|---|---|---|
| все VM | `student` | `student` (sudo без пароля) |
| SSH с хоста | `student` | ключ `~/.ssh/lab-dmz_ed25519` (создаётся автоматически) |

## Требования

* Windows с Oracle VirtualBox 7.x (проверено на 7.2.20; работает и поверх Hyper-V/NEM).
* Bash: **Git Bash** (проверено полностью) или WSL2 (доступ к VM из WSL проверен) — см. [decisions.md §1–2](docs/decisions.md).
* ISO Ubuntu **Live Server** в `%USERPROFILE%\Downloads\ubuntu-*live-server-amd64.iso`
  (проверено на `ubuntu-26.04.1-live-server-amd64.iso`) или путь в переменной `LAB_ISO`.
* Интернет на хосте (пакеты Ubuntu, образ nginx). ~6 GB RAM, ~20 GB диска.

## Поднять с нуля — одна команда

```bash
bash scripts/up.sh
```

Что делает (каждый шаг можно запускать отдельно, повторный запуск безопасен):

| Шаг | Скрипт | Что происходит |
|---|---|---|
| 1 | `scripts/create-vms.sh` | `lab-gw`, `lab-dmz-srv`, `lab-pc1` (создаёт или берёт существующие): параллельная `VBoxManage unattended install` Ubuntu Server без GUI (~30 мин) |
| 2 | `scripts/bootstrap-vms.sh` | через временный port forward: hostname, machine-id, SSH host keys, netplan; linked clones `lab-pc2`, `lab-wan` от `lab-pc1/clean`; итоговые адаптеры и ресурсы |
| 3 | `scripts/configure-gw.sh` | sysctl, nftables, dnsmasq на gw |
| 4 | `scripts/configure-dmz.sh` | Docker + docker compose, nginx на dmz-srv |
| 5 | `scripts/configure-lan.sh` | запуск клиентов, аренды DHCP, `ssh_config` |
| 6 | `scripts/configure-wan.sh` | тестовый внешний хост `lab-wan` |
| 7 | `tests/check.sh --reboot-gw` | матрица доступа → перезагрузка gw → матрица ещё раз |

## Проверить

```bash
bash tests/check.sh
```

```bash
bash tests/check.sh --reboot-gw
```

Скрипт ходит на VM по SSH и печатает таблицу «ожидалось / получено / PASS-FAIL»;
код возврата 0 — всё зелёное. Последний прогон — в [docs/report.md](docs/report.md#9-вывод-testscheck.sh).

Ручной доступ (скрипты дописывают `Include lab-dmz.conf` в `~/.ssh/config`):

```bash
ssh gw
```

```bash
ssh dmz-srv
```

```bash
ssh pc1
```

Веб-сервер с хоста: <http://192.168.56.10/> → `DMZ web server (dmz-srv)`.

## Разобрать

```bash
bash scripts/destroy.sh
```

Удаляет **только** VM с префиксом `lab-` (с подтверждением; `-y` — без вопроса).
Host-only адаптер VirtualBox не трогается.

## Структура

```
lab-dmz/
├── README.md
├── scripts/      lib.sh (общие функции), up.sh, create-vms.sh, bootstrap-vms.sh,
│                 configure-gw.sh, configure-dmz.sh, configure-lan.sh, configure-wan.sh, destroy.sh,
│                 autoinstall/user-data.tmpl (шаблон autoinstall для VBoxManage unattended)
├── gateway/      nftables.conf, dnsmasq.conf, netplan.yaml, sysctl.conf
├── dmz/          netplan.yaml, docker-compose.yml, index.html
├── lan/          netplan.yaml (клиенты, DHCP)
├── wan/          netplan.yaml (тестовый внешний хост)
├── tests/        check.sh
└── docs/         report.md, topology.md, decisions.md
```
