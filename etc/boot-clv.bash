#!/bin/sh -e
#
# rc.local
#
# This script is executed at the end of each multiuser runlevel.
# Make sure that the script will "exit 0" on success or any other
# value on error.
#
# In order to enable or disable this script just change the execution
# bits.
#
# By default this script does nothing.
# Generate the SSH keys if non-existent
if [ ! -f /etc/ssh/ssh_host_rsa_key ]
then
    # else ssh service start in dpkg-reconfigure will fail
    systemctl stop ssh.socket||true
    dpkg-reconfigure openssh-server
fi

# change permissions for the sx1302 gpio's
for n in 122 125 149; do
    if [ ! -d /sys/class/gpio/gpio$n ]; then
        echo "$n" > /sys/class/gpio/export
        sleep 0.1
    fi
    chown root:dialout /sys/class/gpio/gpio$n/direction 2>/dev/null || true
    chown root:dialout /sys/class/gpio/gpio$n/value     2>/dev/null || true
    chmod 0660          /sys/class/gpio/gpio$n/direction 2>/dev/null || true
    chmod 0660          /sys/class/gpio/gpio$n/value     2>/dev/null || true
done

# link is down if EEE is on
/usr/sbin/ethtool --set-eee end0 eee off

# disable DEBUG log
/usr/bin/systemctl log-level info

exit 0
