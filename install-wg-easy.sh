#!/usr/bin/env bash
set -Eeuo pipefail

LOG_FILE="/var/log/wg-easy-install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

SCRIPT_VERSION="2.0.0"

WG_DIR="/opt/wg-easy"
COMPOSE_FILE="${WG_DIR}/docker-compose.yml"
ENV_FILE="${WG_DIR}/.env"
DATA_DIR="${WG_DIR}/data"
BACKUP_ROOT="${WG_DIR}/backups"

NGINX_SITE_NAME="wg-easy"
NGINX_SITE_AVAIL="/etc/nginx/sites-available/${NGINX_SITE_NAME}"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/${NGINX_SITE_NAME}"

QUIET_MODE=false
FORCE_MODE=false

WG_DOMAIN="${WG_DOMAIN:-}"
LE_EMAIL="${LE_EMAIL:-}"
WG_PASSWORD="${WG_PASSWORD:-}"
WG_PASSWORD_FILE="${WG_PASSWORD_FILE:-}"
WG_HOST="${WG_HOST:-}"
WG_DNS="${WG_DNS:-}"
WG_DEFAULT_ADDRESS="${WG_DEFAULT_ADDRESS:-}"
WG_PORT="${WG_PORT:-}"
WG_ALLOWED_IPS="${WG_ALLOWED_IPS:-0.0.0.0/0,::/0}"
WG_MTU="${WG_MTU:-1420}"
WG_PERSISTENT_KEEPALIVE="${WG_PERSISTENT_KEEPALIVE:-25}"
WG_DEVICE="${WG_DEVICE:-eth0}"

ROLLBACK_NGINX_CREATED=0
ROLLBACK_DOCKER_STARTED=0
ROLLBACK_SYSCTL_CREATED=0
ROLLBACK_CERT_ATTEMPTED=0

red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
cyan()   { printf '\033[1;36m%s\033[0m\n' "$*"; }

die() {
  red "ERROR: $*"
  exit 1
}

info() {
  echo "[INFO] $*"
}

warn() {
  yellow "[WARN] $*"
}

ok() {
  green "[OK] $*"
}

cleanup() {
  local exit_code=$?

  if [[ "${exit_code}" -ne 0 ]]; then
    red "Произошла ошибка. Выполняю безопасный откат..."

    if [[ "${ROLLBACK_DOCKER_STARTED}" -eq 1 && -f "${COMPOSE_FILE}" ]]; then
      (
        cd "${WG_DIR}" 2>/dev/null && docker compose down
      ) >/dev/null 2>&1 || true
    fi

    if [[ "${ROLLBACK_NGINX_CREATED}" -eq 1 ]]; then
      rm -f "${NGINX_SITE_ENABLED}" 2>/dev/null || true
      rm -f "${NGINX_SITE_AVAIL}" 2>/dev/null || true
      nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
    fi

    if [[ "${ROLLBACK_SYSCTL_CREATED}" -eq 1 ]]; then
      rm -f /etc/sysctl.d/99-wg-easy.conf 2>/dev/null || true
      sysctl --system >/dev/null 2>&1 || true
    fi

    if [[ "${ROLLBACK_CERT_ATTEMPTED}" -eq 1 && -n "${WG_DOMAIN:-}" ]]; then
      warn "Проверь вручную состояние certbot и nginx для домена ${WG_DOMAIN}."
    fi

    red "Установка завершилась с ошибкой. Лог: ${LOG_FILE}"
  fi
}
trap cleanup EXIT

usage() {
  cat <<EOF
Использование:
  $0 [опции]

Опции:
  --quiet                     Не задавать вопросы, использовать переданные параметры
  --force                     Не спрашивать подтверждения на предупреждениях
  --domain DOMAIN             Домен для панели wg-easy
  --email EMAIL               Email для Let's Encrypt
  --password PASSWORD         Пароль для веб-панели (небезопасно: виден в history/ps)
  --password-file FILE        Файл с паролем для веб-панели
  --wg-host HOST              Endpoint для клиентов WireGuard (по умолчанию DOMAIN)
  --wg-port PORT              UDP порт WireGuard (по умолчанию 51820)
  --wg-dns DNS                DNS для клиентов, например 1.1.1.1,8.8.8.8
  --wg-subnet CIDR            Подсеть клиентов, например 10.8.0.0/24
  --wg-allowed-ips CIDRS      AllowedIPs для клиентов (по умолчанию 0.0.0.0/0,::/0)
  --wg-mtu MTU                MTU (по умолчанию 1420)
  --wg-keepalive SECONDS      PersistentKeepalive (по умолчанию 25)
  --wg-device IFACE           Внешний интерфейс для подсказок/диагностики (по умолчанию eth0)
  -h, --help                  Показать помощь

Примеры:
  Интерактивно:
    $0

  Без вопросов:
    $0 --quiet \\
       --domain vpn.example.com \\
       --email admin@example.com \\
       --password-file /root/wg-pass.txt \\
       --wg-port 51820 \\
       --wg-dns 1.1.1.1,8.8.8.8 \\
       --wg-subnet 10.8.0.0/24
EOF
}

confirm_or_exit() {
  local msg="$1"
  if [[ "${FORCE_MODE}" == "true" ]]; then
    warn "${msg} Продолжаю из-за --force."
    return 0
  fi
  read -r -p "${msg} [y/N]: " ans
  [[ "${ans,,}" == "y" ]] || exit 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --quiet)
        QUIET_MODE=true
        shift
        ;;
      --force)
        FORCE_MODE=true
        shift
        ;;
      --domain)
        WG_DOMAIN="${2:-}"
        shift 2
        ;;
      --email)
        LE_EMAIL="${2:-}"
        shift 2
        ;;
      --password)
        WG_PASSWORD="${2:-}"
        shift 2
        ;;
      --password-file)
        WG_PASSWORD_FILE="${2:-}"
        shift 2
        ;;
      --wg-host)
        WG_HOST="${2:-}"
        shift 2
        ;;
      --wg-port)
        WG_PORT="${2:-}"
        shift 2
        ;;
      --wg-dns)
        WG_DNS="${2:-}"
        shift 2
        ;;
      --wg-subnet)
        WG_DEFAULT_ADDRESS="${2:-}"
        shift 2
        ;;
      --wg-allowed-ips)
        WG_ALLOWED_IPS="${2:-}"
        shift 2
        ;;
      --wg-mtu)
        WG_MTU="${2:-}"
        shift 2
        ;;
      --wg-keepalive)
        WG_PERSISTENT_KEEPALIVE="${2:-}"
        shift 2
        ;;
      --wg-device)
        WG_DEVICE="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Неизвестный аргумент: $1"
        ;;
    esac
  done
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "Запусти скрипт от root."
}

need_ubuntu_2204() {
  [[ -f /etc/os-release ]] || die "Не найден /etc/os-release."
  . /etc/os-release

  [[ "${ID:-}" == "ubuntu" ]] || die "Скрипт рассчитан на Ubuntu."
  if [[ "${VERSION_ID:-}" != "22.04" ]]; then
    warn "Скрипт рассчитан на Ubuntu 22.04, у тебя ${VERSION_ID:-unknown}."
    confirm_or_exit "Продолжить?"
  fi
}

check_required_tools_minimal() {
  command -v awk >/dev/null 2>&1 || die "awk не найден."
  command -v sed >/dev/null 2>&1 || die "sed не найден."
  command -v grep >/dev/null 2>&1 || die "grep не найден."
  command -v timeout >/dev/null 2>&1 || die "timeout не найден."
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum не найден."
}

check_disk_space() {
  cyan "==> Проверяю свободное место..."
  local required_mb=1024
  local available_kb
  local available_mb

  available_kb="$(df / --output=avail | tail -1 | tr -d ' ')"
  available_mb=$((available_kb / 1024))

  info "Свободно на /: ${available_mb} MB"

  if [[ "${available_mb}" -lt "${required_mb}" ]]; then
    warn "Мало свободного места: ${available_mb}MB, рекомендуется минимум ${required_mb}MB."
    confirm_or_exit "Продолжить?"
  fi
}

install_base_packages() {
  cyan "==> Устанавливаю базовые пакеты..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    apt-transport-https \
    software-properties-common \
    nginx \
    certbot \
    python3-certbot-nginx \
    ufw \
    openssl \
    dnsutils \
    iproute2
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    ok "Docker уже установлен."
  else
    cyan "==> Устанавливаю Docker..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    . /etc/os-release
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      docker-ce \
      docker-ce-cli \
      containerd.io \
      docker-buildx-plugin \
      docker-compose-plugin

    systemctl enable --now docker
    ok "Docker установлен."
  fi

  docker compose version >/dev/null 2>&1 || die "docker compose plugin не найден."
}

validate_domain() {
  [[ -n "${WG_DOMAIN}" ]] || die "Домен не задан."
  [[ "${WG_DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]] || die "Некорректный домен: ${WG_DOMAIN}"
  [[ "${WG_DOMAIN}" == *.* ]] || die "Домен должен содержать точку: ${WG_DOMAIN}"
}

validate_email() {
  [[ -n "${LE_EMAIL}" ]] || die "Email не задан."
  [[ "${LE_EMAIL}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "Некорректный email: ${LE_EMAIL}"
}

validate_port() {
  [[ -n "${WG_PORT}" ]] || die "WG_PORT не задан."
  [[ "${WG_PORT}" =~ ^[0-9]+$ ]] || die "WG_PORT должен быть числом."
  (( WG_PORT >= 1 && WG_PORT <= 65535 )) || die "WG_PORT вне диапазона 1..65535."
}

validate_subnet() {
  [[ -n "${WG_DEFAULT_ADDRESS}" ]] || die "WG_DEFAULT_ADDRESS не задан."
  [[ "${WG_DEFAULT_ADDRESS}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] || die "Некорректная подсеть: ${WG_DEFAULT_ADDRESS}"
}

validate_numeric() {
  [[ "${WG_MTU}" =~ ^[0-9]+$ ]] || die "WG_MTU должен быть числом."
  [[ "${WG_PERSISTENT_KEEPALIVE}" =~ ^[0-9]+$ ]] || die "WG_PERSISTENT_KEEPALIVE должен быть числом."
}

load_password_from_file() {
  if [[ -n "${WG_PASSWORD_FILE}" ]]; then
    [[ -f "${WG_PASSWORD_FILE}" ]] || die "Файл с паролем не найден: ${WG_PASSWORD_FILE}"
    WG_PASSWORD="$(head -n1 "${WG_PASSWORD_FILE}" | tr -d '\r')"
  fi
}

validate_password() {
  [[ -n "${WG_PASSWORD}" ]] || die "Пароль для веб-панели не задан."
  if [[ "${#WG_PASSWORD}" -lt 8 ]]; then
    warn "Пароль короче 8 символов."
    confirm_or_exit "Использовать такой пароль?"
  fi
}

prompt_domain() {
  [[ -n "${WG_DOMAIN}" ]] && { ok "Использую домен: ${WG_DOMAIN}"; return; }
  while true; do
    read -r -p "Введите домен для VPN-панели (например vpn.example.com): " WG_DOMAIN
    [[ -n "${WG_DOMAIN}" ]] || { warn "Домен не может быть пустым."; continue; }
    if [[ "${WG_DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]] && [[ "${WG_DOMAIN}" == *.* ]]; then
      break
    fi
    warn "Некорректный домен."
  done
}

prompt_email() {
  [[ -n "${LE_EMAIL}" ]] && { ok "Использую email: ${LE_EMAIL}"; return; }
  while true; do
    read -r -p "Введите email для Let's Encrypt: " LE_EMAIL
    [[ -n "${LE_EMAIL}" ]] || { warn "Email не может быть пустым."; continue; }
    if [[ "${LE_EMAIL}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
      break
    fi
    warn "Некорректный email."
  done
}

prompt_password() {
  if [[ -n "${WG_PASSWORD}" ]]; then
    ok "Пароль для веб-панели получен."
    return
  fi

  while true; do
    read -r -s -p "Введите пароль для веб-интерфейса wg-easy: " WG_PASSWORD
    echo
    [[ -n "${WG_PASSWORD}" ]] || { warn "Пароль не может быть пустым."; continue; }

    local password2
    read -r -s -p "Повторите пароль: " password2
    echo

    [[ "${WG_PASSWORD}" == "${password2}" ]] || { warn "Пароли не совпадают."; continue; }

    if [[ "${#WG_PASSWORD}" -lt 8 ]]; then
      warn "Рекомендуется пароль не короче 8 символов."
      confirm_or_exit "Использовать такой пароль?"
    fi
    break
  done
}

prompt_wg_host() {
  if [[ -n "${WG_HOST}" ]]; then
    ok "Использую endpoint: ${WG_HOST}"
    return
  fi
  read -r -p "Введите публичный IP или DNS-имя WireGuard endpoint [${WG_DOMAIN}]: " WG_HOST
  WG_HOST="${WG_HOST:-$WG_DOMAIN}"
}

prompt_dns() {
  [[ -n "${WG_DNS}" ]] && { ok "Использую DNS: ${WG_DNS}"; return; }
  read -r -p "DNS для клиентов WireGuard [1.1.1.1,8.8.8.8]: " WG_DNS
  WG_DNS="${WG_DNS:-1.1.1.1,8.8.8.8}"
}

prompt_subnet() {
  [[ -n "${WG_DEFAULT_ADDRESS}" ]] && { ok "Использую подсеть: ${WG_DEFAULT_ADDRESS}"; return; }
  read -r -p "Подсеть клиентов WireGuard [10.8.0.0/24]: " WG_DEFAULT_ADDRESS
  WG_DEFAULT_ADDRESS="${WG_DEFAULT_ADDRESS:-10.8.0.0/24}"
}

prompt_port() {
  [[ -n "${WG_PORT}" ]] && { ok "Использую порт: ${WG_PORT}"; return; }
  read -r -p "UDP порт WireGuard [51820]: " WG_PORT
  WG_PORT="${WG_PORT:-51820}"
}

prompt_quiet_requirements() {
  if [[ "${QUIET_MODE}" == "true" ]]; then
    [[ -n "${WG_DOMAIN}" ]] || die "В quiet-режиме нужен --domain"
    [[ -n "${LE_EMAIL}" ]] || die "В quiet-режиме нужен --email"
    [[ -n "${WG_PASSWORD}" || -n "${WG_PASSWORD_FILE}" ]] || die "В quiet-режиме нужен --password или --password-file"
    WG_HOST="${WG_HOST:-$WG_DOMAIN}"
    WG_DNS="${WG_DNS:-1.1.1.1,8.8.8.8}"
    WG_DEFAULT_ADDRESS="${WG_DEFAULT_ADDRESS:-10.8.0.0/24}"
    WG_PORT="${WG_PORT:-51820}"
  fi
}

get_server_ip() {
  SERVER_IP="$(curl -4 -fsSL https://api.ipify.org || true)"
  [[ -n "${SERVER_IP}" ]] || SERVER_IP="UNKNOWN"
}

check_dns_resolution() {
  cyan "==> Проверяю DNS домена..."
  local resolved_ip
  resolved_ip="$(timeout 5 getent ahostsv4 "${WG_DOMAIN}" 2>/dev/null | awk '{print $1}' | head -n1 || true)"

  if [[ -z "${resolved_ip}" ]]; then
    warn "Домен ${WG_DOMAIN} пока не резолвится."
    warn "Let's Encrypt не сможет выпустить сертификат, пока DNS не указывает на сервер."
    confirm_or_exit "Продолжить всё равно?"
    return
  fi

  get_server_ip

  echo "Домен:      ${WG_DOMAIN}"
  echo "DNS -> IP:  ${resolved_ip}"
  echo "Server IP:  ${SERVER_IP}"

  if [[ "${SERVER_IP}" != "UNKNOWN" && "${resolved_ip}" != "${SERVER_IP}" ]]; then
    warn "DNS домена не совпадает с внешним IP сервера."
    confirm_or_exit "Продолжить всё равно?"
  fi
}

check_ports_availability() {
  cyan "==> Проверяю занятость портов..."

  local busy=0

  if ss -lnt "( sport = :80 )" | tail -n +2 | grep -q .; then
    warn "TCP порт 80 уже занят:"
    ss -lntp "( sport = :80 )" || true
    busy=1
  fi

  if ss -lnt "( sport = :443 )" | tail -n +2 | grep -q .; then
    warn "TCP порт 443 уже занят:"
    ss -lntp "( sport = :443 )" || true
    busy=1
  fi

  if ss -lnu "( sport = :${WG_PORT} )" | tail -n +2 | grep -q .; then
    warn "UDP порт ${WG_PORT} уже занят:"
    ss -lnup "( sport = :${WG_PORT} )" || true
    busy=1
  fi

  if [[ "${busy}" -eq 1 ]]; then
    confirm_or_exit "Есть занятые порты. Продолжить?"
  fi
}

configure_firewall() {
  cyan "==> Настраиваю firewall..."
  ufw allow 22/tcp || true
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
  ufw allow "${WG_PORT}/udp" || true

  if ufw status 2>/dev/null | grep -q "Status: inactive"; then
    warn "UFW сейчас выключен."
    if [[ "${QUIET_MODE}" == "false" ]]; then
      read -r -p "Включить UFW сейчас? [y/N]: " ans
      if [[ "${ans,,}" == "y" ]]; then
        ufw --force enable
      fi
    fi
  fi
}

prepare_directories() {
  cyan "==> Подготавливаю каталоги..."
  mkdir -p "${WG_DIR}" "${BACKUP_ROOT}"
}

backup_config() {
  if [[ -f "${ENV_FILE}" || -f "${COMPOSE_FILE}" || -d "${DATA_DIR}" || -f "${NGINX_SITE_AVAIL}" ]]; then
    local backup_dir="${BACKUP_ROOT}/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "${backup_dir}"

    [[ -f "${ENV_FILE}" ]] && cp -a "${ENV_FILE}" "${backup_dir}/"
    [[ -f "${COMPOSE_FILE}" ]] && cp -a "${COMPOSE_FILE}" "${backup_dir}/"
    [[ -d "${DATA_DIR}" ]] && cp -a "${DATA_DIR}" "${backup_dir}/"
    [[ -f "${NGINX_SITE_AVAIL}" ]] && cp -a "${NGINX_SITE_AVAIL}" "${backup_dir}/"

    ok "Существующая конфигурация сохранена в ${backup_dir}"
  else
    info "Существующей конфигурации для бэкапа не найдено."
  fi
}

create_password_hash() {
  cyan "==> Генерирую bcrypt-хэш пароля..."

  docker pull ghcr.io/wg-easy/wg-easy:latest >/dev/null

  PASSWORD_HASH="$(docker run --rm ghcr.io/wg-easy/wg-easy:latest wgpw "${WG_PASSWORD}" 2>/dev/null || true)"
  [[ -n "${PASSWORD_HASH}" ]] || die "Не удалось сгенерировать PASSWORD_HASH."

  ok "Хэш пароля сгенерирован."
}

write_env_file() {
  cyan "==> Создаю .env..."
  cat > "${ENV_FILE}" <<EOF
LANG=ru
WG_HOST=${WG_HOST}
PASSWORD_HASH=${PASSWORD_HASH}
WG_PORT=${WG_PORT}
WG_DEFAULT_ADDRESS=${WG_DEFAULT_ADDRESS}
WG_DEFAULT_DNS=${WG_DNS}
WG_ALLOWED_IPS=${WG_ALLOWED_IPS}
WG_MTU=${WG_MTU}
WG_PERSISTENT_KEEPALIVE=${WG_PERSISTENT_KEEPALIVE}
UI_TRAFFIC_STATS=true
UI_CHART_TYPE=2
EOF
  chmod 600 "${ENV_FILE}"
}

write_compose_file() {
  cyan "==> Создаю docker-compose.yml..."
  cat > "${COMPOSE_FILE}" <<'EOF'
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:latest
    container_name: wg-easy
    restart: unless-stopped
    env_file:
      - .env
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    ports:
      - "51820:51820/udp"
      - "127.0.0.1:51821:51821/tcp"
    volumes:
      - ./data:/etc/wireguard
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
EOF
}

enable_ip_forward() {
  cyan "==> Включаю IP forwarding..."
  cat > /etc/sysctl.d/99-wg-easy.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
EOF
  ROLLBACK_SYSCTL_CREATED=1
  sysctl --system >/dev/null
}

start_wg_easy() {
  cyan "==> Запускаю wg-easy..."
  cd "${WG_DIR}"
  docker compose pull
  docker compose up -d
  ROLLBACK_DOCKER_STARTED=1
}

check_local_panel() {
  cyan "==> Проверяю локальную доступность панели..."
  for _ in {1..20}; do
    if curl -fsSI http://127.0.0.1:51821/ >/dev/null 2>&1; then
      ok "Локальная панель wg-easy отвечает."
      return
    fi
    sleep 2
  done
  die "wg-easy не ответил на http://127.0.0.1:51821/"
}

write_nginx_http_only() {
  cyan "==> Создаю nginx-конфиг для первичного выпуска сертификата..."
  cat > "${NGINX_SITE_AVAIL}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${WG_DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:51821/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

  ln -sf "${NGINX_SITE_AVAIL}" "${NGINX_SITE_ENABLED}"
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
  ROLLBACK_NGINX_CREATED=1
}

check_http_domain_local() {
  cyan "==> Проверяю HTTP-ответ nginx по домену..."
  if curl -fsSI --resolve "${WG_DOMAIN}:80:127.0.0.1" "http://${WG_DOMAIN}/" >/dev/null 2>&1; then
    ok "Nginx отвечает на http://${WG_DOMAIN}"
  else
    warn "Локальная проверка nginx по домену не прошла."
  fi
}

issue_letsencrypt() {
  cyan "==> Выпускаю Let's Encrypt сертификат..."
  ROLLBACK_CERT_ATTEMPTED=1
  certbot --nginx -d "${WG_DOMAIN}" --non-interactive --agree-tos -m "${LE_EMAIL}" --redirect
  ok "Сертификат выпущен и применён."
}

verify_services() {
  cyan "==> Проверяю сервисы..."
  systemctl is-active nginx >/dev/null || die "nginx не активен."
  systemctl is-active docker >/dev/null || die "docker не активен."
  docker ps --format '{{.Names}}' | grep -qx "wg-easy" || die "Контейнер wg-easy не запущен."
}

check_certbot_renew() {
  cyan "==> Проверяю dry-run продления сертификата..."
  if certbot renew --dry-run; then
    ok "Проверка продления сертификата прошла успешно."
  else
    warn "Dry-run продления сертификата завершился с ошибкой. Проверь позже вручную."
  fi
}

show_post_install_info() {
  green "=============================================="
  green "Установка завершена успешно"
  green "=============================================="
  echo "Версия скрипта: ${SCRIPT_VERSION}"
  echo "Лог установки:  ${LOG_FILE}"
  echo
  echo "Панель wg-easy: https://${WG_DOMAIN}"
  echo "Endpoint VPN:   ${WG_HOST}:${WG_PORT}/udp"
  echo "Каталог:        ${WG_DIR}"
  echo
  echo "Полезные команды:"
  echo "  cd ${WG_DIR} && docker compose ps"
  echo "  cd ${WG_DIR} && docker compose logs -f"
  echo "  docker ps"
  echo "  systemctl status nginx --no-pager"
  echo
  echo "Проверка сертификата:"
  echo "  openssl s_client -connect ${WG_DOMAIN}:443 -servername ${WG_DOMAIN} </dev/null | openssl x509 -noout -issuer -subject -dates"
  echo
  echo "Проверка панели:"
  echo "  curl -Ik https://${WG_DOMAIN}"
  echo
  yellow "Важно:"
  echo "1) Убедись, что UDP ${WG_PORT} доступен извне."
  echo "2) Если VPS/провайдер режет UDP, WireGuard не поднимется."
  echo "3) Для quiet-режима используй --password-file, а не --password."
}

main() {
  parse_args "$@"

  need_root
  need_ubuntu_2204
  check_required_tools_minimal
  check_disk_space
  install_base_packages
  install_docker

  prompt_quiet_requirements

  if [[ "${QUIET_MODE}" == "true" ]]; then
    load_password_from_file
  fi

  prompt_domain
  prompt_email

  if [[ -n "${WG_PASSWORD_FILE}" && -z "${WG_PASSWORD}" ]]; then
    load_password_from_file
  fi
  prompt_password

  prompt_wg_host
  prompt_dns
  prompt_subnet
  prompt_port

  validate_domain
  validate_email
  validate_port
  validate_subnet
  validate_numeric
  validate_password

  check_dns_resolution
  check_ports_availability
  configure_firewall
  prepare_directories
  backup_config
  create_password_hash
  write_env_file
  write_compose_file
  enable_ip_forward
  start_wg_easy
  check_local_panel
  write_nginx_http_only
  check_http_domain_local
  issue_letsencrypt
  verify_services
  check_certbot_renew
  show_post_install_info
}

main "$@"
