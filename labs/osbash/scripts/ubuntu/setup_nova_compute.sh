#!/usr/bin/env bash
set -o errexit -o nounset
TOP_DIR=$(cd "$(dirname "$0")/.." && pwd)
source "$TOP_DIR/config/paths"
source "$CONFIG_DIR/credentials"
source "$LIB_DIR/functions.guest.sh"
source "$CONFIG_DIR/admin-openstackrc.sh"
exec_logfile

indicate_current_auto

#------------------------------------------------------------------------------
# Set up OpenStack Compute (nova) for compute node.
# http://docs.openstack.org/liberty/install-guide-ubuntu/nova-compute-install.html
#------------------------------------------------------------------------------

echo "Installing nova for compute node."
#LIBTODO check the KVM status again
# We can't use KVM inside VirtualBox.
sudo apt-get install -y nova-compute-qemu sysfsutils

echo "Configuring nova for compute node."

conf=/etc/nova/nova.conf
echo "Configuring $conf."

# Configure Default section
iniset_sudo $conf DEFAULT rpc_backend rabbit

# Configure oslo_messaging_rabbit
iniset_sudo $conf oslo_messaging_rabbit rabbit_host controller-mgmt
iniset_sudo $conf oslo_messaging_rabbit rabbit_userid openstack
iniset_sudo $conf oslo_messaging_rabbit rabbit_password "$RABBIT_PASSWORD"

# Configuring [DEFAULT] section
iniset_sudo $conf DEFAULT auth_strategy keystone

nova_admin_user=$(service_to_user_name nova)
nova_admin_password=$(service_to_user_password nova)

# Configure [keystone_authtoken] section
iniset_sudo $conf keystone_authtoken auth_uri http://controller-mgmt:5000
iniset_sudo $conf keystone_authtoken auth_url http://controller-mgmt:35357
iniset_sudo $conf keystone_authtoken auth_plugin password
iniset_sudo $conf keystone_authtoken project_domain_id default
iniset_sudo $conf keystone_authtoken user_domain_id default
iniset_sudo $conf keystone_authtoken project_name "$SERVICE_PROJECT_NAME"
iniset_sudo $conf keystone_authtoken username "$nova_admin_user"
iniset_sudo $conf keystone_authtoken password "$nova_admin_password"

#LIBTODO address "Comment out or remove any other options in the
#LIBTODO [keystone_authtoken] section."

iniset_sudo $conf DEFAULT my_ip "$(hostname_to_ip compute-mgmt)"

#LIB new network config in the DEFAULT section

initset_sudo $conf DEFAULT network_api_class nova.network.neutronv2.api.API
initset_sudo $conf DEFAULT security_group_api neutron
initset_sudo $conf DEFAULT linuxnet_interface_driver nova.network.linux_net.NeutronLinuxBridgeInterfaceDriver
initset_sudo $conf DEFAULT firewall_driver nova.virt.firewall.NoopFirewallDriver

#LIB the VNC config has its own [vnc] section

iniset_sudo $conf vnc vnc_enabled True
iniset_sudo $conf vnc vncserver_listen 0.0.0.0
iniset_sudo $conf vnc vncserver_proxyclient_address compute-mgmt
iniset_sudo $conf vnc novncproxy_base_url http://"$(hostname_to_ip controller-api)":6080/vnc_auto.html

iniset_sudo $conf glance host controller-mgmt

iniset_sudo $conf glance oslo_concurrency /var/lib/nova/tmp

iniset_sudo $conf DEFAULT verbose True

#LIBTODO I don't think this is fully tested.
#LIBTODO If there is HW acceleration, virt_type = kvm is set
#LIBTODO But at the beginning of this script, we didn't install KVM

# Configure nova-compute.conf
conf=/etc/nova/nova-compute.conf
echo -n "Hardware acceleration for virtualization: "
if sudo egrep -q '(vmx|svm)' /proc/cpuinfo; then
    echo "available."
    iniset_sudo $conf libvirt virt_type kvm
else
    echo "not available."
    iniset_sudo $conf libvirt virt_type qemu
fi
echo "Config: $(sudo grep virt_type $conf)"

echo "Restarting nova services."
sudo service nova-compute restart

# Remove SQLite database created by Ubuntu package for nova.
sudo rm -v /var/lib/nova/nova.sqlite
