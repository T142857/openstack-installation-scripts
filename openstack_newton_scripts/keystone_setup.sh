#!/bin/bash

source config.cfg


create_database()
{
	echo "### 1. Create the database"

	/usr/bin/mysql -u $MYSQL_ROOT -p$MYSQL_PASS << EOF
	CREATE DATABASE $KEYSTONE_DBNAME;
	GRANT ALL PRIVILEGES ON $KEYSTONE_DBNAME.* TO '$KEYSTONE_DBUSER'@'localhost' \
	  IDENTIFIED BY '$KEYSTONE_DBPASS';
	GRANT ALL PRIVILEGES ON $KEYSTONE_DBNAME.* TO '$KEYSTONE_DBUSER'@'%' \
	  IDENTIFIED BY '$KEYSTONE_DBPASS';
	quit
EOF
}


install_keystone()
{
	echo "### 2. Install Keystone packages"
	#
	# We proceed to install keystone packages and it's dependencies
	#
	yum -y install openstack-keystone httpd mod_wsgi openstack-utils
	if [[ $? -eq 0 ]]
	then
		echo "### Install Keystone is Done"
	else
		clear
		echo '### Error: Install Keystone not Done'
	fi
}

configure_keystone()
{
	echo "### 3. Configure Keystone"
	crudini --set /etc/keystone/keystone.conf DEFAULT admin_token $ADMIN_TOKEN
	crudini --set /etc/keystone/keystone.conf database connection mysql+pymysql://$KEYSTONE_DBUSER:$KEYSTONE_DBPASS@$CONTROLLER_NODES/$KEYSTONE_DBNAME
	crudini --set /etc/keystone/keystone.conf token provider fernet
	su -s /bin/sh -c "keystone-manage db_sync" $KEYSTONE_DBNAME

	keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
	keystone-manage credential_setup --keystone-user keystone --keystone-group keystone

	keystone-manage bootstrap --bootstrap-password $KEYSTONE_ADMIN_PASS \
	  --bootstrap-admin-url http://$CONTROLLER_NODES:35357/v3/ \
	  --bootstrap-internal-url http://$CONTROLLER_NODES:35357/v3/ \
	  --bootstrap-public-url http://$CONTROLLER_NODES:5000/v3/ \
	  --bootstrap-region-id RegionOne
	echo "### Configure Keystone is Done"
}

configure_http()
{
	echo "### 4. Configure HTTPD Server"
	sed -i -e "s/.*ServerName.*/ServerName $CONTROLLER_NODES/g" /etc/httpd/conf/httpd.conf
	ln -s /usr/share/keystone/wsgi-keystone.conf /etc/httpd/conf.d/
	systemctl enable httpd.service
	systemctl start httpd.service
	echo "### Configure HTTPD is Done"
}

create_service_entity_api_enpoints_user_role_domain()
{
	echo "### 5. Create the service entity and API endpoints"
	export OS_TOKEN=$ADMIN_TOKEN
	export OS_URL=http://$CONTROLLER_NODES:35357/v3
	export OS_IDENTITY_API_VERSION=3

	# create the `service` project
	openstack project create --domain default --description "Service Project" service
	# create `demo` project
	openstack project create --domain default --description "Demo Project" demo
	# create the `demo` user
	openstack user create demo --domain default --password $KEYSTONE_DEMO_PASS
	# create the `user` role
	openstack role create user
	# add the `user` role to the `demo` project and user
	openstack role add --project demo --user demo user
}

create_client_env_scripts()
{
	cat > $CONFIG_PATH/.admin-openrc <<EOF
	export OS_PROJECT_DOMAIN_NAME=default
	export OS_USER_DOMAIN_NAME=default
	export OS_PROJECT_NAME=admin
	export OS_USERNAME=admin
	export OS_PASSWORD=$KEYSTONE_ADMIN_PASS
	export OS_AUTH_URL=http://$CONTROLLER_NODES:35357/v3
	export OS_IDENTITY_API_VERSION=3
	export OS_IMAGE_API_VERSION=2
EOF
	
	cat > $CONFIG_PATH/.demo-openrc << EOF
	export OS_PROJECT_DOMAIN_NAME=default
	export OS_USER_DOMAIN_NAME=default
	export OS_PROJECT_NAME=demo
	export OS_USERNAME=demo
	export OS_PASSWORD=$KEYSTONE_DEMO_PASS
	export OS_AUTH_URL=http://$CONTROLLER_NODES:5000/v3
	export OS_IDENTITY_API_VERSION=3
	export OS_IMAGE_API_VERSION=2
EOF

}

verify_keystone()
{
	echo ""
	echo "### Keystone Proccess DONE"
	echo ""
	echo ""
	echo "### 6. Verify Keystone installation"
	echo ""
	echo "Complete list following bellow:"
	echo ""
	source $CONFIG_PATH/.admin-openrc
	echo "- Projects:"
	openstack project list
	sleep 5
	echo "- Users:"
	openstack user list
	sleep 5
	echo "- Services:"
	openstack service list
	sleep 5
	echo "- Roles:"
	openstack role list
	sleep 5
	echo "- Endpoints:"
	openstack endpoint list
	sleep 5
	echo ""
	echo "### Applying IPTABLES rules"
	echo ""
	# iptables -A INPUT -p tcp -m multiport --dports 5000,11211,35357 -j ACCEPT
	# service iptables save
}

main()
{
	echo "#### INSTALL_KEYSTONE = $INSTALL_KEYSTONE"

	create_database
	install_keystone
	configure_keystone
	configure_http
	create_service_entity_api_enpoints_user_role_domain
	create_client_env_scripts
	verify_keystone
}

main
