#!/usr/bin/env bash
set -o errexit -o nounset
TOP_DIR=$(cd "$(dirname "$0")/.." && pwd)
source "$TOP_DIR/config/paths"
source "$CONFIG_DIR/credentials"
source "$LIB_DIR/functions.guest.sh"

exec_logfile

indicate_current_auto

#------------------------------------------------------------------------------
# Install the Orchestration Service (heat).
# http://docs.openstack.org/liberty/install-guide-ubuntu/heat-install.html
#------------------------------------------------------------------------------

#####################################################################
#LIB Prerequisites

echo "Setting up database for heat."
setup_database heat

echo "Sourcing the admin credentials."
source "$CONFIG_DIR/admin-openstackrc.sh"

heat_admin_user=$(service_to_user_name heat)
heat_admin_password=$(service_to_user_password heat)

# Wait for keystone to come up
wait_for_keystone

#LIB New: --domain parameter now mandatory
echo "Creating heat user and giving it admin role under service tenant."
openstack user create \
    --domain default \
    --password "$heat_admin_password" \
    "$heat_admin_user"

openstack role add \
    --project "$SERVICE_PROJECT_NAME" \
    --user "$heat_admin_user" \
    "$ADMIN_ROLE_NAME"

#LIB heat_stack_{owner,user} roles are created further down now

echo "Creating the heat and heat-cfn service entities."
openstack service create \
    --name heat \
    --description "Orchestration" \
    orchestration

openstack service create \
    --name heat-cfn \
    --description "Orchestration" \
    cloudformation

#LIB New way of creating endpoints
#LIB
#LIB openstack endpoint create \
#LIB     --publicurl "http://controller-api:8004/v1/%(tenant_id)s" \
#LIB     --internalurl "http://controller-mgmt:8004/v1/%(tenant_id)s" \
#LIB     --adminurl "http://controller-mgmt:8004/v1/%(tenant_id)s" \
#LIB     --region "$REGION" \
#LIB     orchestration
#LIB
#LIB openstack endpoint create \
#LIB     --publicurl "http://controller-api:8000/v1" \
#LIB     --internalurl "http://controller-mgmt:8000/v1" \
#LIB     --adminurl "http://controller-mgmt:8000/v1" \
#LIB     --region "$REGION" \
#LIB     cloudformation

openstack endpoint create \
    --region RegionOne \
    orchestration public http://controller-api:8004/v1/%\(tenant_id\)s

openstack endpoint create \
    --region RegionOne \
    orchestration internal http://controller-mgmt:8004/v1/%\(tenant_id\)s

openstack endpoint create \
    --region RegionOne \
    orchestration admin http://controller-mgmt:8004/v1/%\(tenant_id\)s

openstack endpoint create  \
    --region RegionOne \
    cloudformation public http://controller-api:8000/v1

openstack endpoint create  \
    --region RegionOne \
    cloudformation internal http://controller-mgmt:8000/v1

openstack endpoint create  \
    --region RegionOne \
    cloudformation admin http://controller-mgmt:8000/v1

#LIB new heat domain, new heat_domain_admin user
#LIBTODO domain name, user name and password are hard coded.

echo "Creating heat domain"
openstack domain create \
          --description "Stack projects and users" \
	  heat

echo "Creating heat_domain_admin user"
openstack user create \
          --domain heat \
	  --password "$HEAT_DOMAIN_PASS" \
	  heat_domain_admin

openstack role add \
          --domain heat \
	  --user heat_domain_admin \
	  admin

echo "Creating the heat stack owner role."
openstack role create "heat_stack_owner"

openstack role add \
    --project "$DEMO_PROJECT_NAME" \
    --user "$DEMO_USER_NAME" \
    "heat_stack_owner"

echo "Creating the heat stack user role."
openstack role create "heat_stack_user"

#####################################################################
#LIB Install and configure components

echo "Installing heat."
sudo apt-get install -y heat-api heat-api-cfn heat-engine python-heatclient

function get_database_url {
    local db_user=$(service_to_db_user heat)
    local db_password=$(service_to_db_password heat)
    local database_host=controller-mgmt

#LIB New: pymysql
    echo "mysql+pymysql://$db_user:$db_password@$database_host/heat"
}

database_url=$(get_database_url)
echo "Database connection: $database_url."

echo "Configuring heat.conf."
conf=/etc/heat/heat.conf
iniset_sudo $conf database connection "$database_url"

echo "Configuring [DEFAULT] section in /etc/heat/heat.conf."

iniset_sudo $conf DEFAULT rpc_backend rabbit
iniset_sudo $conf DEFAULT rabbit_host controller-mgmt
iniset_sudo $conf DEFAULT rabbit_userid openstack
iniset_sudo $conf DEFAULT rabbit_password "$RABBIT_PASSWORD"

#LIB The keystone_authtoken section is much changed compared to Kilo
iniset_sudo $conf keystone_authtoken auth_uri http://controller-mgmt:5000
iniset_sudo $conf keystone_authtoken auth_url http://controller-mgmt:35357
iniset_sudo $conf keystone_authtoken auth_plugin password
iniset_sudo $conf keystone_authtoken project_domain_id default
iniset_sudo $conf keystone_authtoken user_domain_id default
iniset_sudo $conf keystone_authtoken project_name "$SERVICE_PROJECT_NAME"
iniset_sudo $conf keystone_authtoken username "$heat_admin_user"
iniset_sudo $conf keystone_authtoken password "$heat_admin_password"

#LIB new section [trustee]
iniset_sudo $conf trustee auth_uri http://controller-mgmt:5000
iniset_sudo $conf trustee auth_url http://controller-mgmt:35357
iniset_sudo $conf trustee auth_plugin password
iniset_sudo $conf trustee project_domain_id default
iniset_sudo $conf trustee user_domain_id default
iniset_sudo $conf trustee project_name "$SERVICE_PROJECT_NAME"
iniset_sudo $conf trustee username "$heat_admin_user"
iniset_sudo $conf trustee password "$heat_admin_password"

#LIB new section [clients_keystone]
iniset_sudo $conf clients_keystone auth_uri http://controller-mgmt:5000

#LIB Was: 5000/v2.0
iniset_sudo $conf ec2authtoken auth_uri http://controller-mgmt:5000

iniset_sudo $conf DEFAULT heat_metadata_server_url http://controller-mgmt:8000
iniset_sudo $conf DEFAULT heat_waitcondition_server_url http://controller-mgmt:8000/v1/waitcondition

iniset_sudo $conf DEFAULT stack_domain_admin heat_domain_admin
iniset_sudo $conf DEFAULT stack_domain_admin_password "$HEAT_DOMAIN_PASS"
iniset_sudo $conf DEFAULT stack_user_domain_name heat_user_domain

iniset_sudo $conf DEFAULT verbose True

#LIBTODO Should be done as hear user?
echo "Creating the database tables for heat."
sudo heat-manage db_sync

echo "Restarting heat service."
sudo service heat-api restart
sudo service heat-api-cfn restart
sudo service heat-engine restart

echo "Waiting for heat stack-list."
until heat stack-list; do
    sleep 1
done

echo "Removing default SQLite database."
sudo rm -f /var/lib/heat/heat.sqlite
