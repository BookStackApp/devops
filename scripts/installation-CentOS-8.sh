#!/usr/bin/env bash
# This script will install a new BookStack instance on a fresh CentOS 8 server. Tested on CentOS Linux release 8.0.1905 (Core).
# This script is experimental!
# This script will install Apache2 or nginx with FPM/FastCGI, MySQL 8.0, PHP 7.3

INSTALL_PATH='/var/www'

# Check root level permissions
if [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: The installation script must be run as root" >&2
    exit 1
fi

# Check if OS is CentOS 8
# Comment next section, if you want to skip this check
if [[ "$(grep 'CentOS Linux release 8' /etc/redhat-release)" != "CentOS Linux release 8".* ]]; then
    echo "Error: The OS is not CentOS 8" >&2
    exit 1
fi

# Fetch domain to use from first provided parameter,
# Otherwise request the user to input their domain
# If input empty -> use hostname
DOMAIN=$1
if [ -z $1 ]; then
    echo -e "\nEnter the domain you want to host BookStack and press [ENTER]\nExample: "$HOSTNAME""
    read DOMAIN
fi
if [ -z $DOMAIN ]; then
    DOMAIN=$HOSTNAME
    echo -e "Using domain: "$DOMAIN""
else
    echo -e "Using domain: "$DOMAIN""
fi

# Get the current machine IP address
CURRENT_IP=$(ip addr | grep 'state UP' -A2 | tail -n1 | awk '{print $2}' | cut -f1  -d'/')

# Install core system packages
# There is no php-tidy package in CentOS-8 baserepos, so have to use remi repos
# Install remi repo for php 7.3 packages
dnf -y -q install https://rpms.remirepo.net/enterprise/remi-release-8.rpm
dnf -y -q install https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
dnf -y -q install dnf-utils
# Disable php module from CentOS-8 - AppStream
dnf -y -q module disable php 2> /dev/null
# Enable php module from Remi's Modular repository for Enterprise Linux 8
dnf -y -q module install php:remi-7.3 2> /dev/null

# Install packages
dnf -y -q install git curl wget unzip php-fpm php-curl php-mbstring php-ldap php-tidy php-xml php-pecl-zip php-gd php-mysqlnd mysql-server

# Select web-server
echo -e "\v"
PS3='Please select your web-server: '
options=("Apache2" "nginx" "Quit")
select opt in "${options[@]}";
do
    case $opt in
        "Apache2")
            echo "Installing Apache2..."
            WEBSERVER="httpd"
            dnf -y -q install httpd mod_ssl mod_http2
            break
            ;;
        "nginx")
            echo "Installing nginx..."
            WEBSERVER="nginx"
            dnf -y -q install nginx
            break
            ;;
        "Quit")
            echo "Exiting..."
            exit 1
            ;;
        *) echo "Invalid option $REPLY";;
    esac
done

# Set up database
# Password generator string is not optimal. Should be reworked.
MYSQL_ROOT_PASS=8Gl"$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 18)\$"
DB_PASS="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 15)\$"
systemctl enable mysqld && systemctl start mysqld
# MySQL change root password
mysql --user root --connect-expired-password --execute="ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASS';"

# Create Database
mysql --user root --password="$MYSQL_ROOT_PASS" --execute="CREATE DATABASE bookstack;"
mysql --user root --password="$MYSQL_ROOT_PASS" --execute="CREATE USER 'bookstack'@'localhost' IDENTIFIED BY '$DB_PASS';"
mysql --user root --password="$MYSQL_ROOT_PASS" --execute="GRANT ALL ON bookstack.* TO 'bookstack'@'localhost';FLUSH PRIVILEGES;"

# Download BookStack
cd $INSTALL_PATH 
git clone https://github.com/BookStackApp/BookStack.git --branch release --single-branch bookstack
BOOKSTACK_DIR="${INSTALL_PATH}/bookstack"
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

# SElinux permissions
if [[ "$(getenforce)" == "Enforcing" ]]; then
    echo -e "\nSElinux mode is 'Enforcing', trying to set correct context..."
    setsebool -P httpd_can_sendmail 1
    setsebool -P httpd_can_network_connect 1
    semanage fcontext -a -t httpd_sys_rw_content_t "${BOOKSTACK_DIR}/public/uploads(/.*)?"
    semanage fcontext -a -t httpd_sys_rw_content_t "${BOOKSTACK_DIR}/storage(/.*)?"
    semanage fcontext -a -t httpd_sys_rw_content_t "${BOOKSTACK_DIR}/bootstrap/cache(/.*)?"
    restorecon -R "$BOOKSTACK_DIR"
fi

# Change folders permissions
chmod -R 754 bootstrap/cache public/uploads storage
chmod -R o+X bootstrap/cache public/uploads storage

# Set up web-server
case $WEBSERVER in
        "httpd")
           # Set files and folders owner
           chown apache:apache -R bootstrap/cache public/uploads storage

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

           # Start php-fpm
           systemctl enable php-fpm && systemctl start php-fpm

           # Start Apache2
           systemctl enable httpd && systemctl start httpd
           ;;
            
        "nginx")
           # Set files and folders owner
           chown nginx:nginx -R bootstrap/cache public/uploads storage
           
           # Set up php-fpm
           sed -c -i "s/\(user *= *\).*/\1$WEBSERVER/" /etc/php-fpm.d/www.conf
           sed -c -i "s/\(group *= *\).*/\1$WEBSERVER/" /etc/php-fpm.d/www.conf
           systemctl enable php-fpm && systemctl start php-fpm
           
           # Set up nginx
           cat >/etc/nginx/conf.d/bookstack.conf <<EOL
server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name ${DOMAIN};
  root /var/www/bookstack/public;
  index index.php index.html;
  location / {
    try_files \$uri \$uri/ /index.php?\$query_string;
  }
  location ~ ^/(?:\.htaccess|data|config|db_structure\.xml|README) {
    deny all;
  }
  location ~ \.php$ {
    fastcgi_split_path_info ^(.+\.php)(/.+)$;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    fastcgi_param PATH_INFO \$fastcgi_path_info;
    fastcgi_pass unix:/run/php-fpm/www.sock;
  }
}
EOL

           # Remove 'default_server' value in nginx.conf
           sed -i 's/\<default_server\>//g' /etc/nginx/nginx.conf

           # Start nginx
           systemctl enable nginx && systemctl start nginx
            ;;
esac

# Config Firewalld
if [[ "$(systemctl is-active firewalld)" == "active" ]]; then
    echo -e "\nAdding firewalld http service rule... "
    firewall-cmd --add-service=http && firewall-cmd --permanent --add-service=http > /dev/null
fi

echo -e "\v"
echo "#############################################################################"
echo "Setup Finished, Your BookStack instance should now be installed."
echo -e 'You can login with the email '"\033[32m'admin@admin.com'\033[0m"' and password of '"\033[32m'password'\033[0m"
echo -e "Database \033[32mbookstack\033[0m was installed with a root password: \033[32m${MYSQL_ROOT_PASS}\033[0m."
echo -e "Your web-server config file: \033[32m/etc/${WEBSERVER}/conf.d/bookstack.conf\033[0m"
echo ""
echo -e "You can access your BookStack instance at: \033[32mhttp://$CURRENT_IP/\033[0m or \033[32mhttp://$DOMAIN/\033[0m"
exit 0
