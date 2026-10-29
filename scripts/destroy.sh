#!/usr/bin/env bash
# Удаляет ТОЛЬКО VM этой лабы (имя начинается с "lab-"), с подтверждением.
# Клоны удаляются раньше базовых VM (linked clones зависят от снапшотов).
# Флаг -y — без вопроса.
source "$(dirname "$0")/lib.sh"

mapfile -t VMS < <(vbox list vms | tr -d '\r' | sed -n "s/^\"\($PREFIX[^\"]*\)\".*/\1/p")
[ ${#VMS[@]} -gt 0 ] || { log "VM с префиксом $PREFIX нет"; exit 0; }

echo "Будут УДАЛЕНЫ VM вместе с дисками:"
printf '  %s\n' "${VMS[@]}"
if [ "${1:-}" != "-y" ]; then
  read -r -p "Продолжить? [y/N] " ans
  [[ "$ans" =~ ^[YyДд]$ ]] || { echo "Отменено"; exit 1; }
fi

# порядок: linked clones lab-pc1 (pc2.., wan) → прочие → lab-pc1 (у неё снапшот-источник)
order=()
for vm in "${VMS[@]}"; do [[ $vm =~ ^${PREFIX}(pc[2-9]|wan)$ ]] && order+=("$vm"); done
for vm in "${VMS[@]}"; do [[ $vm =~ ^${PREFIX}(pc[2-9]|wan|pc1)$ ]] || order+=("$vm"); done
for vm in "${VMS[@]}"; do [ "$vm" = "${PREFIX}pc1" ] && order+=("$vm"); done

for vm in "${order[@]}"; do
  log "Удаляю $vm"
  vbox controlvm "$vm" poweroff >/dev/null 2>&1 || true
  sleep 1
  vbox unregistervm "$vm" --delete >/dev/null
done
rm -f "$SSH_KNOWN"
log "Готово"
