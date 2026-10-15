LoRaWAN gateway debian packaging scipts

# Instructions

- Use sicXnull work to install armbian from [here](https://github.com/sicXnull/Debian-Helium-Miners)
- Build debian packages. (you may need to install gcc e.t.c.)
- Copy `/etc/boot-clv.bash` to `/etc/`
- Install crond with `apt install cron` then `crontab -e` as root and write `@reboot /etc/boot-clv.bash` so that the script will execute near the end of boot.
