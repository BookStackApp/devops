#!/usr/bin/env bash
# This script will install a new BookStack instance on a fresh Centos 7 server. Tested on CentOS Linux release 7.6.1810 (minimal).
# This script is experimental!

# Check root level permissions
if [[ "$(id -u)" -ne 0 ]]; then
   echo "Error: The installation script must be run as root" >&2
   exit 1
fi

# Fetch domain to use from first provided parameter,
# Otherwise request the user to input their domain
DOMAIN=$1
if [ -z $1 ]; then
   echo -e "\nEnter the domain you want to host BookStack and press [ENTER]\nExample: "$HOSTNAME""
   read DOMAIN
fi
if [ -z $DOMAIN ]; then
   DOMAIN="$HOSTNAME"
fi

# Get the current machine IP address
CURRENT_IP=$(ip addr | grep 'state UP' -A2 | tail -n1 | awk '{print $2}' | cut -f1  -d'/')

# Install core system packages
yum -y -q install epel-release yum-utils
yum -y -q install http://rpms.remirepo.net/enterprise/remi-release-7.rpm
yum -y -q install https://dev.mysql.com/get/mysql80-community-release-el7-1.noarch.rpm
yum-config-manager --disable mysql80-community > /dev/null
yum-config-manager --enable remi-php72 > /dev/null
yum-config-manager --enable mysql57-community > /dev/null
yum -y -q install git httpd curl wget unzip expect policycoreutils-python php php-fpm php-common php-mbstring php-ldap php-tidy php-xml php-pecl-zip php-gd php-mysqlnd mysql-community-server

# Set up database
systemctl enable mysqld && systemctl start mysqld
MYSQL_ROOT_PASS="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 11)\$"
MYSQL_TEMP_PASS="$(grep 'temporary password' /var/log/mysqld.log | grep -o '............$')"
DB_PASS="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 13)\$"
# MySQL Secure Installation
SECURE_MYSQL=$(expect -c "

set timeout 10
spawn mysql_secure_installation

expect \"Enter password for user root:\"
send \"$MYSQL_TEMP_PASS\r\"
expect \"New password:\"
send \"$MYSQL_ROOT_PASS\r\"
expect \"Re-enter new password:\"
send \"$MYSQL_ROOT_PASS\r\"
expect \"Do you wish to continue with the password provided?(Press y|Y for Yes, any other key for No) :\"
send \"n\r\"
expect \"Remove anonymous users? (Press y|Y for Yes, any other key for No) :\"
send \"y\r\"
expect \"Disallow root login remotely? (Press y|Y for Yes, any other key for No) :\"
send \"y\r\"
expect \"Remove test database and access to it? (Press y|Y for Yes, any other key for No) :\"
send \"y\r\"
expect \"Reload privilege tables now? (Press y|Y for Yes, any other key for No) :\"
send \"y\r\"
expect eof
")
echo "$SECURE_MYSQL"

# Create Database
mysql --user root --password="$MYSQL_ROOT_PASS" --execute="CREATE DATABASE bookstack;"
mysql --user root --password="$MYSQL_ROOT_PASS" --execute="CREATE USER 'bookstack'@'localhost' IDENTIFIED BY '$DB_PASS';"
mysql --user root --password="$MYSQL_ROOT_PASS" --execute="GRANT ALL ON bookstack.* TO 'bookstack'@'localhost';FLUSH PRIVILEGES;"

# Download BookStack
cd /var/www
git clone https://github.com/BookStackApp/BookStack.git --branch release --single-branch bookstack
BOOKSTACK_DIR="/var/www/bookstack"
cd $BOOKSTACK_DIR

# Install composer
EXPECTED_SIGNATURE=$(wget https://composer.github.io/installer.sig -O - -q)
curl -s https://getcomposer.org/installer > composer-setup.php
ACTUAL_SIGNATURE=$(php -r "echo hash_file('SHA384', 'composer-setup.php');")

if [ "$EXPECTED_SIGNATURE" = "$ACTUAL_SIGNATURE" ]; then
    php composer-setup.php --quiet
    RESULT=$?
    rm composer-setup.php
else
    >&2 echo 'ERROR: Invalid composer installer signature'
    rm composer-setup.php
    exit 1
fi

# Install BookStack composer dependancies
php composer.phar install

# Copy and update BookStack environment variables
cp .env.example .env
sed -i.bak 's/DB_DATABASE=.*$/DB_DATABASE=bookstack/' .env
sed -i.bak 's/DB_USERNAME=.*$/DB_USERNAME=bookstack/' .env
sed -i.bak "s/DB_PASSWORD=.*\$/DB_PASSWORD=$DB_PASS/" .env
echo "APP_URL="
# Generate the application key
php artisan key:generate --no-interaction --force
# Migrate the databases
php artisan migrate --no-interaction --force

# Set file and folder permissions
chown apache:apache -R bootstrap/cache public/uploads storage && chmod -R 755 bootstrap/cache public/uploads storage

# Set up apache
cat >/etc/httpd/conf.d/bookstack.conf <<EOL
<VirtualHost *:80>
        ServerName ${DOMAIN}
        ServerAdmin webmaster@localhost
        DocumentRoot /var/www/bookstack/public/
    <Directory /var/www/bookstack/public/>
        Options Indexes FollowSymLinks
        AllowOverride None
        Require all granted
        <IfModule mod_rewrite.c>
            <IfModule mod_negotiation.c>
                Options -MultiViews -Indexes
            </IfModule>
            RewriteEngine On
            # Handle Authorization Header
            RewriteCond %{HTTP:Authorization} .
            RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
            # Redirect Trailing Slashes If Not A Folder...
            RewriteCond %{REQUEST_FILENAME} !-d
            RewriteCond %{REQUEST_URI} (.+)/$
            RewriteRule ^ %1 [L,R=301]
            # Handle Front Controller...
            RewriteCond %{REQUEST_FILENAME} !-d
            RewriteCond %{REQUEST_FILENAME} !-f
            RewriteRule ^ index.php [L]
        </IfModule>
    </Directory>
        ErrorLog logs/error_log
        CustomLog logs/access_log combined
</VirtualHost>
EOL

# SElinux folders context
if [[ "$(getenforce)" == "Enforcing" ]]; then
   echo "SElinux mode is 'Enforcing', trying to set correct context..."
   semanage fcontext -a -t httpd_sys_rw_content_t '/var/www/bookstack/public/uploads(/.*)?'
   semanage fcontext -a -t httpd_sys_rw_content_t '/var/www/bookstack/storage(/.*)?'
   semanage fcontext -a -t httpd_cache_t '/var/www/bookstack/bootstrap/cache(/.*)?'
   restorecon -R /var/www
   restorecon -R /var/log/httpd
   restorecon -R /etc/httpd
fi

systemctl enable httpd > /dev/null && systemctl start httpd

# Config Firewalld
if [[ "$(systemctl is-active firewalld)" == "active" ]]; then
   echo -n "Adding firewalld service... "
   firewall-cmd --add-service=http && firewall-cmd --permanent --add-service=http > /dev/null
   firewall-cmd --reload > /dev/null
fi

# Remove package
yum -y -q remove expect

echo ""
echo "Setup Finished, Your BookStack instance should now be installed."
echo "You can login with the email 'admin@admin.com' and password of 'password'"
echo -e "MySQL was installed with a root password: "$MYSQL_ROOT_PASS"."
echo ""
echo -e "You can access your BookStack instance at: http://$CURRENT_IP/ or http://$DOMAIN/"
exit 0
