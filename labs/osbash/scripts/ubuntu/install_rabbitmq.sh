#!/usr/bin/env bash
set -o errexit -o nounset
TOP_DIR=$(cd "$(dirname "$0")/.." && pwd)
source "$TOP_DIR/config/paths"
source "$CONFIG_DIR/credentials"
source "$LIB_DIR/functions.guest.sh"

exec_logfile

indicate_current_auto

#-------------------------------------------------------------------------------
# Install the message broker service (RabbitMQ).
# http://docs.openstack.org/liberty/install-guide-ubuntu/environment-messaging.html
#-------------------------------------------------------------------------------


echo "Installing RabbitMQ."
sudo apt-get install -y rabbitmq-server

echo "Adding openstack user to messaging service."
sudo rabbitmqctl add_user openstack "$RABBIT_PASSWORD"

echo "Permit configuration, write and read access for the openstack user."
sudo rabbitmqctl set_permissions openstack ".*" ".*" ".*"
