#!/usr/bin/env bash
set -o errexit -o nounset
TOP_DIR=$(cd "$(dirname "$0")/.." && pwd)
source "$TOP_DIR/config/paths"
source "$CONFIG_DIR/credentials"
source "$LIB_DIR/functions.guest.sh"
exec_logfile

indicate_current_auto

#------------------------------------------------------------------------------
# Set up Block Storage service controller (cinder controller node)
# http://docs.openstack.org/liberty/install-guide-ubuntu/cinder-controller-install.html
#------------------------------------------------------------------------------

#####################################################################
#LIB Prerequisites

echo "Setting up database for cinder."
setup_database cinder

source "$CONFIG_DIR/admin-openstackrc.sh"

cinder_admin_user=$(service_to_user_name cinder)
cinder_admin_password=$(service_to_user_password cinder)

# Wait for keystone to come up
wait_for_keystone

#LIB --domain parameter now mandatory

echo "Creating cinder user."
openstack user create \
    --domain default \
    --password "$cinder_admin_password" \
    "$cinder_admin_user"

echo "Linking cinder user, service tenant and admin role."
openstack role add \
    --user "$cinder_admin_user" \
    --project "$SERVICE_PROJECT_NAME" \
    "$ADMIN_ROLE_NAME"

echo "Registering cinder with keystone so that other services can locate it."
openstack service create \
    --name cinder \
    --description "OpenStack Block Storage" \
    volume

openstack service create \
    --name cinderv2 \
    --description "OpenStack Block Storage v2" \
    volumev2

#LIB new way of creating endpoints.
#LIB This is the old way, up until Kilo:
#LIB
#LIB openstack endpoint create \
#LIB     --publicurl 'http://controller-api:8776/v1/%(tenant_id)s' \
#LIB     --adminurl 'http://controller-mgmt:8776/v1/%(tenant_id)s' \
#LIB     --internalurl 'http://controller-mgmt:8776/v1/%(tenant_id)s' \
#LIB     --region "$REGION" \
#LIB     volume
#LIB
#LIB openstack endpoint create \
#LIB     --publicurl 'http://controller-api:8776/v2/%(tenant_id)s' \
#LIB     --adminurl 'http://controller-mgmt:8776/v2/%(tenant_id)s' \
#LIB     --internalurl 'http://controller-mgmt:8776/v2/%(tenant_id)s' \
#LIB     --region "$REGION" \
#LIB     volumev2

openstack endpoint create \
    --region RegionOne \
    volume public http://controller-api:8776/v1/%\(tenant_id\)s

openstack endpoint create \
    --region RegionOne \
    volume internal http://controller-mgmt:8776/v1/%\(tenant_id\)s

openstack endpoint create \
    --region RegionOne \
    volume admin http://controller-mgmt:8776/v1/%\(tenant_id\)s

openstack endpoint create \
    --region RegionOne \
    volumev2 public http://controller-api:8776/v2/%\(tenant_id\)s

openstack endpoint create \
    --region RegionOne \
    volumev2 internal http://controller-mgmt:8776/v2/%\(tenant_id\)s

openstack endpoint create \
    --region RegionOne \
    volumev2 admin http://controller-mgmt:8776/v2/%\(tenant_id\)s

#####################################################################
#LIB Install and configure components

echo "Installing cinder."
sudo apt-get install -y cinder-api cinder-scheduler python-cinderclient \
    qemu-utils
# Note: The package 'qemu-utils' is required for 'qemu-img' which allows cinder
#       to convert additional image types to bootable volumes. By default only
#       raw images can be converted.

function get_database_url {
    local db_user=$(service_to_db_user cinder)
    local db_password=$(service_to_db_password cinder)
    local database_host=controller-mgmt

#LIB New: pymysql
    echo "mysql+pymysql://$db_user:$db_password@$database_host/cinder"
}

database_url=$(get_database_url)

echo "Configuring cinder-api.conf."
conf=/etc/cinder/cinder.conf

echo "Setting database connection: $database_url."
iniset_sudo $conf database connection "$database_url"

# Configure [DEFAULT] section to use RabbitMQ message broker.
iniset_sudo $conf DEFAULT rpc_backend rabbit

iniset_sudo $conf oslo_messaging_rabbit rabbit_host controller-mgmt
iniset_sudo $conf oslo_messaging_rabbit rabbit_userid openstack
iniset_sudo $conf oslo_messaging_rabbit rabbit_password "$RABBIT_PASSWORD"

iniset_sudo $conf DEFAULT auth_strategy keystone

# Configure [keystone_authtoken] section.
iniset_sudo $conf keystone_authtoken auth_uri http://controller-mgmt:5000
iniset_sudo $conf keystone_authtoken auth_url http://controller-mgmt:35357
iniset_sudo $conf keystone_authtoken auth_plugin password
iniset_sudo $conf keystone_authtoken project_domain_id default
iniset_sudo $conf keystone_authtoken user_domain_id default
iniset_sudo $conf keystone_authtoken project_name "$SERVICE_PROJECT_NAME"
iniset_sudo $conf keystone_authtoken username "$cinder_admin_user"
iniset_sudo $conf keystone_authtoken password "$cinder_admin_password"

#LIBTODO "Comment out or remove any other options in the
#LIBTODO [keystone_authtoken] section."

iniset_sudo $conf DEFAULT my_ip "$(hostname_to_ip controller-mgmt)"

#LIB Lock path /var/lock/cinder -> /var/lib/cinder/tmp
iniset_sudo $conf oslo_concurrency lock_path /var/lib/cinder/tmp

iniset_sudo $conf DEFAULT verbose True

#LIBTODO should be done by cinder user?
echo "Creating the database tables for cinder."
sudo cinder-manage db sync

echo "Restarting cinder service."
sudo service cinder-scheduler restart
sudo service cinder-api restart

echo "Removing unused SQLite database file (if any)."
sudo rm -rf /var/lib/cinder/cinder.sqlite
