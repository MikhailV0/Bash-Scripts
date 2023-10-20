#!/bin/bash

# Скрипт установки Docker на Debian 12
# Дата: 20 Октября 2023
# Имя файла : install-docker.sh
# Автор: Михаил Волохов (https://github.com/MikhailV0)
# Этот скрипт автоматизирует установку Docker на операционной системе Debian.
# Он также предлагает пользователю добавить себя в группу Docker для удобной работы
# с Docker без использования sudo.
# Проверка успешности выполнения команд, реализована через коды возврата (exit code) 
# последней выполненной команды. $? -eq 0


# Проверка наличия sudo
if ! command -v sudo &> /dev/null; then
    echo "Sudo не установлен. Установите sudo для продолжения."
    exit 1
fi

# Проверка наличия Docker
if command -v docker &> /dev/null; then
    echo "Docker уже установлен."
    exit 0
fi

# Запрос авторизации sudo
sudo -v

# Проверка успешности запроса sudo
if [ $? -ne 0 ]; then
    echo "Ошибка при запросе авторизации sudo."
    exit 1
fi

# Добавление Docker's официального GPG ключа
sudo apt update
sudo apt install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Проверка успешности установки GPG ключа
if [ $? -ne 0 ]; then
    echo "Ошибка при установке GPG ключа Docker."
    exit 1
fi

# Добавление репозитория Docker в Apt
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update

# Проверка успешности добавления репозитория
if [ $? -ne 0 ]; then
    echo "Ошибка при добавлении репозитория Docker."
    exit 1
fi

# Установка Docker
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Проверка успешности установки Docker
if [ $? -eq 0 ]; then
    echo "Docker успешно установлен."
else
    echo "Произошла ошибка при установке Docker."
    exit 1
fi

# Запрос пользователя о добавлении в группу Docker
read -p "Хотите ли вы добавить себя в группу Docker (y/n)? " choice
if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
    sudo usermod -aG docker $USER
    if [ $? -eq 0 ]; then
        echo "Вы были добавлены в группу Docker. Пожалуйста, перезапустите сеанс или систему для применения изменений."
    else
        echo "Ошибка при добавлении в группу Docker."
        exit 1
    fi
else
    echo "Вы решили не добавлять себя в группу Docker. Пожалуйста, не забудьте использовать 'sudo' при работе с Docker."
fi
