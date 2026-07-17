#!/bin/bash
set -e

# --- КОНФИГУРАЦИЯ ---
# Прямая ссылка на "сырой" файл скрипта в вашем репозитории
REPO_URL="https://raw.githubusercontent.com/septumcore/SeptumCore_WAF/main"
SCRIPT_NAME="install.sh"
COMPOSE_NAME="docker-compose.yml"
INSTALL_DIR="/opt/septumcore-waf"

# Проверка на root
if [ "$EUID" -ne 0 ]; then
  echo "❌ ОШИБКА: Запустите скрипт через sudo: sudo $0"
  exit 1
fi

echo "==================================================="
echo "🛡️ SeptumCore WAF CE: Подготовка к установке..."
echo "==================================================="

# --- 0. ПРОВЕРКА И ПЕРЕХОД В РАБОЧУЮ ДИРЕКТОРИЮ ---
if [ "$PWD" == "$INSTALL_DIR" ]; then
    echo "📂 Вы уже находитесь в рабочей директории: $INSTALL_DIR"
else
    if [ ! -d "$INSTALL_DIR" ]; then
        echo "📂 Создаем рабочую директорию $INSTALL_DIR..."
        mkdir -p "$INSTALL_DIR"
    else
        echo "📂 Рабочая директория $INSTALL_DIR найдена."
    fi
    echo "➡️ Переходим в $INSTALL_DIR..."
    cd "$INSTALL_DIR"
fi

# --- 1. ФУНКЦИЯ САМООБНОВЛЕНИЯ ---
update_self() {
    echo "🔄 Проверка наличия новой версии файлов..."
    
    # Скачиваем свежий docker-compose.yml
    curl -sSL "$REPO_URL/$COMPOSE_NAME" -o "$COMPOSE_NAME.new"
    if [ -f "$COMPOSE_NAME.new" ]; then
        if [ -f "$COMPOSE_NAME" ]; then
            echo -n "⚠️ Файл $COMPOSE_NAME уже существует. Перезаписать его? [y/N]: "
            read -r ans < /dev/tty
            if [[ "$ans" =~ ^[Yy]$ ]]; then
                mv "$COMPOSE_NAME.new" "$COMPOSE_NAME"
                echo "✅ Файл конфигурации $COMPOSE_NAME обновлен."
            else
                rm -f "$COMPOSE_NAME.new"
                echo "⏭️ Оставлен текущий файл $COMPOSE_NAME."
            fi
        else
            mv "$COMPOSE_NAME.new" "$COMPOSE_NAME"
            echo "✅ Файл конфигурации $COMPOSE_NAME скачан."
        fi
    fi

    # Скачиваем скрипт
    curl -sSL "$REPO_URL/$SCRIPT_NAME" -o "$SCRIPT_NAME.new"
    if [ -f "$SCRIPT_NAME.new" ]; then
        if [ -f "$SCRIPT_NAME" ] && ! cmp -s "$SCRIPT_NAME" "$SCRIPT_NAME.new"; then
            mv "$SCRIPT_NAME.new" "$SCRIPT_NAME"
            chmod 700 "$SCRIPT_NAME" # СЗИ: только root может запускать и менять
            echo "✅ Скрипт установки обновлен локально."
        else
            mv "$SCRIPT_NAME.new" "$SCRIPT_NAME"
            chmod 700 "$SCRIPT_NAME"
        fi
    fi
}

update_self

# --- 2. ПРОВЕРКА DOCKER ---
if ! command -v docker &> /dev/null; then 
    echo "📦 Устанавливаем Docker..."
    curl -fsSL https://get.docker.com | bash
fi

get_docker_compose_cmd() {
    if docker compose version &>/dev/null; then echo "docker compose";
    elif command -v docker-compose &>/dev/null; then echo "docker-compose";
    else echo "❌ ОШИБКА: Docker Compose не найден!" >&2; exit 1; fi
}
COMPOSE_CMD=$(get_docker_compose_cmd)

# --- 3. ГЕНЕРАЦИЯ .env ---
if [ ! -f .env ]; then
    echo "⏳ Чистая установка. Генерируем ключи..."
    $COMPOSE_CMD down -v 2>/dev/null || true
    SECRET=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 64 | head -n 1)
    DB_PASS=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
    echo "SESSION_SECRET=$SECRET" > .env
    echo "POSTGRES_USER=septumcore" >> .env
    echo "POSTGRES_PASSWORD=$DB_PASS" >> .env
    echo "POSTGRES_DB=septumcore_db" >> .env
    echo "✅ Файл .env успешно создан."
else
    echo "✅ Файл .env найден. Пароли и настройки сохранены."
fi

# --- 4. ПРАВА ДОСТУПА И СТРУКТУРА (Блок СЗИ) ---
echo "⚙️ Настройка локальных директорий и прав доступа..."

mkdir -p waf-logs acme-challenge waf-nginx/conf.d waf-nginx/certs waf-cache waf-html waf-rules
# Обязательно создаем файл лога до старта Докера! Иначе Докер создаст папку вместо файла.
touch waf-logs/audit.log
# Создаем пустой default.conf, чтобы избежать ошибки sed в скриптах запуска OWASP WAF
touch waf-nginx/conf.d/default.conf
# Создаем пустой файл кастомных правил, чтобы Nginx не падал при старте (если используется bind mount)
touch waf-rules/septumcore-rules.conf

# Генерируем SSL-сертификат панели до первого запуска Nginx
if [ ! -f waf-nginx/certs/panel.crt ] || [ ! -f waf-nginx/certs/panel.key ]; then
    echo "🔐 Генерация SSL-сертификата панели управления..."
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout waf-nginx/certs/panel.key \
        -out waf-nginx/certs/panel.crt \
        -subj "/CN=SeptumCore WAF/O=SeptumCore" \
        -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null \
        || openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout waf-nginx/certs/panel.key \
            -out waf-nginx/certs/panel.crt \
            -subj "/CN=SeptumCore WAF/O=SeptumCore"
fi

# Генерируем базовую заглушку Under Attack (если её еще нет)
if [ ! -f waf-html/challenge.html ]; then
    echo "📄 Создаем дефолтную страницу защиты..."
    cat << 'EOF' > waf-html/challenge.html
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Security Check</title><style>body{background:#f1f5f9;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;font-family:sans-serif}.card{background:#fff;padding:40px;border-radius:12px;box-shadow:0 10px 25px rgba(0,0,0,.05);text-align:center}.spinner{border:3px solid rgba(0,0,0,.1);border-top:3px solid #06b6d4;border-radius:50%;width:40px;height:40px;animation:spin 1s linear infinite;margin:0 auto 20px}@keyframes spin{0%{transform:rotate(0deg)}100%{transform:rotate(360deg)}}.info{margin-top:20px;padding:10px;background:#f8fafc;border-radius:6px;font-family:monospace;font-size:12px;color:#64748b}</style></head><body><div class="card"><div class="spinner"></div><h2>Checking your browser...</h2><p style="color:#64748b">Please wait 5 seconds.</p><div class="info">IP: </div></div><script>setTimeout(function(){document.cookie="waf_verify=1; path=/; max-age=86400; SameSite=Lax";window.location.reload(true);},5000);</script></body></html>
EOF
fi

# 1. Зона ответственности БЭКЕНДА (Конфиги, сертификаты, ACME, HTML, Rules)
chown -R 1000:101 waf-nginx acme-challenge waf-cache waf-html waf-rules
# 2770 = Владелец и группа могут всё. Чужие - ничего. SGID бит сохраняет группу.
find waf-nginx acme-challenge waf-cache waf-html waf-rules -type d -exec chmod 2770 {} +
# 660 = Владелец и группа могут читать/писать. Чужие - ничего.
find waf-nginx acme-challenge waf-html waf-rules -type f -exec chmod 660 {} +

# 2. Зона ответственности NGINX (Логи сайтов)
chown -R 101:1000 waf-logs
find waf-logs -type d -exec chmod 2770 {} +
find waf-logs -type f -exec chmod 660 {} +

# Разрешаем бэкенду управлять Docker
chmod 666 /var/run/docker.sock

# --- 5. ОБНОВЛЕНИЕ ОБРАЗОВ И ЗАПУСК ---
echo "🚀 Подтягиваем свежие образы..."
$COMPOSE_CMD pull
$COMPOSE_CMD up -d --remove-orphans

echo ""
echo "✅ УСТАНОВКА/ОБНОВЛЕНИЕ ЗАВЕРШЕНО!"
echo "📂 Все файлы системы находятся в: $INSTALL_DIR"
IP=$(hostname -I | awk '{print $1}')
echo "🌐 Панель управления: https://$IP"
echo "   (самоподписанный сертификат — браузер может запросить подтверждение)"
echo "🔑 Логин по умолчанию: admin"
echo "🔄 Сброс пароля: docker exec -it waf-backend /app/septumcore -reset-user admin"
echo "==================================================="