#!/usr/bin/env bash
set -o nounset                              # Treat unset variables as an error
TOP_DIR=$(cd "$(dirname "$0")/.." && pwd)
source "$TOP_DIR/config/paths"
source "$CONFIG_DIR/credentials"
source "$LIB_DIR/functions.guest.sh"
source "$CONFIG_DIR/openstack"

exec_logfile

indicate_current_auto

#------------------------------------------------------------------------------
# Install the NoSQL (Mongo) service
# http://docs.openstack.org/liberty/install-guide-ubuntu/environment-nosql-database.html
#------------------------------------------------------------------------------

echo "Setting up database for telemetry."

echo "Installing the MongoDB packages."
sudo apt-get install -y mongodb-server mongodb-clients python-pymongo

echo "Configuring mongodb.conf."
conf=/etc/mongodb.conf
iniset_sudo_no_section $conf bind_ip "$(hostname_to_ip controller-mgmt)"
iniset_sudo_no_section $conf smallfiles true

echo "Restarting mongodb."
sudo service mongodb stop
sudo rm /var/lib/mongodb/journal/prealloc.*
sudo service mongodb start

echo -n "Waiting for mongodb to start."
while sudo service mongodb status 2>/dev/null | grep "stop"; do
    sleep 5
    echo -n .
done

