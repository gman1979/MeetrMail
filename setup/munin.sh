#!/bin/bash
# Munin: resource monitoring tool
#################################################

source setup/functions.sh # load our functions
source /etc/meetrmail.conf # load global vars

# install Munin
echo "Installing Munin (system monitoring)..."
apt_install munin munin-node libcgi-fast-perl
# libcgi-fast-perl is needed by /usr/lib/munin/cgi/munin-cgi-graph

# edit config
cat > /etc/munin/munin.conf <<EOF;
dbdir /var/lib/munin
htmldir /var/cache/munin/www
logdir /var/log/munin
rundir /var/run/munin
tmpldir /etc/munin/templates

includedir /etc/munin/munin-conf.d

# path dynazoom uses for requests
cgiurl_graph /admin/munin/cgi-graph

# a simple host tree
[$PRIMARY_HOSTNAME]
address 127.0.0.1

# send alerts to the following address
contacts admin
contact.admin.command mail -s "Munin notification \${var:host}" administrator@$PRIMARY_HOSTNAME
contact.admin.always_send warning critical
EOF

# The Debian installer touches these files and chowns them to www-data:adm for use with spawn-fcgi
chown munin /var/log/munin/munin-cgi-html.log
chown munin /var/log/munin/munin-cgi-graph.log

# ensure munin-node knows the name of this machine
# and reduce logging level to warning
#
# `host 127.0.0.1` binds munin-node to loopback. Debian's default is `host *`,
# which listens on every interface and relies on the `allow` ACL further down
# the file to turn away anyone who isn't loopback. The munin master runs on this
# same box and connects to 127.0.0.1 (see the munin.conf written above), so
# there is nothing to gain from listening publicly, and an app-level ACL in
# front of an open socket is strictly weaker than not opening it.
tools/editconf.py /etc/munin/munin-node.conf -s \
	host_name="$PRIMARY_HOSTNAME" \
	host=127.0.0.1 \
	log_level=1

# Update the activated plugins through munin's autoconfiguration.
munin-node-configure --shell --remove-also 2>/dev/null | sh || /bin/true

# Deactivate monitoring of NTP peers. Not sure why anyone would want to monitor a NTP peer. The addresses seem to change
# (which is taken care of my munin-node-configure, but only when we re-run it.)
find /etc/munin/plugins/ -lname /usr/share/munin/plugins/ntp_ -print0 | xargs -0 /bin/rm -f

# Deactivate monitoring of network interfaces that are not up. Otherwise we can get a lot of empty charts.
for f in $(find /etc/munin/plugins/ \( -lname /usr/share/munin/plugins/if_ -o -lname /usr/share/munin/plugins/if_err_ -o -lname /usr/share/munin/plugins/bonding_err_ \)); do
	IF=$(echo "$f" | sed s/.*_//);
	if ! grep -qFx up "/sys/class/net/$IF/operstate" 2>/dev/null; then
		rm "$f";
	fi;
done

# Create a 'state' directory. Not sure why we need to do this manually.
mkdir -p /var/lib/munin-node/plugin-state/

# Create a systemd service for munin.
ln -sf "$PWD/management/munin_start.sh" /usr/local/lib/meetrmail/munin_start.sh
chmod 0744 /usr/local/lib/meetrmail/munin_start.sh
# Install the unit file. Older versions of MeetrMail made
# /lib/systemd/system/munin.service a symlink, so remove the target first.
cp --remove-destination conf/munin.service /lib/systemd/system/munin.service

# No `systemctl link` here. That command is for unit files *outside* the systemd
# search path, and /lib/systemd/system is inside it -- so linking just creates
# /etc/systemd/system/munin.service as a symlink, and systemd 255 (noble) then
# refuses to enable the unit at all: "Refusing to operate on alias name or
# linked unit file". Remove any such symlink left by an earlier install.
if [ -L /etc/systemd/system/munin.service ]; then
	rm -f /etc/systemd/system/munin.service
fi
hide_output systemctl daemon-reload
hide_output systemctl unmask munin.service
hide_output systemctl enable munin.service

# Restart services.
restart_service munin
restart_service munin-node

# generate initial statistics so the directory isn't empty
# (We get "Pango-WARNING **: error opening config file '/root/.config/pango/pangorc': Permission denied"
# if we don't explicitly set the HOME directory when sudo'ing.)
# We check to see if munin-cron is already running, if it is, there is no need to run it simultaneously
# generating an error.
if [ ! -f /var/run/munin/munin-update.lock ]; then
	sudo -H -u munin munin-cron
fi
