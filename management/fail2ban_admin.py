#!/usr/local/lib/meetrmail/env/bin/python

# Reads fail2ban's state through fail2ban-client for the control panel's
# Fail2ban page, and lets the admin ban and unban addresses by hand.

import ipaddress
import re

import utils


def _client(args):
	# Returns (returncode, output). All arguments are passed as a list, never
	# through a shell.
	return utils.shell('check_output', ["/usr/bin/fail2ban-client", *args], capture_stderr=True, trap=True)


def _field(text, label):
	m = re.search(r"^[\s|`\-]*" + re.escape(label) + r":\s*(.*)$", text, re.MULTILINE)
	return m.group(1).strip() if m else ""


def _int(text):
	try:
		return int(text)
	except ValueError:
		return 0


def get_jail_names():
	code, out = _client(["status"])
	if code != 0:
		msg = "fail2ban is not running or could not be reached: " + out.strip()
		raise ValueError(msg)
	return sorted(j.strip() for j in _field(out, "Jail list").split(",") if j.strip())


def get_fail2ban_status():
	# Returns { jails: [ { name, currently_failed, total_failed, currently_banned,
	#                      total_banned, banned_ips: [...] }, ... ] }
	jails = []
	for name in get_jail_names():
		code, out = _client(["status", name])
		if code != 0:
			continue # the jail may have gone away between the two calls
		jails.append({
			"name": name,
			"currently_failed": _int(_field(out, "Currently failed")),
			"total_failed": _int(_field(out, "Total failed")),
			"currently_banned": _int(_field(out, "Currently banned")),
			"total_banned": _int(_field(out, "Total banned")),
			"banned_ips": sorted(_field(out, "Banned IP list").split(), key=_ip_sort_key),
		})
	return { "jails": jails }


def _ip_sort_key(ip):
	try:
		a = ipaddress.ip_address(ip)
		return (a.version, int(a))
	except ValueError:
		return (0, 0)


def _validate(jail, ip):
	# The jail must be one fail2ban reports, and the IP must parse as an address.
	# This keeps arbitrary text away from fail2ban-client.
	if jail not in get_jail_names():
		msg = f"Unknown jail: {jail}"
		raise ValueError(msg)
	try:
		return str(ipaddress.ip_address(ip.strip()))
	except ValueError:
		msg = "That is not a valid IP address."
		raise ValueError(msg) from None


def unban_ip(jail, ip):
	ip = _validate(jail, ip)
	code, out = _client(["set", jail, "unbanip", ip])
	if code != 0:
		raise ValueError(out.strip() or "Could not unban that address.")
	return f"Unbanned {ip} from {jail}."


def ban_ip(jail, ip):
	ip = _validate(jail, ip)
	code, out = _client(["set", jail, "banip", ip])
	if code != 0:
		raise ValueError(out.strip() or "Could not ban that address.")
	return f"Banned {ip} in {jail}."
