#!/bin/bash
#########################################################
# This script is intended to be run like this:
#
#   curl -L https://raw.githubusercontent.com/OWNER/REPO/BRANCH/setup/bootstrap.sh | sudo -E bash
#
# To install in sandbox mode, for local testing:
#
#   curl -L .../setup/bootstrap.sh | sudo -E MEETRMAIL_SANDBOX=1 bash
#
# Note the -E on sudo: without it, sudo drops the environment and any
# MEETRMAIL_SANDBOX, TAG or SOURCE setting is lost.
#########################################################

# Where to get the code. Override either of these in the environment to install
# a different fork or a different branch/tag:
#
#   SOURCE=https://github.com/you/meetrmail TAG=my-branch
#
# If you have forked this repository, change SOURCE_DEFAULT to point at your
# fork so that the one-line install command above works for you.
SOURCE_DEFAULT=https://github.com/meetrmail/meetrmail
TAG_DEFAULT=noble-php83-py312-rspamd

SOURCE=${SOURCE:-$SOURCE_DEFAULT}
TAG=${TAG:-$TAG_DEFAULT}

# Are we running as root?
if [[ $EUID -ne 0 ]]; then
	echo "This script must be run as root. Did you leave out sudo?"
	exit 1
fi

# Check the OS before doing anything else, so that running this on the wrong
# release fails immediately with a useful message rather than after a clone.
#
# This is an exact match on purpose. This fork targets Ubuntu 24.04 and has not
# been tested anywhere else; a box that half-works is worse than one that
# refuses to install.
UBUNTU_VERSION=$( lsb_release -d 2>/dev/null | sed 's/.*:\s*//' | sed 's/\([0-9]*\.[0-9]*\)\.[0-9]/\1/' )
if [ "$UBUNTU_VERSION" != "Ubuntu 24.04 LTS" ]; then
	echo "This version of MeetrMail can only be installed on Ubuntu 24.04 LTS."
	echo "This machine is running: ${UBUNTU_VERSION:-an unrecognised distribution}"
	echo
	echo "For Ubuntu 22.04, use upstream Mail-in-a-Box v76:"
	echo "  curl -s https://mailinabox.email/setup.sh | sudo -E bash"
	echo
	exit 1
fi

# Clone the repository if it isn't already here.
if [ ! -d "$HOME/meetrmail" ]; then
	if [ ! -f /usr/bin/git ]; then
		echo "Installing git . . ."
		apt-get -q -q update
		DEBIAN_FRONTEND=noninteractive apt-get -q -q install -y git < /dev/null
		echo
	fi

	echo "Downloading MeetrMail $TAG . . ."
	if ! git clone -b "$TAG" --depth 1 "$SOURCE" "$HOME/meetrmail" < /dev/null 2> /dev/null; then
		echo "Could not download $TAG from $SOURCE."
		echo "Check that the repository and branch exist and are readable."
		exit 1
	fi
	echo
fi

cd "$HOME/meetrmail" || exit

# Update it, unless the working tree has local changes -- in which case the
# person running this is developing on the box and we should not clobber them.
if [ "$TAG" != "$(git describe --always 2>/dev/null)" ]; then
	if [ -n "$(git status --porcelain)" ]; then
		echo "$PWD has uncommitted changes, so it will not be updated to $TAG."
		echo "Setup will run against the working tree as it is."
		echo
	else
		echo "Updating MeetrMail to $TAG . . ."
		git fetch --depth 1 --force --prune origin "$TAG" 2>/dev/null \
			|| git fetch --depth 1 --force --prune origin tag "$TAG"
		if ! git checkout -q "FETCH_HEAD"; then
			echo "Update failed. Did you modify something in $PWD?"
			exit 1
		fi
		echo
	fi
fi

# Start setup script. MEETRMAIL_SANDBOX is passed through from the environment.
setup/start.sh
