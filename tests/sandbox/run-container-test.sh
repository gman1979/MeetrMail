#!/bin/bash
# Run a full sandbox install of this MeetrMail in a throwaway Ubuntu 24.04
# container, then run the self-test suite inside it.
#
#   tests/sandbox/run-container-test.sh              build, install, test, keep the container
#   tests/sandbox/run-container-test.sh --rm         ...and remove it afterwards
#   tests/sandbox/run-container-test.sh --shell      drop into a shell in an existing container
#   tests/sandbox/run-container-test.sh --clean      remove the container and image
#
# This does not need root on the host: it runs rootless under podman. It also
# does not need port 25 to be open, real DNS, or a real domain -- that is the
# entire point of sandbox mode.
#
# What it proves: that the installer completes on a real Ubuntu 24.04 with real
# packages, that every service starts, and that mail flows end to end through
# Postfix, the milter chain, Rspamd, Dovecot and sieve.
#
# What it cannot prove: anything that depends on the outside world's opinion of
# your box. See the go-live checklist printed at the end of the self-test.

set -euo pipefail

IMAGE=meetrmail-sandbox-test
NAME=meetrmail-sandbox
HOSTNAME_IN_BOX=box.sandbox.test
SRC=$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)

if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; N=$'\e[0m'; else B=""; G=""; R=""; N=""; fi
step() { echo; echo "${B}==> $*${N}"; }

command -v podman > /dev/null || { echo "podman is not installed. Try: sudo apt-get install -y podman uidmap slirp4netns"; exit 1; }

case "${1:-}" in
	--clean)
		podman rm -f "$NAME" 2>/dev/null || true
		podman rmi -f "$IMAGE" 2>/dev/null || true
		echo "Removed the test container and image."
		exit 0
		;;
	--shell)
		exec podman exec -it "$NAME" bash -c "cd /meetrmail && exec bash"
		;;
esac

REMOVE_AFTER=0
[ "${1:-}" = "--rm" ] && REMOVE_AFTER=1

step "Building the Ubuntu 24.04 test image"
podman build -t "$IMAGE" -f "$SRC/tests/sandbox/Containerfile" "$SRC/tests/sandbox"

step "Starting a fresh container"
podman rm -f "$NAME" 2>/dev/null || true

# Notes on the flags:
#  --systemd=always     run systemd as PID 1 so services can actually start
#  --cap-add            postfix/dovecot/nsd need to set up their own privilege
#                       separation, and nsd binds a privileged port
#  -v $SRC:/meetrmail  the source tree under test, mounted rather than copied,
#                       so an edit-and-retest cycle doesn't rebuild the image.
#                       :Z relabels for SELinux hosts; harmless elsewhere.
#  --tmpfs /run,/tmp    systemd wants these writable and not shared
podman run -d --name "$NAME" \
	--hostname "$HOSTNAME_IN_BOX" \
	--systemd=always \
	--cap-add SYS_ADMIN,NET_ADMIN,NET_BIND_SERVICE,SYS_PTRACE,CHOWN,DAC_OVERRIDE,SETUID,SETGID,FOWNER,KILL,SYS_CHROOT,AUDIT_WRITE \
	--tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
	-v "$SRC:/meetrmail:Z" \
	"$IMAGE" > /dev/null

step "Waiting for systemd to come up"
for _ in $(seq 1 60); do
	if podman exec "$NAME" systemctl is-system-running 2>/dev/null | grep -qE "running|degraded"; then break; fi
	sleep 1
done
podman exec "$NAME" systemctl is-system-running || true

step "Running the MeetrMail installer in sandbox mode"
echo "    hostname: $HOSTNAME_IN_BOX"
echo "    This installs the real packages from the real archives, so it takes a while."
echo

# NONINTERACTIVE and the PRIMARY_HOSTNAME/PUBLIC_IP variables are what let
# setup run without a TTY. MEETRMAIL_SANDBOX=1 does the rest.
set +e
podman exec \
	-e MEETRMAIL_SANDBOX=1 \
	-e NONINTERACTIVE=1 \
	-e PRIMARY_HOSTNAME="$HOSTNAME_IN_BOX" \
	-e PUBLIC_IP=auto \
	-e PUBLIC_IPV6= \
	-e SKIP_NETWORK_CHECKS=1 \
	-e DISABLE_FIREWALL=1 \
	"$NAME" bash -c "cd /meetrmail && setup/start.sh"
INSTALL_RC=$?
set -e

if [ $INSTALL_RC -ne 0 ]; then
	echo
	echo "${R}The installer failed (exit $INSTALL_RC).${N}"
	echo "The container is still running so you can look around:"
	echo
	echo "  tests/sandbox/run-container-test.sh --shell"
	echo "  podman exec $NAME journalctl -xe --no-pager | tail -50"
	echo
	exit $INSTALL_RC
fi

step "Running the self-test suite inside the box"
set +e
podman exec "$NAME" bash -c "cd /meetrmail && tests/sandbox/selftest.sh"
TEST_RC=$?
set -e

echo
if [ $TEST_RC -eq 0 ]; then
	echo "${G}${B}The sandbox install passed.${N}"
else
	echo "${R}${B}The self-test reported failures (exit $TEST_RC).${N}"
fi
echo
echo "Poke around with:   tests/sandbox/run-container-test.sh --shell"
echo "Mail log:           podman exec $NAME tail -f /var/log/mail.log"
echo "Clean up:           tests/sandbox/run-container-test.sh --clean"
echo

if [ $REMOVE_AFTER -eq 1 ]; then
	podman rm -f "$NAME" > /dev/null
	echo "Container removed."
fi

exit $TEST_RC
