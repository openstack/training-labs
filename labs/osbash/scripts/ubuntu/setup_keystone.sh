#!/usr/bin/env bash
set -o errexit -o nounset
TOP_DIR=$(cd "$(dirname "$0")/.." && pwd)
source "$TOP_DIR/config/paths"
source "$CONFIG_DIR/credentials"
source "$CONFIG_DIR/openstack"
source "$LIB_DIR/functions.guest.sh"

exec_logfile

indicate_current_auto

#------------------------------------------------------------------------------
# Set up keystone for controller node
# http://docs.openstack.org/liberty/install-guide-ubuntu/keystone-install.html
#------------------------------------------------------------------------------

echo "Setting up database for keystone."
setup_database keystone

# Create a "shared secret" used as OS_TOKEN, together with OS_URL, before
# keystone can be used for authentication
echo -n "Using openssl to generate a random admin token: "
ADMIN_TOKEN=$(openssl rand -hex 10)
echo "$ADMIN_TOKEN"


echo "Disabling the keystone service from starting automatically after installation."
echo "manual" | sudo tee /etc/init/keystone.override

echo "Installing python openstack client"
sudo apt-get install -y python-openstackclient

echo "Installing keystone."
sudo apt-get install -y keystone  apache2 \
    libapache2-mod-wsgi memcached python-memcache

conf=/etc/keystone/keystone.conf
echo "Configuring [DEFAULT] section in $conf."

echo "Setting admin_token to bootstrap authentication."
iniset_sudo $conf DEFAULT admin_token "$ADMIN_TOKEN"

function get_database_url {
    local db_user=$(service_to_db_user keystone)
    local db_password=$(service_to_db_password keystone)
    local database_host=controller-mgmt

    echo "mysql+pymysql://$db_user:$db_password@$database_host/keystone"
}

database_url=$(get_database_url)

echo "Configuring [database] section in /etc/keystone/keystone.conf."

echo "Setting database connection: $database_url."
iniset_sudo $conf database connection "$database_url"


echo "Configuring the Memcache service."
iniset_sudo $conf memcache servers localhost:11211

echo "Configuring the UUID token provider and SQL driver."
iniset_sudo $conf token provider uuid
iniset_sudo $conf token driver memcache

echo "Configuring the SQL revocation driver."
iniset_sudo $conf revoke driver sql

echo "Enabling verbose logging."
iniset_sudo $conf DEFAULT verbose True

# XXX This should be done as user "keystone"
echo "Creating the database tables for keystone."
sudo keystone-manage db_sync

# Configure Apache HTTP server.

echo "Configuring ServerName option in /etc/apache2/apache2.conf to reference controller node."
echo "ServerName controller-mgmt" | sudo tee -a /etc/apache2/apache2.conf

echo "Creating /etc/apache2/sites-available/wsgi-keystone.conf."
cat << WSGI | sudo tee -a /etc/apache2/sites-available/wsgi-keystone.conf
Listen 5000
Listen 35357

<VirtualHost *:5000>
    WSGIDaemonProcess keystone-public processes=5 threads=1 user=keystone group=keystone display-name=%{GROUP}
    WSGIProcessGroup keystone-public
    WSGIScriptAlias / /usr/bin/keystone-wsgi-public
    WSGIApplicationGroup %{GLOBAL}
    WSGIPassAuthorization On
    <IfVersion >= 2.4>
      ErrorLogFormat "%{cu}t %M"
    </IfVersion>
    ErrorLog /var/log/apache2/keystone.log
    CustomLog /var/log/apache2/keystone_access.log combined

    <Directory /usr/bin>
        <IfVersion >= 2.4>
            Require all granted
        </IfVersion>
        <IfVersion < 2.4>
            Order allow,deny
            Allow from all
        </IfVersion>
    </Directory>
</VirtualHost>

<VirtualHost *:35357>
    WSGIDaemonProcess keystone-admin processes=5 threads=1 user=keystone group=keystone display-name=%{GROUP}
    WSGIProcessGroup keystone-admin
    WSGIScriptAlias / /usr/bin/keystone-wsgi-admin
    WSGIApplicationGroup %{GLOBAL}
    WSGIPassAuthorization On
    <IfVersion >= 2.4>
      ErrorLogFormat "%{cu}t %M"
    </IfVersion>
    ErrorLog /var/log/apache2/keystone.log
    CustomLog /var/log/apache2/keystone_access.log combined

    <Directory /usr/bin>
        <IfVersion >= 2.4>
            Require all granted
        </IfVersion>
        <IfVersion < 2.4>
            Order allow,deny
            Allow from all
        </IfVersion>
    </Directory>
</VirtualHost>

WSGI

echo "Enabling the identity service virtual hosts."
sudo ln -s /etc/apache2/sites-available/wsgi-keystone.conf /etc/apache2/sites-enabled

echo "Restarting apache."
sudo service apache2 restart

echo "Removing default SQLite database."
sudo rm -f /var/lib/keystone/keystone.db

#------------------------------------------------------------------------------
# Configure keystone services and API endpoints
# http://docs.openstack.org/kilo/install-guide/install/apt/content/keystone-services.html
#------------------------------------------------------------------------------

echo "Using OS_TOKEN, OS_URL for authentication."
export OS_TOKEN=$ADMIN_TOKEN
export OS_URL=http://controller-mgmt:35357/v3
export OS_IDENTITY_API_VERSION=3

echo "Creating keystone service."
openstack service create \
    --name keystone \
    --description "OpenStack Identity" \
    identity

echo "Creating endpoints for keystone."
openstack endpoint create --region RegionOne \
    identity public http://controller:5000/v2.0

openstack endpoint create --region RegionOne \
    identity internal http://controller:5000/v2.0

openstack endpoint create --region RegionOne \
    identity admin http://controller:35357/v2.0

#------------------------------------------------------------------------------
# Configure keystone users, tenants and roles
# http://docs.openstack.org/kilo/install-guide/install/apt/content/keystone-users.html
#------------------------------------------------------------------------------

# Wait for keystone to come up
wait_for_keystone

echo "Creating admin project."
openstack project create --domain default \
    --description "Admin Project" \
    "$ADMIN_PROJECT_NAME"

echo "Creating admin user."
openstack user create --domain default \
    --password "$ADMIN_PASSWORD" \
    "$ADMIN_USER_NAME"

echo "Creating admin role."
openstack role create "$ADMIN_ROLE_NAME"

echo "Adding admin role to admin project."
openstack role add \
    --project "$ADMIN_PROJECT_NAME" \
    --user "$ADMIN_USER_NAME" \
    "$ADMIN_ROLE_NAME"

echo "Creating service project."
openstack project create --domain default \
    --description "Service Project" \
    "$SERVICE_PROJECT_NAME"

echo "Creating demo project."
openstack project create --domain default \
    --description "Demo Project" \
    "$DEMO_PROJECT_NAME"

echo "Creating demo user."
openstack user create --domain default \
    --password "$DEMO_PASSWORD" \
    "$DEMO_USER_NAME"

echo "Creating the user role."
openstack role create \
    "$USER_ROLE_NAME"

echo "Linking user role to demo project and user."
openstack role add \
    --project "$DEMO_PROJECT_NAME" \
    --user "$DEMO_USER_NAME" \
    "$USER_ROLE_NAME"

#------------------------------------------------------------------------------
# Verify the Identity Service installation
# http://docs.openstack.org/kilo/install-guide/install/apt/content/keystone-verify.html
#------------------------------------------------------------------------------

echo "Verifying keystone installation."

# Disable temporary authentication token mechanism
conf=/etc/keystone/keystone-paste.ini

for section in pipeline:public_api pipeline:admin_api pipeline:api_v3; do
    if ini_has_option_sudo $conf $section admin_token_auth; then
        echo "Disabling admin_token_auth in section $section."
        inicomment_sudo $conf $section admin_token_auth
    fi
done

# From this point on, we are going to use keystone for authentication
unset OS_TOKEN OS_URL

echo "Requesting an authentication token as an admin user."
openstack \
    --os-auth-url http://controller:35357 \
    --os-project-domain-id default \
    --os-user-domain-id default \
    --os-project-name "$ADMIN_PROJECT_NAME" \
    --os-username "$ADMIN_USER_NAME" \
    --os-auth-type password \
    --os-password "$ADMIN_PASSWORD" \
    token issue

echo "Requesting project list."
openstack \
    --os-auth-url http://controller:35357 \
    --os-project-name "$ADMIN_PROJECT_NAME" \
    --os-username "$ADMIN_USER_NAME" \
    --os-auth-type password \
    --os-password "$ADMIN_PASSWORD" \
    project list

echo "Requesting user list."
openstack \
    --os-auth-url http://controller:35357 \
    --os-project-name "$ADMIN_PROJECT_NAME" \
    --os-username "$ADMIN_USER_NAME" \
    --os-auth-type password \
    --os-password "$ADMIN_PASSWORD" \
    user list

echo "Requesting role list."
openstack \
    --os-auth-url http://controller:35357 \
    --os-project-name "$ADMIN_PROJECT_NAME" \
    --os-username "$ADMIN_USER_NAME" \
    --os-auth-type password \
    --os-password "$ADMIN_PASSWORD" \
    role list

echo "Requesting an authentication token for the demo user."
openstack \
    --os-auth-url http://controller:5000 \
    --os-project-domain-id default \
    --os-user-domain-id default \
    --os-project-name "$DEMO_PROJECT_NAME" \
    --os-username "$DEMO_USER_NAME" \
    --os-auth-type password \
    --os-password "$DEMO_PASSWORD" \
    token issue

echo "Verifying that an admin-only request by the demo user is denied."
openstack \
    --os-auth-url http://controller:5000 \
    --os-project-domain-id default \
    --os-user-domain-id default \
    --os-project-name "$DEMO_PROJECT_NAME" \
    --os-username "$DEMO_USER_NAME" \
    --os-auth-type password \
    --os-password "$DEMO_PASSWORD" \
    user list || rc=$?

echo rc=$rc
if [ $rc -eq 0 ]; then
    echo "The request was not denied. This is an error. Exiting."
    exit 1
else
    echo "The request was correctly denied."
fi
