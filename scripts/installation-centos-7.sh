#!/bin/sh
echo "This script will install a new BookStack instance on a fresh CentOS 7 server."
echo "This script is experimental and does not attend to system security."

# Fetch domain to use from first provided parameter,
# Otherwise request the user to input their domain
DOMAIN=$1
if [ -z $1 ]
then
echo ""
printf "Enter the domain you want to host BookStack and press [ENTER]\nExamples: my-site.com or docs.my-site.com\n"
read DOMAIN
fi

# Get the current machine IP address
CURRENT_IP=$(ip addr | grep 'state UP' -A2 | tail -n1 | awk '{print $2}' | cut -f1  -d'/')

# Install core system packages and remi php repository
yum check-update
yum install -y git httpd curl wget yum-utils mariadb-server
wget https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
wget http://rpms.remirepo.net/enterprise/remi-release-7.rpm
rpm -Uvh remi-release-7.rpm epel-release-latest-7.noarch.rpm
yum-config-manager --enable remi-php73
yum install -y php php-cli php-common php-gd php-json php-ldap php-mysqlnd php-mbstring php-tidy php-xml php-zip php-mcrypt php-opcache

# Start Apache & Mariadb
systemctl start httpd
systemctl start mariadb
# Set Apache and Mariadb to start on system boot
systemctl enable httpd
systemctl enable mariadb

# Set up database
DB_PASS="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 13)"
mysql -u root --execute="CREATE DATABASE bookstack;"
mysql -u root --execute="CREATE USER 'bookstack'@'localhost' IDENTIFIED BY '$DB_PASS';"
mysql -u root --execute="GRANT ALL ON bookstack.* TO 'bookstack'@'localhost';FLUSH PRIVILEGES;"

# Download BookStack
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
    rm -f composer-setup.php
else
    >&2 echo 'ERROR: Invalid composer installer signature'
    rm -f composer-setup.php
    exit 1
fi

# Install BookStack composer dependencies
php composer.phar install

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

# Set BookStack file and folder permissions
chown apache:apache -R bootstrap/cache public/uploads storage && chmod -R 755 bootstrap/cache public/uploads storage

# Set up Apache VirtualHost
mkdir /etc/httpd/sites-available /etc/httpd/sites-enabled
echo "IncludeOptional sites-enabled/*.conf" >> /etc/httpd/conf/httpd.conf
cat >/etc/httpd/sites-available/bookstack.conf <<EOL
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

	ErrorLog /var/log/httpd/bookstack-error.log
	CustomLog /var/log/httpd/bookstack-access.log combined

</VirtualHost>
EOL

ln -s /etc/httpd/sites-available/bookstack.conf /etc/httpd/sites-enabled/bookstack.conf

# Restart apache to load new config
systemctl restart httpd

# Open up the firewall
firewall-cmd --permanent --zone=public --add-service=http 
firewall-cmd --permanent --zone=public --add-service=https
firewall-cmd --reload

# Update SELinux to allow Apache to write to BookStack locations
chcon -Rv --type=httpd_sys_rw_content_t /var/www/bookstack/bootstrap/cache
chcon -Rv --type=httpd_sys_rw_content_t /var/www/bookstack/public/uploads
chcon -Rv --type=httpd_sys_rw_content_t /var/www/bookstack/storage

echo ""
echo "Setup Finished, Your BookStack instance should now be installed."
echo "You can login with the email 'admin@admin.com' and password of 'password'"
echo "MySQL was installed without a root password, It is recommended that you set a root MySQL password."
echo ""
echo "You should be able to access your BookStack instance at: http://$CURRENT_IP/ or http://$DOMAIN/"
