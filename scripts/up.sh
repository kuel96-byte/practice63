#!/usr/bin/env bash
# Поднять лабу с нуля одной командой: установка ОС → bootstrap/клоны → настройка → тесты.
# Повторный запуск безопасен: готовые шаги пропускаются, конфиги переприменяются.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"

bash "$D/create-vms.sh"
bash "$D/bootstrap-vms.sh"
bash "$D/configure-gw.sh"
bash "$D/configure-dmz.sh"
bash "$D/configure-lan.sh"
bash "$D/configure-wan.sh"
bash "$D/../tests/check.sh" --reboot-gw
