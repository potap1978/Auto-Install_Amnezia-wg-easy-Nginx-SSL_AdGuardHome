Amnezia-wg-easy-Nginx-SSL
```bash
bash <(wget -qO- https://raw.githubusercontent.com/potap1978/Auto-Install_Amnezia-wg-easy-Nginx-SSL/main/Auto-Install_Amnezia-wg-easy+Nginx-SSL.sh)
```

Amnezia-wg-easy-Nginx-SSL_AdGuardHome
```bash
bash <(wget -qO- https://raw.githubusercontent.com/potap1978/Auto-Install_Amnezia-wg-easy-Nginx-SSL/main/Auto-Install_Amnezia-wg-easy-Nginx-SSL_AdGuardHome.sh)
```

```bash
docker run --name adguardhome\
    --restart unless-stopped\
    -v /my/own/workdir:/opt/adguardhome/work\
    -v /my/own/confdir:/opt/adguardhome/conf\
    -p 53:53/tcp -p 53:53/udp\
    -p 67:67/udp -p 68:68/udp\
    -p 80:80/tcp -p 443:443/tcp -p 443:443/udp -p 3000:3000/tcp\
    -p 853:853/tcp\
    -p 853:853/udp\
    -p 5443:5443/tcp -p 5443:5443/udp\
    -p 6060:6060/tcp\
    -d adguard/adguardhome
```

Сопоставление портов, которые вам могут указать:

 -p 53:53/tcp -p 53:53/udp: простой DNS.

 -p 67:67/udp -p 68:68/tcp -p 68:68/udp: параметры, если вы планируете использовать AdGuard Home в качестве DHCP-сервера.

 -p 80:80/tcp -p 443:443/tcp -p 443:443/udp -p 3000:3000/tcp: параметр, если вы собираетесь использовать панель администратора AdGuard Home, а также запускать AdGuard Home как сервер HTTPS/DNS-over-HTTPS .

 -p 853:853/tcp: переключатели, если вы собираетесь запустить AdGuard Home как сервер DNS-over-TLS .

 -p 853:853/udp: параметры, если вы собираетесь запустить AdGuard Home как DNS-over-QUIC -сервер.

 -p 5443:5443/tcp -p 5443:5443/udp: параметры, если вы используете запуск AdGuard Home как сервер DNSCrypt .

 -p 6060:6060/tcp: отладочные профили.
