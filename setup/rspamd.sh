#!/bin/bash
# Spam filtering and greylisting with Rspamd
# ------------------------------------------
#
# Rspamd replaces four things that Mail-in-a-Box v76 used:
#
#   spampd + spamassassin   ->  Rspamd's proxy worker, attached to Postfix as a milter
#   postgrey                ->  Rspamd's greylist module
#   razor, pyzor            ->  Rspamd's fuzzy storage and built-in reputation
#   dovecot-antispam        ->  IMAPSieve calling rspamc learn_spam / learn_ham
#
# The shape of the mail path changes as a result. v76 inserted spampd into the
# *delivery* path: Postfix handed mail to spampd over LMTP on :10025, spampd
# scanned it and handed it on to Dovecot's LMTP on :10026. Rspamd is not a
# delivery agent -- it is a milter, so it inspects mail during the SMTP
# transaction and Postfix then delivers straight to Dovecot on :10026. That is
# also what makes greylisting possible without a separate daemon: a milter can
# defer a message before Postfix has accepted it, which a delivery agent cannot.
#
# What this script deliberately does NOT do
# -----------------------------------------
# Rspamd can sign outbound mail with DKIM and enforce DMARC, and eventually it
# should: that would let OpenDKIM and OpenDMARC be deleted. But DKIM signing is
# the single thing that determines whether Gmail accepts mail from this box, and
# moving it means rewriting the key generation in management/dns_update.py and
# the validation in management/status_checks.py.
#
# So OpenDKIM and OpenDMARC stay exactly as v76 had them (see setup/dkim.sh),
# and Rspamd's own dkim_signing and dmarc-enforcement paths are left off. Rspamd
# still *verifies* SPF, DKIM and DMARC for scoring purposes using its own
# modules, which is strictly better than v76's approach of regex-matching
# OpenDMARC's Authentication-Results header in SpamAssassin rules.

source /etc/meetrmail.conf # get global vars
source setup/functions.sh # load our functions

# ### Package source
#
# Rspamd is in Ubuntu universe (3.8.1 on noble), but universe carries no
# security-update guarantee and that version is two major releases behind. A
# spam filter parsing hostile input from the public internet is exactly the
# wrong place to run unmaintained code, so by default we use the Rspamd
# project's own apt repository, with its signing key pinned by fingerprint.
#
# This is the one third-party apt source on the box. To use Ubuntu's package
# instead -- for example to avoid any external repository at all -- set
# RSPAMD_PACKAGE_SOURCE=ubuntu in the environment before running setup.
#
# The choice is recorded in /etc/meetrmail.conf by setup/start.sh and read back
# from there (this script sources it above), so a later plain `sudo meetrmail-setup`
# does not silently move the box from one repository to the other -- which could
# mean an unannounced jump across two major Rspamd versions.

RSPAMD_PACKAGE_SOURCE="${RSPAMD_PACKAGE_SOURCE:-upstream}"
RSPAMD_KEY_FINGERPRINT=3FA347D5E599BE4595CA2576FFA232EDBF21E25E

if [ "$RSPAMD_PACKAGE_SOURCE" = "upstream" ]; then
	echo "Configuring the Rspamd apt repository..."
	apt_install gnupg ca-certificates

	# Fetch the signing key and refuse to continue unless it is the key we
	# expect. Pinning the fingerprint is what makes this safe; fetching a key
	# over TLS and trusting whatever arrives would not be.
	rm -f /tmp/rspamd.key
	hide_output wget -O /tmp/rspamd.key https://rspamd.com/apt-stable/gpg.key
	if ! gpg --show-keys --with-colons --with-fingerprint /tmp/rspamd.key 2>/dev/null \
		| grep -q "^fpr:::::::::$RSPAMD_KEY_FINGERPRINT:"; then
		echo "The Rspamd signing key did not have the expected fingerprint."
		echo "Expected: $RSPAMD_KEY_FINGERPRINT"
		echo "Got:"
		gpg --show-keys --with-colons --with-fingerprint /tmp/rspamd.key 2>/dev/null | sed -n 's/^fpr:*\([0-9A-F]*\):$/  \1/p'
		rm -f /tmp/rspamd.key
		exit 1
	fi
	mkdir -p /etc/apt/keyrings
	gpg --dearmor < /tmp/rspamd.key > /etc/apt/keyrings/rspamd.gpg
	chmod 644 /etc/apt/keyrings/rspamd.gpg
	rm -f /tmp/rspamd.key

	# Pin the repository to the rspamd packages only, so that adding it cannot
	# change where anything else on the box comes from.
	cat > /etc/apt/sources.list.d/rspamd.sources <<EOF;
# MeetrMail --- Do not edit / will be overwritten on update.
Types: deb
URIs: https://rspamd.com/apt-stable/
Suites: $(lsb_release -cs)
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/rspamd.gpg
EOF
	cat > /etc/apt/preferences.d/rspamd <<EOF;
# MeetrMail --- Do not edit / will be overwritten on update.
# Only take rspamd packages from the Rspamd repository; everything else comes
# from the Ubuntu archive regardless of version numbers.
Package: *
Pin: origin rspamd.com
Pin-Priority: 1

Package: rspamd rspamd-dbg
Pin: origin rspamd.com
Pin-Priority: 600
EOF
	hide_output apt-get update
else
	# Using Ubuntu's package: make sure any previously-added repository is gone
	# so that apt doesn't keep pulling from it.
	rm -f /etc/apt/sources.list.d/rspamd.sources /etc/apt/preferences.d/rspamd /etc/apt/keyrings/rspamd.gpg
	hide_output apt-get update
fi

echo "Installing Rspamd and Redis..."
apt_install rspamd redis-server

# Redis holds the Bayes tokens, the fuzzy hashes, the greylisting records and
# the ratelimit counters. It listens on loopback only, which is the packaged
# default on Ubuntu, and we do not want it reachable from anywhere else.
#
# Its data directory is moved under STORAGE_ROOT. That is deliberate and it
# matters: the Bayes classifier is trained by the user over months, and v76 kept
# SpamAssassin's bayes database under STORAGE_ROOT so it was included in backups
# and survived a restore. Leaving Redis at its default /var/lib/redis would
# silently drop all of that from the backup set. management/backup.py stops
# Redis before the backup runs, so the snapshot is consistent.
# Three different users need different things from $STORAGE_ROOT/mail/rspamd,
# so each piece is set explicitly:
#
#   the directory itself  root:mail 751 -- o+x so the redis user can traverse
#                         into its own subdirectory; not o+r, so its contents
#                         cannot be listed
#   redis/                redis:redis 750 -- Redis's own data, nobody else's
#   controller_password   root:mail 640 -- set further down, where it is
#                         created; the mail user runs the IMAPSieve learning
#                         scripts and has to read it
#
# These are set here, before Redis is restarted, rather than at the end of the
# script -- Redis cannot start without them.
mkdir -p "$STORAGE_ROOT/mail/rspamd/redis"
chgrp mail "$STORAGE_ROOT/mail/rspamd"
chmod 751 "$STORAGE_ROOT/mail/rspamd"
chown redis:redis "$STORAGE_ROOT/mail/rspamd/redis"
chmod 750 "$STORAGE_ROOT/mail/rspamd/redis"

# Ubuntu's redis-server.service runs with ProtectHome=yes and
# ProtectSystem=strict, so /home is simply not visible to the process and
# ReadWritePaths cannot open a path underneath it. Redis exits 1 on startup with
# no useful message if you only change `dir`.
#
# Relax ProtectHome for this unit and grant write access to exactly the one
# directory, leaving the rest of the hardening in place.
mkdir -p /etc/systemd/system/redis-server.service.d
cat > /etc/systemd/system/redis-server.service.d/meetrmail.conf <<EOF;
# MeetrMail --- Do not edit / will be overwritten on update.
# Redis keeps the spam filter's Bayes tokens, fuzzy hashes and greylist records
# under STORAGE_ROOT so that they are included in backups. See setup/rspamd.sh.
[Service]
ProtectHome=false
ReadWritePaths=-$STORAGE_ROOT/mail/rspamd/redis
EOF
hide_output systemctl daemon-reload

tools/editconf.py /etc/redis/redis.conf -s \
	"bind=127.0.0.1 -::1" \
	"protected-mode=yes" \
	"dir=$STORAGE_ROOT/mail/rspamd/redis"

# If there is an existing dump at the packaged location and none at the new one,
# move it across so that training built up before this change is not lost.
if [ -f /var/lib/redis/dump.rdb ] && [ ! -f "$STORAGE_ROOT/mail/rspamd/redis/dump.rdb" ]; then
	service redis-server stop > /dev/null 2>&1 || true
	mv /var/lib/redis/dump.rdb "$STORAGE_ROOT/mail/rspamd/redis/dump.rdb"
	chown redis:redis "$STORAGE_ROOT/mail/rspamd/redis/dump.rdb"
fi

restart_service redis-server

# Confirm it actually came up on the new directory. Redis failing to start here
# would leave the box with no Bayes classifier, no greylisting and no fuzzy
# storage -- and Rspamd would carry on running without any of them.
if ! redis-cli ping 2>/dev/null | grep -q PONG; then
	echo "Redis did not start. Its status:"
	systemctl status redis-server --no-pager -n 20 || true
	exit 1
fi

# ### Configuration
#
# Everything below is written into /etc/rspamd/local.d/. That is the supported
# place for local overrides: files there are merged over the packaged defaults,
# so a package upgrade never discards our settings and never leaves us with a
# stale copy of a default we didn't mean to freeze.

mkdir -p /etc/rspamd/local.d

# #### Workers
#
# Three workers, all bound to loopback:
#
#   proxy (11332)      the milter endpoint Postfix talks to
#   normal (11333)     does the actual scanning, called by the proxy
#   controller (11334) the web UI, statistics, and the target of rspamc
#
# The proxy worker is in "self-scan" mode, meaning it scans in-process rather
# than forwarding to the normal worker. On a single small box that saves a hop
# and some memory.

cat > /etc/rspamd/local.d/worker-proxy.inc <<EOF;
# MeetrMail --- Do not edit / will be overwritten on update.
bind_socket = "127.0.0.1:11332";
milter = yes;
timeout = 120s;
upstream "local" {
  default = yes;
  self_scan = yes;
}
EOF

cat > /etc/rspamd/local.d/worker-normal.inc <<EOF;
# MeetrMail --- Do not edit / will be overwritten on update.
bind_socket = "127.0.0.1:11333";
EOF

# The controller's web UI is bound to loopback only. Reach it over an SSH
# tunnel:  ssh -L 11334:127.0.0.1:11334 you@$PRIMARY_HOSTNAME
# then open http://127.0.0.1:11334 and use the password below.
#
# The password is generated once and kept in STORAGE_ROOT so that it survives
# re-running setup, and so that it is included in backups.
mkdir -p "$STORAGE_ROOT/mail/rspamd"
if [ ! -f "$STORAGE_ROOT/mail/rspamd/controller_password.txt" ]; then
	# openssl rather than `tr < /dev/urandom | head -c`: /dev/urandom never
	# ends, so head closing the pipe sends tr a SIGPIPE and the whole pipeline
	# fails under this script's `set -o pipefail`.
	(umask 077; openssl rand -hex 24 > "$STORAGE_ROOT/mail/rspamd/controller_password.txt")
fi
rspamd_controller_password=$(cat "$STORAGE_ROOT/mail/rspamd/controller_password.txt")

# Store the hash, not the password. rspamadm pw produces a PBKDF2 hash that the
# controller accepts in place of a plaintext password.
rspamd_controller_hash=$(rspamadm pw --encrypt --password "$rspamd_controller_password")

cat > /etc/rspamd/local.d/worker-controller.inc <<EOF;
# MeetrMail --- Do not edit / will be overwritten on update.
bind_socket = "127.0.0.1:11334";
password = "$rspamd_controller_hash";
# enable_password is what rspamc uses for privileged operations such as
# learning. Same credential; there is no second class of user on this box.
enable_password = "$rspamd_controller_hash";
EOF

# #### Redis
cat > /etc/rspamd/local.d/redis.conf <<EOF;
# MeetrMail --- Do not edit / will be overwritten on update.
servers = "127.0.0.1:6379";
EOF

# #### Logging
#
# Log to syslog so that everything lands in /var/log/mail.log alongside Postfix
# and Dovecot. management/mail_log.py reads that file, and so do the fail2ban
# jails, so a private logfile would make Rspamd invisible to both.
cat > /etc/rspamd/local.d/logging.inc <<EOF;
# MeetrMail --- Do not edit / will be overwritten on update.
type = "syslog";
facility = "mail";
level = "info";
EOF

# #### Options
#
# local_networks matters: mail arriving from these addresses is not greylisted
# and skips several checks. Only loopback belongs here -- mail from this box's
# own public IP arriving on port 25 is somebody else's mail, not ours.
cat > /etc/rspamd/local.d/options.inc <<EOF;
# MeetrMail --- Do not edit / will be overwritten on update.
local_addrs = "127.0.0.0/8, ::1";
# Use the box's own validating resolver (bind9, see setup/system.sh) rather
# than whatever is in resolv.conf at the time. DNSSEC validation is done there,
# and the DNS blocklists we query refuse service to large public resolvers.
dns {
  nameserver = ["127.0.0.1"];
  timeout = 2s;
  retransmits = 2;
}
EOF

# #### Actions
#
# Rspamd's thresholds. These are the defaults with the reject threshold raised:
# a mail server that silently rejects at 15 is a mail server that loses mail,
# and on a personal box a false positive costs far more than a spam that lands
# in the Spam folder. Mail above add_header gets tagged and filed by the sieve
# rule in conf/sieve-spam.txt; nothing is discarded.
cat > /etc/rspamd/local.d/actions.conf <<EOF;
# MeetrMail --- Do not edit / will be overwritten on update.
greylist = 4;
add_header = 6;
reject = 15;
EOF

# #### Headers
#
# Add the headers the delivery-time sieve rule and mail clients look for.
#
# X-Spam-Status is the header v76's SpamAssassin emitted and the one
# conf/sieve-spam.txt matches on, so producing it here keeps the spam-filing
# rule working unchanged -- and keeps working any per-user sieve rule somebody
# already wrote against it.
#
# We deliberately do not add Rspamd's own Authentication-Results header:
# OpenDKIM and OpenDMARC already add one, and two of them in a message is
# confusing to read and to debug.
cat > /etc/rspamd/local.d/milter_headers.conf <<EOF;
# MeetrMail --- Do not edit / will be overwritten on update.
use = ["x-spam-status", "x-spam-level", "x-spamd-bar", "x-spamd-result", "x-rspamd-server", "x-rspamd-queue-id"];
extended_spam_headers = true;
skip_local = true;
skip_authenticated = true;
EOF

# #### Greylisting
#
# Replaces postgrey. A sender is deferred with a 4xx temporary failure; a real
# mail server retries a few minutes later and is let through, while a lot of
# spam never comes back. Records live in Redis.
#
# Note this is not a like-for-like replacement of postgrey's behaviour. postgrey
# deferred every first contact from an unknown sender; Rspamd defers only mail
# scoring into the greylist band set in actions.conf (4.0-6.0 here). Ordinary
# mail from a new correspondent is no longer delayed at all. To get blanket
# greylisting back, lower the `greylist` action threshold toward zero.
#
# In sandbox mode use a much shorter delay. Greylisting is one of the things
# worth actually testing, and a five-minute wait makes that impractical -- but
# disabling it would mean testing a box that behaves differently from the live
# one. Ten seconds keeps the behaviour and makes it observable.
if is_sandbox; then
	rspamd_greylist_timeout=10s
else
	rspamd_greylist_timeout=300s
fi

cat > /etc/rspamd/local.d/greylist.conf <<EOF;
# MeetrMail --- Do not edit / will be overwritten on update.
enabled = true;
timeout = $rspamd_greylist_timeout;   # how long a sender must wait before being accepted
expire = 86400s;                      # how long we remember a sender that got through
message = "Greylisted, please try again shortly";
EOF

# #### Bayes
#
# Statistical classification, trained by the user dragging mail into and out of
# the Spam folder (see the IMAPSieve section below). Tokens live in Redis, whose
# data directory is under STORAGE_ROOT (see above), so training is backed up the
# same way SpamAssassin's bayes database was in v76.
#
# autolearn trains on mail Rspamd is already very confident about, so the
# classifier becomes useful without the user having to do anything.
cat > /etc/rspamd/local.d/classifier-bayes.conf <<EOF;
# MeetrMail --- Do not edit / will be overwritten on update.
backend = "redis";
autolearn = true;
# Learn per-box, not per-user: on a family-sized box there is not enough mail
# for per-user classifiers to ever become accurate.
users_enabled = false;
new_schema = true;
expire = 8640000;  # 100 days
EOF

# Rspamd refuses to start if both local.d/classifier-bayes.conf and
# local.d/statistic.conf exist -- it cannot tell which one owns the classifier
# and reports "classifier has no statfiles defined". Everything we need is in
# classifier-bayes.conf above, so remove a statistic.conf left by an earlier
# install of this fork.
rm -f /etc/rspamd/local.d/statistic.conf

# #### Modules we turn off
#
# dkim_signing and the DMARC *reporting/enforcement* paths stay off because
# OpenDKIM and OpenDMARC own those jobs on this box. Rspamd's dkim and dmarc
# *check* modules stay on -- they are what produce the scores.
cat > /etc/rspamd/local.d/dkim_signing.conf <<EOF;
# MeetrMail --- Do not edit / will be overwritten on update.
# OpenDKIM signs outbound mail on this box (see setup/dkim.sh), so Rspamd must
# not also sign it -- two signatures with different canonicalisation is a good
# way to fail verification at the far end.
enabled = false;
EOF

cat > /etc/rspamd/local.d/arc.conf <<EOF;
# MeetrMail --- Do not edit / will be overwritten on update.
# ARC sealing is only meaningful for a forwarder. This box is not one.
sign_inbound = false;
EOF

# clickhouse/elastic exporters and the neural module are off by default; leave
# them that way. They cost memory that a 4GB box does not have spare.
cat > /etc/rspamd/local.d/neural.conf <<EOF;
# MeetrMail --- Do not edit / will be overwritten on update.
enabled = false;
EOF

# #### Sandbox adjustments
#
# In sandbox mode the box has no working path to the internet reputation
# services, so the modules that depend on them would log a DNS timeout for
# every message and add several seconds of latency to every delivery. Turn them
# off so that a sandbox install behaves predictably. Everything that can be
# tested locally -- greylisting, Bayes, the regex rules, SPF/DKIM/DMARC
# verification against the box's own DNS -- stays on.
if is_sandbox; then
	sandbox_skip "Rspamd internet reputation modules (fuzzy_check, RBLs, SURBL, URL reputation)"
	for m in fuzzy_check rbl surbl phishing url_reputation reputation; do
		cat > "/etc/rspamd/local.d/$m.conf" <<EOF;
# MeetrMail --- Do not edit / will be overwritten on update.
# Disabled because this box is in sandbox mode and cannot reach the reputation
# services this module queries. Re-running setup outside sandbox mode, or
# 'meetrmail-mode live', removes this file.
enabled = false;
EOF
	done
else
	# Not in sandbox mode: make sure a previous sandbox install's overrides are
	# gone, so that going live actually turns these back on.
	for m in fuzzy_check rbl surbl phishing url_reputation reputation; do
		if [ -f "/etc/rspamd/local.d/$m.conf" ] && grep -q "sandbox mode" "/etc/rspamd/local.d/$m.conf"; then
			rm -f "/etc/rspamd/local.d/$m.conf"
		fi
	done
fi

# ### Learning from the user
#
# Moving a message into the Spam folder should teach the filter that it was
# spam, and moving one out should teach it that it was not.
#
# v76 did this with dovecot-antispam, a plugin that has had no upstream release
# since 2017. Dovecot's own IMAPSieve does the same job and is maintained: it
# runs a sieve script when a message is copied into or out of a named mailbox,
# and sieve_extprograms lets that script pipe the message to a command.

cat > /etc/dovecot/conf.d/99-local-rspamd.conf <<EOF;
# MeetrMail --- Do not edit / will be overwritten on update.
plugin {
  sieve_plugins = sieve_imapsieve sieve_extprograms

  # Message copied INTO Spam --> it is spam.
  #
  # COPY covers a client moving a message (IMAP MOVE, and the COPY+delete that
  # older clients do). APPEND covers a client that uploads the message into the
  # folder instead, which some do. Sieve's own delivery of spam into this folder
  # goes through LMTP, not IMAP, so it does not trigger either and cannot feed
  # the classifier its own output.
  imapsieve_mailbox1_name = Spam
  imapsieve_mailbox1_causes = COPY,APPEND
  imapsieve_mailbox1_before = file:/etc/dovecot/sieve/learn-spam.sieve

  # Message copied OUT of Spam into anywhere else --> it is not spam.
  imapsieve_mailbox2_name = *
  imapsieve_mailbox2_from = Spam
  imapsieve_mailbox2_causes = COPY
  imapsieve_mailbox2_before = file:/etc/dovecot/sieve/learn-ham.sieve

  sieve_pipe_bin_dir = /usr/local/lib/dovecot/sieve-pipe
  sieve_global_extensions = +vnd.dovecot.pipe +vnd.dovecot.environment
}
EOF

mkdir -p /etc/dovecot/sieve /usr/local/lib/dovecot/sieve-pipe

cat > /etc/dovecot/sieve/learn-spam.sieve <<EOF;
require ["vnd.dovecot.pipe", "copy", "imapsieve"];
pipe :copy "rspamd-learn-spam.sh";
EOF

cat > /etc/dovecot/sieve/learn-ham.sieve <<EOF;
require ["vnd.dovecot.pipe", "copy", "imapsieve"];
pipe :copy "rspamd-learn-ham.sh";
EOF

# rspamc talks to the controller worker, which needs the enable_password for
# learning. Read it from the file rather than baking it into the script so that
# regenerating the password does not require regenerating these.
for kind in spam ham; do
	cat > "/usr/local/lib/dovecot/sieve-pipe/rspamd-learn-$kind.sh" <<EOF;
#!/bin/bash
# MeetrMail --- Do not edit / will be overwritten on update.
# Called by Dovecot's IMAPSieve when a message is moved into or out of the Spam
# folder. Reads the message on stdin.
exec /usr/bin/rspamc -h 127.0.0.1:11334 \\
	-P "\\$(cat $STORAGE_ROOT/mail/rspamd/controller_password.txt)" \\
	learn_$kind
EOF
	chmod 755 "/usr/local/lib/dovecot/sieve-pipe/rspamd-learn-$kind.sh"
done

# Compile the sieve scripts now.
#
# Dovecot would compile them on first use, but it runs IMAPSieve as the mail
# user, which cannot write a .svbin into root-owned /etc/dovecot/sieve -- so it
# would recompile on every single message move.
#
# The plugins and extensions have to be named explicitly. They are set in
# /etc/dovecot/conf.d/99-local-rspamd.conf and `doveconf -n` shows them, but
# sievec reads only a subset of the configuration when run standalone and so
# does not pick up sieve_plugins or sieve_global_extensions from it.
sievec -P sieve_imapsieve -P sieve_extprograms \
	-x "+vnd.dovecot.pipe +vnd.dovecot.environment" \
	/etc/dovecot/sieve/learn-spam.sieve
sievec -P sieve_imapsieve -P sieve_extprograms \
	-x "+vnd.dovecot.pipe +vnd.dovecot.environment" \
	/etc/dovecot/sieve/learn-ham.sieve

# The mail user runs the IMAPSieve learning scripts, so it has to be able to
# read the controller password. Note this is deliberately not `chgrp -R` on the
# parent: that would take the redis data directory away from the redis user, and
# Redis would then fail to start on the next reboot -- while Rspamd carried on
# running without it, silently losing the Bayes classifier, greylisting and
# fuzzy storage. The directory's own permissions are set further up.
chgrp mail "$STORAGE_ROOT/mail/rspamd/controller_password.txt"
chmod 640 "$STORAGE_ROOT/mail/rspamd/controller_password.txt"

# ### Remove the v76 spam stack
#
# Leaving spampd installed would leave a daemon listening on :10025 that nothing
# delivers to any more, and leaving dovecot-antispam's config in place would
# make Dovecot fail to start now that the plugin is gone.
to_purge=""
for pkg in spampd spamassassin dovecot-antispam razor pyzor postgrey; do
	if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "^install ok installed"; then
		to_purge="$to_purge $pkg"
	fi
done
if [ -n "$to_purge" ]; then
	echo "Removing the v76 spam stack that Rspamd replaces:$to_purge"
	# shellcheck disable=SC2086  # deliberate word splitting: a list of packages
	hide_output apt-get -y purge $to_purge || /bin/true
	hide_output apt-get -y autoremove || /bin/true
fi
# postgrey's greylisting database lived under STORAGE_ROOT. Rspamd keeps
# greylist records in Redis instead, so this is dead weight -- but leave it on
# disk rather than deleting it, in case somebody wants to look at it.
rm -f /etc/cron.daily/mailinabox-postgrey-whitelist
rm -f /etc/dovecot/conf.d/99-local-spampd.conf
rm -f /etc/spamassassin/mailinabox_spf_dmarc.cf
rm -f /usr/local/bin/sa-learn-pipe.sh

# Remove the antispam plugin from Dovecot's plugin lists if a previous install
# put it there.
sed -i "s/ antispam//" /etc/dovecot/conf.d/20-imap.conf
sed -i "s/ antispam//" /etc/dovecot/conf.d/20-pop3.conf
tools/editconf.py /etc/dovecot/conf.d/10-mail.conf -e mail_access_groups=

# ### Postfix wiring
#
# Add Rspamd to the milter chain, after OpenDKIM and OpenDMARC so that it sees
# the Authentication-Results header they add. See setup/dkim.sh, which sets the
# first two; this must list all three because smtpd_milters is a single value.
#
# Note that the submission listeners (465/587) are left alone: they run with
# only the OpenDKIM milter (see setup/mail-postfix.sh), so authenticated users'
# outbound mail is signed but never greylisted or spam-scored.
tools/editconf.py /etc/postfix/main.cf \
	"smtpd_milters=inet:127.0.0.1:8891 inet:127.0.0.1:8893 inet:127.0.0.1:11332" \
	non_smtpd_milters=\$smtpd_milters \
	milter_default_action=accept \
	"milter_mail_macros=i {mail_addr} {client_addr} {client_name} {auth_authen}"

# Deliver straight to Dovecot's LMTP listener. v76 pointed this at spampd on
# :10025, which then relayed to Dovecot on :10026. Rspamd is a milter, so it is
# no longer in the delivery path and that hop disappears.
tools/editconf.py /etc/postfix/main.cf "virtual_transport=lmtp:[127.0.0.1]:10026"

# ### Start it up
#
# No firewall rule is needed: every Rspamd socket is bound to loopback. The
# controller's web UI is reached over an SSH tunnel, not over the network.
systemctl enable rspamd > /dev/null 2>&1
restart_service rspamd
restart_service postfix
restart_service dovecot
