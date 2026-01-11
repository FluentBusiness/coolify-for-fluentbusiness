#!/bin/bash

# --- НАСТРОЙКИ ---
# Работаем только от root
if [[ $EUID -ne 0 ]]; then
   echo "Этот скрипт должен быть запущен от имени root" 
   exit 1
fi

set -e

# --- ЦВЕТА ---
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

ask_yes_no() {
    local prompt="$1"
    while true; do
        read -p "$prompt (y/n): " INPUT < /dev/tty
        case "$INPUT" in
            [yY]|[yY][eE][sS]) CONFIRM="y"; return 0 ;;
            [nN]|[nN][oO]) CONFIRM="n"; return 1 ;;
            *) echo -e "${YELLOW}Введите 'y' или 'n'.${NC}" ;;
        esac
    done
}

# --- 1. ОБНОВЛЕНИЕ СИСТЕМЫ ---
update_system() {
    info "Обновление пакетов и установка зависимостей..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get -qqy update
    apt-get -qqy -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade
    apt-get -y autoremove
    
    # Установка утилит:
    # putty-tools - для конвертации ключей
    # jq, git, curl, wget - нужны для работы многих скриптов и Coolify
    # htop - для мониторинга ресурсов
    # openssl - критически важен для генерации паролей в скрипте установки Coolify
    apt-get install -y putty-tools curl wget jq git htop openssl
    
    info "Система обновлена и базовые утилиты установлены."
}

# --- 2. НАСТРОЙКА SWAP (4GB) ---
configure_swap() {
    info "--- ПРОВЕРКА SWAP ---"
    
    # Проверяем, включен ли swap
    if swapon --show | grep -q "partition\|file"; then
        info "Swap уже активен. Пропуск создания."
    elif [ -f /swapfile ]; then
        warn "Файл /swapfile существует, но не активен. Пропуск во избежание конфликтов."
    else
        # OnlyOffice требователен к памяти, ставим 4GB для надежности
        info "Создание Swap-файла размером 4GB..."
        fallocate -l 4G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        
        # Добавляем в fstab для автозагрузки
        if ! grep -q "/swapfile" /etc/fstab; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
            info "Swap добавлен в автозагрузку."
        fi
        
        info "✅ Swap (4GB) успешно создан и подключен."
    fi
}

# --- 3. ГЕНЕРАЦИЯ КЛЮЧЕЙ ---
generate_keys() {
    info "--- ГЕНЕРАЦИЯ КЛЮЧЕЙ ---"
    
    KEY_PATH="/root/coolify_root_key"
    
    rm -f "${KEY_PATH}" "${KEY_PATH}.pub" "${KEY_PATH}.ppk"

    info "Генерация Ed25519 ключа..."
    ssh-keygen -t ed25519 -C "root-coolify-access" -f "$KEY_PATH" -N "" -q
    
    info "Конвертация в PPK (для PuTTY)..."
    puttygen "$KEY_PATH" -o "${KEY_PATH}.ppk" -O private

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    
    # Добавляем публичный ключ в authorized_keys
    if ! grep -qf "${KEY_PATH}.pub" /root/.ssh/authorized_keys 2>/dev/null; then
        cat "${KEY_PATH}.pub" >> /root/.ssh/authorized_keys
        info "Ключ добавлен в authorized_keys."
    fi
    chmod 600 /root/.ssh/authorized_keys
    
    # Сохраняем ключи в переменные перед удалением
    PRIVATE_KEY_OPENSSH=$(cat "$KEY_PATH")
    PRIVATE_KEY_PPK=$(cat "${KEY_PATH}.ppk")
    
    # Удаляем ключи с диска (для безопасности)
    rm -f "$KEY_PATH" "${KEY_PATH}.ppk" "${KEY_PATH}.pub"
    info "Временные файлы ключей удалены с диска."
}

# --- 4. ФАЕРВОЛ ---
setup_firewall() {
    info "--- НАСТРОЙКА UFW ---"
    
    if ! command -v ufw &> /dev/null; then
        apt-get install -y ufw
    fi

    ufw --force reset > /dev/null
    ufw default deny incoming
    ufw default allow outgoing

    ufw allow 22/tcp comment 'SSH'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    ufw allow 443/udp comment 'HTTP/3'
    
    # Порты для Coolify
    ufw allow 8000/tcp comment 'Coolify Dashboard'
    ufw allow 6001/tcp comment 'Coolify Realtime Service'

    echo "y" | ufw enable
    info "✅ Порты 22, 80, 443, 8000, 6001 открыты."
}

# --- 5. SSH HARDENING (ROOT) ---
harden_ssh() {
    info "--- НАСТРОЙКА SSH ---"
    warn "ВНИМАНИЕ: Парольный вход будет отключен!"
    
    SSHD_CONFIG="/etc/ssh/sshd_config"
    cp $SSHD_CONFIG "${SSHD_CONFIG}.bak"

    # Разрешаем root только по ключам, отключаем пароли
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSHD_CONFIG"
    sed -i 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' "$SSHD_CONFIG"
    sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' "$SSHD_CONFIG"
    sed -i 's/^#\?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' "$SSHD_CONFIG"
    # UsePAM оставляем (или yes), полное отключение может ломать сессии на некоторых OS
    
    systemctl restart ssh
    info "✅ SSH настроен: Root разрешен (только ключи), пароли отключены."
}

# --- 6. DOCKER ---
install_docker() {
    info "--- УСТАНОВКА DOCKER ---"
    if ! command -v docker &> /dev/null; then
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm get-docker.sh
        info "Docker установлен."
    else
        info "Docker уже установлен."
    fi
}

# --- 7. FAIL2BAN ---
install_fail2ban() {
    info "--- FAIL2BAN ---"
    if ! command -v fail2ban-client &> /dev/null; then
        apt-get install -y fail2ban
    fi
    
    cat <<EOF > /etc/fail2ban/jail.local
[sshd]
enabled = true
port    = ssh
filter  = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
EOF
    systemctl restart fail2ban
    systemctl enable fail2ban
    info "✅ Fail2Ban активен."
}

# --- ЗАПУСК ---
echo ""
echo "Этот скрипт подготовит сервер для Coolify/Docker."
echo "Будет настроен: Swap (4GB), Docker, UFW, SSH (Key-only), Fail2ban."
echo ""
ask_yes_no "Начать настройку?"
if [[ "$CONFIRM" == "n" ]]; then exit 0; fi

update_system
configure_swap
generate_keys
setup_firewall
install_docker
harden_ssh
install_fail2ban

# --- ОТЧЕТ ---
clear
echo ""
echo -e "${GREEN}==========================================================${NC}"
echo -e "${GREEN}   НАСТРОЙКА ЗАВЕРШЕНА УСПЕШНО${NC}"
echo -e "${GREEN}==========================================================${NC}"
echo ""
echo "IP сервера: $(curl -s4 https://ifconfig.me)"
echo "Пользователь: root"
echo "Порт SSH: 22"
echo "Порт Coolify: 8000 (будет доступен после установки)"
echo "Swap: Активен (4GB)"
echo "Docker: $(docker --version)"
echo ""
echo -e "${YELLOW}!!! СКОПИРУЙТЕ КЛЮЧИ ПРЯМО СЕЙЧАС !!!${NC}"
echo "Ключи УДАЛЕНЫ с диска сервера. Вы видите их в последний раз."
echo "Если вы закроете терминал без сохранения, доступ будет утерян."
echo ""
echo "----------------------------------------------------------"
echo "PRIVATE KEY (OpenSSH) - Вставьте этот ключ в Coolify:"
echo "----------------------------------------------------------"
echo -e "${YELLOW}${PRIVATE_KEY_OPENSSH}${NC}"
echo ""
echo "----------------------------------------------------------"
echo "PRIVATE KEY (PuTTY .ppk) - Если нужен доступ через Windows:"
echo "----------------------------------------------------------"
echo -e "${YELLOW}${PRIVATE_KEY_PPK}${NC}"
echo "----------------------------------------------------------"
echo ""
echo -e "${GREEN}Готово. Теперь запустите установку Coolify:${NC}"
echo -e "curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash"
echo ""