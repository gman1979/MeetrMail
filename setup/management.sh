#!/bin/bash

source setup/functions.sh
source /etc/meetrmail.conf # load global vars

echo "Installing MeetrMail system management daemon..."

# DEPENDENCIES

# duplicity is used to make backups of user data.
#
# certbot installs EFF's certbot which we use to
# provision free TLS certificates.
apt_install duplicity certbot rsync

# ### The management daemon's Python environment
#
# Built by uv from management/pyproject.toml and management/uv.lock, on a
# CPython that uv downloads itself (see setup/uv.sh). The system interpreter is
# never modified, so noble's PEP 668 EXTERNALLY-MANAGED marker is irrelevant,
# and uv.lock makes the install reproducible -- which the `pip install
# --upgrade` that v76 used was not.
#
# --frozen means "install exactly what uv.lock says, and fail if pyproject.toml
# has drifted from it" rather than silently re-resolving on the box.
inst_dir=/usr/local/lib/meetrmail
mkdir -p $inst_dir
venv=$inst_dir/env

echo "Installing the management daemon's Python environment..."
(
	cd management || exit 1
	export HOME="${HOME:-/root}"
	export UV_PROJECT_ENVIRONMENT="$venv"
	hide_output uv sync --frozen --no-dev
)

# ### duplicity's backup backends
#
# b2sdk is used for Backblaze B2 backups and boto3 for Amazon S3. These have to
# be importable by *duplicity's* interpreter, which is the system python3 (from
# the Ubuntu duplicity package), not the management daemon's venv.
#
# So give duplicity its own uv-managed environment on the system interpreter's
# version and point duplicity at it through a wrapper on PATH. This keeps the
# system site-packages untouched -- no --break-system-packages anywhere.
dup_venv=$inst_dir/duplicity-env
if [ ! -d "$dup_venv" ]; then
	# Build this against /usr/bin/python3 specifically, not against a version
	# number. A version number would let uv satisfy it with one of its own
	# managed CPython builds, and packages installed there are not guaranteed to
	# be importable by the system interpreter that actually runs duplicity.
	hide_output uv venv --python /usr/bin/python3 --system-site-packages "$dup_venv"
fi
hide_output uv pip install --python "$dup_venv/bin/python" --upgrade b2sdk boto3

# Fail loudly here rather than at 3am when the first backup runs.
if ! PYTHONPATH="$(echo "$dup_venv"/lib/python*/site-packages)" \
	/usr/bin/python3 -c "import boto3, b2sdk" 2>/dev/null; then
	echo "The backup backends (boto3, b2sdk) are not importable by the interpreter that"
	echo "runs duplicity. Backups to S3 or Backblaze B2 would fail."
	exit 1
fi

# management/backup.py invokes /usr/bin/duplicity by absolute path and builds
# its environment in get_duplicity_env_vars(), which puts this directory on
# duplicity's PYTHONPATH. Record the path here so the two stay in step.
echo "$dup_venv" > $inst_dir/duplicity-env-path

# CONFIGURATION

# Create a backup directory and a random key for encrypting backups.
mkdir -p "$STORAGE_ROOT/backup"
if [ ! -f "$STORAGE_ROOT/backup/secret_key.txt" ]; then
	(umask 077; openssl rand -base64 2048 > "$STORAGE_ROOT/backup/secret_key.txt")
fi


# Download jQuery and Bootstrap local files

# Make sure we have the directory to save to.
assets_dir=$inst_dir/vendor/assets
rm -rf $assets_dir
mkdir -p $assets_dir

# jQuery CDN URL
jquery_version=2.2.4
jquery_url=https://code.jquery.com

# Get jQuery
wget_verify $jquery_url/jquery-$jquery_version.min.js 69bb69e25ca7d5ef0935317584e6153f3fd9a88c $assets_dir/jquery.min.js

# Bootstrap CDN URL
bootstrap_version=3.4.1
bootstrap_url=https://github.com/twbs/bootstrap/releases/download/v$bootstrap_version/bootstrap-$bootstrap_version-dist.zip

# Get Bootstrap
wget_verify $bootstrap_url 0bb64c67c2552014d48ab4db81c2e8c01781f580 /tmp/bootstrap.zip
unzip -q /tmp/bootstrap.zip -d $assets_dir
mv $assets_dir/bootstrap-$bootstrap_version-dist $assets_dir/bootstrap
rm -f /tmp/bootstrap.zip

# Create an init script to start the management daemon and keep it
# running after a reboot.
# Set a long timeout since some commands take a while to run, matching
# the timeout we set for PHP (fastcgi_read_timeout in the nginx confs).
# Note: Authentication currently breaks with more than 1 gunicorn worker.
cat > $inst_dir/start <<EOF;
#!/bin/bash
# Set character encoding flags to ensure that any non-ASCII don't cause problems.
export LANGUAGE=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_TYPE=en_US.UTF-8

mkdir -p /var/lib/meetrmail
tr -cd '[:xdigit:]' < /dev/urandom | head -c 32 > /var/lib/meetrmail/api.key
chmod 640 /var/lib/meetrmail/api.key

source $venv/bin/activate
export PYTHONPATH=$PWD/management
exec $venv/bin/gunicorn -b 127.0.0.1:10222 -w 1 --timeout 630 wsgi:app
EOF
chmod +x $inst_dir/start
# Install the unit file. Older versions of MeetrMail made
# /lib/systemd/system/meetrmail.service a symlink, so remove the target first.
cp --remove-destination conf/meetrmail.service /lib/systemd/system/meetrmail.service

# No `systemctl link` here. That command is for unit files *outside* the systemd
# search path, and /lib/systemd/system is inside it -- so linking just creates
# /etc/systemd/system/meetrmail.service as a symlink, and systemd 255 (noble) then
# refuses to enable the unit at all: "Refusing to operate on alias name or
# linked unit file". Remove any such symlink left by an earlier install.
if [ -L /etc/systemd/system/meetrmail.service ]; then
	rm -f /etc/systemd/system/meetrmail.service
fi
hide_output systemctl daemon-reload
hide_output systemctl enable meetrmail.service

# Perform nightly tasks at 3am in system time: take a backup, run
# status checks and email the administrator any changes.

minute=$((RANDOM % 60))  # avoid overloading meetrmail.net
cat > /etc/cron.d/meetrmail-nightly << EOF;
# MeetrMail --- Do not edit / will be overwritten on update.
# Run nightly tasks: backup, status checks.
$minute 1 * * *	root	(cd $PWD && management/daily_tasks.sh)
EOF

# Start the management server.
restart_service meetrmail
