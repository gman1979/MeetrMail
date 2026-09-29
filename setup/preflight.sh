#!/bin/bash
# Are we running as root?
if [[ $EUID -ne 0 ]]; then
	echo "This script must be run as root. Please re-run like this:"
	echo
	echo "sudo $0"
	echo
	exit 1
fi

# Check that we are running on Ubuntu 24.04 LTS (or 24.04.xx).
# Pull in the variables defined in /etc/os-release but in a
# namespace to avoid polluting our variables.
#
# This is deliberately an exact whitelist rather than a ">=" comparison. We
# would rather the box refuse to install on an untested release than half-work
# on one. When 26.04 is ported, add it here explicitly.
source <(sed s/^/OS_RELEASE_/ /etc/os-release)
if [ "${OS_RELEASE_ID:-}" != "ubuntu" ] || [ "${OS_RELEASE_VERSION_ID:-}" != "24.04" ]; then
	echo "MeetrMail only supports being installed on Ubuntu 24.04, sorry. You are running:"
	echo
	echo "${OS_RELEASE_ID:-"Unknown linux distribution"} ${OS_RELEASE_VERSION_ID:-}"
	echo
	echo "We can't write scripts that run on every possible setup, sorry."
	exit 1
fi

# Check that we have enough memory.
#
# /proc/meminfo reports free memory in kibibytes. Our baseline will be 512 MB,
# which is 500000 kibibytes.
#
# We will display a warning if the memory is below 768 MB which is 750000 kibibytes
#
# Skip the check if we appear to be running inside of Vagrant or in sandbox
# mode, because those are really just for testing.
TOTAL_PHYSICAL_MEM=$(head -n 1 /proc/meminfo | awk '{print $2}')
if [ "$TOTAL_PHYSICAL_MEM" -lt 490000 ]; then
if [ ! -d /vagrant ] && ! is_sandbox; then
	TOTAL_PHYSICAL_MEM=$(( TOTAL_PHYSICAL_MEM * 1024 / 1000 / 1000 ))
	echo "Your MeetrMail needs more memory (RAM) to function properly."
	echo "Please provision a machine with at least 512 MB, 1 GB recommended."
	echo "This machine has $TOTAL_PHYSICAL_MEM MB memory."
	exit
fi
fi
if [ "$TOTAL_PHYSICAL_MEM" -lt 750000 ]; then
	echo "WARNING: Your MeetrMail has less than 768 MB of memory."
	echo "         It might run unreliably when under heavy load."
fi

# Check that tempfs is mounted with exec
MOUNTED_TMP_AS_NO_EXEC=$(grep "/tmp.*noexec" /proc/mounts || /bin/true)
if [ -n "$MOUNTED_TMP_AS_NO_EXEC" ]; then
	echo "MeetrMail has to have exec rights on /tmp, please mount /tmp with exec"
	exit
fi

# Check that no .wgetrc exists
if [ -e ~/.wgetrc ]; then
	echo "MeetrMail expects no overrides to wget defaults, ~/.wgetrc exists"
	exit
fi

# Check that we are running on x86_64 or i686 architecture, which are the only
# ones we support / test.
ARCHITECTURE=$(uname -m)
if [ "$ARCHITECTURE" != "x86_64" ] && [ "$ARCHITECTURE" != "i686" ]; then
	echo
	echo "WARNING:"
	echo "MeetrMail has only been tested on x86_64 and i686 platform"
	echo "architectures. Your architecture, $ARCHITECTURE, may not work."
	echo "You are on your own."
	echo
fi

# ### Sandbox preflight
#
# Report what sandbox mode is about to relax, so there is never any doubt about
# whether the box you are looking at is a test box or a real one.
if is_sandbox; then
	echo
	echo "================================================================"
	echo " SANDBOX MODE"
	echo
	echo " This box is being installed for local testing. It will NOT be"
	echo " able to send or receive mail from the public internet, and its"
	echo " TLS certificate will be self-signed."
	echo
	echo " Run 'sudo meetrmail-mode live' when you are ready to go live."
	echo "================================================================"
	echo
fi
