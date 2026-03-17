#!/usr/bin/env bash
set -Eeuo pipefail

# =========================================================
# Установка WireGuard/wg-easy + Nginx + Let's Encrypt
# Ubuntu Server 22.04
# Авторская заготовка для быстрого развёртывания
# =========================================================

WG_DIR="/opt/wg-easy"
COMPOSE_FILE="${WG_DIR}/docker-compose.yml"
ENV_FILE="${WG_DIR}/.env"
NGINX_SITE_AVAIL="/etc/nginx/sites-available/wg-easy"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/wg-easy"

red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
cyan()   { printf '\033[1;36m%s\033[0m\n' "$*"; }

die() {
  red "ERROR: $*"
  exit 1
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Запусти скрипт от root."
  fi
}

need_ubuntu_2204() {
  if [[ ! -f /etc/os-release ]]; then
    die "Не найден /etc/os-release."
  fi
  . /etc/os-release

  if [[ "${ID:-}" != "ubuntu" ]]; then
    die "Скрипт рассчитан на Ubuntu."
  fi

  if [[ "${VERSION_ID:-}" != "22.04" ]]; then
    yellow "Предупреждение: скрипт рассчитан на Ubuntu 22.04, у тебя ${VERSION_ID:-unknown}."
    read -r -p "Продолжить? [y/N]: " ans
    [[ "${ans,,}" == "y" ]] || exit 1
  fi
}

check_command() {
  command -v "$1" >/dev/null 2>&1
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
    openssl
}

install_docker() {
  if check_command docker; then
    green "Docker уже установлен."
    return
  fi

  cyan "==> Устанавливаю Docker..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  . /etc/os-release
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  systemctl enable --now docker
  green "Docker установлен."
}

prompt_domain() {
  while true; do
    read -r -p "Введите домен для VPN-панели (например vpn.example.com): " WG_DOMAIN
    [[ -n "${WG_DOMAIN}" ]] || { yellow "Домен не может быть пустым."; continue; }

    if [[ "${WG_DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]] && [[ "${WG_DOMAIN}" == *.* ]]; then
      break
    fi
    yellow "Некорректный домен. Попробуй ещё раз."
  done
}

prompt_email() {
  while true; do
    read -r -p "Введите email для Let's Encrypt уведомлений: " LE_EMAIL
    [[ -n "${LE_EMAIL}" ]] || { yellow "Email не может быть пустым."; continue; }

    if [[ "${LE_EMAIL}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
      break
    fi
    yellow "Некорректный email. Попробуй ещё раз."
  done
}

prompt_password() {
  while true; do
    read -r -s -p "Введите пароль для веб-интерфейса wg-easy: " WG_PASSWORD
    echo
    [[ -n "${WG_PASSWORD}" ]] || { yellow "Пароль не может быть пустым."; continue; }

    read -r -s -p "Повторите пароль: " WG_PASSWORD2
    echo

    if [[ "${WG_PASSWORD}" != "${WG_PASSWORD2}" ]]; then
      yellow "Пароли не совпадают."
      continue
    fi

    if [[ "${#WG_PASSWORD}" -lt 8 ]]; then
      yellow "Рекомендуется пароль не короче 8 символов."
      read -r -p "Использовать всё равно? [y/N]: " ans
      [[ "${ans,,}" == "y" ]] || continue
    fi
    break
  done
}

prompt_wg_host() {
  while true; do
    read -r -p "Введите публичный IP или DNS-имя WireGuard endpoint [${WG_DOMAIN}]: " WG_HOST
    WG_HOST="${WG_HOST:-$WG_DOMAIN}"
    [[ -n "${WG_HOST}" ]] && break
  done
}

prompt_dns() {
  read -r -p "DNS для клиентов WireGuard [1.1.1.1,8.8.8.8]: " WG_DNS
  WG_DNS="${WG_DNS:-1.1.1.1,8.8.8.8}"
}

prompt_subnet() {
  read -r -p "Подсеть клиентов WireGuard [10.8.0.0/24]: " WG_DEFAULT_ADDRESS
  WG_DEFAULT_ADDRESS="${WG_DEFAULT_ADDRESS:-10.8.0.0/24}"
}

prompt_port() {
  read -r -p "UDP порт WireGuard [51820]: " WG_PORT
  WG_PORT="${WG_PORT:-51820}"
  [[ "${WG_PORT}" =~ ^[0-9]+$ ]] || die "Порт должен быть числом."
}

get_server_ip() {
  SERVER_IP="$(curl -4 -fsSL https://api.ipify.org || true)"
  if [[ -z "${SERVER_IP}" ]]; then
    yellow "Не удалось автоматически определить внешний IP."
    SERVER_IP="UNKNOWN"
  fi
}

check_dns_resolution() {
  cyan "==> Проверяю DNS домена..."
  RESOLVED_IP="$(getent ahostsv4 "${WG_DOMAIN}" 2>/dev/null | awk '{print $1}' | head -n1 || true)"

  if [[ -z "${RESOLVED_IP}" ]]; then
    yellow "Домен ${WG_DOMAIN} пока не резолвится."
    yellow "Let's Encrypt может не выпуститься, пока DNS не указывает на сервер."
    read -r -p "Продолжить всё равно? [y/N]: " ans
    [[ "${ans,,}" == "y" ]] || exit 1
    return
  fi

  get_server_ip

  echo "Домен:      ${WG_DOMAIN}"
  echo "DNS -> IP:  ${RESOLVED_IP}"
  echo "Server IP:  ${SERVER_IP}"

  if [[ "${SERVER_IP}" != "UNKNOWN" && "${RESOLVED_IP}" != "${SERVER_IP}" ]]; then
    yellow "DNS домена не совпадает с внешним IP сервера."
    read -r -p "Продолжить всё равно? [y/N]: " ans
    [[ "${ans,,}" == "y" ]] || exit 1
  fi
}

configure_firewall() {
  cyan "==> Настраиваю firewall..."
  ufw allow 22/tcp || true
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
  ufw allow "${WG_PORT}"/udp || true

  if ufw status | grep -q "Status: inactive"; then
    yellow "UFW сейчас выключен."
    read -r -p "Включить UFW сейчас? [y/N]: " ans
    if [[ "${ans,,}" == "y" ]]; then
      ufw --force enable
    fi
  fi
}

prepare_directories() {
  cyan "==> Подготавливаю каталоги..."
  mkdir -p "${WG_DIR}"
}

create_password_hash() {
  cyan "==> Генерирую bcrypt-хэш пароля..."
  WG_PASSWORD_HASH="$(
    docker run --rm ghcr.io/wg-easy/wg-easy:latest wgpw "${WG_PASSWORD}" 2>/dev/null \
      || true
  )"

  if [[ -z "${WG_PASSWORD_HASH}" ]]; then
    yellow "Не удалось получить хэш через образ wg-easy, пробую через node..."
    WG_PASSWORD_HASH="$(
      docker run --rm node:20-alpine sh -c \
      "npm -s install bcryptjs >/dev/null 2>&1 && node -e \"const bcrypt=require('bcryptjs'); console.log(bcrypt.hashSync(process.argv[1], 10))\" '${WG_PASSWORD}'" \
      2>/dev/null | tail -n1 || true
    )"
  fi

  [[ -n "${WG_PASSWORD_HASH}" ]] || die "Не удалось сгенерировать bcrypt-хэш для пароля."
}

write_env_file() {
  cyan "==> Создаю .env..."
  cat > "${ENV_FILE}" <<EOF
LANG=ru
WG_HOST=${WG_HOST}
PASSWORD_HASH=${WG_PASSWORD_HASH}
WG_PORT=${WG_PORT}
WG_DEFAULT_ADDRESS=${WG_DEFAULT_ADDRESS}
WG_DEFAULT_DNS=${WG_DNS}
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
  sysctl --system >/dev/null
}

start_wg_easy() {
  cyan "==> Запускаю wg-easy..."
  cd "${WG_DIR}"
  docker compose pull
  docker compose up -d
}

write_nginx_http_only() {
  cyan "==> Создаю nginx-конфиг под первичный выпуск сертификата..."
  cat > "${NGINX_SITE_AVAIL}" <<EOF
server {
    listen 80;
    server_name ${WG_DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:51821/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

  ln -sf "${NGINX_SITE_AVAIL}" "${NGINX_SITE_ENABLED}"
  rm -f /etc/nginx/sites-enabled/default

  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
}

issue_letsencrypt() {
  cyan "==> Выпускаю Let's Encrypt сертификат..."
  certbot --nginx -d "${WG_DOMAIN}" --non-interactive --agree-tos -m "${LE_EMAIL}" --redirect
}

verify_services() {
  cyan "==> Проверяю сервисы..."
  systemctl is-active nginx >/dev/null || die "nginx не активен."
  systemctl is-active docker >/dev/null || die "docker не активен."
  docker ps | grep -q "wg-easy" || die "Контейнер wg-easy не запущен."
}

show_result() {
  green "=============================================="
  green "Установка завершена."
  green "=============================================="
  echo "Панель wg-easy: https://${WG_DOMAIN}"
  echo "WireGuard endpoint: ${WG_HOST}:${WG_PORT}/udp"
  echo "Каталог проекта: ${WG_DIR}"
  echo
  echo "Проверка контейнера:"
  echo "  cd ${WG_DIR} && docker compose ps"
  echo
  echo "Просмотр логов:"
  echo "  cd ${WG_DIR} && docker compose logs -f"
  echo
  echo "Проверка сертификата:"
  echo "  openssl s_client -connect ${WG_DOMAIN}:443 -servername ${WG_DOMAIN} </dev/null | openssl x509 -noout -issuer -subject -dates"
  echo
  yellow "Важно:"
  echo "1) Убедись, что домен ${WG_DOMAIN} указывает на этот сервер."
  echo "2) Для клиентов WireGuard понадобится открыть UDP ${WG_PORT}."
  echo "3) Если провайдер/VPS режет UDP, туннель не поднимется."
}

main() {
  need_root
  need_ubuntu_2204
  install_base_packages
  install_docker

  prompt_domain
  prompt_email
  prompt_password
  prompt_wg_host
  prompt_dns
  prompt_subnet
  prompt_port

  check_dns_resolution
  configure_firewall
  prepare_directories
  create_password_hash
  write_env_file
  write_compose_file
  enable_ip_forward
  start_wg_easy
  write_nginx_http_only
  issue_letsencrypt
  verify_services
  show_result
}

main "$@"
