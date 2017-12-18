#!/bin/sh
# This script will install a new BookStack instance in a fresh SmartOS zone.
# This script is experimental and does not ensure any security.

echo "Enter your the domain you want to host BookStack and press [ENTER]: "
read DOMAIN

myip=$(ifconfig | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1')

pkgin -y up
pkgin -y in git-base nginx curl php71-fpm php71-curl php71-mbstring php71-ldap php71-pecl-mcrypt \
php71-tidy php71-xmlrpc php71-zlib php71-pdo php71-zip php71-json php71-gd php71-pdo_mysql mysql-server-5.7 mcrypt

# Start mysql server
/usr/sbin/svcadm enable -r svc:/pkgsrc/mysql && sleep 15

# Set up database
DB_PASS="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 13)"
mysql -u root --execute="CREATE DATABASE bookstack;"
mysql -u root --execute="CREATE USER 'bookstack'@'localhost' IDENTIFIED BY '$DB_PASS';"
mysql -u root --execute="GRANT ALL ON bookstack.* TO 'bookstack'@'localhost';FLUSH PRIVILEGES;"

# Download BookStack
mkdir -p /var/www
chown -R www:www /var/www
cd /var/www
git clone https://github.com/BookStackApp/BookStack.git --branch release --single-branch bookstack
BOOKSTACK_DIR="/var/www/bookstack"
cd $BOOKSTACK_DIR

# Install composer
EXPECTED_SIGNATURE=$(wget https://composer.github.io/installer.sig -O - -q)
curl -s https://getcomposer.org/installer > composer-setup.php
ACTUAL_SIGNATURE=$(php -r "echo hash_file('SHA384', 'composer-setup.php');")

if [ "$EXPECTED_SIGNATURE" = "$ACTUAL_SIGNATURE" ]
then
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

# Generate the application key
php artisan key:generate --no-interaction --force

# Migrate the databases
php artisan migrate --no-interaction --force

# Set file and folder permissions
chown www:www -R bootstrap/cache
chown www:www -R public/uploads
chown www:www -R storage
chmod -R 755 bootstrap/cache public/uploads storage

# Add nginx configuration
mv /opt/local/etc/nginx/nginx.conf /opt/local/etc/nginx/nginx.conf.bak
mkdir -p /opt/local/etc/nginx/{snippets,sites-available,sites-enabled}

cat > /opt/local/etc/nginx/snippets/fastcgi-php.conf << 'EOL'

fastcgi_split_path_info ^(.+\.php)(/.+)$;
try_files $fastcgi_script_name = 404;
set $path_info $fastcgi_path_info;
fastcgi_param PATH_INFO $path_info;
fastcgi_index index.php;
include fastcgi.conf;

EOL

cat > /opt/local/etc/nginx/nginx.conf << 'EOL'

user www www;
worker_processes auto;

events {
	worker_connections 1024;
}

http {
	sendfile on;
	tcp_nopush on;
	tcp_nodelay on;
	keepalive_timeout 65;
	types_hash_max_size 2048;

	include /opt/local/etc/nginx/mime.types;
	default_type application/octet-stream;

	ssl_protocols TLSv1 TLSv1.1 TLSv1.2; # Dropping SSLv3, ref: POODLE
	ssl_prefer_server_ciphers on;

	access_log /var/log/nginx/access.log;
	error_log /var/log/nginx/error.log;

	gzip on;
	gzip_disable "msie6";

	include /opt/local/etc/nginx/sites-enabled/*;
}

EOL

curl -s https://raw.githubusercontent.com/BookStackApp/devops/master/config/nginx > /opt/local/etc/nginx/sites-available/bookstack
chmod -R 755 /opt/local/etc/nginx/snippets /opt/local/etc/nginx/sites-available /opt/local/etc/nginx/sites-enabled
sed -i.bak "s/bookstack.dev/$DOMAIN/" /opt/local/etc/nginx/sites-available/bookstack
sed -i.bak "s/unix:\/run\/php\/php7.0-fpm.sock/127.0.0.1:9000/" /opt/local/etc/nginx/sites-available/bookstack
ln -s /opt/local/etc/nginx/sites-available/bookstack /opt/local/etc/nginx/sites-enabled/bookstack

# Start php-fpm
/usr/sbin/svcadm enable -r svc:/pkgsrc/php-fpm:default && sleep 3

# Start nginx
/usr/sbin/svcadm enable -r svc:/pkgsrc/nginx:default && sleep 3

echo ""
echo "Setup Finished, Your BookStack instance should now be installed."
echo "You can login with the email 'admin@admin.com' and password of 'password'"
echo "MySQL was installed without a root password, It is recommended that you set a root MySQL password."
echo ""
echo "You can access your BookStack instance at: http://$myip/"
