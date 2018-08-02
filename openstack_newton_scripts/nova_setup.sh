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
	CREATE DATABASE $NOVA_DBNAME;
	CREATE DATABASE $NOVA_API_DBNAME;
	GRANT ALL PRIVILEGES ON $NOVA_DBNAME.* TO '$NOVA_DBUSER'@'localhost' \
	  IDENTIFIED BY '$NOVA_DBPASS';
	GRANT ALL PRIVILEGES ON $NOVA_DBNAME.* TO '$NOVA_DBUSER'@'%' \
	  IDENTIFIED BY '$NOVA_DBPASS';
	GRANT ALL PRIVILEGES ON $NOVA_API_DBNAME.* TO '$NOVA_DBUSER'@'localhost' \
	  IDENTIFIED BY '$NOVA_DBPASS';
	GRANT ALL PRIVILEGES ON $NOVA_API_DBNAME.* TO '$NOVA_DBUSER'@'%' \
	  IDENTIFIED BY '$NOVA_DBPASS';
	quit
EOF
}

remove_database()
{
	echo "### WARNING. Removing the database"

	/usr/bin/mysql -u $MYSQL_ROOT -p$MYSQL_PASS << EOF
	DROP DATABASE $NOVA_DBNAME;
	DROP DATABASE $NOVA_API_DBNAME;
EOF
}

create_endpoint_user_project()
{
	echo "### 2. create the service credentials"
	source $CONFIG_PATH/.admin-openrc
	# create the `nova` user
	openstack user create nova --domain default --password $NOVA_PASS
	# add the `admin` role to the `nova` user
	openstack role add --project service --user nova admin
	# create the `nova` service entity
	openstack service create --name nova --description "OpenStack Compute" compute
	# create the compute service API endpoints
	openstack endpoint create --region RegionOne compute public http://$CONTROLLER_NODES:8774/v2.1/%\(tenant_id\)s
	openstack endpoint create --region RegionOne compute internal http://$CONTROLLER_NODES:8774/v2.1/%\(tenant_id\)s
	openstack endpoint create --region RegionOne compute admin http://$CONTROLLER_NODES:8774/v2.1/%\(tenant_id\)s
}

remove_endpoint_user_project()
{
	echo "### WARNING. Removing the service credentials"
	source $CONFIG_PATH/.admin-openrc
	openstack user delete nova
	openstack service delete nova
}

install_nova_packages()
{
	echo "### 3. Install Nova packages"
	
	yum install -y openstack-nova-api openstack-nova-conductor \
  				openstack-nova-console openstack-nova-novncproxy \
  				openstack-nova-scheduler
	if [[ $? -eq 0 ]]
	then
		echo "### Install Nova is Done"
	else
		clear
		echo '### Error: Install Nova not Done'
	fi
}

remove_nova_packages()
{
	echo "### WARNING. Removing the nova packages"
	yum remove -y openstack-nova-api openstack-nova-conductor \
  				openstack-nova-console openstack-nova-novncproxy \
  				openstack-nova-scheduler
}

configure_nova()
{
	echo "### 4. configure nova"
	crudini --set /etc/nova/nova.conf DEFAULT enabled_apis osapi_compute,metadata
	crudini --set /etc/nova/nova.conf DEFAULT transport_url rabbit://$RABBIT_USER:$RABBIT_PASS@$CONTROLLER_NODES
	crudini --set /etc/nova/nova.conf DEFAULT auth_strategy keystone
	crudini --set /etc/nova/nova.conf DEFAULT my_ip $CONTROLLER_IP
	crudini --set /etc/nova/nova.conf use_neutron True
	crudini --set /etc/nova/nova.conf firewall_driver nova.virt.firewall.NoopFirewallDriver

	# Configure to use database Mysql
	crudini --set /etc/nova/nova.conf api_database connection = mysql+pymysql://$NOVA_DBUSER:$NOVA_DBPASS@$CONTROLLER_NODES/$NOVA_API_DBNAME
	crudini --set /etc/nova/nova.conf database connection = mysql+pymysql://$NOVA_DBUSER:$NOVA_DBPASS@$CONTROLLER_NODES/$NOVA_DBNAME

	# Configure to use keystone service
	crudini --set /etc/nova/nova.conf keystone_authtoken auth_uri http://$CONTROLLER_NODES:5000
	crudini --set /etc/nova/nova.conf keystone_authtoken auth_url http://$CONTROLLER_NODES:35357
	crudini --set /etc/nova/nova.conf keystone_authtoken memcached_servers $CONTROLLER_NODES:11211
	crudini --set /etc/nova/nova.conf keystone_authtoken auth_type password
	crudini --set /etc/nova/nova.conf keystone_authtoken project_domain_name Default
	crudini --set /etc/nova/nova.conf keystone_authtoken user_domain_name Default
	crudini --set /etc/nova/nova.conf keystone_authtoken project_name service
	crudini --set /etc/nova/nova.conf keystone_authtoken username nova
	crudini --set /etc/nova/nova.conf keystone_authtoken password $NOVA_PASS

	# Enable VNC service
	crudini --set /etc/nova/nova.conf vnc vncserver_listen $my_ip
	crudini --set /etc/nova/nova.conf vnc vncserver_proxyclient_address $my_ip

	# Configure to use glance service
	crudini --set /etc/nova/nova.conf glance api_servers http://$CONTROLLER_NODES:9292
	crudini --set /etc/nova/nova.conf oslo_concurrency lock_path /var/lib/nova/tmp

	# Configure to use neutron service
	crudini --set /etc/nova/nova.conf neutron url http://$CONTROLLER_NODES:9696
	crudini --set /etc/nova/nova.conf neutron auth_url http://$CONTROLLER_NODES:35357
	crudini --set /etc/nova/nova.conf neutron auth_type password
	crudini --set /etc/nova/nova.conf neutron project_domain_name Default
	crudini --set /etc/nova/nova.conf neutron user_domain_name Default
	crudini --set /etc/nova/nova.conf neutron region_name RegionOne
	crudini --set /etc/nova/nova.conf neutron project_name service
	crudini --set /etc/nova/nova.conf neutron username neutron
	crudini --set /etc/nova/nova.conf neutron password $NEUTRON_PASS
	crudini --set /etc/nova/nova.conf neutron service_metadata_proxy True
	crudini --set /etc/nova/nova.conf neutron metadata_proxy_shared_secret $METADATA_SECRET

	# Populate the Compute databases
	IS_MASTER=$1
	if [[ $IS_MASTER == "MASTER" ]]
	then
		su -s /bin/sh -c "nova-manage api_db sync" nova
		su -s /bin/sh -c "nova-manage db sync" nova
	fi

	# Start the Compute services and configure them to start when the system boots
	systemctl enable openstack-nova-api.service \
  		openstack-nova-consoleauth.service openstack-nova-scheduler.service \
  		openstack-nova-conductor.service openstack-nova-novncproxy.service
  	systemctl start openstack-nova-api.service \
  		openstack-nova-consoleauth.service openstack-nova-scheduler.service \
  		openstack-nova-conductor.service openstack-nova-novncproxy.service

}

verify_nova()
{
	echo "### 5. verify nova"
	source $CONFIG_PATH/.admin-openrc
	openstack compute service list
}

main()
{
    echo "#### SETUP NOVA MODE: $1"

    NODE_TYPE=$1
	# just permit NODE TYPE in MASTER | SLAVE
    if [[ ( $NODE_TYPE == "MASTER" ) || ( $NODE_TYPE == "SLAVE" ) ]]
    then
    	if [[ $NODE_TYPE == "MASTER" ]]
    	then
    		create_database
    	fi
    	install_nova_packages
    	if [[ $NODE_TYPE == "MASTER" ]]
    	then
    		create_endpoint_user_project
    	fi
		configure_nova $NODE_TYPE
		verify_nova
    elif [[ $NODE_TYPE == "CLEAR" ]]
    then
    	remove_endpoint_user_project
    	remove_nova_packages
    	remove_database
    else
        echo "### Please provide NODE TYPE exactly!"
    fi
}

main $1
