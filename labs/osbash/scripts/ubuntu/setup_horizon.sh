#!/usr/bin/env bash
set -o errexit -o nounset
TOP_DIR=$(cd "$(dirname "$0")/.." && pwd)
source "$TOP_DIR/config/paths"
source "$LIB_DIR/functions.guest.sh"
exec_logfile

indicate_current_auto

#------------------------------------------------------------------------------
# Set up OpenStack Dashboard (horizon)
# http://docs.openstack.org/liberty/install-guide-ubuntu/horizon-install.html
#------------------------------------------------------------------------------

#LIB the instructions don't seem to differ between Kilo and Liberty

echo "Installing horizon."
sudo apt-get install -y openstack-dashboard

#LIBTODO I don't know what the purge is about; it appears neither in
#LIBTODO the Kilo nor the Liberty guide
echo "Purging Ubuntu theme."
sudo dpkg --purge openstack-dashboard-ubuntu-theme

function check_dashboard_settings {
    local dashboard_conf=/etc/openstack-dashboard/local_settings.py

    local auth_host=controller-mgmt
    echo "Setting OPENSTACK_HOST = \"$auth_host\"."
#LIBTODO Why the trailing semicolon?
    sudo sed -i "s#^\(OPENSTACK_HOST =\).*#\1 \"$auth_host\";#" $dashboard_conf

#LIBTODO should be set to ALLOWED_HOSTS = ['*', ]
    echo -n "Allowed hosts: "
    grep "^ALLOWED_HOSTS" $dashboard_conf

    local memcached_conf=/etc/memcached.conf
    # Port is a number on line starting with "-p "
    local port=$(grep -Po -- '(?<=^-p )\d+' $memcached_conf)

    # Interface is an IP address on line starting with "-l "
    local interface=$(grep -Po -- '(?<=^-l )[\d\.]+' $memcached_conf)

    echo "memcached listening on $interface:$port."

    # Line should read something like: 'LOCATION' : '127.0.0.1:11211',
    if grep "LOCATION.*$interface:$port" $dashboard_conf; then
        echo "$dashboard_conf agrees."
    else
        echo >&2 "$dashboard_conf disagrees. Aborting."
        exit 1
    fi

    echo -n "Time zone setting: "
    grep TIME_ZONE $dashboard_conf
}

echo "Checking dashboard configuration."
check_dashboard_settings

function check_apache_service {
    # Check if apache service is down, if not force retry a couple of times.
    sleep 10
    i=0
    until service apache2 status | grep 'not running'; do
        sudo service apache2 stop
        sleep 10
        i=$((i + 1))
        if [ $i -gt 3 ]; then
            break
        fi
    done
}

echo "Reloading apache and memcached service."
sudo service apache2 stop
check_apache_service
sudo service apache2 start
