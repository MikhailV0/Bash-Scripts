#!/bin/bash

# Опция для отображения колонки PCI
show_pci=false
# Для большей гибкости можно использовать getopts, но для одного флага текущий вариант прост и достаточен.
if [[ "$1" == "-h" ]]; then
    show_pci=true
fi

# Заголовок таблицы
header="Interface  | INT   "
$show_pci && header+="| PCI (bus/dev.fn)       "
header+="| ethtool            | lshw               | lspci              | sysfs              | udevadm"
printf "%s\n" "$header"
# printf "%0.s-" "$(seq 1 ${#header})"
line=$(printf '%*s' "${#header}" '')
printf '%s\n' "${line// /-}"

# Фильтрация только физических интерфейсов
# Этот способ надежнее, так как отбирает только интерфейсы с реальным backing device
get_interfaces() {
    for iface_path in /sys/class/net/*; do
        [ -L "$iface_path/device" ] && basename "$iface_path"
    done | grep -vE '^(lo|vlan|virbr|docker|br|vmnet|veth|tun|tap|wl|bonding_masters|fwbr|fwln|ovs|vmbr)'
}

# Предварительный вызов тяжелых команд для оптимизации
lshw_output=$(lshw -class network -businfo 2>/dev/null)
lspci_output=$(lspci -Dnn 2>/dev/null)


# Основной цикл. Использование `while read` более надежно.
get_interfaces | while IFS= read -r iface; do
    sysfs_path="/sys/class/net/$iface/device"

    # Получаем PCI-адрес из sysfs
    pci_sysfs=$(basename "$(readlink -f "$sysfs_path")" 2>/dev/null)

    # Кэшируем вывод udevadm, чтобы не вызывать команду дважды
    udev_info=$(udevadm info -q all -p "/sys/class/net/$iface" 2>/dev/null)

    # Оптимизированное получение данных с помощью awk
    pci_ethtool=$(ethtool -i "$iface" 2>/dev/null | awk -F': ' '/bus-info/ {print $2}')
    pci_lshw=$(echo "$lshw_output" | awk -v iface="$iface" '$0 ~ iface {sub(/^pci@/, "", $1); print $1; exit}')
    pci_lspci=$(echo "$lspci_output" | awk -v pci="$pci_sysfs" '$0 ~ pci {print $1; exit}')
    pci_udev=$(echo "$udev_info" | awk -F= '/PCI_SLOT_NAME/ {print $2; exit}')

    # Определение встроенности (onboard) через udevadm - самый надежный способ
    if echo "$udev_info" | grep -q 'ID_NET_NAME_ONBOARD'; then
        int_flag="true"
    else
        int_flag="false"
    fi

    # Динамическое формирование строки вывода для printf, чтобы избежать дублирования кода
    # Корректировка ширины для многобайтовых символов в поле INT
    # Вычисляем разницу между байтами и символами и добавляем ее к ширине поля.
    int_flag_len="${#int_flag}"
    int_flag_bytes=$(printf "%s" "$int_flag" | wc -c)
    int_width=$((5 + int_flag_bytes - int_flag_len))

    format_string="%-10s | %-*s " # Используем динамическую ширину
    args=("$iface" "$int_width" "$int_flag")

    if $show_pci; then
        format_string+="| %-22s "
        if [[ "$pci_sysfs" =~ ^([0-9a-f]{4}):([0-9a-f]{2}):([0-9a-f]{2})\.([0-9])$ ]]; then
            pci_col="bus:${BASH_REMATCH[2]} dev:${BASH_REMATCH[3]}.${BASH_REMATCH[4]}"
            args+=("$pci_col")
        else
            args+=("n/a")
        fi
    fi

    format_string+="| %-18s | %-18s | %-18s | %-18s | %s\n"
    args+=("${pci_ethtool:-n/a}" "${pci_lshw:-n/a}" "${pci_lspci:-n/a}" "${pci_sysfs:-n/a}" "${pci_udev:-n/a}")

    printf "$format_string" "${args[@]}"
done
