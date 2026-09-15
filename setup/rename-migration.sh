#!/bin/bash
# One-time migration of a box installed under the old Mail-in-a-Box names
# (/etc/mailinabox.conf, the mailinabox service, `sudo mailinabox`, and so on)
# to the MeetrMail names. Sourced by setup/start.sh before anything reads
# /etc/meetrmail.conf. Does nothing on a fresh install or a box already migrated.
#
# Files that setup regenerates on every run (the management daemon's Python
# environments, cron jobs, fail2ban and redis drop-ins, nginx aliases) are
# simply removed under their old names and recreated under the new ones later
# in the run. Only state that setup cannot regenerate is moved.

if [ -f /etc/mailinabox.conf ] && [ ! -f /etc/meetrmail.conf ]; then
	echo "Migrating this box from Mail-in-a-Box names to MeetrMail names..."

	# The old management daemon is running from /usr/local/lib/mailinabox.
	if systemctl list-unit-files mailinabox.service > /dev/null 2>&1; then
		systemctl disable --now mailinabox.service > /dev/null 2>&1 || true
	fi
	rm -f /etc/systemd/system/mailinabox.service /lib/systemd/system/mailinabox.service
	rm -f /etc/systemd/system/redis-server.service.d/mailinabox.conf
	systemctl daemon-reload

	# State that has to survive: settings, the migration counter, the API key
	# and generated client configs, and the backup SSH key (its public half may
	# already be authorized on a remote backup server).
	mv /etc/mailinabox.conf /etc/meetrmail.conf
	STORAGE_ROOT=$(sed -n 's/^STORAGE_ROOT=//p' /etc/meetrmail.conf | head -n 1)
	if [ -n "$STORAGE_ROOT" ] && [ -f "$STORAGE_ROOT/mailinabox.version" ] && [ ! -f "$STORAGE_ROOT/meetrmail.version" ]; then
		mv "$STORAGE_ROOT/mailinabox.version" "$STORAGE_ROOT/meetrmail.version"
	fi
	if [ -d /var/lib/mailinabox ] && [ ! -e /var/lib/meetrmail ]; then
		mv /var/lib/mailinabox /var/lib/meetrmail
	fi
	for f in id_rsa_miab id_rsa_miab.pub; do
		if [ -f "/root/.ssh/$f" ] && [ ! -e "/root/.ssh/${f/miab/meetrmail}" ]; then
			mv "/root/.ssh/$f" "/root/.ssh/${f/miab/meetrmail}"
		fi
	done

	# The sandbox DNS forwarding block is found by its marker comments.
	if [ -f /etc/bind/named.conf.local ]; then
		sed -i 's/### \(BEGIN\|END\) Mail-in-a-Box sandbox DNS ###/### \1 MeetrMail sandbox DNS ###/' /etc/bind/named.conf.local
	fi

	# Regenerated later in this run under the new names.
	rm -rf /usr/local/lib/mailinabox /var/cache/mailinabox
	rm -f /usr/local/bin/mailinabox /usr/local/bin/miab-mode
	rm -f /etc/cron.d/mailinabox-nightly /etc/cron.d/mailinabox-nextcloud
	rm -f /etc/cron.daily/mailinabox-dnssec /etc/cron.daily/mailinabox-ssl-cleanup
	rm -f /etc/fail2ban/jail.d/mailinabox.conf /etc/fail2ban/filter.d/miab-*.conf
fi
