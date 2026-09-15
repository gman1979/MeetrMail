#!/bin/bash
# uv --- the Python toolchain for the management daemon
# -----------------------------------------------------
#
# This runs very early in setup, before setup/questions.sh, because the
# question flow itself needs a Python with email_validator available and we do
# not want to install that into the system interpreter.

source setup/functions.sh # load our functions

# This is the first script in setup that downloads anything or runs any of the
# Python helpers, so make sure the things it needs exist. A minimal Ubuntu
# image has none of them.
#
# python3 is the system interpreter, needed because tools/editconf.py and
# setup/migrate.py carry a #!/usr/bin/python3 shebang and are used throughout
# setup, long before the management daemon's own environment exists. We only
# ever *run* it -- nothing is ever pip-installed into it, which is what keeps
# noble's PEP 668 marker irrelevant here.
if [ ! -x /usr/bin/wget ] || [ ! -x /usr/bin/xz ] || [ ! -x /usr/bin/python3 ]; then
	echo "Installing packages needed to bootstrap setup..."
	hide_output apt-get update
	apt_get_quiet install wget ca-certificates xz-utils python3
fi

# ### Install uv (Python toolchain manager)
#
# The management daemon runs on its own Python, installed and managed by `uv`,
# rather than on the system interpreter. Two reasons:
#
#  1. Noble's pip 24.0 enforces PEP 668's EXTERNALLY-MANAGED marker, so the
#     bare `pip3 install` calls v76 used now abort outright. Rather than
#     defeating that marker with --break-system-packages, we simply stop
#     touching the system interpreter at all.
#
#  2. uv vendors its own CPython, so the daemon's Python version stops being
#     "whatever this Ubuntu release happened to ship". That removes this entire
#     class of breakage from the next port as well.
#
# uv is pinned to an exact version and verified by SHA-256, matching the
# wget_verify discipline used for every other out-of-archive download here.

UV_VERSION=0.12.6
case "$(uname -m)" in
	x86_64)  UV_TARGET=x86_64-unknown-linux-gnu;  UV_SHA256=8681d8921e7d520fb368991dcf5f9c1905b80f5bf2a265a0ed085c8d8e342477 ;;
	aarch64) UV_TARGET=aarch64-unknown-linux-gnu; UV_SHA256=d58030acd26159499ac82f32da12d1b3c12a3a1bfc414232d9082070c03e128d ;;
	*)
		echo "No pinned uv build for architecture $(uname -m). Setup cannot continue."
		exit 1
		;;
esac

if [ ! -x /usr/local/bin/uv ] || [ "$(/usr/local/bin/uv --version 2>/dev/null | awk '{print $2}')" != "$UV_VERSION" ]; then
	echo "Installing uv $UV_VERSION..."
	wget_verify_sha256 \
		"https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-$UV_TARGET.tar.gz" \
		"$UV_SHA256" \
		/tmp/uv.tar.gz
	rm -rf /tmp/uv-unpack && mkdir -p /tmp/uv-unpack
	tar -xzf /tmp/uv.tar.gz -C /tmp/uv-unpack --strip-components=1
	install -m 755 /tmp/uv-unpack/uv /usr/local/bin/uv
	install -m 755 /tmp/uv-unpack/uvx /usr/local/bin/uvx
	rm -rf /tmp/uv.tar.gz /tmp/uv-unpack
fi


# ### Pre-fetch the Python interpreter
#
# Download the CPython build now, rather than at first use, so that a network
# problem surfaces here with a clear message instead of halfway through
# configuring the management daemon.
if ! hide_output uv python install "$PYTHON_VER"; then
	echo "Could not download the Python $PYTHON_VER interpreter. Check the machine's"
	echo "internet connection and try again."
	exit 1
fi

# ### A Python for setup-time scripts
#
# setup/questions.sh validates the administrator's email address by running
# management/mailconfig.py, which needs email_validator and idna. That happens
# long before the management daemon's own environment exists.
#
# v76 solved this with `pip3 install email_validator` against the system
# interpreter. On noble that fails outright: pip 24.0 honours PEP 668's
# EXTERNALLY-MANAGED marker and refuses. We use an ephemeral, cached uv
# environment instead -- see setup_python() in setup/functions.sh.
