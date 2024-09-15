
#!/bin/bash


# Disable SELinux if enabled
if [[ $(getenforce) == "Enforcing" ]]; then
  sudo sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
  echo "SELinux disabled. Reboot is required."
  sudo shutdown -r now
else
  echo "No reboot required."
fi


# Function to check if a package is installed
is_installed() {
  rpm -q "$1" &> /dev/null
  return $?
}

# Function to check if a service is active
is_active() {
  systemctl is-active --quiet "$1"
  return $?
}

# Update system only if necessary
echo "Checking for system updates..."
sudo dnf check-update
if [ $? -eq 100 ]; then
  echo "System updates available. Updating..."
  sudo dnf update -y
else
  echo "System is already up to date."
fi

# Enable repository if necessary
if ! sudo subscription-manager repos --list-enabled | grep -q codeready-builder; then
  sudo subscription-manager repos --enable codeready-builder-for-rhel-9-$(arch)-rpms
fi

# Check and install EPEL and other packages
echo "Installing required packages..."
if ! is_installed epel-release; then
  sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
fi

for package in chkconfig initscripts mysql-server mysql-devel python3-devel unixODBC unixODBC-devel libtool-ltdl mariadb-connector-odbc expect; do
  if ! is_installed $package; then
    sudo dnf install -y $package
  else
    echo "$package is already installed."
  fi
done

# Start and enable MySQL service if not running
if ! is_active mysqld; then
  echo "Starting and enabling MySQL..."
  sudo systemctl enable --now mysqld
else
  echo "MySQL is already running."
fi

#----------------------

# Generate a temporary MySQL root password
# MySQL root user variables
MYSQL_ROOT_USER_NAME="root"
MYSQL_ROOT_USER_PASSWORD=$(tr -dc 'A-Za-z0-9!?%=' < /dev/urandom | head -c 15)

# Asterisk Variables
ASTERISK_DATABASE_NAME="asterisk"
ASTERISK_USER_NAME="asterisk"
ASTERISK_USER_PASSWORD=$(tr -dc 'A-Za-z0-9!?%=' < /dev/urandom | head -c 15)
ASTERISK_DSN="asterisk"
# Define variables
SQL_FILE_PATH="/tmp/asterisk_setup.sql"
EXPECT_SCRIPT_PATH="/tmp/expect_mysql_secure.sh"

# Create the SQL file
cat <<EOL > $SQL_FILE_PATH
-- Create the database if it doesn't already exist
CREATE DATABASE IF NOT EXISTS ${ASTERISK_DATABASE_NAME};

USE ${ASTERISK_DATABASE_NAME};

-- Create the CDR table if it doesn't already exist
CREATE TABLE IF NOT EXISTS cdr (
  id INT(11) UNSIGNED NOT NULL AUTO_INCREMENT,
  calldate DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  clid VARCHAR(80) NOT NULL,
  src VARCHAR(80) NOT NULL,
  dst VARCHAR(80) NOT NULL,
  dcontext VARCHAR(80) NOT NULL,
  lastapp VARCHAR(80) NOT NULL,
  lastdata VARCHAR(80) NOT NULL,
  duration FLOAT UNSIGNED DEFAULT NULL,
  billsec FLOAT UNSIGNED DEFAULT NULL,
  disposition ENUM('ANSWERED','BUSY','FAILED','NO ANSWER','CONGESTION') DEFAULT NULL,
  channel VARCHAR(80) DEFAULT NULL,
  dstchannel VARCHAR(80) DEFAULT NULL,
  amaflags VARCHAR(50) DEFAULT NULL,
  accountcode VARCHAR(20) DEFAULT NULL,
  uniqueid VARCHAR(32) NOT NULL DEFAULT '',
  userfield FLOAT UNSIGNED DEFAULT NULL,
  peeraccount VARCHAR(50) DEFAULT NULL,
  linkedid VARCHAR(50) DEFAULT NULL,
  sequence INT DEFAULT 0,
  PRIMARY KEY (id),
  INDEX (calldate),
  INDEX (dst),
  INDEX (src),
  INDEX (dcontext),
  INDEX (clid)
) COLLATE='utf8_bin' ENGINE=InnoDB;

-- Create the MySQL user if it doesn't already exist
CREATE USER IF NOT EXISTS '${ASTERISK_USER_NAME}'@'localhost' IDENTIFIED BY '${ASTERISK_USER_PASSWORD}';

-- Grant privileges to the asterisk user
GRANT ALL PRIVILEGES ON ${ASTERISK_DATABASE_NAME}.* TO '${ASTERISK_USER_NAME}'@'localhost';

-- Apply changes
FLUSH PRIVILEGES;
EOL

echo "SQL file created at: $SQL_FILE_PATH"

# Check if the MySQL service is running
if ! systemctl is-active --quiet mysqld; then
  echo "MySQL service is not running. Starting MySQL..."
  sudo systemctl start mysqld
else
  echo "MySQL service is already running."
fi

# Execute the SQL script
echo "Executing SQL file..."
mysql -u$MYSQL_ROOT_USER_NAME < $SQL_FILE_PATH

if [ $? -eq 0 ]; then
  echo "SQL script executed successfully."
else
  echo "Failed to execute SQL script."
fi



# Secure MySQL installation using Expect script
cat <<EOL > $EXPECT_SCRIPT_PATH
#!/usr/bin/expect -f
set password "${MYSQL_ROOT_USER_PASSWORD}"
set new_password "${MYSQL_ROOT_USER_PASSWORD}"

spawn mysql_secure_installation

expect "Enter password for user root:"
send "\$password\r"

expect "New password:"
send "\$new_password\r"

expect "Re-enter new password:"
send "\$new_password\r"

expect "Remove anonymous users? (Press y|Y for Yes, any other key for No) :"
send "y\r"

expect "Disallow root login remotely? (Press y|Y for Yes, any other key for No) :"
send "y\r"

expect "Remove test database and access to it? (Press y|Y for Yes, any other key for No) :"
send "y\r"

expect "Reload privilege tables now? (Press y|Y for Yes, any other key for No) :"
send "y\r"

expect eof
EOL

chmod +x $EXPECT_SCRIPT_PATH
exec expect $EXPECT_SCRIPT_PATH &

sleep 5

rm -f $EXPECT_SCRIPT_PATH
rm -f $SQL_FILE_PATH


#----------------------




# Download and install Asterisk if not already installed
if ! is_installed asterisk; then
  echo "Installing Asterisk..."
  cd /usr/local/src
  sudo wget https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-21-current.tar.gz
  sudo tar -zxvf asterisk-21-current.tar.gz
  rm -f asterisk-21-current.tar.gz
  cd asterisk-*

  # Install dependencies and configure Asterisk
  sudo ./contrib/scripts/get_mp3_source.sh
  sudo ./contrib/scripts/install_prereq install
  sudo ./configure --libdir=/usr/lib64 --with-pjproject-bundled --with-jansson-bundled

  sudo menuselect/menuselect --disable BUILD_NATIVE --enable CORE-SOUNDS-EN-WAV --enable CORE-SOUNDS-EN-ULAW --enable CORE-SOUNDS-EN-ALAW --enable CORE-SOUNDS-EN-GSM  --enable MOH-OPSOUND-WAV --enable MOH-OPSOUND-ULAW --enable MOH-OPSOUND-ALAW --enable MOH-OPSOUND-GSM --enable EXTRA-SOUNDS-EN-WAV --enable EXTRA-SOUNDS-EN-ULAW --enable EXTRA-SOUNDS-EN-ALAW --enable EXTRA-SOUNDS-EN-GSM --enable res_odbc --enable res_config_odbc

  # Compile and install Asterisk
  sudo make menuselect.makeopts
  sudo make install
  sudo make samples
  sudo make config
  sudo ldconfig
  sudo make distclean
else
  echo "Asterisk is already installed."
fi




sudo tee /etc/asterisk/cdr_adaptive_odbc.conf > /dev/null <<EOL
[adaptive_connection]
connection=${ASTERISK_DSN}
table=cdr
EOL

sudo tee /etc/asterisk/res_odbc.conf > /dev/null <<EOL
[${ASTERISK_DSN}]
enabled => yes
dsn => ${ASTERISK_DSN}
username => ${ASTERISK_USER_NAME}
password => ${ASTERISK_USER_PASSWORD}
pre-connect => yes;
logging => yes
EOL

# Configure ODBC for Asterisk if not present
sudo tee /etc/odbc.ini > /dev/null <<EOL
[${ASTERISK_DSN}]
Description = MySQL connection to '${ASTERISK_DATABASE_NAME}' database
Driver = MariaDB
Database = ${ASTERISK_DATABASE_NAME}
User = ${ASTERISK_USER_NAME}
Password = ${ASTERISK_USER_PASSWORD}
Server = localhost
Port = 3306
Socket = /var/lib/mysql/mysql.sock
EOL

sudo tee /etc/asterisk/modules.conf > /dev/null <<EOL
[modules]
autoload=yes
preload => res_odbc.so
preload => res_config_odbc.so
noload = res_hep.so
noload = res_hep_pjsip.so
noload = res_hep_rtcp.so
noload = app_voicemail_imap.so
noload = app_voicemail_odbc.so
EOL

# Set permissions for Asterisk directories if not already set

echo "Setting up Asterisk user and permissions..."
sudo groupadd asterisk
sudo useradd -r -d /var/lib/asterisk -g asterisk asterisk
sudo chown -R asterisk:asterisk /etc/asterisk /var/{lib,log,spool}/asterisk /usr/lib64/asterisk
sudo restorecon -vr /etc/asterisk /var/lib/asterisk /var/log/asterisk /var/spool/asterisk


# Enable and start Asterisk if not already running
if ! is_active asterisk; then
  sudo systemctl enable --now asterisk
else
  echo "Asterisk is already running."
fi

# Configure firewall for SIP and RTP if not already configured
if ! sudo firewall-cmd --list-services --zone=public | grep -q sip; then
  sudo firewall-cmd --zone=public --add-service=sip --permanent
  sudo firewall-cmd --zone=public --add-port=10000-20000/udp --permanent
  sudo firewall-cmd --reload
else
  echo "Firewall is already configured for SIP and RTP."
fi

echo "Your MySQL root  password is: ${MYSQL_ROOT_USER_PASSWORD}"
echo "Your MySQL asterisk password is: ${ASTERISK_USER_PASSWORD}"

