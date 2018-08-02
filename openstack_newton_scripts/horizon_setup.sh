#!/bin/bash

source config.cfg

unset LANG
unset LANGUAGE
LC_ALL=C
export LC_ALL


install_configure_horizon()
{
    echo ""
    echo "### 1. Install and configure Dashboard"
    echo ""
    yum -y install openstack-dashboard
    mv /etc/openstack-dashboard/local_settings /etc/openstack-dashboard/local_settings.bak
    cp local_settings /etc/openstack-dashboard/local_settings
    
    #
    # Change Time zone
    # 
    
    sed -r -i "s/CUSTOM_TIMEZONE/$TIMEZONE/g" /etc/openstack-dashboard/local_settings
    sed -r -i "s/_CONTROLLER/$CONTROLLER_NODES/g" /etc/openstack-dashboard/local_settings  

    #
    # If you chose networking option 1, disable support for layer-3 networking services:
    # 
    case $1 in
    provider)
        cat <<eof >> /etc/openstack-dashboard/local_settings
OPENSTACK_NEUTRON_NETWORK = {
    'enable_router': False,
    'enable_quotas': False,
    'enable_ipv6': True,
    'enable_distributed_router': False,
    'enable_ha_router': False,
    'enable_lb': False,
    'enable_firewall': False,
    'enable_vpn': False,
    'enable_fip_topology_check': False,
    'default_ipv4_subnet_pool_label': None,
    'default_ipv6_subnet_pool_label': None,
    'profile_support': None,
    'supported_provider_types': ['*'],
    'supported_vnic_types': ['*'],
}
eof
        ;;
    self-service)
        cat <<eof >> /etc/openstack-dashboard/local_settings
OPENSTACK_NEUTRON_NETWORK = {
    'enable_router': True,
    'enable_quotas': True,
    'enable_ipv6': True,
    'enable_distributed_router': True,
    'enable_ha_router': False,
    'enable_lb': True,
    'enable_firewall': True,
    'enable_vpn': True,
    'enable_fip_topology_check': False,
    'default_ipv4_subnet_pool_label': None,
    'default_ipv6_subnet_pool_label': None,
    'profile_support': None,
    'supported_provider_types': ['*'],
    'supported_vnic_types': ['*'],
}
eof
        ;;
    *)
        echo ""
        echo "### ERROR: Wrong network option, config this variable with"
        echo "'self-service' or 'provider'"
        echo ""
        exit 1
        ;; 
    esac

systemctl restart httpd.service memcached.service

}

verify_horizon()
{
    echo ""
    echo "### 2. Verify Horizon"
    echo "- Now you can access http://<controller-ip>/dashboard"
    echo "- Account: admin/"$KEYSTONE_ADMIN_PASS
    echo ""
}

main()
{
    echo "INSTALL_HORIZON"
    if [[ ( $1 == "provider" ) || ( $NODE_TYPE == "self-service" ) ]]
    then
        install_configure_horizon $1    
        verify_horizon
    else
        echo "### Please provide NODE TYPE exactly!"
    fi
}

main $1

