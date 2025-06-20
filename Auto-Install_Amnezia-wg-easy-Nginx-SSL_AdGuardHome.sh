#!/bin/bash

# Проверка на root
if [ "$(id -u)" -ne 0 ]; then
  echo "Этот скрипт должен запускаться с правами root" >&2
  exit 1
fi

# Функция для проверки IP-адреса
validate_ip() {
  local ip=$1
  if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    return 0
  else
    return 1
  fi
}

# Определение внешнего IP-адреса
DEFAULT_IP=$(curl -s ifconfig.me)
if ! validate_ip "$DEFAULT_IP"; then
  DEFAULT_IP=""
fi

# Запрос IP-адреса с предложением по умолчанию
while true; do
  if [ -n "$DEFAULT_IP" ]; then
    read -p "Введите IP-адрес вашего сервера [$DEFAULT_IP]: " SERVER_IP
    SERVER_IP=${SERVER_IP:-$DEFAULT_IP}
  else
    read -p "Введите IP-адрес вашего сервера: " SERVER_IP
  fi
  
  if validate_ip "$SERVER_IP"; then
    break
  else
    echo "Неверный формат IP-адреса. Попробуйте снова."
  fi
done

# Запрос пароля для Amnezia-WG-Easy
read -p "Введите пароль для Amnezia-WG-Easy: " WG_PASSWORD
echo ""

# Установка зависимостей для AdGuard Home
echo "Устанавливаем необходимые зависимости..."
apt update && apt install -y apache2-utils
if ! command -v htpasswd &> /dev/null; then
    echo "Ошибка: не удалось установить apache2-utils" >&2
    exit 1
fi

# Запрос учетных данных для AdGuard Home
read -p "Введите логин для AdGuardHome (по умолчанию: admin): " ADGUARD_USER
ADGUARD_USER=${ADGUARD_USER:-admin}

read -p "Введите пароль для AdGuardHome (по умолчанию: admin): " ADGUARD_PASSWORD
ADGUARD_PASSWORD=${ADGUARD_PASSWORD:-admin}
ADGUARD_HASH=$(htpasswd -nbB "$ADGUARD_USER" "$ADGUARD_PASSWORD" | cut -d ":" -f 2)

# Установка NGINX и OpenSSL
echo "Устанавливаем NGINX и OpenSSL..."
apt update && \
apt upgrade -y && \
apt install curl gnupg2 ca-certificates lsb-release ubuntu-keyring -y && \
curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor | sudo tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null && \
gpg --dry-run --quiet --no-keyring --import --import-options import-show /usr/share/keyrings/nginx-archive-keyring.gpg && \
echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" | sudo tee /etc/apt/sources.list.d/nginx.list && \
echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/ubuntu $(lsb_release -cs) nginx" | sudo tee /etc/apt/sources.list.d/nginx.list && \
echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" | sudo tee /etc/apt/preferences.d/99nginx && \
apt update && \
apt install nginx openssl -y

# Генерация SSL сертификатов
echo "Генерируем SSL сертификаты..."
CERT_DIR="/home"
CERT_NAME="AmneziaWG"
DAYS_VALID=3650
mkdir -p "$CERT_DIR"
CERT_PATH="$CERT_DIR/$CERT_NAME-PUB_KEY.crt"
KEY_PATH="$CERT_DIR/$CERT_NAME-PRIVAT_KEY.key"

openssl req -x509 -nodes -days $DAYS_VALID -newkey rsa:2048 \
  -keyout "$KEY_PATH" \
  -out "$CERT_PATH" \
  -subj "/C=US/ST=State/L=City/O=Organization/OU=Department/CN=$SERVER_IP"

if [ $? -ne 0 ]; then
  echo "Ошибка при генерации сертификатов" >&2
  exit 1
fi

# Настройка NGINX
echo "Настраиваем NGINX..."
cat > /etc/nginx/conf.d/default.conf <<EOF
server {
    listen 80;
    server_name $SERVER_IP;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    server_name $SERVER_IP;

    ssl_certificate $CERT_PATH;
    ssl_certificate_key $KEY_PATH;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;

    location / {
        proxy_pass http://127.0.0.1:51821;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# Перезапуск NGINX
systemctl restart nginx
systemctl enable nginx

# Установка Docker
echo "Устанавливаем Docker..."
curl -fsSL https://get.docker.com | sh
usermod -aG docker $(whoami)

# Создание локальной сети Docker
echo "Создаем локальную сеть Docker..."
docker network create --subnet=172.20.0.0/24 amnezia_net

# Генерация хэша пароля
echo "Генерируем хэш пароля..."
PASSWORD_HASH=$(docker run --rm ghcr.io/potap1978/amnezia-wg-easy wgpw "$WG_PASSWORD" | sed "s/^.*'\(.*\)'.*$/\1/")

# Настройка конфигурации AdGuard Home
echo "Настраиваем AdGuard Home..."
mkdir -p /opt/adguardhome/conf
cat > /opt/adguardhome/conf/AdGuardHome.yaml <<EOF
http:
  pprof:
    port: 6060
    enabled: false
  address: 0.0.0.0:80
  session_ttl: 720h
users:
  - name: $ADGUARD_USER
    password: $ADGUARD_HASH
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: ""
theme: auto
dns:
  bind_hosts:
    - 0.0.0.0
  port: 53
  anonymize_client_ip: false
  ratelimit: 20
  ratelimit_subnet_len_ipv4: 24
  ratelimit_subnet_len_ipv6: 56
  ratelimit_whitelist: []
  refuse_any: true
  upstream_dns:
    - https://cloudflare-dns.com/dns-query
    - https://dns.adguard-dns.com/dns-query
    - https://dns.quad9.net/dns-query
  upstream_dns_file: ""
  bootstrap_dns:
    - 9.9.9.10
    - 149.112.112.10
    - 2620:fe::10
    - 2620:fe::fe:10
  fallback_dns:
    - https://dns.quad9.net/dns-query
    - quic://unfiltered.adguard-dns.com
  upstream_mode: parallel
  fastest_timeout: 1s
  allowed_clients: []
  disallowed_clients: []
  blocked_hosts:
    - version.bind
    - id.server
    - hostname.bind
  trusted_proxies:
    - 127.0.0.0/8
    - ::1/128
  cache_size: 4194304
  cache_ttl_min: 0
  cache_ttl_max: 0
  cache_optimistic: false
  bogus_nxdomain: []
  aaaa_disabled: false
  enable_dnssec: false
  edns_client_subnet:
    custom_ip: ""
    enabled: false
    use_custom: false
  max_goroutines: 300
  handle_ddr: true
  ipset: []
  ipset_file: ""
  bootstrap_prefer_ipv6: false
  upstream_timeout: 10s
  private_networks: []
  use_private_ptr_resolvers: false
  local_ptr_upstreams: []
  use_dns64: false
  dns64_prefixes: []
  serve_http3: false
  use_http3_upstreams: false
  serve_plain_dns: true
  hostsfile_enabled: true
tls:
  enabled: false
  server_name: ""
  force_https: false
  port_https: 443
  port_dns_over_tls: 853
  port_dns_over_quic: 853
  port_dnscrypt: 0
  dnscrypt_config_file: ""
  allow_unencrypted_doh: false
  certificate_chain: ""
  private_key: ""
  certificate_path: ""
  private_key_path: ""
  strict_sni_check: false
querylog:
  dir_path: ""
  ignored: []
  interval: 24h
  size_memory: 1000
  enabled: true
  file_enabled: true
statistics:
  dir_path: ""
  ignored: []
  interval: 24h
  enabled: true
filters:
  - enabled: true
    url: https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt
    name: AdGuard DNS filter
    id: 1
  - enabled: true
    url: https://adaway.org/hosts.txt
    name: AdAway Default Blocklist
    id: 2
  - enabled: true
    url: https://easylist-downloads.adblockplus.org/advblock.txt
    name: RuAdlist
    id: 1670584470
  - enabled: false
    url: https://easylist-downloads.adblockplus.org/bitblock.txt
    name: BitBlock
    id: 1670584471
  - enabled: true
    url: https://easylist-downloads.adblockplus.org/cntblock.txt
    name: cntblock
    id: 1670584472
  - enabled: true
    url: https://easylist-downloads.adblockplus.org/easylist.txt
    name: easyList
    id: 1670584473
  - enabled: false
    url: https://schakal.ru/hosts/alive_hosts_ru_com.txt
    name: то же без неотвечающих хостов и доменов вне зон RU, NET и COM
    id: 1677533164
  - enabled: true
    url: https://schakal.ru/hosts/hosts_mail_fb.txt
    name: файл с разблокированными r.mail.ru и graph.facebook.com
    id: 1677533165
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1726948599
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_59.txt
    name: AdGuard DNS Popup Hosts filter
    id: 1726948600
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_27.txt
    name: OISD Blocklist Big
    id: 1726948601
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_24.txt
    name: 1Hosts (Lite)
    id: 1726948602
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_10.txt
    name: Scam Blocklist by DurableNapkin
    id: 1726948603
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_11.txt
    name: Malicious URL Blocklist (URLHaus)
    id: 1726948604
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_50.txt
    name: uBlock₀ filters – Badware risks
    id: 1726948605
whitelist_filters: []
user_rules: []
dhcp:
  enabled: false
  interface_name: ""
  local_domain_name: lan
  dhcpv4:
    gateway_ip: ""
    subnet_mask: ""
    range_start: ""
    range_end: ""
    lease_duration: 86400
    icmp_timeout_msec: 1000
    options: []
  dhcpv6:
    range_start: ""
    lease_duration: 86400
    ra_slaac_only: false
    ra_allow_slaac: false
filtering:
  blocking_ipv4: ""
  blocking_ipv6: ""
  blocked_services:
    schedule:
      time_zone: America/Los_Angeles
    ids: []
  protection_disabled_until: null
  safe_search:
    enabled: false
    bing: true
    duckduckgo: true
    google: true
    pixabay: true
    yandex: true
    youtube: true
  blocking_mode: default
  parental_block_host: family-block.dns.adguard.com
  safebrowsing_block_host: standard-block.dns.adguard.com
  rewrites: []
  safebrowsing_cache_size: 1048576
  safesearch_cache_size: 1048576
  parental_cache_size: 1048576
  cache_time: 30
  filters_update_interval: 24
  blocked_response_ttl: 10
  filtering_enabled: true
  parental_enabled: false
  safebrowsing_enabled: false
  protection_enabled: true
clients:
  runtime_sources:
    whois: true
    arp: true
    rdns: true
    dhcp: true
    hosts: true
  persistent: []
log:
  enabled: true
  file: ""
  max_backups: 0
  max_size: 100
  max_age: 3
  compress: false
  local_time: false
  verbose: false
os:
  group: ""
  user: ""
  rlimit_nofile: 0
schema_version: 28
EOF

# Запуск Amnezia-WG-Easy
echo "Запускаем Amnezia-WG-Easy..."
docker run -d \
  --name=amnezia-wg-easy \
  --network=amnezia_net \
  --ip=172.20.0.2 \
  -e LANG=ru \
  -e WG_HOST=$SERVER_IP \
  -e PASSWORD_HASH=$PASSWORD_HASH \
  -e PORT=51821 \
  -e WG_PORT=51820 \
  -e WG_ENABLE_EXPIRES_TIME=true \
  -e UI_TRAFFIC_STATS=true \
  -e WG_DEFAULT_DNS='172.20.0.3' \
  -e WG_ENABLE_ONE_TIME_LINKS=true \
  -e DICEBEAR_TYPE=bottts \
  -e WG_PERSISTENT_KEEPALIVE=15 \
  -e WG_ALLOWED_IPS='0.0.0.0/0, ::/0' \
  -v ~/.amnezia-wg-easy:/etc/wireguard \
  -p 51820:51820/udp \
  -p 127.0.0.1:51821:51821/tcp \
  --cap-add=NET_ADMIN \
  --cap-add=SYS_MODULE \
  --sysctl="net.ipv4.conf.all.src_valid_mark=1" \
  --sysctl="net.ipv4.ip_forward=1" \
  --device=/dev/net/tun:/dev/net/tun \
  --restart unless-stopped \
  ghcr.io/potap1978/amnezia-wg-easy

# Запуск AdGuard Home (только во внутренней сети)
echo "Запускаем AdGuard Home (только во внутренней сети)..."
docker run -d \
  --name adguardhome \
  --network=amnezia_net \
  --ip=172.20.0.3 \
  -v /opt/adguardhome/work:/opt/adguardhome/work \
  -v /opt/adguardhome/conf:/opt/adguardhome/conf \
  --restart unless-stopped \
  adguard/adguardhome

# Вывод информации
echo ""
echo "Установка завершена!"
echo "-----------------------------"
echo "Доступ к веб-интерфейсу Amnezia-WG-Easy: https://$SERVER_IP"
echo "Ваш пароль для входа: $WG_PASSWORD"
echo ""
echo "AdGuard Home доступен только по внутреннему адресу: http://172.20.0.3"
echo "Логин AdGuardHome: $ADGUARD_USER"
echo "Пароль AdGuardHome: $ADGUARD_PASSWORD"
echo ""
echo "IP-адреса в локальной сети:"
echo "Amnezia-WG-Easy: 172.20.0.2"
echo "AdGuard Home: 172.20.0.3"
echo ""

# Очистка истории команд
echo "Очищаем историю команд..."
history -c
history -w
echo "История команд очищена."
