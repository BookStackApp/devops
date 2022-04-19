#!/bin/bash

echo "This script installs a new BookStack instance on a fresh Ubuntu 22.04 server."
echo "This script does not ensure system security."
echo ""

# Check we're running as root and exit if not
if [[ $EUID -gt 0 ]]
then
  >&2 echo "ERROR: This script must be ran with root/sudo privileges"
  exit 1
fi

# Get the current user running the script
SCRIPT_USER="${SUDO_USER:-$USER}"

# Get the current machine IP address
CURRENT_IP=$(ip addr | grep 'state UP' -A4 | grep 'inet ' | awk '{print $2}' | cut -f1  -d'/')

# Fetch domain to use from first provided parameter,
# Otherwise request the user to input their domain
DOMAIN=$1
if [ -z "$1" ]
then
  echo ""
  echo "Enter the domain (or IP if not using a domain) you want to host BookStack on and press [ENTER]."
  echo "Examples: my-site.com or docs.my-site.com or ${CURRENT_IP}"
  read -r DOMAIN
fi

# Ensure a domain was provided otherwise display
# an error message and stop the script
if [ -z "$DOMAIN" ]
then
  >&2 echo 'ERROR: A domain must be provided to run this script'
  exit 1
fi

# Install core system packages
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y git unzip apache2 php8.1 curl php8.1-curl php8.1-mbstring php8.1-ldap \
php8.1-xml php8.1-zip php8.1-gd php8.1-mysql mysql-server-8.0 libapache2-mod-php8.1

# Set up database
DB_PASS="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 13)"
mysql -u root --execute="CREATE DATABASE bookstack;"
mysql -u root --execute="CREATE USER 'bookstack'@'localhost' IDENTIFIED WITH mysql_native_password BY '$DB_PASS';"
mysql -u root --execute="GRANT ALL ON bookstack.* TO 'bookstack'@'localhost';FLUSH PRIVILEGES;"

# Download BookStack
cd /var/www || exit
git clone https://github.com/BookStackApp/BookStack.git --branch release --single-branch bookstack
BOOKSTACK_DIR="/var/www/bookstack"

# Move into the BookStack install directory
cd $BOOKSTACK_DIR || exit

# Install composer
EXPECTED_CHECKSUM="$(php -r 'copy("https://composer.github.io/installer.sig", "php://stdout");')"
php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"

if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]
then
    >&2 echo 'ERROR: Invalid composer installer checksum'
    rm composer-setup.php
    exit 1
fi

php composer-setup.php --quiet
rm composer-setup.php

# Move composer to global installation
mv composer.phar /usr/local/bin/composer

# Install BookStack composer dependencies
export COMPOSER_ALLOW_SUPERUSER=1
php /usr/local/bin/composer install --no-dev --no-plugins

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
# Sets current user as owner user and www-data as owner group then
# provides group write access only to required directories.
# Hides the `.env` file so it's not visible to other users on the system.
chown -R "$SCRIPT_USER":www-data ./
chmod -R 755 ./
chmod -R 775 bootstrap/cache public/uploads storage
chmod 740 .env

# Tell git to ignore permission changes
git config core.fileMode false

# Enable required apache modules
a2enmod rewrite
a2enmod php8.1

# Set-up the required BookStack apache config
cat >/etc/apache2/sites-available/bookstack.conf <<EOL
<VirtualHost *:80>
	ServerName ${DOMAIN}

	ServerAdmin webmaster@localhost
	DocumentRoot /var/www/bookstack/public/

  <Directory /var/www/bookstack/public/>
      Options -Indexes +FollowSymLinks
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

	ErrorLog \${APACHE_LOG_DIR}/error.log
	CustomLog \${APACHE_LOG_DIR}/access.log combined

</VirtualHost>
EOL

# Disable the default apache site and enable BookStack
a2dissite 000-default.conf
a2ensite bookstack.conf

# Restart apache to load new config
systemctl restart apache2

echo ""
echo "Setup Finished, Your BookStack instance should now be installed."
echo "You can login with the email 'admin@admin.com' and password of 'password'"
echo "MySQL was installed without a root password, It is recommended that you set a root MySQL password."
echo ""
echo "You can access your BookStack instance at: http://$CURRENT_IP/ or http://$DOMAIN/"
