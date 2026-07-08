#!/usr/bin/env bash
set -euo pipefail

RULES_BASENAME="70-persistent-net-names.rules"
RULES_FILE="/etc/udev/rules.d/$RULES_BASENAME"
MODE="dry-run"
SHOW_PCI=false
SHOW_RULES=true
SCRIPT_NAME="${0##*/}"

# Печатает справку по использованию скрипта.
usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [--dry-run] [--apply] [--rules-file PATH] [-p|--show-pci] [--no-rules] [-h|--help]

Собирает физические PCI сетевые интерфейсы, сортирует их по PCI-адресам
и формирует udev-правила для стабильного переименования.

Схема именования:
  - onboard-интерфейсы, найденные по ID_NET_NAME_ONBOARD: c0p1, c0p2, ...
  - остальные интерфейсы: каждая новая PCI-шина получает c1, c2, ...,
    порты внутри шины получают p1, p2, ...

Правила udev привязываются к PCI-устройству через KERNELS и, если драйвер
определён, через DRIVERS. Если драйвер не удалось определить, правило
формируется только с KERNELS.

Если --rules-file указывает на каталог или оканчивается на '/', правила будут
записаны в файл $RULES_BASENAME внутри этого каталога.

По умолчанию работает в безопасном режиме dry-run и только печатает таблицу
и правила. Для записи правил используйте --apply от root.
EOF
}

while (($#)); do
    case "$1" in
        --dry-run)
            MODE="dry-run"
            ;;
        --apply)
            MODE="apply"
            ;;
        --rules-file)
            [[ $# -ge 2 ]] || { echo "ERROR: --rules-file требует путь" >&2; exit 2; }
            RULES_FILE="$2"
            shift
            ;;
        -p|--show-pci)
            SHOW_PCI=true
            ;;
        --no-rules)
            SHOW_RULES=false
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'ERROR: неизвестный аргумент: %s\n\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done


command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Находит физические сетевые PCI-интерфейсы.
get_interfaces() {
    local iface_path iface

    for iface_path in /sys/class/net/*; do
        [[ -e "$iface_path" ]] || continue
        [[ -L "$iface_path/device" ]] || continue
        iface="${iface_path##*/}"

        case "$iface" in
            lo|vlan*|virbr*|docker*|br*|vmnet*|veth*|tun*|tap*|wl*|bonding_masters|fwbr*|fwln*|ovs*|vmbr*)
                continue
                ;;
        esac

        printf '%s\n' "$iface"
    done
}

# PCI-адрес (домен:шина:устройство.функция) → числовой ключ для сортировки (невалидный уходит в конец).
pci_sort_key() {
    local pci="$1"

    if [[ "$pci" =~ ^([0-9A-Fa-f]{4}):([0-9A-Fa-f]{2}):([0-9A-Fa-f]{2})\.([0-7])$ ]]; then
        printf '%05d:%03d:%03d:%02d' \
            "$((16#${BASH_REMATCH[1]}))" \
            "$((16#${BASH_REMATCH[2]}))" \
            "$((16#${BASH_REMATCH[3]}))" \
            "${BASH_REMATCH[4]}"
    else
        printf '99999:999:999:99'
    fi
}

# Группировка портов одной физической карты для схемы cN в build_plan
pci_bus_key() {
    local pci="$1"

    if [[ "$pci" =~ ^([0-9A-Fa-f]{4}):([0-9A-Fa-f]{2}):([0-9A-Fa-f]{2})\.([0-7])$ ]]; then
        printf '%s:%s' "${BASH_REMATCH[1],,}" "${BASH_REMATCH[2],,}"
    else
        printf 'unknown'
    fi
}

# Делает короткое описание PCI-адреса для таблицы.
pci_short() {
    local pci="$1"

    if [[ "$pci" =~ ^[0-9A-Fa-f]{4}:([0-9A-Fa-f]{2}):([0-9A-Fa-f]{2}\.[0-7])$ ]]; then
        printf 'bus:%s dev:%s' "${BASH_REMATCH[1],,}" "${BASH_REMATCH[2],,}"
    else
        printf 'n/a'
    fi
}

# Собирает сведения об интерфейсах для построения плана.
collect_records() {
    local iface sysfs_path pci mac udev_info onboard sort_key bus_key driver

    while IFS= read -r iface; do
        sysfs_path="/sys/class/net/$iface/device"
        pci=$(basename "$(readlink -f "$sysfs_path")" 2>/dev/null || true)
        [[ "$pci" =~ ^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-7]$ ]] || continue

        mac=$(<"/sys/class/net/$iface/address")
        driver="n/a"
        if command_exists ethtool; then
            driver=$(ethtool -i "$iface" 2>/dev/null | awk -F': ' '/^driver:/ {print $2; exit}' || true)
            driver=${driver:-n/a}
        fi

        udev_info=""
        if command_exists udevadm; then
            udev_info=$(udevadm info -q all -p "/sys/class/net/$iface" 2>/dev/null || true)
        fi

        if grep -q 'ID_NET_NAME_ONBOARD=' <<<"$udev_info"; then
            onboard=1
        else
            onboard=0
        fi

        sort_key=$(pci_sort_key "$pci")
        bus_key=$(pci_bus_key "$pci")

        printf '%s|%s|%s|%s|%s|%s|%s\n' \
            "$sort_key" "$onboard" "$bus_key" "$iface" "${pci,,}" "${mac,,}" "$driver"
    done < <(get_interfaces)
}

# Рассчитывает новые имена интерфейсов по PCI-порядку.
build_plan() {
    local records=()
    local record sort_key onboard bus_key iface pci mac driver
    local port current_bus controller target
    local records_file
    local -A used_names=()

    records_file=$(mktemp)
    if ! collect_records | sort -t'|' -k1,1 >"$records_file"; then
        rm -f "$records_file"
        echo "ERROR: не удалось собрать список физических PCI сетевых интерфейсов" >&2
        return 1
    fi

    mapfile -t records <"$records_file"
    rm -f "$records_file"

    if ((${#records[@]} == 0)); then
        echo "ERROR: физические PCI сетевые интерфейсы не найдены" >&2
        return 1
    fi

    port=0
    for record in "${records[@]}"; do
        IFS='|' read -r sort_key onboard bus_key iface pci mac driver <<<"$record"
        [[ "$onboard" == "1" ]] || continue
        port=$((port + 1))
        target="c0p${port}"
        used_names["$target"]=1
        printf '%s|%s|%s|%s|%s|%s|%s\n' "$iface" "$target" "$pci" "$mac" "true" "$driver" "$(pci_short "$pci")"
    done

    controller=0
    port=0
    current_bus=""
    for record in "${records[@]}"; do
        IFS='|' read -r sort_key onboard bus_key iface pci mac driver <<<"$record"
        [[ "$onboard" == "0" ]] || continue

        if [[ "$bus_key" != "$current_bus" ]]; then
            controller=$((controller + 1))
            port=1
            current_bus="$bus_key"
        else
            port=$((port + 1))
        fi

        target="c${controller}p${port}"
        if [[ -n "${used_names[$target]:-}" ]]; then
            echo "ERROR: внутренний конфликт имени $target" >&2
            return 1
        fi
        used_names["$target"]=1
        printf '%s|%s|%s|%s|%s|%s|%s\n' "$iface" "$target" "$pci" "$mac" "false" "$driver" "$(pci_short "$pci")"
    done
}

# Проверяет, не заняты ли целевые имена чужими интерфейсами.
check_name_conflicts() {
    local row iface target pci mac onboard driver short existing_iface
    local -A managed_ifaces=()

    for row in "$@"; do
        IFS='|' read -r iface target pci mac onboard driver short <<<"$row"
        [[ -n "$iface" ]] || continue
        managed_ifaces["$iface"]=1
    done

    for row in "$@"; do
        IFS='|' read -r iface target pci mac onboard driver short <<<"$row"
        [[ -n "$iface" ]] || continue
        existing_iface="/sys/class/net/$target"
        if [[ -e "$existing_iface" && -z "${managed_ifaces[$target]:-}" ]]; then
            echo "ERROR: целевое имя $target уже занято интерфейсом вне текущего плана" >&2
            return 1
        fi
    done
}

# Генерирует текст udev-правил для переименования.
generate_rules() {
    local row iface target pci mac onboard driver short

printf '# This file was generated by %s\n' "$SCRIPT_NAME"
    cat <<'EOF'
# Stable network interface names by PCI order.
# Onboard interfaces: c0pN. Other PCI buses: c1pN, c2pN, ...
# Rules are matched by PCI device path via KERNELS and by DRIVERS when available.
EOF


    for row in "$@"; do
        IFS='|' read -r iface target pci mac onboard driver short <<<"$row"
        [[ -n "$iface" ]] || continue
        printf '# %s -> %s, PCI=%s, onboard=%s, driver=%s\n' "$iface" "$target" "$pci" "$onboard" "$driver"
        if [[ -n "$driver" && "$driver" != "n/a" ]]; then
            printf 'ACTION=="add", SUBSYSTEM=="net", KERNELS=="%s", DRIVERS=="%s", NAME="%s"\n' "$pci" "$driver" "$target"
        else
            printf 'ACTION=="add", SUBSYSTEM=="net", KERNELS=="%s", NAME="%s"\n' "$pci" "$target"
        fi
    done
}

# Приводит путь правил к конкретному файлу, если указан каталог.
normalize_rules_file_path() {
    local rules_dir

    if [[ "$RULES_FILE" == */ || -d "$RULES_FILE" ]]; then
        rules_dir="${RULES_FILE%/}"
        [[ -n "$rules_dir" ]] || rules_dir="/"
        RULES_FILE="${rules_dir}/${RULES_BASENAME}"
    fi
}

# Выводит таблицу текущих и целевых имён интерфейсов.
print_table() {
    local row iface target pci mac onboard driver short

    if [[ "$SHOW_PCI" == "true" ]]; then
        printf '%-14s | %-8s | %-5s | %-22s | %-17s | %s\n' "Interface" "Target" "INT" "PCI (bus/dev.fn)" "MAC" "Driver"
        printf '%s\n' '----------------------------------------------------------------------------------------------'
    else
        printf '%-14s | %-8s | %-5s | %-12s | %-17s | %s\n' "Interface" "Target" "INT" "PCI" "MAC" "Driver"
        printf '%s\n' '--------------------------------------------------------------------------------'
    fi

    for row in "$@"; do
        IFS='|' read -r iface target pci mac onboard driver short <<<"$row"
        if [[ "$SHOW_PCI" == "true" ]]; then
            printf '%-14s | %-8s | %-5s | %-22s | %-17s | %s\n' "$iface" "$target" "$onboard" "$short" "$mac" "$driver"
        else
            printf '%-14s | %-8s | %-5s | %-12s | %-17s | %s\n' "$iface" "$target" "$onboard" "$pci" "$mac" "$driver"
        fi
    done
}

# Записывает правила на диск и перезагружает udev.
apply_rules() {
    local rules_content="$1"
    local rules_dir tmp_file backup_file timestamp

    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo "ERROR: запись udev-правил требует root. Запустите: sudo $0 --apply" >&2
        return 1
    fi

    rules_dir=$(dirname "$RULES_FILE")
    mkdir -p "$rules_dir"

    if [[ -e "$RULES_FILE" ]]; then
        timestamp=$(date +%Y%m%d-%H%M%S)
        backup_file="${RULES_FILE}.${timestamp}.bak"
        cp -a "$RULES_FILE" "$backup_file"
        echo "Backup: $backup_file"
    fi

    tmp_file=$(mktemp "${RULES_FILE}.tmp.XXXXXX")
    printf '%s\n' "$rules_content" >"$tmp_file"
    chmod 0644 "$tmp_file"
    mv "$tmp_file" "$RULES_FILE"

    if command_exists udevadm; then
        udevadm control --reload
    fi

    echo "Rules written: $RULES_FILE"
    echo "Для применения имён безопаснее перезагрузить систему."
}

# Выполняет основной сценарий: план, вывод и применение правил.
main() {
    local plan=()
    local rules_content
    local plan_file

    # Если передан каталог, преобразуем его в путь к файлу правил.
    normalize_rules_file_path

    # Временный файл нужен, чтобы безопасно прочитать многострочный вывод build_plan в массив.
    plan_file=$(mktemp)
    if ! build_plan >"$plan_file"; then
        rm -f "$plan_file"
        exit 1
    fi

    mapfile -t plan <"$plan_file"
    rm -f "$plan_file"

    # Пустой план означает, что правила создавать не для чего.
    if ((${#plan[@]} == 0)); then
        echo "ERROR: план переименования пуст; правила не сформированы" >&2
        exit 1
    fi

    # Перед выводом правил убеждаемся, что новые имена никого не перезапишут.
    check_name_conflicts "${plan[@]}"

    print_table "${plan[@]}"

    # Генерируем правила один раз, чтобы одинаковый текст показать и при необходимости записать.
    rules_content=$(generate_rules "${plan[@]}")

    if [[ "$SHOW_RULES" == "true" ]]; then
        printf '\n%s\n' "--- udev rules: $RULES_FILE ---"
        printf '%s\n' "$rules_content"
    fi

    # В dry-run только показываем результат, а в apply записываем правила в систему.
    if [[ "$MODE" == "apply" ]]; then
        apply_rules "$rules_content"
    else
        printf '\nDry-run: правила не записаны. Для записи выполните: sudo %s --apply\n' "$0"
    fi
}

main
