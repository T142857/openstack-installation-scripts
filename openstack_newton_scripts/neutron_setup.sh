#!/bin/bash

source config.cfg

unset LANG
unset LANGUAGE
LC_ALL=C
export LC_ALL


create_database()
{
	echo "### 1. Create the database"

	/usr/bin/mysql -u $MYSQL_ROOT -p$MYSQL_PASS << EOF
	CREATE DATABASE $NEUTRON_DBNAME;
	GRANT ALL PRIVILEGES ON $NEUTRON_DBNAME.* TO '$NEUTRON_DBUSER'@'localhost' \
	  IDENTIFIED BY '$NEUTRON_DBPASS';
	GRANT ALL PRIVILEGES ON $NEUTRON_DBNAME.* TO '$NEUTRON_DBUSER'@'%' \
	  IDENTIFIED BY '$NEUTRON_DBPASS';
	quit
EOF
}



create_endpoint_user_project()
{
	echo "### 2. create the service credentials"
	source $CONFIG_PATH/.admin-openrc
	# create the `neutron` user
	openstack user create neutron --domain default --password $NEUTRON_PASS
	# add the `admin` role to the `neutron` user
	openstack role add --project service --user neutron admin
	# create the `neutron` service entity
	openstack service create --name neutron --description "OpenStack Networking" network
	# create the networking service API endpoints
	openstack endpoint create --region RegionOne network public http://$CONTROLLER_NODES:9696
	openstack endpoint create --region RegionOne network internal http://$CONTROLLER_NODES:9696
	openstack endpoint create --region RegionOne network admin http://$CONTROLLER_NODES:9696
}



install_neutron_provider_network()
{
	echo "### 3. install neutron provider netowrk"
	yum -y install openstack-neutron openstack-neutron-ml2 \
  		openstack-neutron-linuxbridge ebtables
	if [[ $? -eq 0 ]]
	then
		echo "### Install Neutron is Done"
	else
		clear
		echo '### Error: Install Neutron not Done'
	fi
}


configure_neutron_provider_network()
{
	echo "### 4. configure neutron"
	crudini --set /etc/neutron/neutron.conf DEFAULT transport_url rabbit://$RABBIT_USER:$RABBIT_PASS@$CONTROLLER_NODES
	crudini --set /etc/neutron/neutron.conf DEFAULT core_plugin ml2
	crudini --set /etc/neutron/neutron.conf DEFAULT service_plugins
	crudini --set /etc/neutron/neutron.conf DEFAULT auth_strategy keystone
	crudini --set /etc/neutron/neutron.conf DEFAULT notify_nova_on_port_status_changes True
	crudini --set /etc/neutron/neutron.conf DEFAULT notify_nova_on_port_data_changes True

	# Configure to use Mysql
	crudini --set /etc/neutron/neutron.conf database connection mysql+pymysql://$NEUTRON_DBUSER:$NEUTRON_DBPASS@$CONTROLLER_NODES/$NEUTRON_DBNAME

	# Configure to use keystone service
	crudini --set /etc/neutron/neutron.conf keystone_authtoken auth_uri http://$CONTROLLER_NODES:5000
	crudini --set /etc/neutron/neutron.conf keystone_authtoken auth_url http://$CONTROLLER_NODES:35357
	crudini --set /etc/neutron/neutron.conf keystone_authtoken memcached_servers $CONTROLLER_NODES:11211
	crudini --set /etc/neutron/neutron.conf keystone_authtoken auth_type password
	crudini --set /etc/neutron/neutron.conf keystone_authtoken project_domain_name Default
	crudini --set /etc/neutron/neutron.conf keystone_authtoken user_domain_name Default
	crudini --set /etc/neutron/neutron.conf keystone_authtoken project_name service
	crudini --set /etc/neutron/neutron.conf keystone_authtoken username neutron
	crudini --set /etc/neutron/neutron.conf keystone_authtoken password $NEUTRON_PASS

	# Configure to use nova service
	crudini --set /etc/neutron/neutron.conf nova auth_url http://$CONTROLLER_NODES:35357
	crudini --set /etc/neutron/neutron.conf nova auth_type password
	crudini --set /etc/neutron/neutron.conf nova project_domain_name Default
	crudini --set /etc/neutron/neutron.conf nova user_domain_name Default
	crudini --set /etc/neutron/neutron.conf nova region_name RegionOne
	crudini --set /etc/neutron/neutron.conf nova project_name service
	crudini --set /etc/neutron/neutron.conf nova username nova
	crudini --set /etc/neutron/neutron.conf nova password $NOVA_PASS

	crudini --set /etc/neutron/neutron.conf oslo_concurrency lock_path /var/lib/neutron/tmp

	# Configure ML2 
	crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 type_drivers flat,vlan
	crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 tenant_network_types
	crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 mechanism_drivers linuxbridge
	crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2 extension_drivers port_security
	crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_flat flat_networks provider
	crudini --set /etc/neutron/plugins/ml2/ml2_conf.ini securitygroup enable_ipset True

	# Configure Bridge agent
	crudini --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini linux_bridge physical_interface_mappings provider:$PROVIDER_INTERFACE_NAME
	crudini --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini vxlan enable_vxlan False
	crudini --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini securitygroup enable_security_group True
	crudini --set /etc/neutron/plugins/ml2/linuxbridge_agent.ini firewall_driver neutron.agent.linux.iptables_firewall.IptablesFirewallDriver

	# Configure DHCP agent
	crudini --set /etc/neutron/dhcp_agent.ini DEFAULT interface_driver neutron.agent.linux.interface.BridgeInterfaceDriver
	crudini --set /etc/neutron/dhcp_agent.ini DEFAULT dhcp_driver neutron.agent.linux.dhcp.Dnsmasq
	crudini --set /etc/neutron/dhcp_agent.ini DEFAULT enable_isolated_metadata True

	# Configure Metadata agent
	crudini --set /etc/neutron/metadata_agent.ini DEFAULT nova_metadata_ip $CONTROLLER_NODES
	crudini --set /etc/neutron/metadata_agent.ini DEFAULT metadata_proxy_shared_secret $METADATA_SECRET

	# Finalize installation
	ln -s /etc/neutron/plugins/ml2/ml2_conf.ini /etc/neutron/plugin.ini

	IS_MASTER=$1
	if [[ $IS_MASTER == "MASTER" ]]
	then
		su -s /bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf \
  			--config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head" neutron
	fi

	systemctl enable neutron-server.service \
  		neutron-linuxbridge-agent.service neutron-dhcp-agent.service neutron-metadata-agent.service
  	systemctl start neutron-server.service \
  		neutron-linuxbridge-agent.service neutron-dhcp-agent.service neutron-metadata-agent.service

}

verify_neutron_network_provider()
{
	echo "### 5. verify nova"
	source $CONFIG_PATH/.admin-openrc
	openstack network agent list
}

remove_database()
{
	echo "### WARNING. Removing the database"

	/usr/bin/mysql -u $MYSQL_ROOT -p$MYSQL_PASS << EOF
	DROP DATABASE $NEUTRON_DBNAME;
EOF
}

remove_endpoint_user_project()
{
	echo "### WARNING. Removing the service credentials"
	source $CONFIG_PATH/.admin-openrc
	openstack user delete neutron
	openstack service delete neutron
}

remove_neutron_provider_network()
{
	echo "### WARNING. Removing neutron provider network"
	yum -y install openstack-neutron openstack-neutron-ml2 \
  		openstack-neutron-linuxbridge ebtables
}

main()
{
    echo "#### SETUP NEUTRON CONTROLLER PROVIDER MODE: $1"

    NODE_TYPE=$1
	# just permit NODE TYPE in MASTER | SLAVE
    if [[ ( $NODE_TYPE == "MASTER" ) || ( $NODE_TYPE == "SLAVE" ) ]]
    then
    	if [[ $NODE_TYPE == "MASTER" ]]
    	then
    		create_database
    	fi
    	install_neutron_provider_network
    	if [[ $NODE_TYPE == "MASTER" ]]
    	then
    		create_endpoint_user_project
    	fi
		configure_neutron_provider_network $NODE_TYPE
		verify_neutron_network_provider
    elif [[ $NODE_TYPE == "CLEAR" ]]
    then
    	remove_endpoint_user_project
    	remove_neutron_provider_network
    	remove_database
    else
        echo "### Please provide NODE TYPE exactly!"
    fi
}

main $1










