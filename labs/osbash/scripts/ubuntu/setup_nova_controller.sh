#!/usr/bin/env bash
set -o errexit -o nounset
TOP_DIR=$(cd "$(dirname "$0")/.." && pwd)
source "$TOP_DIR/config/paths"
source "$CONFIG_DIR/credentials"
source "$LIB_DIR/functions.guest.sh"
exec_logfile

indicate_current_auto

#------------------------------------------------------------------------------
# Install Compute controller services
# http://docs.openstack.org/liberty/install-guide-ubuntu/nova-controller-install.html
#------------------------------------------------------------------------------

echo "Setting up database for nova."
setup_database nova

echo "Sourcing the admin credentials."
source "$CONFIG_DIR/admin-openstackrc.sh"

nova_admin_user=$(service_to_user_name nova)
nova_admin_password=$(service_to_user_password nova)

# Wait for keystone to come up
wait_for_keystone

echo "Creating nova user and giving it the admin role."
openstack user create \
    --domain default  \
    --password "$nova_admin_password" \
    "$nova_admin_user"

openstack role add \
    --project "$SERVICE_PROJECT_NAME" \
    --user "$nova_admin_user" \
    "$ADMIN_ROLE_NAME"

echo "Creating the nova service entity."
openstack service create \
    --name nova \
    --description "OpenStack Compute" \
    compute

openstack endpoint create \
    --region RegionOne \
    compute public http://controller-api:8774/v2/%\(tenant_id\)s

openstack endpoint create \
    --region RegionOne \
    compute internal http://controller-mgmt:8774/v2/%\(tenant_id\)s

openstack endpoint create \
    --region RegionOne \
    compute admin http://controller-mgmt:8774/v2/%\(tenant_id\)s

echo "Installing nova for controller node."
sudo apt-get install -y \
    nova-api nova-cert nova-conductor nova-consoleauth \
    nova-novncproxy nova-scheduler python-novaclient

function get_database_url {
    local db_user=$(service_to_db_user nova)
    local db_password=$(service_to_db_password nova)
    local database_host=controller-mgmt

    echo "mysql+pymysql://$db_user:$db_password@$database_host/nova"
}

database_url=$(get_database_url)

conf=/etc/nova/nova.conf

echo "Setting database connection: $database_url."
iniset_sudo $conf database connection "$database_url"

echo "Configuring nova services."

# Default Section.
iniset_sudo $conf DEFAULT rpc_backend rabbit

# oslo_messaging_rabbit section.
iniset_sudo $conf oslo_messaging_rabbit rabbit_host controller-mgmt
iniset_sudo $conf oslo_messaging_rabbit rabbit_userid openstack
iniset_sudo $conf oslo_messaging_rabbit rabbit_password "$RABBIT_PASSWORD"


iniset_sudo $conf DEFAULT auth_strategy keystone

# Configure keystone_authtoken section.
iniset_sudo $conf keystone_authtoken auth_uri http://controller-mgmt:5000
iniset_sudo $conf keystone_authtoken auth_url http://controller-mgmt:35357
iniset_sudo $conf keystone_authtoken auth_plugin password
iniset_sudo $conf keystone_authtoken project_domain_id default
iniset_sudo $conf keystone_authtoken user_domain_id default
iniset_sudo $conf keystone_authtoken project_name "$SERVICE_PROJECT_NAME"
iniset_sudo $conf keystone_authtoken username "$nova_admin_user"
iniset_sudo $conf keystone_authtoken password "$nova_admin_password"

# Default section
iniset_sudo $conf DEFAULT my_ip "$(hostname_to_ip controller-mgmt)"

iniset_sudo $conf DEFAULT network_api_class nova.network.neutronv2.api.API
iniset_sudo $conf DEFAULT security_group_api neutron
iniset_sudo $conf DEFAULT linuxnet_interface_driver                 \
                   nova.network.linux_net.NeutronLinuxBridgeInterfaceDriver
iniset_sudo $conf DEFAULT                                           \
                   firewall_driver nova.virt.firewall.NoopFirewallDriver

# VNC section
iniset_sudo $conf vnc vncserver_listen controller-mgmt
iniset_sudo $conf vnc vncserver_proxyclient_address controller-mgmt

# Glance section
iniset_sudo $conf glance host controller-mgmt

# oslo_concurrency section
iniset_sudo $conf oslo_concurrency lock_path /var/lib/nova/tmp

# default section
iniset_sudo $conf DEFAULT enabled_apis osapi_compute,metadata
iniset_sudo $conf DEFAULT verbose True

#XXX Should be done as user nova
echo "Creating the database tables for nova."
sudo nova-manage db sync

iniset_sudo $conf cinder os_region_name RegionOne

echo "Restarting nova services."
declare -a nova_services=(nova-api nova-cert nova-consoleauth \
    nova-scheduler nova-conductor nova-novncproxy)

for nova_service in "${nova_services[@]}"; do
    echo "Restarting $nova_service"
    sudo service "$nova_service" restart
done

#------------------------------------------------------------------------------
# Verify the Compute controller installation
#------------------------------------------------------------------------------

echo "Verify nova service status."
echo "Checking nova services"
loop=0
until nova service-list 2>/dev/null
do 
    echo -n .
    loop=$((loop+1))
    if ((loop%10 == 0))
    then echo; echo still checking
    fi
    sleep 1
done

#echo "Verify nova service status."
#echo "Checking nova services"
#nova service-list

echo "Checking nova endpoints"
nova endpoints

echo "Checking nova images"
nova image-list

