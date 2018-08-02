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
	CREATE DATABASE $GLANCE_DBNAME;
	GRANT ALL PRIVILEGES ON $GLANCE_DBNAME.* TO '$GLANCE_DBUSER'@'localhost' \
	  IDENTIFIED BY '$GLANCE_DBPASS';
	GRANT ALL PRIVILEGES ON $GLANCE_DBNAME.* TO '$GLANCE_DBUSER'@'%' \
	  IDENTIFIED BY '$GLANCE_DBPASS';
	quit
EOF
}


create_endpoint_user_project()
{
	echo "### 2. create the service credentials"
	source $CONFIG_PATH/.admin-openrc
	# create the `glance` user
	openstack user create glance --domain default --password $GLANCE_PASS
	# add the `admin` role to the `glance` user and `service` project
	openstack role add --project service --user glance admin
	# create the `glance` service entity
	openstack service create --name glance --description "OpenStack Image" image
	# create the Image service API endpoints
	openstack endpoint create --region RegionOne image public http://$CONTROLLER_NODES:9292
	openstack endpoint create --region RegionOne image internal http://$CONTROLLER_NODES:9292
	openstack endpoint create --region RegionOne image admin http://$CONTROLLER_NODES:9292
}


install_glance()
{
	echo "### 3. Install Glance packages"
	
	yum install -y openstack-glance
	if [[ $? -eq 0 ]]
	then
		echo "### Install Glance is Done"
	else
		clear
		echo '### Error: Install Glance not Done'
	fi
}

configure_glance()
{
	echo "### 4. Configure Glance"

	# edit the file /etc/glance/glance-api.conf
	crudini --set /etc/glance/glance-api.conf database connection mysql+pymysql://$GLANCE_DBUSER:$GLANCE_DBPASS@$CONTROLLER_NODES/$GLANCE_DBNAME
	crudini --set /etc/glance/glance-api.conf keystone_authtoken auth_uri http://$CONTROLLER_NODES:5000
	crudini --set /etc/glance/glance-api.conf keystone_authtoken auth_url http://$CONTROLLER_NODES:35357
	crudini --set /etc/glance/glance-api.conf keystone_authtoken memcached_servers $CONTROLLER_NODES:11211
	crudini --set /etc/glance/glance-api.conf keystone_authtoken auth_type password
	crudini --set /etc/glance/glance-api.conf keystone_authtoken project_domain_name Default
	crudini --set /etc/glance/glance-api.conf keystone_authtoken user_domain_name Default
	crudini --set /etc/glance/glance-api.conf keystone_authtoken project_name service
	crudini --set /etc/glance/glance-api.conf keystone_authtoken username glance
	crudini --set /etc/glance/glance-api.conf keystone_authtoken password $GLANCE_PASS
	crudini --set /etc/glance/glance-api.conf paste_deploy flavor keystone
	crudini --set /etc/glance/glance-api.conf glance_store stores file,http
	crudini --set /etc/glance/glance-api.conf glance_store default_store file
	crudini --set /etc/glance/glance-api.conf glance_store filesystem_store_datadir /var/lib/glance/images/

	# edit the file /etc/glance/glance-registry.conf
	crudini --set /etc/glance/glance-registry.conf database connection mysql+pymysql://$GLANCE_DBUSER:$GLANCE_DBPASS@$CONTROLLER_NODES/$GLANCE_DBNAME
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken auth_uri http://$CONTROLLER_NODES:5000
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken auth_url http://$CONTROLLER_NODES:35357
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken auth_type password
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken project_domain_name Default
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken user_domain_name Default
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken project_name service
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken username glance
	crudini --set /etc/glance/glance-registry.conf keystone_authtoken password $GLANCE_PASS
	crudini --set /etc/glance/glance-registry.conf paste_deploy flavor keystone

	IS_MASTER=$1
	if [[ $IS_MASTER == "MASTER" ]]
	then
		su -s /bin/sh -c "glance-manage db_sync" $GLANCE_DBNAME
	fi

	systemctl enable openstack-glance-api.service openstack-glance-registry.service
	systemctl start openstack-glance-api.service openstack-glance-registry.service
}

verify_glance()
{
	echo "### 5. Vefiry Glance"
	source $CONFIG_PATH/.admin-openrc
	yum -y install wget
	wget http://download.cirros-cloud.net/0.3.4/cirros-0.3.4-x86_64-disk.img
	openstack image create "cirros" \
  		--file cirros-0.3.4-x86_64-disk.img \
  		--disk-format qcow2 --container-format bare \
  		--public
  	openstack image list
}

remove_database()
{
	echo "### WARNING. Remove the database"

	/usr/bin/mysql -u $MYSQL_ROOT -p$MYSQL_PASS << EOF
	DROP DATABASE $GLANCE_DBNAME;
	quit
EOF
}

remove_glance_packages()
{
	echo "### WARNING. Removing Glance packages"
	
	yum -y remove openstack-glance
	if [[ $? -eq 0 ]]
	then
		echo "### Remove Glance is Done"
	else
		clear
		echo '### Error: Remove Glance not Done'
	fi
}

remove_glance_in_keystone()
{
	source $CONFIG_PATH/.admin-openrc
	openstack user delete glance
	openstack service delete glance
}

main()
{
    echo "#### SETUP GLANCE MODE: $1"

    NODE_TYPE=$1
	# just permit NODE TYPE in MASTER | SLAVE
    if [[ ( $NODE_TYPE == "MASTER" ) || ( $NODE_TYPE == "SLAVE" ) ]]
    then
    	if [[ $NODE_TYPE == "MASTER" ]]
    	then
    		create_database
    	fi
    	install_glance
    	if [[ $NODE_TYPE == "MASTER" ]]
    	then
    		create_endpoint_user_project
    	fi
		configure_glance $NODE_TYPE
		verify_glance
    elif [[ $NODE_TYPE == "CLEAR" ]]
    then
    	remove_glance_in_keystone
    	remove_glance_packages
    	remove_database
    else
        echo "### Please provide NODE TYPE exactly!"
    fi
}

main $1

