LoRaWAN gateway debian packaging scipts


# Instructions

. Build debian packages
. Install crond with `apt install cron` then `crontab -e` as root and write `@reboot /etc/boot-clv.bash` so that the script will execute near the end of boot.
