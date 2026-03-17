Версия скрипта установки wg-easy + nginx + Let's Encrypt для Ubuntu Server 22.04.

Что в нём есть:

- интерактивный режим

- quiet/non-interactive режим через аргументы

- ввод домена, email, пароля

- поддержка --password-file

- логирование установки

- проверка root / Ubuntu 22.04

- проверка свободного места

- проверка занятости портов 80/tcp, 443/tcp, WG_PORT/udp

- DNS-проверка с timeout

- бэкап существующей конфигурации

- аккуратный rollback при ошибке

- установка Docker + Compose plugin

- настройка nginx

- выпуск сертификата Let’s Encrypt

- проверка автопродления

- безопасная генерация PASSWORD_HASH

- включение ip_forward

Скрипт можно использовать и как шаблон для массовой установки.

Как использовать

Сохрани в файл, например:

```
nano /root/install-wg-easy.sh
```

Вставь скрипт целиком и сохрани.

Сделай исполняемым:

```
chmod +x /root/install-wg-easy.sh
```

Запусти:

```
/root/install-wg-easy.sh
```

Что важно до запуска

Домен вида vpn.твой-домен.ru должен уже смотреть на IP сервера. Иначе Let’s Encrypt не выпустится.

Запуск без вопросов:

```
echo 'S3curePassw0rd!' > /root/wg-pass.txt
chmod 600 /root/wg-pass.txt

/root/install-wg-easy.sh \
  --quiet \
  --force \
  --domain vpn.example.com \
  --email admin@example.com \
  --password-file /root/wg-pass.txt \
  --wg-port 51820 \
  --wg-dns 1.1.1.1,8.8.8.8 \
  --wg-subnet 10.8.0.0/24
```




