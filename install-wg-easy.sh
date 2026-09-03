#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="2.3.0-tui-fixed"
BACKTITLE="  WireGuard VPN + wg-easy  ▸  v${SCRIPT_VERSION}  ▸  sysnotes.ru  "
DW=74   # ширина всех диалогов

# ─────────────────────────────── Пути ───────────────────────────────
WG_DIR="/opt/wg-easy"
COMPOSE_FILE="${WG_DIR}/docker-compose.yml"
ENV_FILE="${WG_DIR}/wg.env"
DATA_DIR="${WG_DIR}/data"
BACKUP_ROOT="${WG_DIR}/backups"
NGINX_SITE_NAME="wg-easy"
NGINX_SITE_AVAIL="/etc/nginx/sites-available/${NGINX_SITE_NAME}"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/${NGINX_SITE_NAME}"

# ─────────────────────────────── Лог ───────────────────────────────
LOG_FILE="/var/log/wg-easy-install-$(date +%Y%m%d-%H%M%S).log"
touch "$LOG_FILE" 2>/dev/null \
  || LOG_FILE="/tmp/wg-easy-install-$(date +%Y%m%d-%H%M%S).log"
chmod 600 "$LOG_FILE" 2>/dev/null || true

# ─────────────────────────────── Параметры ───────────────────────────────
WG_DOMAIN=""
LE_EMAIL=""
WG_PASSWORD=""
WG_HOST=""
WG_DNS="1.1.1.1,8.8.8.8"
WG_DEFAULT_ADDRESS="10.8.0.x/24"
WG_PORT="51820"
WG_ALLOWED_IPS="0.0.0.0/0,::/0"
WG_MTU="1420"
WG_PERSISTENT_KEEPALIVE="25"
WG_DEVICE=""
PASSWORD_HASH=""
VERSION_CODENAME=""   # заполняется из /etc/os-release

# ─────────────────────────────── Флаги отката ───────────────────────────────
ROLLBACK_NGINX_CREATED=0
ROLLBACK_DOCKER_STARTED=0
ROLLBACK_SYSCTL_CREATED=0
ROLLBACK_CERT_ATTEMPTED=0
_ENVFILE=""
_LAST_ERROR=""

# ─────────────────────────────── Прогресс ───────────────────────────────
PROGRESS_STEP=0
PROGRESS_TOTAL=12

# ═══════════════════════════════════════════════════════
#  TUI хелперы
# ═══════════════════════════════════════════════════════

wt_msgbox() {
    local title="$1" msg="$2" h="${3:-12}"
    whiptail --backtitle "$BACKTITLE" --title "$title" \
        --msgbox "$msg" "$h" "$DW" \
        >/dev/tty 2>/dev/null </dev/tty
}

wt_infobox() {
    local title="$1" msg="$2" h="${3:-10}"
    whiptail --backtitle "$BACKTITLE" --title "$title" \
        --infobox "$msg" "$h" "$DW" \
        >/dev/tty 2>/dev/null
}

wt_yesno() {
    local title="$1" msg="$2" h="${3:-10}"
    whiptail --backtitle "$BACKTITLE" --title "$title" \
        --yesno "$msg" "$h" "$DW" \
        >/dev/tty 2>/dev/null </dev/tty
}

wt_input() {
    local title="$1" msg="$2" default="${3:-}"
    local tmpf; tmpf=$(mktemp)
    whiptail --backtitle "$BACKTITLE" --title "$title" \
        --inputbox "$msg" 11 "$DW" "$default" \
        >/dev/tty 2>"$tmpf" </dev/tty
    local rc=$?; cat "$tmpf"; rm -f "$tmpf"; return $rc
}

wt_password() {
    local title="$1" msg="$2"
    local tmpf; tmpf=$(mktemp)
    whiptail --backtitle "$BACKTITLE" --title "$title" \
        --passwordbox "$msg" 10 "$DW" "" \
        >/dev/tty 2>"$tmpf" </dev/tty
    local rc=$?; cat "$tmpf"; rm -f "$tmpf"; return $rc
}

wt_menu() {
    local title="$1" msg="$2" h="$3"; shift 3
    local tmpf; tmpf=$(mktemp)
    whiptail --backtitle "$BACKTITLE" --title "$title" \
        --menu "$msg" "$h" "$DW" $(( h - 8 )) \
        "$@" \
        >/dev/tty 2>"$tmpf" </dev/tty
    local rc=$?; cat "$tmpf"; rm -f "$tmpf"; return $rc
}

confirm_exit() {
    if wt_yesno " Выход из установщика" \
"
  Выйти из мастера установки?

  Введённые данные не сохранятся.
  Уже установленные компоненты останутся." 11; then
        exit 0
    fi
}

show_step() {
    PROGRESS_STEP=$(( PROGRESS_STEP + 1 ))
    local msg="$1"
    local pct=$(( PROGRESS_STEP * 100 / PROGRESS_TOTAL ))
    local bw=54 filled=$(( pct * 54 / 100 )) i bar=""
    for (( i=0; i<filled; i++ )); do bar+="▓"; done
    for (( i=filled; i<bw; i++ )); do bar+="░"; done

    wt_infobox " Установка  ▸  шаг ${PROGRESS_STEP} / ${PROGRESS_TOTAL}" \
"
  ▸  ${msg}

  [${bar}]
      ${pct}%

  Лог: ${LOG_FILE}" 13
}

# ═══════════════════════════════════════════════════════
#  Откат + Trap
# ═══════════════════════════════════════════════════════

cleanup() {
    local exit_code=$?
    [[ "${exit_code}" -eq 0 ]] && return

    [[ -n "${_ENVFILE:-}" && -f "${_ENVFILE}" ]] \
        && rm -f "${_ENVFILE}" 2>/dev/null || true

    [[ "${ROLLBACK_DOCKER_STARTED}" -eq 1 && -f "${COMPOSE_FILE}" ]] && \
        (cd "${WG_DIR}" 2>/dev/null && docker compose down) >>"$LOG_FILE" 2>&1 || true

    if [[ "${ROLLBACK_NGINX_CREATED}" -eq 1 ]]; then
        rm -f "${NGINX_SITE_ENABLED}" "${NGINX_SITE_AVAIL}" 2>/dev/null || true
        nginx -t >>"$LOG_FILE" 2>&1 \
            && systemctl reload nginx >>"$LOG_FILE" 2>&1 || true
    fi

    if [[ "${ROLLBACK_SYSCTL_CREATED}" -eq 1 ]]; then
        rm -f /etc/sysctl.d/99-wg-easy.conf 2>/dev/null || true
        sysctl --system >>"$LOG_FILE" 2>&1 || true
    fi

    [[ "${ROLLBACK_CERT_ATTEMPTED}" -eq 1 && -n "${WG_DOMAIN:-}" ]] && \
        echo "[WARN] Проверь вручную certbot/nginx для ${WG_DOMAIN}" >>"$LOG_FILE" || true

    local detail=""
    [[ -n "${_LAST_ERROR:-}" ]] \
        && detail="\n\n  Причина:\n    ${_LAST_ERROR}"

    wt_msgbox " ❌  Установка прервана" \
"${detail}

  Изменения откачены.

  Детали ошибки:
    tail -50 ${LOG_FILE}

  Лог установки:
    ${LOG_FILE}" 18
}
trap cleanup EXIT

die() {
    _LAST_ERROR="$*"
    echo "ERROR: $*" >>"$LOG_FILE" 2>/dev/null || true
    exit 1
}

# ═══════════════════════════════════════════════════════
#  Предварительные проверки (до TUI)
# ═══════════════════════════════════════════════════════

need_root() {
    [[ "${EUID}" -eq 0 ]] && return
    echo ""
    echo "  Ошибка: скрипт должен быть запущен от root."
    echo "  Выполни:  sudo bash $0"
    echo ""
    exit 1
}

ensure_whiptail() {
    command -v whiptail &>/dev/null && return
    echo "  Устанавливаю whiptail..." >&2
    apt-get update -q >>"$LOG_FILE" 2>&1
    apt-get install -y whiptail >>"$LOG_FILE" 2>&1 \
        || { echo "  Не удалось установить whiptail." >&2; exit 1; }
}

check_os_version() {
    [[ -f /etc/os-release ]] || { echo "Не найден /etc/os-release." >&2; exit 1; }
    # shellcheck source=/etc/os-release
    . /etc/os-release
    VERSION_CODENAME="${VERSION_CODENAME:-}"

    [[ "${ID:-}" == "ubuntu" ]] \
        || { wt_msgbox " ❌  Ошибка" "\n  Скрипт рассчитан на Ubuntu." 8; exit 1; }

    if [[ "${VERSION_ID:-}" != "22.04" ]]; then
        wt_yesno " ⚠  Совместимость" \
"
  Скрипт рассчитан на Ubuntu 22.04.
  Обнаружена версия: ${VERSION_ID:-unknown}

  Продолжить установку на этой версии?" 11 || exit 0
    fi
}

# ═══════════════════════════════════════════════════════
#  Мастер настройки (7 шагов)
# ═══════════════════════════════════════════════════════

wiz_welcome() {
    wt_msgbox " 🛡  WireGuard VPN + wg-easy  —  Мастер установки" \
"
  Этот мастер установит полноценный VPN-сервер:

    ●  Docker + wg-easy  (WireGuard с веб-панелью)
    ●  Nginx reverse proxy
    ●  Let's Encrypt SSL  (автопродление)
    ●  UFW firewall

  Требования перед запуском:
    ✔  Ubuntu 22.04+
    ✔  Публичный IP на сервере
    ✔  DNS-домен, уже указывающий на этот IP
    ✔  Порты: 80/tcp  443/tcp  51820/udp  51821/tcp (для wg-easy)

  Навигация:   Enter / Стрелки / Tab
  Отмена:      ESC  или  Ctrl+C

  Нажми Enter для начала." 23 || exit 0
}

wiz_domain() {
    local T=" ⚙  Шаг 1 / 7  —  Домен"
    while true; do
        local val
        if ! val=$(wt_input "$T" \
"  Домен для веб-панели wg-easy.

  Пример:   vpn.example.com

  Важно: домен должен уже указывать на IP этого
  сервера — Let's Encrypt проверит это при выпуске
  SSL-сертификата.

  Домен:" "${WG_DOMAIN}"); then
            confirm_exit || true; continue
        fi

        [[ -n "$val" ]] \
            || { wt_msgbox " ⚠" "\n  Домен не может быть пустым." 7; continue; }

        if [[ "$val" =~ ^[A-Za-z0-9.-]+$ ]] && [[ "$val" == *.* ]]; then
            WG_DOMAIN="$val"
            [[ -z "$WG_HOST" ]] && WG_HOST="$val"
            break
        fi
        wt_msgbox " ⚠  Некорректный домен" \
"
  '${val}'

  Допустимы: буквы, цифры, дефисы, точки.
  Должна быть минимум одна точка.
  Пример:  vpn.example.com" 12
    done
}

wiz_email() {
    local T=" ⚙  Шаг 2 / 7  —  Email"
    while true; do
        local val
        if ! val=$(wt_input "$T" \
"  Email для Let's Encrypt.

  На него придут уведомления об истечении
  SSL-сертификата. Используется только для
  уведомлений, не для аутентификации.

  Email:" "${LE_EMAIL}"); then
            confirm_exit || true; continue
        fi

        [[ -n "$val" ]] \
            || { wt_msgbox " ⚠" "\n  Email не может быть пустым." 7; continue; }

        if [[ "$val" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
            LE_EMAIL="$val"; break
        fi
        wt_msgbox " ⚠  Некорректный email" \
"
  '${val}'

  Пример:  admin@example.com" 9
    done
}

wiz_password() {
    local T=" ⚙  Шаг 3 / 7  —  Пароль для панели"
    while true; do
        local p1 p2

        if ! p1=$(wt_password "$T" \
"  Пароль для входа в веб-панель wg-easy.

  Рекомендуется: 12+ символов,
  буквы + цифры + спецсимволы.

  Пароль:"); then
            confirm_exit || true; continue
        fi

        [[ -n "$p1" ]] \
            || { wt_msgbox " ⚠" "\n  Пароль не может быть пустым." 7; continue; }

        if ! p2=$(wt_password "$T" \
"  Повтори пароль для подтверждения.


  Подтверждение:"); then
            continue   # Отмена → вернуться к первому полю
        fi

        if [[ "$p1" != "$p2" ]]; then
            wt_msgbox " ⚠  Пароли не совпадают" \
"\n  Введённые пароли отличаются.\n  Попробуй ещё раз." 9
            continue
        fi

        if [[ "${#p1}" -lt 8 ]]; then
            wt_yesno " ⚠  Короткий пароль" \
"
  Пароль содержит ${#p1} символов.
  Рекомендуется минимум 8 символов.

  Использовать такой пароль?" 11 || continue
        fi

        WG_PASSWORD="$p1"; break
    done
}

wiz_endpoint() {
    local T=" ⚙  Шаг 4 / 7  —  VPN Endpoint"
    while true; do
        local val
        if ! val=$(wt_input "$T" \
"  Публичный адрес сервера для подключения клиентов.

  Это IP или DNS-имя, которое клиенты WireGuard
  будут использовать в своих конфигах.

  Оставь пустым → будет использован домен:
  '${WG_DOMAIN}'

  Endpoint (IP или hostname):" "${WG_HOST}"); then
            confirm_exit || true; continue
        fi
        WG_HOST="${val:-${WG_DOMAIN}}"; break
    done
}

wiz_dns() {
    local T=" ⚙  Шаг 5 / 7  —  DNS для клиентов VPN"
    while true; do
        local choice
        if ! choice=$(wt_menu "$T" \
"  DNS-серверы для клиентов при подключении к VPN.
  Выбери готовый вариант или введи свой:" 20 \
            "cf+g" "  1.1.1.1, 8.8.8.8       Cloudflare + Google   ★ рекомендуется" \
            "goog" "  8.8.8.8, 8.8.4.4       Google DNS" \
            "cf"   "  1.1.1.1, 1.0.0.1       Cloudflare" \
            "adg"  "  94.140.14.14, ...       AdGuard  (блокирует рекламу)" \
            "own"  "  Ввести вручную..."); then
            confirm_exit || true; continue
        fi

        case "$choice" in
            cf+g) WG_DNS="1.1.1.1,8.8.8.8";           break ;;
            goog) WG_DNS="8.8.8.8,8.8.4.4";            break ;;
            cf)   WG_DNS="1.1.1.1,1.0.0.1";            break ;;
            adg)  WG_DNS="94.140.14.14,94.140.15.15";  break ;;
            own)
                while true; do
                    local val
                    if ! val=$(wt_input "$T" \
"  Введи DNS-серверы через запятую (без пробелов).

  Примеры:
    1.1.1.1,8.8.8.8
    192.168.1.1,8.8.8.8

  DNS-серверы:" "${WG_DNS}"); then
                        break   # Отмена → вернуться в меню
                    fi
                    [[ -n "$val" ]] && { WG_DNS="$val"; return; }
                    wt_msgbox " ⚠" "\n  Поле не может быть пустым." 7
                done
                ;;
        esac
    done
}

wiz_network() {
    local T=" ⚙  Шаг 6 / 7  —  Сетевые настройки"

    # ── Шаблон адресов клиентов ──
    while true; do
        local val
        if ! val=$(wt_input "$T" \
"  Шаблон IP-адресов для клиентов WireGuard.

  'x' → заменяется номером клиента:
    клиент 1 получит 10.8.0.1/24
    клиент 2 получит 10.8.0.2/24  и т.д.

  ⚠  Формат: A.B.C.x/PREFIX
     НЕ обычный CIDR (не 10.8.0.0/24!)

  Шаблон адреса:" "${WG_DEFAULT_ADDRESS}"); then
            confirm_exit || true; continue
        fi

        local re='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.x/([0-9]{1,2})$'
        if [[ "$val" =~ $re ]]; then
            local o1="${BASH_REMATCH[1]}" o2="${BASH_REMATCH[2]}" \
                  o3="${BASH_REMATCH[3]}" pfx="${BASH_REMATCH[4]}"
            if (( o1<=255 && o2<=255 && o3<=255 && pfx>=1 && pfx<=30 )); then
                WG_DEFAULT_ADDRESS="$val"; break
            fi
        fi
        wt_msgbox " ⚠  Неверный формат" \
"
  '${val}'

  Ожидается:  A.B.C.x/PREFIX
  Пример:     10.8.0.x/24
  Диапазон:   октеты 0-255, PREFIX 1-30" 12
    done

    # ── UDP порт WireGuard ──
    while true; do
        local val
        if ! val=$(wt_input "$T" \
"  UDP-порт WireGuard на сервере.

  Стандарт: 51820
  Диапазон:  1 – 65535

  ⚠  Этот порт должен быть открыт у провайдера.
     Некоторые VPS/провайдеры блокируют нестандартные
     UDP-порты.

  UDP порт:" "${WG_PORT}"); then
            confirm_exit || true; continue
        fi

        if [[ "$val" =~ ^[0-9]+$ ]] && (( val >= 1 && val <= 65535 )); then
            WG_PORT="$val"; break
        fi
        wt_msgbox " ⚠  Неверный порт" \
"\n  Порт должен быть числом от 1 до 65535.\n\n  Введено: '${val}'" 9
    done
}

wiz_interface() {
    local T=" ⚙  Шаг 7 / 7  —  Сетевой интерфейс"

    local iface_args=()
    while IFS= read -r line; do
        local iface state
        iface=$(awk '{print $1}' <<< "$line")
        state=$(awk '{print $2}' <<< "$line")
        [[ "$iface" == "lo" ]] && continue
        iface_args+=("$iface" "$(printf '%-14s  [%s]' "$iface" "$state")")
    done < <(ip -br link show 2>/dev/null)
    iface_args+=("manual" "  Ввести имя вручную...")

    while true; do
        local h=$(( ${#iface_args[@]} / 2 + 11 ))
        (( h > 22 )) && h=22

        local choice
        if ! choice=$(wt_menu "$T" \
"  Основной сетевой интерфейс сервера.

  Используется в командах диагностики трафика.
  wg-easy самостоятельно определяет маршрутизацию.

  Интерфейс:" "$h" "${iface_args[@]}"); then
            confirm_exit || true; continue
        fi

        if [[ "$choice" == "manual" ]]; then
            local val
            if ! val=$(wt_input "$T" \
"  Введи имя сетевого интерфейса.

  Примеры: eth0  ens3  ens18  enp1s0

  Интерфейс:" "${WG_DEVICE:-eth0}"); then
                continue
            fi
            WG_DEVICE="${val:-eth0}"
        else
            WG_DEVICE="$choice"
        fi
        break
    done
}

wiz_summary() {
    local stars; stars=$(printf '%0.s●' $(seq 1 "${#WG_PASSWORD}"))
    (( "${#WG_PASSWORD}" > 14 )) && stars="●●●●●●●●●●●●●●..."

    wt_yesno " 📋  Параметры установки — подтверждение" \
"
  Домен панели:   ${WG_DOMAIN}
  Email (LE):     ${LE_EMAIL}
  Пароль:         ${stars}

  Endpoint VPN:   ${WG_HOST}:${WG_PORT}/udp
  DNS клиентов:   ${WG_DNS}
  Подсеть:        ${WG_DEFAULT_ADDRESS}
  Интерфейс:      ${WG_DEVICE}
  AllowedIPs:     ${WG_ALLOWED_IPS}

  ─────────────────────────────────────────────────────
    Да  — начать установку
    Нет — изменить параметры (вернуться к шагу 1)" 23
}

run_wizard() {
    wiz_welcome
    while true; do
        wiz_domain
        wiz_email
        wiz_password
        wiz_endpoint
        wiz_dns
        wiz_network
        wiz_interface
        wiz_summary && break
    done
}

# ═══════════════════════════════════════════════════════
#  Проверки окружения (TUI-диалоги, до exec redirect)
# ═══════════════════════════════════════════════════════

env_check_disk() {
    local req_mb=1024 avail_kb avail_mb
    avail_kb="$(df / --output=avail | tail -1 | tr -d ' ')"
    avail_mb=$(( avail_kb / 1024 ))
    (( avail_mb >= req_mb )) && return 0

    wt_yesno " ⚠  Мало места на диске" \
"
  Свободно на /:   ${avail_mb} MB
  Рекомендуется:   ${req_mb} MB

  При нехватке места установка Docker-образа
  или пакетов может завершиться с ошибкой.

  Продолжить несмотря на предупреждение?" 14 || exit 0
}

env_check_dns() {
    wt_infobox " Проверка DNS" \
        "\n  Проверяю DNS-запись для '${WG_DOMAIN}'...\n" 7
    sleep 1

    local resolved_ip server_ip="UNKNOWN"
    resolved_ip="$(timeout 5 getent ahostsv4 "${WG_DOMAIN}" 2>/dev/null \
        | awk '{print $1}' | head -n1 || true)"
    server_ip="$(curl -4 -fsSL --max-time 5 https://api.ipify.org 2>/dev/null \
        || echo 'UNKNOWN')"

    if [[ -z "$resolved_ip" ]]; then
        wt_yesno " ⚠  DNS не резолвится" \
"
  Домен '${WG_DOMAIN}' не резолвится.

  IP сервера:   ${server_ip}

  Let's Encrypt не выдаст сертификат, пока
  DNS не указывает на IP этого сервера.

  Продолжить всё равно?" 15 || exit 0
        return
    fi

    if [[ "$server_ip" != "UNKNOWN" && "$resolved_ip" != "$server_ip" ]]; then
        wt_yesno " ⚠  DNS не совпадает с IP" \
"
  Домен:          ${WG_DOMAIN}
  DNS → IP:       ${resolved_ip}
  IP сервера:     ${server_ip}

  Адреса не совпадают.
  Let's Encrypt может не выдать сертификат.

  Продолжить всё равно?" 16 || exit 0
    fi
}

env_check_ports() {
    local msg=""
    ss -lnt "( sport = :80 )"        | tail -n +2 | grep -q . \
        && msg+="    TCP 80    (HTTP)\n"
    ss -lnt "( sport = :443 )"       | tail -n +2 | grep -q . \
        && msg+="    TCP 443   (HTTPS)\n"
    ss -lnu "( sport = :${WG_PORT} )" | tail -n +2 | grep -q . \
        && msg+="    UDP ${WG_PORT}  (WireGuard)\n"
    ss -lnt "( sport = :51821 )"     | tail -n +2 | grep -q . \
        && msg+="    TCP 51821 (wg-easy web)\n"

    [[ -z "$msg" ]] && return 0

    wt_yesno " ⚠  Занятые порты" \
"
  Следующие порты уже используются:

${msg}
  При переустановке — это нормально.
  При первой установке — возможен конфликт.

  Продолжить?" 17 || exit 0
}

# ═══════════════════════════════════════════════════════
#  Установочные функции
# ═══════════════════════════════════════════════════════

inst_base_packages() {
    apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        ca-certificates curl gnupg lsb-release apt-transport-https \
        software-properties-common nginx certbot python3-certbot-nginx \
        ufw openssl dnsutils iproute2
}

inst_docker() {
    if command -v docker &>/dev/null; then
        systemctl is-active docker &>/dev/null || systemctl enable --now docker
        docker compose version &>/dev/null \
            || die "docker compose plugin не найден. Переустанови Docker."
        return
    fi
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    docker compose version &>/dev/null \
        || die "docker compose plugin не найден после установки."
}

inst_firewall() {
    ufw allow 22/tcp   comment 'SSH'          || true
    ufw allow 80/tcp   comment 'HTTP'         || true
    ufw allow 443/tcp  comment 'HTTPS'        || true
    ufw allow "${WG_PORT}/udp" comment 'WireGuard' || true
    if ufw status 2>/dev/null | grep -q "Status: inactive"; then
        ufw --force enable || true
    fi
}

inst_dirs_backup() {
    mkdir -p "${WG_DIR}" "${BACKUP_ROOT}"

    local data_ok=0
    [[ -d "${DATA_DIR}" && -n "$(ls -A "${DATA_DIR}" 2>/dev/null)" ]] && data_ok=1

    local need=0
    [[ -f "${ENV_FILE}" ]]       && need=1
    [[ -f "${COMPOSE_FILE}" ]]   && need=1
    [[ -f "${NGINX_SITE_AVAIL}" ]] && need=1
    [[ "${data_ok}" -eq 1 ]]     && need=1
    [[ "${need}" -eq 0 ]] && return 0

    local bdir="${BACKUP_ROOT}/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "${bdir}"
    [[ -f "${ENV_FILE}" ]]         && cp -a "${ENV_FILE}"         "${bdir}/"
    [[ -f "${COMPOSE_FILE}" ]]     && cp -a "${COMPOSE_FILE}"     "${bdir}/"
    [[ -f "${NGINX_SITE_AVAIL}" ]] && cp -a "${NGINX_SITE_AVAIL}" "${bdir}/"
    [[ "${data_ok}" -eq 1 ]]       && cp -a "${DATA_DIR}"         "${bdir}/"
    echo "[INFO] Бэкап сохранён: ${bdir}"
}

inst_password_hash() {
    _ENVFILE="$(mktemp)"
    chmod 600 "${_ENVFILE}"
    printf 'WG_PASSWORD=%s\n' "${WG_PASSWORD}" > "${_ENVFILE}"

    local raw
    raw="$(docker run --rm --env-file "${_ENVFILE}" \
        ghcr.io/wg-easy/wg-easy:latest sh -c 'wgpw "$WG_PASSWORD"')" || true
    rm -f "${_ENVFILE}"; _ENVFILE=""

    PASSWORD_HASH="$(printf '%s' "${raw}" \
        | grep -oE '[$]2[abxy][$][0-9]{2}[$][./A-Za-z0-9]{53}' | head -1 || true)"

    if [[ -z "${PASSWORD_HASH}" ]]; then
        local doubled
        doubled="$(printf '%s' "${raw}" \
            | grep -oE '[$][$]2[abxy][$][$][0-9]{2}[$][$][./A-Za-z0-9]{53}' \
            | head -1 || true)"
        [[ -n "${doubled}" ]] && PASSWORD_HASH="${doubled//\$\$/\$}"
    fi

    [[ -n "${PASSWORD_HASH}" ]] \
        || die "Не удалось получить bcrypt-хэш от wgpw.\nВывод: ${raw:-<пустой>}"
}

inst_write_configs() {
    # Исправление 1: удаляем маску из шаблона адреса (wg-easy добавляет её сам)
    local address_no_mask="${WG_DEFAULT_ADDRESS%/*}"   # убираем всё после '/'

    # Исправление 2: экранируем $ в хэше (заменяем каждый $ на $$)
    local password_hash_esc="${PASSWORD_HASH//\$/$$}"

    cat > "${ENV_FILE}" <<EOF
LANG=ru
WG_HOST=${WG_HOST}
PASSWORD_HASH=${password_hash_esc}
WG_PORT=${WG_PORT}
WG_DEFAULT_ADDRESS=${address_no_mask}
WG_DEFAULT_DNS=${WG_DNS}
WG_ALLOWED_IPS=${WG_ALLOWED_IPS}
WG_MTU=${WG_MTU}
WG_PERSISTENT_KEEPALIVE=${WG_PERSISTENT_KEEPALIVE}
UI_TRAFFIC_STATS=true
UI_CHART_TYPE=2
EOF
    chmod 600 "${ENV_FILE}"

    cat > "${COMPOSE_FILE}" <<EOF
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:latest
    container_name: wg-easy
    restart: unless-stopped
    env_file:
      - wg.env
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    ports:
      - "${WG_PORT}:${WG_PORT}/udp"
      - "127.0.0.1:51821:51821/tcp"
    volumes:
      - ./data:/etc/wireguard
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.forwarding=1
EOF
}

inst_ip_forward() {
    cat > /etc/sysctl.d/99-wg-easy.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
net.ipv6.conf.all.forwarding=1
EOF
    ROLLBACK_SYSCTL_CREATED=1
    sysctl --system >/dev/null
}

inst_start_container() {
    (
        cd "${WG_DIR}"
        docker compose pull
        docker compose up -d
    )
    ROLLBACK_DOCKER_STARTED=1

    # Проверяем, что контейнер действительно запустился
    sleep 3
    if ! docker ps --format '{{.Names}}' | grep -qx "wg-easy"; then
        echo "Контейнер wg-easy не запустился. Логи:" >&2
        docker logs wg-easy --tail 50 >&2 || true
        die "Контейнер wg-easy не запущен. Проверь логи выше."
    fi
}

inst_wait_panel() {
    local i
    for i in {1..20}; do
        if curl -fsSI --max-time 2 http://127.0.0.1:51821/ &>/dev/null; then
            return 0
        fi
        sleep 2
    done
    # При ошибке показываем логи
    echo "wg-easy не ответил на :51821 за 40 сек. Логи контейнера:" >&2
    docker logs wg-easy --tail 50 >&2 || true
    die "wg-easy не ответил на :51821 за 40 сек. Проверь: docker logs wg-easy"
}

inst_nginx() {
    cat > "${NGINX_SITE_AVAIL}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${WG_DOMAIN};

    location / {
        proxy_pass         http://127.0.0.1:51821/;
        proxy_http_version 1.1;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        "upgrade";
    }
}
EOF
    ROLLBACK_NGINX_CREATED=1
    ln -sf "${NGINX_SITE_AVAIL}" "${NGINX_SITE_ENABLED}"
    rm -f /etc/nginx/sites-enabled/default
    nginx -t
    systemctl enable --now nginx
    systemctl reload nginx

    if ! curl -fsSI --max-time 5 \
            --resolve "${WG_DOMAIN}:80:127.0.0.1" "http://${WG_DOMAIN}/" &>/dev/null; then
        echo "[WARN] Nginx не ответил по домену — продолжаем."
        wt_yesno " ⚠  Nginx не отвечает" \
"
  Nginx не ответил на http://${WG_DOMAIN}
  (локальный тест через 127.0.0.1).

  Это может указывать на ошибку конфига.
  certbot может не пройти проверку домена.

  Продолжить выпуск сертификата?" 14 \
            || die "Установка прервана перед выпуском сертификата."
    fi
}

inst_certbot() {
    ROLLBACK_CERT_ATTEMPTED=1
    certbot --nginx -d "${WG_DOMAIN}" \
        --non-interactive --agree-tos -m "${LE_EMAIL}" --redirect
}

inst_verify() {
    systemctl is-active nginx  &>/dev/null || die "nginx не активен."
    systemctl is-active docker &>/dev/null || die "docker не активен."
    docker ps --format '{{.Names}}' | grep -qx "wg-easy" \
        || die "Контейнер wg-easy не запущен. Проверь: docker logs wg-easy"

    local out
    if ! out="$(certbot renew --dry-run 2>&1)"; then
        echo "[WARN] certbot dry-run с ошибкой:"
        echo "$out" | head -20
    fi
}

inst_show_success() {
    local stars; stars=$(printf '%0.s●' $(seq 1 "${#WG_PASSWORD}"))
    (( "${#WG_PASSWORD}" > 14 )) && stars="●●●●●●●●●●●●●●..."

    wt_msgbox " ✅  Установка завершена успешно!" \
"
  Панель wg-easy:   https://${WG_DOMAIN}
  Endpoint VPN:     ${WG_HOST}:${WG_PORT}/udp
  Пароль:           ${stars}

  Каталог:          ${WG_DIR}
  Данные WG:        ${WG_DIR}/data
  Лог установки:    ${LOG_FILE}

  ───────────────────────────────────────────────────
  Управление:
    cd ${WG_DIR} && docker compose ps
    cd ${WG_DIR} && docker compose logs -f
    cd ${WG_DIR} && docker compose restart

  SSL сертификат:
    certbot certificates

  Диагностика  [интерфейс: ${WG_DEVICE}]:
    ss -lnup 'sport = :${WG_PORT}'
    tcpdump -ni ${WG_DEVICE} udp port ${WG_PORT}" 30
}

# ═══════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════

main() {
    need_root
    ensure_whiptail
    check_os_version

    run_wizard

    wt_infobox " Проверка окружения" \
"
  Проверяю диск, DNS, занятые порты...
  Пожалуйста, подождите." 9
    env_check_disk
    env_check_dns
    env_check_ports

    wt_infobox " Начинаю установку" \
"
  Параметры подтверждены. Запускаю установку.
  Весь вывод будет записан в лог:
  ${LOG_FILE}

  Пожалуйста, не закрывай терминал." 11
    sleep 2

    exec >>"$LOG_FILE" 2>&1

    show_step "Устанавливаю базовые пакеты (nginx, certbot, ufw)..."
    inst_base_packages

    show_step "Устанавливаю Docker Engine..."
    inst_docker

    show_step "Настраиваю UFW firewall..."
    inst_firewall

    show_step "Создаю каталоги и бэкап существующих конфигов..."
    inst_dirs_backup

    show_step "Генерирую bcrypt-хэш пароля..."
    inst_password_hash

    show_step "Записываю конфигурационные файлы..."
    inst_write_configs

    show_step "Включаю IP forwarding (IPv4 + IPv6)..."
    inst_ip_forward

    show_step "Скачиваю Docker-образ и запускаю wg-easy..."
    inst_start_container

    show_step "Жду запуска веб-панели wg-easy..."
    inst_wait_panel

    show_step "Создаю nginx-конфиг и проверяю домен..."
    inst_nginx

    show_step "Выпускаю Let's Encrypt SSL-сертификат..."
    inst_certbot

    show_step "Проверяю сервисы и автопродление сертификата..."
    inst_verify

    inst_show_success
}

main "$@"
