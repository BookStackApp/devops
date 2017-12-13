#!/bin/bash
#This script should remove your Bookstack install. 
#This script is experimental and no guarantees are made. 

echo "This uninstall script is catastrophic." 
echo "Do not continue if have other sites and/or services running."
echo "This script will completely remove nginx and mysql."
read -p "Do you want to continue?" -n 1 -r
if [[ $REPLY =~ ^[Yy]$ ]]
then

service mysql stop
service nginx stop
apt-get -y remove --purge git nginx curl php5 php5-cgi php5-curl php5-cli \
php5-ldap php5-fpm php5-mcrypt php5-tidy php-xml-dtd php-pclzip php5-gd \
php5-mysql mysql-server-5.5 mcrypt
