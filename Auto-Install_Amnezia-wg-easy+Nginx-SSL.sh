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
read -sp "Введите пароль для Amnezia-WG-Easy: " WG_PASSWORD
echo ""

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
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA38;

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

# Генерация хэша пароля
echo "Генерируем хэш пароля..."
PASSWORD_HASH=$(docker run --rm ghcr.io/potap1978/amnezia-wg-easy wgpw "$WG_PASSWORD" | sed "s/^.*'\(.*\)'.*$/\1/")

# Запуск Amnezia-WG-Easy
echo "Запускаем Amnezia-WG-Easy..."
docker run -d \
  --name=amnezia-wg-easy \
  -e LANG=ru \
  -e WG_HOST=$SERVER_IP \
  -e PASSWORD_HASH=$PASSWORD_HASH \
  -e PORT=51821 \
  -e WG_PORT=51820 \
  -e WG_ENABLE_EXPIRES_TIME=true \
  -e UI_TRAFFIC_STATS=true \
  -e WG_DEFAULT_DNS='8.8.8.8, 8.8.4.4' \
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

# Вывод информации
echo "Обязательно передай привет Potap`у :) "
echo "Установка завершена!"
echo "-----------------------------"
echo "Доступ к веб-интерфейсу: https://$SERVER_IP"
echo "Ваш пароль для входа: $WG_PASSWORD"
echo ""

# Очистка истории команд
echo "Очищаем историю команд..."
history -c
history -w
echo "История команд очищена."

