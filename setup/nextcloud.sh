#!/bin/bash
# Nextcloud
##########################

source setup/functions.sh # load our functions
source /etc/meetrmail.conf # load global vars

# ### Installing Nextcloud

echo "Installing Nextcloud (contacts/calendar)..."

# Nextcloud core and app (plugin) versions to install.
# With each version we store a hash to ensure we install what we expect.

# Nextcloud core
# --------------
# * See https://nextcloud.com/changelog for the latest version.
# * Check https://docs.nextcloud.com/server/latest/admin_manual/installation/system_requirements.html
#   for whether it supports the version of PHP available on this machine.
# * The hash is the SHA-256 hash of the ZIP package. Nextcloud publishes it at
#   <url>.sha256; there is no .sha1, which is why this script uses
#   wget_verify_sha256 rather than wget_verify.
#
# Why 33 and not the newest release:
#
#   * 33 lists PHP 8.3 among its supported interpreters, so it will still be
#     supported if this box later moves to PHP 8.4.
#   * user_external 4.0.0 -- the app that makes Nextcloud authenticate against
#     Dovecot, and the whole reason Nextcloud is here -- declares
#     max-version="34". Nextcloud 35 would leave it unsupported.
#   * 33 has been out long enough to be shaken out.
nextcloud_ver=33.0.9
nextcloud_hash=fa8ec03b2ccd3261c127b36fbf85d13b13b474051f7787b90239f0fcf2bf9e70

# Nextcloud apps
# --------------
# Downloaded from each app's GitHub *release asset*, not from an archive of the
# git tag.
#
# This is a change from v76, which fetched
# `.../archive/refs/tags/v$ver.tar.gz`. Those archives are the source tree: they
# unpack to a directory named `contacts-5.5.3` rather than `contacts` (so
# Nextcloud does not recognise the app at all) and they contain no built
# JavaScript. The published release asset unpacks to `contacts/` and includes
# the built assets, which is what Nextcloud actually needs.
#
# Verify compatibility before bumping any of these -- each app's
# appinfo/info.xml carries a <nextcloud min-version max-version> range that
# must include $nextcloud_ver:
#   https://github.com/nextcloud-releases/contacts/releases
#   https://github.com/nextcloud-releases/calendar/releases
#   https://github.com/nextcloud-releases/user_external/releases

# nextcloud 33-35, php 8.2-8.5
contacts_ver=8.8.1
contacts_hash=2ae3edbd90edcc44ab8c2d3172661e5d1948205aa0a4d3e712fc66d2501329f7

# nextcloud 32-35, php 8.1-8.5
calendar_ver=6.5.4
calendar_hash=67c777a6ea974409e9d228c23fc60f2be8e675d376531b6b1b125f2f0365738d

# nextcloud 31-34
#
# Note: as of 4.0.0 this app authenticates over cURL's imap:// protocol rather
# than PHP's ext/imap. So Nextcloud login no longer depends on php-imap -- only
# Roundcube does (see setup/webmail.sh). libcurl in Ubuntu is built with IMAP
# support, which is what makes this work.
user_external_ver=4.0.0
user_external_hash=f1f98c577bd02177fe74e9199f8e50d0c288ffa94bb50a227101a5ba0633c529

# Developer advice (test plan)
# ----------------------------
# When upgrading above versions, how to test?
#
# 1. Enter your server instance (or on the Vagrant image)
# 1. Git clone <your fork>
# 2. Git checkout <your fork>
# 3. Run `sudo ./setup/nextcloud.sh`
# 4. Ensure the installation completes. If any hashes mismatch, correct them.
# 5. Enter nextcloud web, run following tests:
# 5.1 You still can create, edit and delete contacts
# 5.2 You still can create, edit and delete calendar events
# 5.3 You still can create, edit and delete users
# 5.4 Go to Administration > Logs and ensure no new errors are shown

# Clear prior packages and install dependencies from apt.
apt-get purge -qq -y owncloud* # we used to use the package manager

apt_install curl php"${PHP_VER}" php"${PHP_VER}"-fpm \
	php"${PHP_VER}"-cli php"${PHP_VER}"-sqlite3 php"${PHP_VER}"-gd php"${PHP_VER}"-imap php"${PHP_VER}"-curl \
	php"${PHP_VER}"-dev php"${PHP_VER}"-gd php"${PHP_VER}"-xml php"${PHP_VER}"-mbstring php"${PHP_VER}"-zip php"${PHP_VER}"-apcu \
	php"${PHP_VER}"-intl php"${PHP_VER}"-imagick php"${PHP_VER}"-gmp php"${PHP_VER}"-bcmath

# Enable APC before Nextcloud tools are run.
tools/editconf.py /etc/php/"$PHP_VER"/mods-available/apcu.ini -c ';' \
	apc.enabled=1 \
	apc.enable_cli=1

InstallNextcloudApp() {
	# Unpack one app release asset into Nextcloud's apps directory. The asset
	# unpacks to a directory named exactly after the app id, which is what
	# Nextcloud requires in order to find it.
	app=$1
	version=$2
	hash=$3

	wget_verify_sha256 \
		"https://github.com/nextcloud-releases/$app/releases/download/v$version/$app-v$version.tar.gz" \
		"$hash" \
		"/tmp/nc-$app.tgz"
	rm -rf "/usr/local/lib/owncloud/apps/$app"
	tar -xf "/tmp/nc-$app.tgz" -C /usr/local/lib/owncloud/apps/
	rm -f "/tmp/nc-$app.tgz"
	if [ ! -f "/usr/local/lib/owncloud/apps/$app/appinfo/info.xml" ]; then
		echo "The $app app did not unpack to apps/$app as expected."
		exit 1
	fi
}

InstallNextcloud() {

	version=$1
	hash=$2
	version_contacts=$3
	hash_contacts=$4
	version_calendar=$5
	hash_calendar=$6
	version_user_external=$7
	hash_user_external=$8

	echo
	echo "Installing Nextcloud version $version"
	echo

	# Download and verify
	wget_verify_sha256 "https://download.nextcloud.com/server/releases/nextcloud-$version.zip" "$hash" /tmp/nextcloud.zip

	# Remove the current owncloud/Nextcloud
	rm -rf /usr/local/lib/owncloud

	# Extract Nextcloud. It is installed to a path called 'owncloud' for
	# historical reasons; renaming it would invalidate every existing box's
	# paths for no benefit.
	unzip -q /tmp/nextcloud.zip -d /usr/local/lib
	mv /usr/local/lib/nextcloud /usr/local/lib/owncloud
	rm -f /tmp/nextcloud.zip

	# The apps we actually want are not in Nextcloud core.
	mkdir -p /usr/local/lib/owncloud/apps
	InstallNextcloudApp contacts "$version_contacts" "$hash_contacts"
	InstallNextcloudApp calendar "$version_calendar" "$hash_calendar"
	InstallNextcloudApp user_external "$version_user_external" "$hash_user_external"

	# Fix weird permissions.
	chmod 750 /usr/local/lib/owncloud/{apps,config}

	# Create a symlink to the config.php in STORAGE_ROOT (for upgrades we're restoring the symlink we previously
	# put in, and in new installs we're creating a symlink and will create the actual config later).
	ln -sf "$STORAGE_ROOT/owncloud/config.php" /usr/local/lib/owncloud/config/config.php

	# Make sure permissions are correct or the upgrade step won't run.
	# $STORAGE_ROOT/owncloud may not yet exist, so use -f to suppress
	# that error.
	chown -f -R www-data:www-data "$STORAGE_ROOT/owncloud" /usr/local/lib/owncloud || /bin/true

	# If the database already exists, this is a re-run of setup against an
	# already-installed box, so let Nextcloud reconcile its schema with the
	# files we just unpacked. 0 = upgraded, 3 = nothing to do.
	if [ -e "$STORAGE_ROOT/owncloud/owncloud.db" ]; then
		set +e
		sudo -u www-data php"$PHP_VER" /usr/local/lib/owncloud/occ upgrade
		E=$?
		set -e
		if [ $E -ne 0 ] && [ $E -ne 3 ]; then exit 1; fi
		sudo -u www-data php"$PHP_VER" /usr/local/lib/owncloud/occ db:add-missing-indices
		sudo -u www-data php"$PHP_VER" /usr/local/lib/owncloud/occ db:add-missing-primary-keys
	fi
}

# Install Nextcloud if it isn't already there at the version we want.
#
# v76 carried an upgrade ladder here -- a chain of InstallNextcloud calls from
# 20 through 25 -- which existed to walk boxes installed years ago forward one
# major version at a time. This fork targets a fresh 24.04 install, so there is
# nothing to walk forward from and the ladder is gone. A box that needs to move
# across several Nextcloud majors should use upstream Mail-in-a-Box on 22.04 to
# get current first.
if [ -f "$STORAGE_ROOT/owncloud/config.php" ]; then
	CURRENT_NEXTCLOUD_VER=$(php"$PHP_VER" -r "include(\"$STORAGE_ROOT/owncloud/config.php\"); echo(\$CONFIG['version']);")
else
	CURRENT_NEXTCLOUD_VER=""
fi

if [ -n "$CURRENT_NEXTCLOUD_VER" ] && [[ ! ${CURRENT_NEXTCLOUD_VER} =~ ^(${nextcloud_ver%%.*}|${nextcloud_ver}) ]]; then
	# There is an existing install, and it is not the major version we ship.
	# Nextcloud only supports upgrading one major at a time, so refuse rather
	# than attempt a jump that would corrupt the database.
	echo
	echo "This box has Nextcloud $CURRENT_NEXTCLOUD_VER installed, but this version of"
	echo "MeetrMail installs Nextcloud $nextcloud_ver and does not carry the"
	echo "intermediate versions needed to upgrade across majors."
	echo
	echo "Your Nextcloud data is untouched. Migrate it with upstream Mail-in-a-Box on"
	echo "Ubuntu 22.04 first, which carries the intermediate versions."
	echo
	exit 1
fi

if [ ! -d /usr/local/lib/owncloud/ ] || [[ ! ${CURRENT_NEXTCLOUD_VER} =~ ^$nextcloud_ver ]]; then
	# Stop php-fpm if running. If it is not running (which happens on a
	# previously failed install), don't bail.
	service php"$PHP_VER"-fpm stop &> /dev/null || /bin/true

	# Back up anything that is already there.
	if [ -d /usr/local/lib/owncloud/ ] || [ -e "$STORAGE_ROOT/owncloud/owncloud.db" ]; then
		BACKUP_DIRECTORY=$STORAGE_ROOT/owncloud-backup/$(date +"%Y-%m-%d-%T")
		mkdir -p "$BACKUP_DIRECTORY"
		echo "Backing up the existing Nextcloud installation to $BACKUP_DIRECTORY..."
		if [ -d /usr/local/lib/owncloud/ ]; then
			cp -r /usr/local/lib/owncloud "$BACKUP_DIRECTORY/owncloud-install"
		fi
		if [ -e "$STORAGE_ROOT/owncloud/owncloud.db" ]; then
			cp "$STORAGE_ROOT/owncloud/owncloud.db" "$BACKUP_DIRECTORY"
		fi
		if [ -e "$STORAGE_ROOT/owncloud/config.php" ]; then
			cp "$STORAGE_ROOT/owncloud/config.php" "$BACKUP_DIRECTORY"
			# Remove the read-onlyness of the config, which migrations need.
			sed -i -e '/config_is_read_only/d' "$STORAGE_ROOT/owncloud/config.php"
		fi
	fi

	InstallNextcloud "$nextcloud_ver" "$nextcloud_hash" \
		"$contacts_ver" "$contacts_hash" \
		"$calendar_ver" "$calendar_hash" \
		"$user_external_ver" "$user_external_hash"
fi

# ### Configuring Nextcloud

# Set up Nextcloud if its database does not yet exist. Running the installer
# when the database does exist would wipe the database and user data.
if [ ! -f "$STORAGE_ROOT/owncloud/owncloud.db" ]; then
	# Create user data directory
	mkdir -p "$STORAGE_ROOT/owncloud"

	# Seed the configuration file. InstallNextcloud has already symlinked
	# /usr/local/lib/owncloud/config/config.php here, so this is the file the
	# installer will complete.
	instanceid=oc$(echo "$PRIMARY_HOSTNAME" | sha1sum | fold -w 10 | head -n 1)
	cat > "$STORAGE_ROOT/owncloud/config.php" <<EOF;
<?php
\$CONFIG = array (
  'datadirectory' => '$STORAGE_ROOT/owncloud',
  'instanceid' => '$instanceid',
  'overwritewebroot' => '/cloud',
  'overwrite.cli.url' => '/cloud',
  'overwriteprotocol' => 'https',
  'memcache.local' => '\OC\Memcache\APCu',
);
?>
EOF

	chown -R www-data:www-data "$STORAGE_ROOT/owncloud" /usr/local/lib/owncloud

	# Run the installer.
	#
	# v76 did this by writing an autoconfig.php and then requesting index.php as
	# www-data, which returns HTML and swallows the reason for any failure.
	# `occ maintenance:install` is the supported path and exits non-zero with a
	# readable error, which matters a great deal when it goes wrong.
	#
	# The admin account gets a random password that is never shown. Nothing
	# useful is done through the Nextcloud admin UI on a MeetrMail, and
	# tools/owncloud-unlockadmin.sh exists for the rare case where it is needed.
	adminpassword=$(dd if=/dev/urandom bs=1 count=40 2>/dev/null | sha1sum | fold -w 30 | head -n 1)
	echo "Running the Nextcloud installer..."
	hide_output sudo -u www-data php"$PHP_VER" /usr/local/lib/owncloud/occ maintenance:install \
		--database sqlite \
		--data-dir "$STORAGE_ROOT/owncloud" \
		--admin-user root \
		--admin-pass "$adminpassword"

	if [ ! -f "$STORAGE_ROOT/owncloud/owncloud.db" ]; then
		echo "The Nextcloud installer did not create its database. Setup cannot continue."
		exit 1
	fi
fi

# Update config.php.
# * trusted_domains is reset to localhost by autoconfig starting with ownCloud 8.1.1,
#   so set it here. It also can change if the box's PRIMARY_HOSTNAME changes, so
#   this will make sure it has the right value.
# * Some settings weren't included in previous versions of MeetrMail.
# * We need to set the timezone to the system timezone to allow fail2ban to ban
#   users within the proper timeframe
# * We need to set the logdateformat to something that will work correctly with fail2ban
# * mail_domain' needs to be set every time we run the setup. Making sure we are setting
#   the correct domain name if the domain is being change from the previous setup.
# Use PHP to read the settings file, modify it, and write out the new settings array.
TIMEZONE=$(cat /etc/timezone)
CONFIG_TEMP=$(/bin/mktemp)
php"$PHP_VER" <<EOF > "$CONFIG_TEMP" && mv "$CONFIG_TEMP" "$STORAGE_ROOT/owncloud/config.php";
<?php
include("$STORAGE_ROOT/owncloud/config.php");

\$CONFIG['config_is_read_only'] = false;
\$CONFIG['overwriteprotocol'] = 'https'; # replaces the 'forcessl' setting removed from Nextcloud years ago; without it Nextcloud emits HSTS=0, which conflicts with our nginx config
\$CONFIG['appstoreenabled'] = false; # we pin app versions in this script, so don't let the box install its own

\$CONFIG['trusted_domains'] = array('$PRIMARY_HOSTNAME');

\$CONFIG['memcache.local'] = '\OC\Memcache\APCu';
\$CONFIG['overwrite.cli.url'] = 'https://${PRIMARY_HOSTNAME}/cloud';

\$CONFIG['logtimezone'] = '$TIMEZONE';
\$CONFIG['logdateformat'] = 'Y-m-d H:i:s';

\$CONFIG['user_backends'] = array(
  array(
    'class' => '\OCA\UserExternal\IMAP',
    'arguments' => array(
      '127.0.0.1', 143, null, null, false, false
    ),
  ),
);

\$CONFIG['mail_domain'] = '$PRIMARY_HOSTNAME';
\$CONFIG['mail_from_address'] = 'administrator'; # just the local part, matches the required administrator alias on mail_domain/$PRIMARY_HOSTNAME
\$CONFIG['mail_smtpmode'] = 'sendmail';
\$CONFIG['mail_smtpauth'] = true; # if smtpmode is smtp
\$CONFIG['mail_smtphost'] = '127.0.0.1'; # if smtpmode is smtp
\$CONFIG['mail_smtpport'] = '587'; # if smtpmode is smtp
\$CONFIG['mail_smtpsecure'] = ''; # if smtpmode is smtp, must be empty string
\$CONFIG['mail_smtpname'] = ''; # if smtpmode is smtp, set this to a mail user
\$CONFIG['mail_smtppassword'] = ''; # if smtpmode is smtp, set this to the user's password

echo "<?php\n\\\$CONFIG = ";
var_export(\$CONFIG);
echo ";";
?>
EOF
chown www-data:www-data "$STORAGE_ROOT/owncloud/config.php"

# Enable/disable apps. Note that this must be done after the Nextcloud setup.
# The firstrunwizard gave Josh all sorts of problems, so disabling that.
# user_external is what allows Nextcloud to use IMAP for login. The contacts
# and calendar apps are the extensions we really care about here.
hide_output sudo -u www-data php"$PHP_VER" /usr/local/lib/owncloud/occ app:enable user_external
hide_output sudo -u www-data php"$PHP_VER" /usr/local/lib/owncloud/occ app:enable contacts
hide_output sudo -u www-data php"$PHP_VER" /usr/local/lib/owncloud/occ app:enable calendar

# When upgrading, run the upgrade script again now that apps are enabled. It seems like
# the first upgrade at the top won't work because apps may be disabled during upgrade?
# Check for success (0=ok, 3=no upgrade needed).
sudo -u www-data php"$PHP_VER" /usr/local/lib/owncloud/occ upgrade
E=$?
if [ $E -ne 0 ] && [ $E -ne 3 ]; then exit 1; fi

# Disable the default apps we don't use. This box runs Nextcloud only for
# CardDAV and CalDAV, and every enabled app costs memory on what is often a 4GB
# machine. `grep -v` because occ reports apps that were already disabled, which
# is not an error for us.
sudo -u www-data \
	php"$PHP_VER" /usr/local/lib/owncloud/occ app:disable \
		photos dashboard activity firstrunwizard \
		weather_status user_status recommendations \
		nextcloud_announcements survey_client support \
	| (grep -v "No such app enabled" || /bin/true)

# Set PHP FPM values to support large file uploads
# (semicolon is the comment character in this file, hashes produce deprecation warnings)
tools/editconf.py /etc/php/"$PHP_VER"/fpm/php.ini -c ';' \
	upload_max_filesize=16G \
	post_max_size=16G \
	output_buffering=16384 \
	memory_limit=512M \
	max_execution_time=600 \
	short_open_tag=On

# Set Nextcloud recommended opcache settings
tools/editconf.py /etc/php/"$PHP_VER"/cli/conf.d/10-opcache.ini -c ';' \
	opcache.enable=1 \
	opcache.enable_cli=1 \
	opcache.interned_strings_buffer=8 \
	opcache.max_accelerated_files=10000 \
	opcache.memory_consumption=128 \
	opcache.save_comments=1 \
	opcache.revalidate_freq=1


# Set up a general cron job for Nextcloud.
# Also add another job for Calendar updates, per advice in the Nextcloud docs
# https://docs.nextcloud.com/server/24/admin_manual/groupware/calendar.html#background-jobs
cat > /etc/cron.d/meetrmail-nextcloud << EOF;
#!/bin/bash
# MeetrMail
*/5 * * * *	www-data	php$PHP_VER -f /usr/local/lib/owncloud/cron.php
*/5 * * * *	www-data	php$PHP_VER -f /usr/local/lib/owncloud/occ dav:send-event-reminders
EOF
chmod +x /etc/cron.d/meetrmail-nextcloud

# We also need to change the sending mode from background-job to occ.
# Or else the reminders will just be sent as soon as possible when the background jobs run.
hide_output sudo -u www-data php"$PHP_VER" -f /usr/local/lib/owncloud/occ config:app:set dav sendEventRemindersMode --value occ

# Now set the config to read-only.
# Do this only at the very bottom when no further occ commands are needed.
sed -i'' "s/'config_is_read_only'\s*=>\s*false/'config_is_read_only' => true/" "$STORAGE_ROOT/owncloud/config.php"

# Rotate the nextcloud.log file
cat > /etc/logrotate.d/nextcloud <<EOF
# Nextcloud logs
$STORAGE_ROOT/owncloud/nextcloud.log {
		size 10M
		create 640 www-data www-data
		rotate 30
		copytruncate
		missingok
		compress
}
EOF

# There's nothing much of interest that a user could do as an admin for Nextcloud,
# and there's a lot they could mess up, so we don't make any users admins of Nextcloud.
# But if we wanted to, we would do this:
# ```
# for user in $(management/cli.py user admins); do
#	 sqlite3 $STORAGE_ROOT/owncloud/owncloud.db "INSERT OR IGNORE INTO oc_group_user VALUES ('admin', '$user')"
# done
# ```

# Enable PHP modules and restart PHP.
restart_service php"$PHP_VER"-fpm
