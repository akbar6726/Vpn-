#!/usr/bin/env bash
# =============================================================================
#  Личный VPN для обхода GFW: VLESS + REALITY (Xray) и Hysteria2
#  Запускать на чистом VPS (Ubuntu 22.04/24.04 или Debian 11/12) от root:
#      bash install.sh
#
#  Переменные окружения (необязательно):
#      REALITY_SNI=www.microsoft.com   сайт, под который маскируется REALITY
#      HY2_SNI=www.bing.com            SNI для Hysteria2
#      SERVER_IP=1.2.3.4               если автоопределение IP не сработало
#      HY2_HOP_PORTS=20000:50000       диапазон UDP-портов для port hopping
#      NO_PORT_HOPPING=1               отключить port hopping
# =============================================================================
set -euo pipefail

ENV_REALITY_SNI="${REALITY_SNI:-}"
ENV_HY2_SNI="${HY2_SNI:-}"
ENV_SERVER_IP="${SERVER_IP:-}"
HY2_HOP_PORTS="${HY2_HOP_PORTS:-20000:50000}"
NO_PORT_HOPPING="${NO_PORT_HOPPING:-0}"

STATE_DIR=/etc/myvpn
STATE_FILE=$STATE_DIR/params.env
CLIENT_DIR=/root/vpn-client
XRAY_CONF=/usr/local/etc/xray/config.json
HY2_DIR=/etc/hysteria

c_green='\033[1;32m'; c_yellow='\033[1;33m'; c_red='\033[1;31m'; c_off='\033[0m'
log()  { echo -e "${c_green}[+]${c_off} $*"; }
warn() { echo -e "${c_yellow}[!]${c_off} $*"; }
die()  { echo -e "${c_red}[x]${c_off} $*" >&2; exit 1; }

# ---------------------------------------------------------------- проверки ---
[[ $EUID -eq 0 ]] || die "Запусти от root: sudo bash install.sh"
command -v apt-get >/dev/null || die "Поддерживаются только Debian/Ubuntu"
command -v systemctl >/dev/null || die "Нужен systemd"

if ss -ltnp 2>/dev/null | grep -qE ':443\s' && ! ss -ltnp | grep -E ':443\s' | grep -q xray; then
  die "TCP-порт 443 уже занят другой программой (nginx/apache?). Освободи его и запусти снова."
fi

# ---------------- параметры: сохранённые от прошлой установки + переопределения ---
mkdir -p "$STATE_DIR" "$CLIENT_DIR"
chmod 700 "$STATE_DIR" "$CLIENT_DIR"
if [[ -f $STATE_FILE ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  log "Нашёл сохранённые ключи — переиспользую (ссылки не изменятся)"
fi
REALITY_SNI="${ENV_REALITY_SNI:-${REALITY_SNI:-www.microsoft.com}}"
HY2_SNI="${ENV_HY2_SNI:-${HY2_SNI:-www.bing.com}}"
SERVER_IP="${ENV_SERVER_IP:-${SERVER_IP:-}}"

# ------------------------------------------------------------------ пакеты ---
log "Устанавливаю пакеты..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget openssl jq qrencode ca-certificates iptables uuid-runtime >/dev/null

# ---------------------------------------------------------------- IP адрес ---
if [[ -z "${SERVER_IP:-}" ]]; then
  for u in https://api.ipify.org https://ifconfig.me https://ipv4.icanhazip.com; do
    SERVER_IP=$(curl -4 -fsS --max-time 8 "$u" 2>/dev/null | tr -d '[:space:]') && [[ -n "$SERVER_IP" ]] && break
  done
fi
[[ "${SERVER_IP:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Не смог определить IPv4. Запусти: SERVER_IP=x.x.x.x bash install.sh"
log "IP сервера: $SERVER_IP"

# ------------------------------------------------- проверка сайта для REALITY ---
log "Проверяю, что $REALITY_SNI поддерживает TLS 1.3 + HTTP/2..."
if echo | timeout 10 openssl s_client -connect "$REALITY_SNI:443" -servername "$REALITY_SNI" \
      -tls1_3 -alpn h2 2>/dev/null | grep -q "ALPN protocol: h2"; then
  log "OK: $REALITY_SNI подходит"
else
  warn "$REALITY_SNI не прошёл проверку TLS1.3/h2. Лучше выбрать другой: REALITY_SNI=... bash install.sh"
fi

# ---------------------------------------------------------------- BBR/sysctl ---
log "Включаю BBR и сетевые оптимизации..."
cat > /etc/sysctl.d/99-myvpn.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.ip_forward = 1
EOF
sysctl --system >/dev/null 2>&1 || true

# ------------------------------------------------------------------- Xray ----
log "Устанавливаю Xray-core..."
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null
XRAY=/usr/local/bin/xray
[[ -x $XRAY ]] || die "Xray не установился"

if [[ -z "${XRAY_UUID:-}" ]]; then
  XRAY_UUID=$($XRAY uuid)
  KEYS=$($XRAY x25519)
  # Формат вывода менялся между версиями: берём значение после ':' из 1-й и 2-й строки
  XRAY_PRIV=$(echo "$KEYS" | sed -n '1p' | awk -F': *' '{print $2}' | tr -d '[:space:]')
  XRAY_PUB=$(echo "$KEYS"  | sed -n '2p' | awk -F': *' '{print $2}' | tr -d '[:space:]')
  XRAY_SID=$(openssl rand -hex 8)
fi
[[ -n "$XRAY_PRIV" && -n "$XRAY_PUB" ]] || die "Не удалось сгенерировать ключи REALITY"

cat > "$XRAY_CONF" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "reality-in",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$XRAY_UUID", "flow": "xtls-rprx-vision", "email": "laptop" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$REALITY_SNI:443",
          "xver": 0,
          "serverNames": ["$REALITY_SNI"],
          "privateKey": "$XRAY_PRIV",
          "shortIds": ["$XRAY_SID"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4" } },
    { "tag": "block",  "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" },
      { "type": "field", "ip": ["geoip:cn"], "outboundTag": "block" },
      { "type": "field", "domain": ["geosite:cn"], "outboundTag": "block" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" }
    ]
  },
  "policy": { "levels": { "0": { "handshake": 3, "connIdle": 180 } } }
}
EOF
$XRAY run -test -c "$XRAY_CONF" >/dev/null || die "Конфиг Xray невалидный"
systemctl enable --now xray >/dev/null 2>&1
systemctl restart xray

# --------------------------------------------------------------- Hysteria2 ---
log "Устанавливаю Hysteria2..."
bash <(curl -fsSL https://get.hy2.sh/) >/dev/null
command -v hysteria >/dev/null || die "Hysteria2 не установилась"

[[ -z "${HY2_PASS:-}" ]] && HY2_PASS=$(openssl rand -hex 16)
[[ -z "${HY2_OBFS:-}" ]] && HY2_OBFS=$(openssl rand -hex 16)

mkdir -p "$HY2_DIR"
if [[ ! -f $HY2_DIR/server.crt ]]; then
  openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout "$HY2_DIR/server.key" -out "$HY2_DIR/server.crt" \
    -subj "/CN=$HY2_SNI" -days 36500 >/dev/null 2>&1
fi
id hysteria >/dev/null 2>&1 && chown hysteria:hysteria "$HY2_DIR/server.key" "$HY2_DIR/server.crt"
chmod 600 "$HY2_DIR/server.key"
HY2_PIN=$(openssl x509 -noout -fingerprint -sha256 -in "$HY2_DIR/server.crt" | cut -d= -f2)

cat > "$HY2_DIR/config.yaml" <<EOF
listen: :443

tls:
  cert: $HY2_DIR/server.crt
  key: $HY2_DIR/server.key

obfs:
  type: salamander
  salamander:
    password: $HY2_OBFS

auth:
  type: password
  password: $HY2_PASS

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520

acl:
  inline:
    - reject(geoip:cn)
    - reject(geoip:private)
    - direct(all)

masquerade:
  type: proxy
  proxy:
    url: https://$HY2_SNI
    rewriteHost: true
EOF
systemctl enable --now hysteria-server >/dev/null 2>&1
systemctl restart hysteria-server

# ------------------------------------------------- UDP port hopping (Hy2) ----
HOP_SUFFIX=""
if [[ "$NO_PORT_HOPPING" != "1" ]]; then
  log "Настраиваю UDP port hopping ($HY2_HOP_PORTS -> 443)..."
  cat > /etc/systemd/system/myvpn-porthop.service <<EOF
[Unit]
Description=Hysteria2 UDP port hopping
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'iptables -t nat -C PREROUTING -p udp --dport $HY2_HOP_PORTS -j REDIRECT --to-ports 443 2>/dev/null || iptables -t nat -A PREROUTING -p udp --dport $HY2_HOP_PORTS -j REDIRECT --to-ports 443'
ExecStop=/bin/sh -c 'iptables -t nat -D PREROUTING -p udp --dport $HY2_HOP_PORTS -j REDIRECT --to-ports 443 || true'

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now myvpn-porthop >/dev/null 2>&1
  HOP_SUFFIX="${HY2_HOP_PORTS/:/-}"
fi

# ---------------------------------------------------------------- firewall ---
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  log "Открываю порты в ufw..."
  ufw allow 443/tcp >/dev/null
  ufw allow 443/udp >/dev/null
  [[ -n "$HOP_SUFFIX" ]] && ufw allow "$HY2_HOP_PORTS/udp" >/dev/null
fi

# --------------------------------------------------------- сохраняем ключи ---
cat > "$STATE_FILE" <<EOF
SERVER_IP=$SERVER_IP
REALITY_SNI=$REALITY_SNI
HY2_SNI=$HY2_SNI
XRAY_UUID=$XRAY_UUID
XRAY_PRIV=$XRAY_PRIV
XRAY_PUB=$XRAY_PUB
XRAY_SID=$XRAY_SID
HY2_PASS=$HY2_PASS
HY2_OBFS=$HY2_OBFS
HY2_PIN=$HY2_PIN
HOP_SUFFIX=$HOP_SUFFIX
EOF
chmod 600 "$STATE_FILE"

# ---------------------------------------------- клиентские конфиги и ссылки ---
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -f $SCRIPT_DIR/vpn ]]; then
  install -m 755 "$SCRIPT_DIR/vpn" /usr/local/bin/vpn
fi
[[ "$(readlink -f "${BASH_SOURCE[0]}")" != "$STATE_DIR/install.sh" ]] && install -m 700 "${BASH_SOURCE[0]}" "$STATE_DIR/install.sh"
/usr/local/bin/vpn gen >/dev/null 2>&1 || true

sleep 1
systemctl is-active --quiet xray            || die "Xray не запустился: journalctl -u xray -n 50"
systemctl is-active --quiet hysteria-server || die "Hysteria2 не запустилась: journalctl -u hysteria-server -n 50"

echo
log "Готово! Оба протокола работают."
echo
if command -v vpn >/dev/null; then
  vpn show
else
  warn "Файл 'vpn' не найден рядом с install.sh — положи его рядом и запусти снова, чтобы получить ссылки."
fi
