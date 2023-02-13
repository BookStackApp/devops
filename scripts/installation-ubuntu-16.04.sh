#!/bin/sh
# This script will install a new BookStack instance on a fresh Ubuntu 16.04 server.
# This script is experimental and does not ensure any security.

echo "THIS SCRIPT IS NO LONGER SUPPORTED OR MAINTAINED"
echo "IT MAY NOT WORK WITH CURRENT VERSIONS OF BOOKSTACK"
echo ""

echo ""
echo -n "Enter the domain you want to host BookStack and press [ENTER]: "
read DOMAIN

myip=$(ip addr | grep 'state UP' -A2 | tail -n1 | awk '{print $2}' | cut -f1  -d'/')

export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y software-properties-common python-software-properties
add-apt-repository -yu ppa:ondrej/php
apt install -y git nginx curl php7.4 php7.4-fpm php7.4-curl php7.4-mbstring php7.4-ldap \
php7.4-tidy php7.4-xml php7.4-zip php7.4-gd php7.4-mysql mysql-server-5.7

# Set up database
DB_PASS="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 13)"
mysql -u root --execute="CREATE DATABASE bookstack;"
mysql -u root --execute="CREATE USER 'bookstack'@'localhost' IDENTIFIED BY '$DB_PASS';"
mysql -u root --execute="GRANT ALL ON bookstack.* TO 'bookstack'@'localhost';FLUSH PRIVILEGES;"

# Download BookStack
cd /var/www
git clone https://github.com/ssddanbrown/BookStack.git --branch release --single-branch bookstack
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

# Install BookStack composer dependencies
php composer.phar install --no-dev

# Copy and update BookStack environment variables
cp .env.example .env
sed -i.bak "s@APP_URL=.*\$@APP_URL=http://$DOMAIN@" .env
sed -i.bak 's/DB_DATABASE=.*$/DB_DATABASE=bookstack/' .env
sed -i.bak 's/DB_USERNAME=.*$/DB_USERNAME=bookstack/' .env
sed -i.bak "s/DB_PASSWORD=.*\$/DB_PASSWORD=$DB_PASS/" .env

# Generate the application key
php artisan key:generate --no-interaction --force
# Migrate the databases
php artisan migrate --no-interaction --force

# Set file and folder permissions
chown www-data:www-data -R bootstrap/cache public/uploads storage && chmod -R 755 bootstrap/cache public/uploads storage

# Add nginx configuration
curl -s https://raw.githubusercontent.com/BookStackApp/devops/main/config/nginx/ubuntu-1604-install-config > /etc/nginx/sites-available/bookstack
sed -i.bak "s/bookstack.dev/$DOMAIN/" /etc/nginx/sites-available/bookstack
ln -s /etc/nginx/sites-available/bookstack /etc/nginx/sites-enabled/bookstack

# Remove the default nginx configuration
rm /etc/nginx/sites-enabled/default

# Restart nginx to load new config
service nginx restart

echo ""
echo "Setup Finished, Your BookStack instance should now be installed."
echo "You can login with the email 'admin@admin.com' and password of 'password'"
echo "MySQL was installed without a root password, It is recommended that you set a root MySQL password."
echo ""
echo "You can access your BookStack instance at: http://$myip/"
