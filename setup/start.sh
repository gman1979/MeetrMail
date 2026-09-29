#!/bin/bash
# This is the entry point for configuring the system.
#####################################################

source setup/functions.sh # load our functions

echo "MeetrMail $(cat VERSION) setup (based on Mail-in-a-Box v76)"
echo

# Check system setup: Are we running as root on Ubuntu 18.04 on a
# machine with enough memory? Is /tmp mounted with exec.
# If not, this shows an error and exits.
source setup/preflight.sh

# Ensure Python reads/writes files in UTF-8. If the machine
# triggers some other locale in Python, like ASCII encoding,
# Python may not be able to read/write files. This is also
# in the management daemon startup script and the cron script.

if ! locale -a | grep en_US.utf8 > /dev/null; then
    # Generate locale if not exists
    hide_output locale-gen en_US.UTF-8
fi

export LANGUAGE=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_TYPE=en_US.UTF-8

# Fix so line drawing characters are shown correctly in Putty on Windows. See #744.
export NCURSES_NO_UTF8_ACS=1

# Move a box installed under the old Mail-in-a-Box names to the MeetrMail names.
source setup/rename-migration.sh

# Recall the last settings used if we're running this a second time.
if [ -f /etc/meetrmail.conf ]; then
	# Run any system migrations before proceeding. Since this is a second run,
	# we assume we have Python already installed.
	setup/migrate.py --migrate || exit 1

	# Load the old .conf file to get existing configuration options loaded
	# into variables with a DEFAULT_ prefix.
	cat /etc/meetrmail.conf | sed s/^/DEFAULT_/ > /tmp/meetrmail.prev.conf
	source /tmp/meetrmail.prev.conf
	rm -f /tmp/meetrmail.prev.conf
else
	FIRST_TIME_SETUP=1
fi

# Put a start script in a global location. We tell the user to run 'meetrmail-setup'
# in the first dialog prompt, so we should do this before that starts.
cat > /usr/local/bin/meetrmail-setup << EOF;
#!/bin/bash
cd $PWD
source setup/start.sh
EOF
chmod +x /usr/local/bin/meetrmail-setup

# Same for the sandbox/live mode switch. It reads the source directory out of
# /usr/local/bin/meetrmail-setup above, so it has to be installed after it.
cat > /usr/local/bin/meetrmail-mode << EOF;
#!/bin/bash
cd $PWD
exec tools/meetrmail-mode "\$@"
EOF
chmod +x /usr/local/bin/meetrmail-mode

# Install uv and the Python interpreter the management daemon and the setup
# questions both need. This has to come before questions.sh, which validates
# the administrator's email address by running management/mailconfig.py.
source setup/uv.sh

# Ask the user for the PRIMARY_HOSTNAME, PUBLIC_IP, and PUBLIC_IPV6,
# if values have not already been set in environment variables. When running
# non-interactively, be sure to set values for all! Also sets STORAGE_USER and
# STORAGE_ROOT.
source setup/questions.sh

# Run some network checks to make sure setup on this machine makes sense.
# Skip on existing installs since we don't want this to block the ability to
# upgrade, and these checks are also in the control panel status checks.
if [ -z "${DEFAULT_PRIMARY_HOSTNAME:-}" ]; then
if [ -z "${SKIP_NETWORK_CHECKS:-}" ]; then
	source setup/network-checks.sh
fi
fi

# Create the STORAGE_USER and STORAGE_ROOT directory if they don't already exist.
#
# Set the directory and all of its parent directories' permissions to world
# readable since it holds files owned by different processes.
#
# If the STORAGE_ROOT is missing the meetrmail.version file that lists a
# migration (schema) number for the files stored there, assume this is a fresh
# installation to that directory and write the file to contain the current
# migration number for this version of MeetrMail.
if ! id -u "$STORAGE_USER" >/dev/null 2>&1; then
	useradd -m "$STORAGE_USER"
fi
if [ ! -d "$STORAGE_ROOT" ]; then
	mkdir -p "$STORAGE_ROOT"
fi
f=$STORAGE_ROOT
while [[ $f != / ]]; do chmod a+rx "$f"; f=$(dirname "$f"); done;
if [ ! -f "$STORAGE_ROOT/meetrmail.version" ]; then
	setup/migrate.py --current > "$STORAGE_ROOT/meetrmail.version"
	chown "$STORAGE_USER:$STORAGE_USER" "$STORAGE_ROOT/meetrmail.version"
fi

# Save the global options in /etc/meetrmail.conf so that standalone
# tools know where to look for data. The default MTA_STS_MODE setting
# is blank unless set by an environment variable, but see web.sh for
# how that is interpreted.
cat > /etc/meetrmail.conf << EOF;
STORAGE_USER=$STORAGE_USER
STORAGE_ROOT=$STORAGE_ROOT
PRIMARY_HOSTNAME=$PRIMARY_HOSTNAME
PUBLIC_IP=$PUBLIC_IP
PUBLIC_IPV6=$PUBLIC_IPV6
PRIVATE_IP=$PRIVATE_IP
PRIVATE_IPV6=$PRIVATE_IPV6
MTA_STS_MODE=${DEFAULT_MTA_STS_MODE:-enforce}
PHP_VERSION=$PHP_VER
SANDBOX_MODE=$MEETRMAIL_SANDBOX
RSPAMD_PACKAGE_SOURCE=${RSPAMD_PACKAGE_SOURCE:-${DEFAULT_RSPAMD_PACKAGE_SOURCE:-upstream}}
EOF

# Start service configuration.
source setup/system.sh
source setup/ssl.sh
source setup/dns.sh
source setup/mail-postfix.sh
source setup/mail-dovecot.sh
source setup/mail-users.sh
source setup/dkim.sh
source setup/rspamd.sh
source setup/web.sh
source setup/webmail.sh
source setup/nextcloud.sh
source setup/management.sh
source setup/munin.sh

# Wait for the management daemon to start...
until nc -z -w 4 127.0.0.1 10222
do
	echo "Waiting for the MeetrMail management daemon to start..."
	sleep 2
done

# ...and then have it write the DNS and nginx configuration files and start those
# services.
tools/dns_update
tools/web_update

# In sandbox mode, make the box's own zones resolvable locally. This has to run
# after dns_update, because that is what tells nsd which zones exist.
tools/sandbox-dns-forward

# Give fail2ban another restart. The log files may not all have been present when
# fail2ban was first configured, but they should exist now.
restart_service fail2ban

# If there aren't any mail users yet, create one.
source setup/firstuser.sh

# Register with Let's Encrypt, including agreeing to the Terms of Service.
# We'd let certbot ask the user interactively, but when this script is
# run in the recommended curl-pipe-to-bash method there is no TTY and
# certbot will fail if it tries to ask.
if is_sandbox; then
	# Let's Encrypt has to reach this box over port 80 at a publicly resolvable
	# name to issue anything, which is exactly what a sandbox box does not have.
	# ssl.sh has already created a self-signed certificate, which is what the
	# box will use. Registering an ACME account here would just fail.
	sandbox_skip "Let's Encrypt registration (using the self-signed certificate)"
elif [ ! -d "$STORAGE_ROOT/ssl/lets_encrypt/accounts/acme-v02.api.letsencrypt.org/" ]; then
echo
echo "-----------------------------------------------"
echo "MeetrMail uses Let's Encrypt to provision free SSL/TLS certificates"
echo "to enable HTTPS connections to your box. We're automatically"
echo "agreeing you to their subscriber agreement. See https://letsencrypt.org."
echo
certbot register --register-unsafely-without-email --agree-tos --config-dir "$STORAGE_ROOT/ssl/lets_encrypt"
fi

# Done.
echo
echo "-----------------------------------------------"
echo
if is_sandbox; then
	echo "Your MeetrMail is running in SANDBOX mode."
	echo
	echo "It will not send or receive mail from the public internet and its TLS"
	echo "certificate is self-signed. Run the self-test suite to check it over:"
	echo
	echo "  sudo tests/sandbox/selftest.sh"
	echo
	echo "When you are ready to go live:  sudo meetrmail-mode live"
	echo
else
	echo "Your MeetrMail is running."
fi
echo
echo "Please log in to the control panel for further instructions at:"
echo
if management/status_checks.py --check-primary-hostname; then
	# Show the nice URL if it appears to be resolving and has a valid certificate.
	echo "https://$PRIMARY_HOSTNAME/admin"
	echo
	echo "If you have a DNS problem put the box's IP address in the URL"
	echo "(https://$PUBLIC_IP/admin) but then check the TLS fingerprint:"
	openssl x509 -in "$STORAGE_ROOT/ssl/ssl_certificate.pem" -noout -fingerprint -sha256\
        	| sed "s/SHA256 Fingerprint=//i"
else
	echo "https://$PUBLIC_IP/admin"
	echo
	echo "You will be alerted that the website has an invalid certificate. Check that"
	echo "the certificate fingerprint matches:"
	echo
	openssl x509 -in "$STORAGE_ROOT/ssl/ssl_certificate.pem" -noout -fingerprint -sha256\
        	| sed "s/SHA256 Fingerprint=//i"
	echo
	echo "Then you can confirm the security exception and continue."
	echo
fi
