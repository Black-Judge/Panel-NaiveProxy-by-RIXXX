#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
#  Panel NaiveProxy by Veles — PRO Edition (Fixed & Secure)
#  Интеллектуальный сканер SSL, авто-названия профилей, пароли 16 симв.
# ═══════════════════════════════════════════════════════════════════════

set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

REPO_URL="https://github.com/Black-Judge/Panel-NaiveProxy-by-RIXXX"
PANEL_DIR="/opt/naiveproxy-panel"
SERVICE_NAME="naiveproxy-panel"
INTERNAL_PORT=3000

# ── Colors ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'
BOLD='\033[1m'; RESET='\033[0m'

header() {
  clear
  echo ""
  echo -e "${PURPLE}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${PURPLE}${BOLD}║        Panel NaiveProxy by Veles — PRO Edition           ║${RESET}"
  echo -e "${PURPLE}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
  echo ""
}

log_step() { echo -e "\n${CYAN}${BOLD}▶ $1${RESET}"; }
log_ok()   { echo -e "${GREEN}✅ $1${RESET}"; }
log_warn() { echo -e "${YELLOW}⚠  $1${RESET}"; }
log_err()  { echo -e "${RED}❌ $1${RESET}"; }
log_info() { echo -e "   ${BLUE}$1${RESET}"; }

if [[ $EUID -ne 0 ]]; then log_err "Запускайте скрипт от root (sudo)"; exit 1; fi
if ! command -v apt-get &>/dev/null; then log_err "Только Debian/Ubuntu"; exit 1; fi

# Ускоренное определение IP-адреса
SERVER_IP=$(curl -4 -s --max-time 2 ipv4.icanhazip.com 2>/dev/null || curl -4 -s --max-time 2 api.ipify.org 2>/dev/null || true)
if [[ -z "$SERVER_IP" || "$SERVER_IP" == *" "* ]]; then
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    SERVER_IP=${SERVER_IP:-"127.0.0.1"}
fi

# ── Функция: Пересборка Caddyfile ───────────────────────────────────────
rebuild_caddyfile() {
    local domain email p_domain p_email acc_mode
    domain=$(jq -r '.domain' "${PANEL_DIR}/panel/data/config.json")
    email=$(jq -r '.email // empty' "${PANEL_DIR}/panel/data/config.json")
    p_domain=$(jq -r '.panelDomain // empty' "${PANEL_DIR}/panel/data/config.json")
    p_email=$(jq -r '.panelEmail // empty' "${PANEL_DIR}/panel/data/config.json")
    acc_mode=$(jq -r '.accessMode // "1"' "${PANEL_DIR}/panel/data/config.json")

    # ЗАЩИТА ОТ ПУСТОГО EMAIL
    [[ -z "$email" ]] && email="admin@$domain"
    [[ -z "$p_email" && -n "$p_domain" ]] && p_email="admin@$p_domain"

    {
        printf '{\n  order forward_proxy before file_server\n}\n\n'
        
        # Блок ядра NaiveProxy
        printf ':443, %s {\n' "$domain"
        if [[ -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]]; then
            printf '  tls /etc/letsencrypt/live/%s/fullchain.pem /etc/letsencrypt/live/%s/privkey.pem\n\n' "$domain" "$domain"
        else
            printf '  tls %s\n\n' "$email"
        fi

        printf '  forward_proxy {\n'
        jq -c '.proxyUsers[]' "${PANEL_DIR}/panel/data/config.json" | while read -r user; do
            u_name=$(echo "$user" | jq -r '.username')
            u_pass=$(echo "$user" | jq -r '.password')
            printf '    basic_auth %s %s\n' "$u_name" "$u_pass"
        done
        printf '    hide_ip\n    hide_via\n    probe_resistance\n  }\n\n'
        printf '  root * /var/www/html\n  file_server\n}\n\n'

        # Блок панели
        if [[ "$acc_mode" == "2" && -n "$p_domain" ]]; then
            printf '%s {\n' "$p_domain"
            if [[ -f "/etc/letsencrypt/live/$p_domain/fullchain.pem" ]]; then
                printf '  tls /etc/letsencrypt/live/%s/fullchain.pem /etc/letsencrypt/live/%s/privkey.pem\n' "$p_domain" "$p_domain"
            else
                printf '  tls %s\n' "$p_email"
            fi
            printf '  reverse_proxy 127.0.0.1:%s\n' "$INTERNAL_PORT"
            printf '}\n'
        fi
    } > /etc/caddy/Caddyfile

    caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || systemctl restart caddy >/dev/null 2>&1
}

# ════════════════════════════════════════════════════════════════════════
# ГЛАВНОЕ МЕНЮ (Если панель уже установлена)
# ════════════════════════════════════════════════════════════════════════
if [[ -d "$PANEL_DIR" && -f "${PANEL_DIR}/panel/data/config.json" ]]; then
    while true; do
        header
        echo -e "   ${BLUE}IP сервера: ${BOLD}${SERVER_IP}${RESET}\n"
        
        naive_domain=$(jq -r '.domain' "${PANEL_DIR}/panel/data/config.json")
        user_count=$(jq '.proxyUsers | length' "${PANEL_DIR}/panel/data/config.json")
        
        echo -e "${GREEN}${BOLD}✅ Панель NaiveProxy установлена и работает.${RESET}\n"
        echo -e "Выберите действие:"
        echo -e "  ${CYAN}1)${RESET} 👥 Управление пользователями (${BOLD}${user_count}${RESET} шт.)"
        echo -e "  ${CYAN}2)${RESET} ⚙️ Управление сервисами и логи (Caddy & PM2)"
        echo -e "  ${YELLOW}3)${RESET} 🔒 Аудит SSL сертификатов и задач обновления"
        echo -e "  ${CYAN}4)${RESET} ⬆ Обновить панель управления (GitHub Pull)"
        echo -e "  ${RED}5)${RESET} 🗑 Чистое удаление (Uninstall)"
        echo -e "  ${CYAN}0)${RESET} Выход"
        echo ""
        read -rp "Ваш выбор: " menu_choice

        case "$menu_choice" in
            1)
                while true; do
                    clear
                    echo -e "${PURPLE}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
                    echo -e "${PURPLE}${BOLD}║                Управление пользователями                 ║${RESET}"
                    echo -e "${PURPLE}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}\n"
                    
                    user_count=$(jq '.proxyUsers | length' "${PANEL_DIR}/panel/data/config.json")
                    echo -e "Пользователи NaiveProxy (${naive_domain}):\n"
                    
                    i=1
                    unset u_map 2>/dev/null || true
                    declare -A u_map
                    
                    while read -r u_data; do
                        u_name=$(echo "$u_data" | jq -r '.username')
                        u_pass=$(echo "$u_data" | jq -r '.password')
                        echo -e "  ${CYAN}[$i]${RESET} Логин: ${BOLD}${u_name}${RESET} | Пароль: ${u_pass}"
                        u_map[$i]="$u_name|$u_pass"
                        ((i++))
                    done < <(jq -c '.proxyUsers[]' "${PANEL_DIR}/panel/data/config.json")

                    echo -e "\nДействия:"
                    echo -e "  ${GREEN}1)${RESET} ➕ Добавить пользователя"
                    echo -e "  ${RED}2)${RESET} 🗑 Удалить пользователя"
                    echo -e "  ${CYAN}3)${RESET} 📱 Показать ссылку и QR-код"
                    echo -e "  ${YELLOW}0)${RESET} 🔙 Назад"
                    echo ""
                    read -rp "Выбор: " u_choice

                    case "$u_choice" in
                        1)
                            new_login=$(openssl rand -hex 4)
                            new_pass=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16)
                            created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
                            
                            read -rp "Введите название профиля (например: My_Phone): " p_name
                            p_name=${p_name:-"Profile_${new_login}"}
                            enc_p_name="${p_name// /%20}"
                            
                            new_json=$(jq ".proxyUsers += [{\"username\": \"$new_login\", \"password\": \"$new_pass\", \"createdAt\": \"$created_at\", \"profileName\": \"$enc_p_name\"}]" "${PANEL_DIR}/panel/data/config.json")
                            echo "$new_json" > "${PANEL_DIR}/panel/data/config.json"
                            
                            rebuild_caddyfile
                            log_ok "Пользователь $new_login добавлен! Caddy перезагружен."
                            read -rp "Нажмите Enter..."
                            ;;
                        2)
                            if [[ $user_count -le 1 ]]; then
                                log_warn "Нельзя удалить единственного пользователя!"
                                sleep 2; continue
                            fi
                            read -rp "Введите номер для удаления (1-$((i-1))): " del_num
                            if [[ -n "${u_map[$del_num]:-}" ]]; then
                                u_del_name=$(echo "${u_map[$del_num]}" | cut -d'|' -f1)
                                new_json=$(jq "del(.proxyUsers[] | select(.username == \"$u_del_name\"))" "${PANEL_DIR}/panel/data/config.json")
                                echo "$new_json" > "${PANEL_DIR}/panel/data/config.json"
                                rebuild_caddyfile
                                log_ok "Пользователь удален."
                            else
                                log_err "Неверный номер."
                            fi
                            sleep 1
                            ;;
                        3)
                            read -rp "Введите номер пользователя (1-$((i-1))): " qr_num
                            if [[ -n "${u_map[$qr_num]:-}" ]]; then
                                qr_name=$(echo "${u_map[$qr_num]}" | cut -d'|' -f1)
                                qr_pass=$(echo "${u_map[$qr_num]}" | cut -d'|' -f2)
                                
                                qr_prof=$(jq -r ".proxyUsers[] | select(.username == \"$qr_name\") | .profileName" "${PANEL_DIR}/panel/data/config.json" 2>/dev/null)
                                [[ "$qr_prof" == "null" || -z "$qr_prof" ]] && qr_prof="Naive_$qr_name"
                                
                                link="naive+https://${qr_name}:${qr_pass}@${naive_domain}:443#${qr_prof}"
                                echo -e "\n${BOLD}Ссылка:${RESET} ${CYAN}${link}${RESET}\n"
                                qrencode -t ANSIUTF8 "$link"
                            fi
                            echo ""
                            read -rp "Нажмите Enter для возврата..."
                            ;;
                        0) break ;;
                    esac
                done
                ;;
            2)
                while true; do
                    clear
                    echo -e "${PURPLE}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
                    echo -e "${PURPLE}${BOLD}║                Управление сервисами и логи               ║${RESET}"
                    echo -e "${PURPLE}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}\n"

                    echo -e "  ${CYAN}1)${RESET} 📊 Посмотреть статусы (Caddy & Панель)"
                    echo -e "  ${GREEN}2)${RESET} 🔄 Перезапустить ядро NaiveProxy (Caddy)"
                    echo -e "  ${GREEN}3)${RESET} 🔄 Перезапустить веб-панель (PM2)"
                    echo -e "  ${YELLOW}4)${RESET} 📋 Живые логи ядра NaiveProxy (Caddy)"
                    echo -e "  ${YELLOW}5)${RESET} 📋 Живые логи веб-панели (PM2)"
                    echo -e "  ${RED}6)${RESET} 🛑 Остановить сервисы"
                    echo -e "  ${GREEN}7)${RESET} ▶ Запустить сервисы"
                    echo -e "  ${CYAN}0)${RESET} 🔙 Назад"
                    echo ""
                    read -rp "Выбор: " s_choice

                    case "$s_choice" in
                        1)
                            echo -e "\n${BOLD}Статус PM2 (Панель):${RESET}"
                            pm2 status "$SERVICE_NAME"
                            echo -e "\n${BOLD}Статус Caddy (NaiveProxy):${RESET}"
                            systemctl status caddy --no-pager | head -n 10
                            echo ""
                            read -rp "Нажмите Enter для возврата..."
                            ;;
                        2)
                            systemctl restart caddy
                            log_ok "Ядро Caddy перезапущено!"
                            sleep 1.5
                            ;;
                        3)
                            pm2 restart "$SERVICE_NAME"
                            log_ok "Веб-панель перезапущена!"
                            sleep 1.5
                            ;;
                        4)
                            echo -e "\n${YELLOW}Нажмите Ctrl+C для выхода из режима логов${RESET}\n"
                            journalctl -u caddy -f -n 50
                            ;;
                        5)
                            echo -e "\n${YELLOW}Нажмите Ctrl+C для выхода из режима логов${RESET}\n"
                            pm2 logs "$SERVICE_NAME"
                            ;;
                        6)
                            systemctl stop caddy
                            pm2 stop "$SERVICE_NAME" >/dev/null 2>&1
                            log_warn "Сервисы остановлены!"
                            sleep 1.5
                            ;;
                        7)
                            systemctl start caddy
                            pm2 start "$SERVICE_NAME" >/dev/null 2>&1
                            log_ok "Сервисы запущены!"
                            sleep 1.5
                            ;;
                        0) break ;;
                    esac
                done
                ;;
            3)
                clear
                echo -e "${PURPLE}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
                echo -e "${PURPLE}${BOLD}║              Аудит SSL сертификатов                      ║${RESET}"
                echo -e "${PURPLE}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}\n"
                
                echo -e "${CYAN}[1] Сертификаты Caddy (Автоматические):${RESET}"
                CADDY_CERTS=$(find /root/.local/share/caddy/certificates /var/lib/caddy/certificates -type f -name "*.crt" 2>/dev/null)
                if [[ -n "$CADDY_CERTS" ]]; then
                    echo "$CADDY_CERTS" | while read -r cert; do
                        domain=$(basename $(dirname "$cert"))
                        echo -e "  ${GREEN}✅ Найден:${RESET} $domain"
                        openssl x509 -enddate -noout -in "$cert" | sed 's/notAfter=/     Действителен до: /'
                    done
                else
                    echo -e "  ${YELLOW}Нет активных сертификатов Caddy${RESET}"
                fi

                echo -e "\n${CYAN}[2] Сертификаты Certbot (Ручные):${RESET}"
                if command -v certbot &>/dev/null; then
                    certbot certificates 2>/dev/null | grep -E "Certificate Name|Expiry Date|Domains" || echo -e "  ${YELLOW}Сертификатов нет${RESET}"
                else
                    echo -e "  ${YELLOW}Утилита Certbot не установлена (Используется только Caddy)${RESET}"
                fi

                echo -e "\n${CYAN}[3] Задачи автоматического обновления:${RESET}"
                echo -e "  ${BOLD}--- Systemd Timers (Certbot/Acme) ---${RESET}"
                systemctl list-timers | grep -E "certbot|acme" || echo "  Нет systemd таймеров для SSL"
                echo -e "  ${BOLD}--- Cron Jobs ---${RESET}"
                crontab -l 2>/dev/null | grep -E "certbot|acme" || echo "  Нет cron задач для SSL"

                echo -e "\n${PURPLE}💡 КАК РАБОТАЕТ CADDY:${RESET}"
                echo -e "Caddy обновляет свои сертификаты САМ во время работы сервера."
                echo -e "Ему НЕ НУЖНЫ cron-задачи или таймеры. Он держит обновление в оперативной памяти."
                echo -e "Главное правило: ${BOLD}никогда не останавливайте сервис Caddy надолго.${RESET}\n"

                read -rp "Нажмите Enter для возврата..."
                ;;
            4)
                log_step "Обновление панели управления..."
                cd "${PANEL_DIR}" || exit
                git pull
                cd "${PANEL_DIR}/panel" || exit
                npm install --omit=dev
                pm2 restart "$SERVICE_NAME"
                log_ok "Панель обновлена!"
                read -rp "Нажмите Enter для возврата..."
                ;;
            5)
                echo -e "\n${YELLOW}${BOLD}⚠ Начинаем полное удаление...${RESET}"
                if command -v ufw >/dev/null; then
                    ufw delete allow 80/tcp >/dev/null 2>&1 || true
                    ufw delete allow 443/tcp >/dev/null 2>&1 || true
                    ufw delete allow 443/udp >/dev/null 2>&1 || true
                    ufw delete allow 8080/tcp >/dev/null 2>&1 || true
                    log_ok "Правила UFW удалены (SSH порты не трогаем для безопасности)."
                fi
                pm2 delete "$SERVICE_NAME" >/dev/null 2>&1 || true
                pm2 save --force >/dev/null 2>&1 || true
                systemctl stop caddy 2>/dev/null || true
                systemctl disable caddy 2>/dev/null || true
                rm -f /etc/systemd/system/caddy.service
                rm -rf "$PANEL_DIR" /etc/caddy /usr/bin/caddy
                systemctl daemon-reload
                log_ok "Система полностью очищена от NaiveProxy и Панели."
                exit 0
                ;;
            0) exit 0 ;;
        esac
    done
fi

# ════════════════════════════════════════════════════════════════════════
# ЧИСТАЯ УСТАНОВКА
# ════════════════════════════════════════════════════════════════════════
header
echo -e "   ${BLUE}IP сервера: ${BOLD}${SERVER_IP}${RESET}\n"

# --- БЕЗОПАСНОЕ ОПРЕДЕЛЕНИЕ ПОРТА SSH ---
echo -e "${BOLD}🛡 Защита доступа (UFW Firewall):${RESET}"
DETECTED_SSH_PORT=""
if [[ -n "${SSH_CONNECTION:-}" ]]; then
    DETECTED_SSH_PORT=$(echo "$SSH_CONNECTION" | awk '{print $4}')
fi
if [[ -z "$DETECTED_SSH_PORT" || ! "$DETECTED_SSH_PORT" =~ ^[0-9]+$ ]]; then
    DETECTED_SSH_PORT=$(ss -tlnp 2>/dev/null | grep -m 1 -iE 'sshd|dropbear' | awk '{print $4}' | awk -F':' '{print $NF}')
fi
if [[ -z "$DETECTED_SSH_PORT" || ! "$DETECTED_SSH_PORT" =~ ^[0-9]+$ ]]; then
    DETECTED_SSH_PORT=22
fi

read -rp "  Подтвердите ваш SSH порт [$DETECTED_SSH_PORT]: " INPUT_SSH_PORT
SSH_PORT=${INPUT_SSH_PORT:-$DETECTED_SSH_PORT}

if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
    log_warn "Введен некорректный порт. Возвращаем дефолтный 22."
    SSH_PORT=22
fi
echo -e "  ${GREEN}✅ UFW откроет порт: ${SSH_PORT}${RESET}\n"

echo -e "${BOLD}Выберите способ доступа к панели управления:${RESET}"
echo ""
echo -e "  ${CYAN}1)${RESET} Строго Localhost + SSH Туннель ${GREEN}(Для IP-адресов - Максимально безопасно)${RESET}"
echo -e "     ${YELLOW}└ Панель не торчит в интернет. Доступ только через туннель.${RESET}"
echo -e "  ${CYAN}2)${RESET} Через Caddy с доменом + HTTPS ${GREEN}(Идеально, нужен поддомен)${RESET}"
echo ""
read -rp "Ваш выбор [1/2]: " ACCESS_MODE
ACCESS_MODE="${ACCESS_MODE:-1}"

PANEL_DOMAIN=""
PANEL_EMAIL_SSL=""

if [[ "$ACCESS_MODE" == "2" ]]; then
  echo ""
  if [[ -d "/etc/letsencrypt/live" ]]; then
      DOMAINS_P=()
      for d in /etc/letsencrypt/live/*/; do
          [[ -d "$d" ]] || continue
          d_name=$(basename "$d")
          [[ "$d_name" == "README" || "$d_name" == "*" ]] && continue
          DOMAINS_P+=("$d_name")
      done

      if [[ ${#DOMAINS_P[@]} -gt 0 ]]; then
          echo -e "  ${GREEN}Найдены готовые SSL сертификаты для панели:${RESET}"
          for i in "${!DOMAINS_P[@]}"; do
              echo -e "  ${CYAN}$((i+1)))${RESET} ${DOMAINS_P[$i]}"
          done
          echo -e "  ${CYAN}$(( ${#DOMAINS_P[@]} + 1 )))${RESET} Ввести новый домен"
          
          while true; do
              read -rp "  Выберите домен панели [1-$(( ${#DOMAINS_P[@]} + 1 ))]: " DOM_CHOICE
              if [[ "$DOM_CHOICE" =~ ^[0-9]+$ ]] && [ "$DOM_CHOICE" -ge 1 ] && [ "$DOM_CHOICE" -le $(( ${#DOMAINS_P[@]} + 1 )) ]; then
                  if [ "$DOM_CHOICE" -eq $(( ${#DOMAINS_P[@]} + 1 )) ]; then
                      break
                  else
                      PANEL_DOMAIN="${DOMAINS_P[$((DOM_CHOICE-1))]}"
                      echo -e "  ${GREEN}✅ Выбран домен панели: ${PANEL_DOMAIN}${RESET}"
                      break
                  fi
              fi
          done
      fi
  fi
  
  if [[ -z "$PANEL_DOMAIN" ]]; then
      read -rp "  Домен для панели (например panel.yourdomain.com): " PANEL_DOMAIN
      read -rp "  Email для Let's Encrypt (SSL панели): " PANEL_EMAIL_SSL
  fi
fi

echo -e "\n${BOLD}Настройка NaiveProxy:${RESET}"
NAIVE_DOMAIN=""
NAIVE_EMAIL=""
NAIVE_TLS_CONFIG=""

if [[ -d "/etc/letsencrypt/live" ]]; then
    DOMAINS_N=()
    for d in /etc/letsencrypt/live/*/; do
        [[ -d "$d" ]] || continue
        d_name=$(basename "$d")
        [[ "$d_name" == "README" || "$d_name" == "*" ]] && continue
        DOMAINS_N+=("$d_name")
    done

    if [[ ${#DOMAINS_N[@]} -gt 0 ]]; then
        echo -e "  ${GREEN}Найдены готовые сертификаты для ядра NaiveProxy:${RESET}"
        for i in "${!DOMAINS_N[@]}"; do
            echo -e "  ${CYAN}$((i+1)))${RESET} ${DOMAINS_N[$i]}"
        done
        echo -e "  ${CYAN}$(( ${#DOMAINS_N[@]} + 1 )))${RESET} Ввести новый домен"
        
        while true; do
            read -rp "  Выберите домен VPN [1-$(( ${#DOMAINS_N[@]} + 1 ))]: " DOM_CHOICE
            if [[ "$DOM_CHOICE" =~ ^[0-9]+$ ]] && [ "$DOM_CHOICE" -ge 1 ] && [ "$DOM_CHOICE" -le $(( ${#DOMAINS_N[@]} + 1 )) ]; then
                if [ "$DOM_CHOICE" -eq $(( ${#DOMAINS_N[@]} + 1 )) ]; then
                    break
                else
                    NAIVE_DOMAIN="${DOMAINS_N[$((DOM_CHOICE-1))]}"
                    NAIVE_TLS_CONFIG="/etc/letsencrypt/live/${NAIVE_DOMAIN}/fullchain.pem /etc/letsencrypt/live/${NAIVE_DOMAIN}/privkey.pem"
                    echo -e "  ${GREEN}✅ Выбран домен VPN: ${NAIVE_DOMAIN}${RESET}"
                    break
                fi
            fi
        done
    fi
fi

if [[ -z "$NAIVE_DOMAIN" ]]; then
    read -rp "  Домен для NaiveProxy (например vpn.yourdomain.com): " NAIVE_DOMAIN
    read -rp "  Email для Let's Encrypt (TLS): " NAIVE_EMAIL
    NAIVE_TLS_CONFIG="${NAIVE_EMAIL:-admin@$NAIVE_DOMAIN}"
fi

read -rp "  Название профиля для Karing/Throne (например: Main_Server): " FIRST_PROFILE_NAME
FIRST_PROFILE_NAME=${FIRST_PROFILE_NAME:-"Naive_Proxy"}
ENC_FIRST_PROFILE="${FIRST_PROFILE_NAME// /%20}"

PANEL_LOGIN=$(openssl rand -hex 4)
PANEL_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16)
NAIVE_LOGIN=$(openssl rand -hex 5)
NAIVE_PASS=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16)

log_step "[1/10] Обновление системы и фикс зависаний..."
systemctl stop unattended-upgrades 2>/dev/null || true
pkill -9 unattended-upgrades 2>/dev/null || true
rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>/dev/null || true
dpkg --configure -a >/dev/null 2>&1 || true

if [ -f /etc/needrestart/needrestart.conf ]; then
  sed -i "s/#\$nrconf{restart} = 'i';/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf 2>/dev/null || true
  sed -i "s/\$nrconf{restart} = 'i';/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf 2>/dev/null || true
fi

DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl wget git openssl ufw build-essential iproute2 qrencode jq >/dev/null 2>&1 || true
log_ok "Система обновлена."

log_step "[2/10] Включение BBR..."
if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  sysctl -p >/dev/null 2>&1 || true
fi
log_ok "BBR включен."

log_step "[3/10] Установка Go и сборка Caddy..."
if ! command -v /usr/local/go/bin/go &>/dev/null; then
  wget -q "https://go.dev/dl/go1.22.5.linux-amd64.tar.gz" -O /tmp/go.tar.gz
  tar -C /usr/local -xzf /tmp/go.tar.gz
  rm -f /tmp/go.tar.gz
fi
export PATH=/usr/local/go/bin:$PATH

/usr/local/go/bin/go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
/root/go/bin/xcaddy build --with github.com/caddyserver/forwardproxy@caddy2=github.com/Black-Judge/forwardproxy@naive >/dev/null 2>&1
mv caddy /usr/bin/caddy && chmod +x /usr/bin/caddy
log_ok "Caddy собран с NaiveProxy."

log_step "[4/10] Камуфляжная страница..."
mkdir -p /var/www/html /etc/caddy
cat > /var/www/html/index.html << 'EOF'
<!DOCTYPE html><html><body style="background:#111;color:#fff;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;font-family:sans-serif;"><h3>404 Not Found</h3></body></html>
EOF

log_step "[5/10] Настройка Systemd для Caddy..."
cat > /etc/caddy/Caddyfile << EOF
{
  order forward_proxy before file_server
}
:443, $NAIVE_DOMAIN {
  tls $NAIVE_TLS_CONFIG
  forward_proxy {
    basic_auth $NAIVE_LOGIN $NAIVE_PASS
    hide_ip
    hide_via
    probe_resistance
  }
  root * /var/www/html
  file_server
}
EOF

cat > /etc/systemd/system/caddy.service << 'EOF'
[Unit]
Description=Caddy NaiveProxy by Veles
After=network.target network-online.target
[Service]
Type=notify
User=root
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
Restart=always
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable --now caddy >/dev/null 2>&1
log_ok "Caddy запущен."

log_step "[6/10] Установка Node.js и PM2..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs >/dev/null 2>&1
npm install -g pm2 --silent >/dev/null 2>&1

log_step "[7/10] Установка форка панели и настройка окружения..."
git clone "$REPO_URL" "$PANEL_DIR" >/dev/null 2>&1

cd "${PANEL_DIR}/panel" && npm install --omit=dev >/dev/null 2>&1
mkdir -p "${PANEL_DIR}/panel/data"

cat > "${PANEL_DIR}/panel/data/config.json" << EOF
{
  "installed": true,
  "domain": "${NAIVE_DOMAIN}",
  "email": "${NAIVE_EMAIL}",
  "panelDomain": "${PANEL_DOMAIN}",
  "panelEmail": "${PANEL_EMAIL_SSL}",
  "accessMode": "${ACCESS_MODE}",
  "serverIp": "${SERVER_IP}",
  "adminPassword": "${PANEL_PASS}",
  "proxyUsers": [
    {
      "username": "${NAIVE_LOGIN}",
      "password": "${NAIVE_PASS}",
      "createdAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
      "profileName": "${ENC_FIRST_PROFILE}"
    }
  ]
}
EOF

cat > .env << ENVEOF
PORT=${INTERNAL_PORT}
ADMIN_USER=${PANEL_LOGIN}
ADMIN_PASS=${PANEL_PASS}
ENVEOF

pm2 start server/index.js --name "$SERVICE_NAME" --env .env >/dev/null 2>&1
pm2 save --force >/dev/null 2>&1
pm2 startup systemd -u root --hp /root >/dev/null 2>&1 || true
log_ok "Панель запущена с защищенными переменными окружения."

log_step "[8/10] Настройка реверс-прокси для Панели (Caddy)..."
if [[ "$ACCESS_MODE" == "2" ]]; then
  log_ok "Настраиваю Caddy для работы с доменом панели $PANEL_DOMAIN..."
  rebuild_caddyfile
  log_ok "Caddy успешно настроен как реверс-прокси для панели."
else
  log_ok "Панель изолирована на локальном порту $INTERNAL_PORT."
  rebuild_caddyfile
fi

log_step "[9/10] Настройка UFW..."
if ! command -v ufw &>/dev/null; then
    log_info "Установка UFW..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw >/dev/null 2>&1 || true
fi

# Применяем подтвержденный SSH порт
ufw allow "${SSH_PORT}/tcp" >/dev/null 2>&1 || true

# На всякий случай
if [[ "$SSH_PORT" != "22" ]]; then
    ufw allow 22/tcp >/dev/null 2>&1 || true
fi

ufw allow 80/tcp >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1 || true
ufw allow 443/udp >/dev/null 2>&1 || true
ufw deny ${INTERNAL_PORT}/tcp >/dev/null 2>&1 || true

echo "y" | ufw enable >/dev/null 2>&1 || true
log_ok "Файрволл активирован. Доступ по SSH защищен на порту: ${SSH_PORT}"

log_step "[10/10] Завершение..."
NAIVE_LINK="naive+https://${NAIVE_LOGIN}:${NAIVE_PASS}@${NAIVE_DOMAIN}:443#${ENC_FIRST_PROFILE}"

echo -e "\n${PURPLE}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${PURPLE}${BOLD}║  ✅  Установка завершена! Панель и Ядро работают.            ║${RESET}"
echo -e "${PURPLE}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}\n"

echo -e "${BOLD}🔑 ДОСТУП К ПАНЕЛИ УПРАВЛЕНИЯ:${RESET}"
if [[ "$ACCESS_MODE" == "2" ]]; then
  echo -e "   Адрес:  ${CYAN}https://${PANEL_DOMAIN}${RESET}"
else
  echo -e "   ${YELLOW}Доступ ограничен (SSH Туннель). Для входа выполните на ПК:${RESET}"
  echo -e "   ssh -L 8080:127.0.0.1:3000 root@${SERVER_IP}"
  echo -e "   Затем откройте в браузере: ${CYAN}http://localhost:8080${RESET}"
fi
echo -e "   Логин:  ${GREEN}${PANEL_LOGIN}${RESET}"
echo -e "   Пароль: ${GREEN}${PANEL_PASS}${RESET}\n"

echo -e "${BOLD}🔒 ПЕРВЫЙ ПОЛЬЗОВАТЕЛЬ NAIVEPROXY:${RESET}"
echo -e "   Ссылка: ${CYAN}${NAIVE_LINK}${RESET}"
qrencode -t ANSIUTF8 "$NAIVE_LINK"

echo -e "\n${PURPLE}💡 Для вызова меню управления запустите этот же скрипт еще раз.${RESET}\n"