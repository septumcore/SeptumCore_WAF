#!/bin/bash
set -euo pipefail

# --- КОНФИГУРАЦИЯ ---
# Прямая ссылка на "сырой" файл скрипта в вашем репозитории
REPO_URL="https://raw.githubusercontent.com/septumcore/SeptumCore_WAF/main"
SCRIPT_NAME="install.sh"
COMPOSE_NAME="docker-compose.yml"
INSTALL_DIR="/opt/septumcore-waf"
DOCKER_MIRRORS_DEFAULT="https://mirror.gcr.io,https://docker.m.daocloud.io"
# Версия релиза: latest (по умолчанию) или конкретная, напр. alfa-0.7.63
# Можно задать: VERSION=alfa-0.7.60 sudo bash install.sh
# Или:         sudo bash install.sh --version alfa-0.7.60
TARGET_VERSION="${VERSION:-latest}"
RESOLVED_VERSION=""

usage() {
    cat <<EOF
Использование: $0 [--version <ver>|latest] [--list] [--help]

  --version, -v   Установить конкретный релиз (или latest)
  --list, -l      Показать последние доступные релизы
  --help, -h      Справка

Примеры:
  curl -sSL ${REPO_URL}/install.sh | sudo bash
  curl -sSL ${REPO_URL}/install.sh | sudo VERSION=alfa-0.7.60 bash
  sudo bash install.sh --version alfa-0.7.60
  sudo bash install.sh --list

Переменные окружения:
  VERSION=...           Версия релиза (как --version)
  REPLACE_COMPOSE=yes   Без спроса заменить docker-compose.yml

Примечание: latest всегда резолвится в конкретный тег из releases/versions.json
(не в плавающий Docker :latest — он часто отстаёт).
Если локальный docker-compose.yml уже есть и отличается от релиза —
скрипт спросит, заменять ли его (по умолчанию — нет).
EOF
}

resolve_latest_version() {
    local manifest
    manifest=$(mktemp)
    if ! curl --fail --location --silent --show-error \
        --connect-timeout 10 --max-time 30 \
        "$REPO_URL/releases/versions.json" -o "$manifest"; then
        rm -f "$manifest"
        return 1
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("latest",""))' "$manifest"
    else
        # грубый fallback без python
        grep -o '"latest"[[:space:]]*:[[:space:]]*"[^"]*"' "$manifest" | head -1 | cut -d'"' -f4
    fi
    rm -f "$manifest"
}

list_releases() {
    local manifest
    manifest=$(mktemp)
    if ! curl --fail --location --silent --show-error \
        --connect-timeout 10 --max-time 30 \
        "$REPO_URL/releases/versions.json" -o "$manifest"; then
        rm -f "$manifest"
        echo "❌ Не удалось загрузить список релизов: $REPO_URL/releases/versions.json"
        exit 1
    fi
    echo "📦 Доступные релизы (последние 5):"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$manifest" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print(f"  latest → {data.get('latest', '?')}")
for r in data.get("releases", []):
    mark = " *" if r.get("version") == data.get("latest") else "  "
    print(f"{mark}{r.get('version')}  ({r.get('date', '-')})")
print("\nУстановка: sudo VERSION=<ver> bash install.sh")
PY
    else
        cat "$manifest"
    fi
    rm -f "$manifest"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version|-v)
            TARGET_VERSION="${2:-}"
            if [ -z "$TARGET_VERSION" ]; then
                echo "❌ Укажите версию после --version"
                exit 1
            fi
            shift 2
            ;;
        --list|-l)
            list_releases
            exit 0
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "❌ Неизвестный аргумент: $1"
            usage
            exit 1
            ;;
    esac
done

retry() {
    local attempts="$1"
    shift
    local n=1
    until "$@"; do
        if [ "$n" -ge "$attempts" ]; then
            return 1
        fi
        echo "⚠️ Попытка $n не удалась, повторяем..."
        n=$((n + 1))
        sleep 3
    done
}

curl_fetch() {
    local url="$1"
    local out="$2"
    retry 3 curl --fail --location --silent --show-error \
        --connect-timeout 10 --max-time 120 \
        "$url" -o "$out"
}

wait_for_docker() {
    echo "⏳ Ожидаем готовности Docker daemon..."
    for _ in $(seq 1 30); do
        if docker info >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    echo "❌ Docker daemon не поднялся вовремя."
    return 1
}

configure_docker_mirrors() {
    local mirrors_csv="${DOCKER_REGISTRY_MIRRORS:-$DOCKER_MIRRORS_DEFAULT}"
    [ -n "$mirrors_csv" ] || return 0

    if ! command -v python3 >/dev/null 2>&1; then
        echo "ℹ️ python3 не найден, пропускаем настройку registry mirrors."
        return 0
    fi

    mkdir -p /etc/docker
    MIRRORS_CSV="$mirrors_csv" python3 <<'PY'
import json, os, pathlib
path = pathlib.Path("/etc/docker/daemon.json")
data = {}
if path.exists():
    try:
        data = json.loads(path.read_text())
    except Exception:
        data = {}
mirrors = [m.strip() for m in os.environ.get("MIRRORS_CSV", "").split(",") if m.strip()]
if mirrors:
    data["registry-mirrors"] = mirrors
path.write_text(json.dumps(data, indent=2) + "\n")
PY

    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart docker
    elif command -v service >/dev/null 2>&1; then
        service docker restart
    fi
    wait_for_docker
    echo "✅ Docker registry mirrors настроены: $mirrors_csv"
}

# Проверка на root
if [ "$EUID" -ne 0 ]; then
  echo "❌ ОШИБКА: Запустите скрипт через sudo: sudo $0"
  exit 1
fi

echo "==================================================="
echo "🛡️ SeptumCore WAF CE: Подготовка к установке..."
echo "📌 Запрошено: ${TARGET_VERSION}"

# latest → конкретный тег из манифеста (надёжнее плавающего Docker :latest)
if [ "$TARGET_VERSION" = "latest" ] || [ -z "$TARGET_VERSION" ]; then
    if RESOLVED_VERSION=$(resolve_latest_version) && [ -n "$RESOLVED_VERSION" ]; then
        echo "📌 Актуальный релиз из манифеста: ${RESOLVED_VERSION}"
    else
        echo "⚠️ Не удалось прочитать releases/versions.json — используем плавающий :latest"
        RESOLVED_VERSION="latest"
    fi
else
    RESOLVED_VERSION="$TARGET_VERSION"
fi
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

compose_source_url() {
    if [ "$RESOLVED_VERSION" = "latest" ]; then
        echo "$REPO_URL/$COMPOSE_NAME"
    else
        echo "$REPO_URL/releases/${RESOLVED_VERSION}/$COMPOSE_NAME"
    fi
}

# --- 1. ФУНКЦИЯ САМООБНОВЛЕНИЯ ---
is_yes() {
    local v
    v=$(printf '%s' "${1:-}" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')
    case "$v" in
        y|yes|д|да) return 0 ;;
        *) return 1 ;;
    esac
}

update_self() {
    echo "🔄 Проверка наличия новой версии файлов..."

    local compose_url
    compose_url=$(compose_source_url)
    echo "⬇️ Compose: $compose_url"

    if ! curl_fetch "$compose_url" "$COMPOSE_NAME.new"; then
        if [ "$RESOLVED_VERSION" != "latest" ]; then
            echo "⚠️ Нет releases/${RESOLVED_VERSION}/compose — пробуем корневой и закрепляем тег..."
            if curl_fetch "$REPO_URL/$COMPOSE_NAME" "$COMPOSE_NAME.new"; then
                # На случай если в корне :latest — пиним на релизный тег
                sed -i.bak "s|:latest|:${RESOLVED_VERSION}|g" "$COMPOSE_NAME.new" 2>/dev/null \
                  || sed -i '' "s|:latest|:${RESOLVED_VERSION}|g" "$COMPOSE_NAME.new"
                rm -f "$COMPOSE_NAME.new.bak"
            else
                echo "❌ Не удалось скачать compose."
                exit 1
            fi
        else
            echo "❌ Не удалось скачать compose."
            exit 1
        fi
    fi

    if [ -f "$COMPOSE_NAME.new" ]; then
        local replace_compose=0
        if [ ! -f "$COMPOSE_NAME" ]; then
            replace_compose=1
        elif [ "${REPLACE_COMPOSE:-}" = "1" ] || [ "${REPLACE_COMPOSE:-}" = "yes" ] || [ "${FORCE_COMPOSE:-}" = "1" ]; then
            replace_compose=1
            echo "ℹ️ REPLACE_COMPOSE=yes — docker-compose.yml будет заменён."
        elif cmp -s "$COMPOSE_NAME" "$COMPOSE_NAME.new" 2>/dev/null; then
            echo "✅ docker-compose.yml уже актуален для ${RESOLVED_VERSION}."
            rm -f "$COMPOSE_NAME.new"
        else
            echo ""
            echo "⚠️ Найден локальный docker-compose.yml — он отличается от релиза ${RESOLVED_VERSION}."
            echo "   Локальные правки (порты, volumes, env) будут потеряны при замене."
            local answer=""
            if [ -r /dev/tty ]; then
                printf "❓ Заменить docker-compose.yml на версию из релиза? [y/N]: " > /dev/tty
                IFS= read -r answer < /dev/tty || true
            elif [ -t 0 ]; then
                printf "❓ Заменить docker-compose.yml на версию из релиза? [y/N]: "
                IFS= read -r answer || true
            else
                echo "ℹ️ Нет TTY — оставляем текущий docker-compose.yml без изменений."
                echo "   Чтобы заменить: REPLACE_COMPOSE=yes sudo bash install.sh"
                answer="n"
            fi
            if is_yes "$answer"; then
                replace_compose=1
            else
                echo "⏭️ docker-compose.yml оставлен без изменений."
                # Всё равно обновим теги образов в существующем compose, если там :latest
                if [ "$RESOLVED_VERSION" != "latest" ] && grep -q ':latest' "$COMPOSE_NAME" 2>/dev/null; then
                    echo "🔧 В текущем compose найдены теги :latest — закрепляем ${RESOLVED_VERSION}..."
                    cp "$COMPOSE_NAME" "${COMPOSE_NAME}.bak.$(date +%Y%m%d%H%M%S)"
                    sed -i.bak "s|:latest|:${RESOLVED_VERSION}|g" "$COMPOSE_NAME" 2>/dev/null \
                      || sed -i '' "s|:latest|:${RESOLVED_VERSION}|g" "$COMPOSE_NAME"
                    rm -f "${COMPOSE_NAME}.bak"
                fi
                rm -f "$COMPOSE_NAME.new"
            fi
        fi

        if [ "$replace_compose" -eq 1 ] && [ -f "$COMPOSE_NAME.new" ]; then
            if [ -f "$COMPOSE_NAME" ]; then
                cp "$COMPOSE_NAME" "${COMPOSE_NAME}.bak.$(date +%Y%m%d%H%M%S)"
                echo "💾 Бэкап текущего compose сохранён."
            fi
            mv "$COMPOSE_NAME.new" "$COMPOSE_NAME"
            echo "✅ Установлен docker-compose.yml для ${RESOLVED_VERSION}."
        fi
    fi

    curl_fetch "$REPO_URL/$SCRIPT_NAME" "$SCRIPT_NAME.new"
    if [ -f "$SCRIPT_NAME.new" ]; then
        mv "$SCRIPT_NAME.new" "$SCRIPT_NAME"
        chmod 700 "$SCRIPT_NAME"
        echo "✅ Скрипт установки обновлен локально."
    fi

    echo "$RESOLVED_VERSION" > .installed_version
}

update_self

# --- 2. ПРОВЕРКА DOCKER ---
if ! command -v docker &> /dev/null; then
    echo "📦 Устанавливаем Docker..."
    retry 3 sh -c "curl --fail --location --silent --show-error --connect-timeout 10 --max-time 300 https://get.docker.com | bash"
fi

wait_for_docker
configure_docker_mirrors

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
touch waf-logs/audit.log
touch waf-nginx/conf.d/default.conf
touch waf-rules/septumcore-rules.conf

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

if [ ! -f waf-html/challenge.html ]; then
    echo "📄 Создаем дефолтную страницу защиты..."
    cat << 'EOF' > waf-html/challenge.html
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>Security Check</title><style>body{background:#f1f5f9;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;font-family:sans-serif}.card{background:#fff;padding:40px;border-radius:12px;box-shadow:0 10px 25px rgba(0,0,0,.05);text-align:center}.spinner{border:3px solid rgba(0,0,0,.1);border-top:3px solid #06b6d4;border-radius:50%;width:40px;height:40px;animation:spin 1s linear infinite;margin:0 auto 20px}@keyframes spin{0%{transform:rotate(0deg)}100%{transform:rotate(360deg)}}.info{margin-top:20px;padding:10px;background:#f8fafc;border-radius:6px;font-family:monospace;font-size:12px;color:#64748b}</style></head><body><div class="card"><div class="spinner"></div><h2>Checking your browser...</h2><p style="color:#64748b">Please wait 5 seconds.</p><div class="info">IP: </div></div><script>setTimeout(function(){document.cookie="waf_verify=1; path=/; max-age=86400; SameSite=Lax";window.location.reload(true);},5000);</script></body></html>
EOF
fi

chown -R 1000:101 waf-nginx acme-challenge waf-cache waf-html waf-rules
find waf-nginx acme-challenge waf-cache waf-html waf-rules -type d -exec chmod 2770 {} +
find waf-nginx acme-challenge waf-html waf-rules -type f -exec chmod 660 {} +

chown -R 101:1000 waf-logs
find waf-logs -type d -exec chmod 2770 {} +
find waf-logs -type f -exec chmod 660 {} +

chmod 666 /var/run/docker.sock

# --- 5. ОБНОВЛЕНИЕ ОБРАЗОВ И ЗАПУСК ---
echo "🚀 Подтягиваем образы (релиз: ${RESOLVED_VERSION})..."
retry 3 $COMPOSE_CMD pull
echo "🔄 Пересоздаём контейнеры, чтобы подхватить новые образы..."
retry 3 $COMPOSE_CMD up -d --remove-orphans --force-recreate

# Даём backend пару секунд на старт перед -v
sleep 3

echo ""
echo "✅ УСТАНОВКА/ОБНОВЛЕНИЕ ЗАВЕРШЕНО!"
echo "📂 Все файлы системы находятся в: $INSTALL_DIR"
echo "📌 Установленный релиз: ${RESOLVED_VERSION}"
if command -v docker >/dev/null 2>&1; then
    echo "🔎 Версия внутри backend-контейнера:"
    docker exec waf-backend /app/septumcore -v 2>/dev/null || echo "   (контейнер ещё стартует — проверьте: curl -sk https://127.0.0.1:9000/api/version)"
fi
IP=$(hostname -I | awk '{print $1}')
echo "🌐 Панель управления: https://$IP:9000"
echo "   (самоподписанный сертификат — браузер может запросить подтверждение)"
echo "🔑 Логин по умолчанию: admin"
echo "🔄 Сброс пароля: docker exec -it waf-backend /app/septumcore -reset-user admin"
echo "📜 Список релизов: sudo bash $INSTALL_DIR/install.sh --list"
echo "==================================================="
