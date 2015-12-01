# The variables in this file are exported for use by OpenStack client
# applications.

# Unlike a regular openstackrc.sh file, this file gets its variable values
# from other configuration files (to limit redundancy).

# Use BASH_SOURCE so the file works when sourced from a shell, too
CONFIG_DIR=$(dirname "$BASH_SOURCE")
source "$CONFIG_DIR/openstack"
source "$CONFIG_DIR/credentials"

#------------------------------------------------------------------------------
# OpenStack client environment scripts
# http://docs.openstack.org/kilo/install-guide/install/apt/content/keystone-client-environment-scripts.html
#------------------------------------------------------------------------------

export OS_PROJECT_DOMAIN_ID=default
export OS_USER_DOMAIN_ID=default
export OS_PROJECT_NAME=$ADMIN_PROJECT_NAME
export OS_TENANT_NAME=$ADMIN_PROJECT_NAME
export OS_USERNAME=$ADMIN_USER_NAME
export OS_PASSWORD=$ADMIN_PASSWORD
export OS_AUTH_URL=http://controller-mgmt:35357/v3
export OS_REGION_NAME=$REGION
export OS_IDENTITY_API_VERSION=3
