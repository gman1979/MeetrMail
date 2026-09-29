#!/usr/local/lib/meetrmail/env/bin/python

# Spam filtering settings and reports for the control panel's Spam page.
#
# Rspamd is configured from files that setup/rspamd.sh installs. Everything the
# administrator can change here is kept in $STORAGE_ROOT/mail/rspamd/ so that
# re-running setup puts it back rather than resetting it:
#
#   actions.conf         global score thresholds  -> /etc/rspamd/local.d/actions.conf
#   settings.conf        per-recipient thresholds -> /etc/rspamd/local.d/settings.conf
#   lists.json           the allow/block lists
#   *.map                the lists in the form Rspamd's multimap module reads
#   user_thresholds.json per-recipient thresholds as data
#
# Usage:
#   spam.py --digest     print a summary of the last 24 hours of spam filtering

import datetime
import email.header
import email.parser
import email.utils
import ipaddress
import json
import os
import re
import shutil
import sys
import urllib.error
import urllib.request

import utils

DEFAULT_THRESHOLDS = { "greylist": 4.0, "add_header": 6.0, "reject": 15.0 }
THRESHOLD_LABELS = { "greylist": "greylist", "add_header": "add header", "reject": "reject" }
CONTROLLER = "http://127.0.0.1:11334"
LOCAL_D = "/etc/rspamd/local.d"

# The allow/block lists. Each is a list of entries; a sender entry is either a
# full address or a bare domain, and an IP entry is an address or a network.
LIST_KINDS = ("allow_senders", "block_senders", "allow_ips", "block_ips")
DOMAIN_RE = re.compile(r"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")
ADDRESS_RE = re.compile(r"^[a-z0-9._%+'=-]{1,64}@([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")


def rspamd_dir(env):
	return os.path.join(env["STORAGE_ROOT"], "mail/rspamd")


def _write(path, content, mode=0o644):
	# Replace a file atomically so that Rspamd never reads half of it.
	tmp = path + ".tmp"
	with open(tmp, "w", encoding="utf-8") as f:
		f.write(content)
	os.chmod(tmp, mode)
	os.replace(tmp, path)


def _install(env, name):
	# Copy a persisted file into Rspamd's config directory. Only when Rspamd is
	# installed (the directory exists), so this is harmless in a dev checkout.
	if os.path.isdir(LOCAL_D):
		shutil.copyfile(os.path.join(rspamd_dir(env), name), os.path.join(LOCAL_D, name))
		os.chmod(os.path.join(LOCAL_D, name), 0o644)


def _reload_rspamd():
	utils.shell("check_output", ["systemctl", "reload", "rspamd"], capture_stderr=True, trap=True)


# ### Controller (statistics)

def _controller_get(env, path):
	with open(os.path.join(rspamd_dir(env), "controller_password.txt"), encoding="utf-8") as f:
		password = f.read().strip()
	req = urllib.request.Request(CONTROLLER + path, headers={ "Password": password })
	with urllib.request.urlopen(req, timeout=10) as r: # noqa: S310 -- fixed loopback URL
		return json.loads(r.read().decode("utf-8"))


def get_stats(env):
	# Counters since Rspamd last started, and what the Bayes classifier has learned.
	try:
		stat = _controller_get(env, "/stat")
	except (OSError, ValueError, urllib.error.URLError) as e:
		return { "available": False, "error": f"Could not read statistics from Rspamd: {e}" }

	learned = { "spam": 0, "ham": 0 }
	for sf in stat.get("statfiles", []):
		symbol = sf.get("symbol", "")
		if symbol == "BAYES_SPAM": learned["spam"] = sf.get("revision", 0)
		elif symbol == "BAYES_HAM": learned["ham"] = sf.get("revision", 0)

	return {
		"available": True,
		"version": stat.get("version"),
		"uptime": stat.get("uptime"),
		"scanned": stat.get("scanned", 0),
		"learned_messages": stat.get("learned", 0),
		"actions": stat.get("actions", {}),
		"bayes": learned,
	}


# ### Global thresholds

def get_thresholds(env):
	thresholds = dict(DEFAULT_THRESHOLDS)
	try:
		with open(os.path.join(rspamd_dir(env), "actions.conf"), encoding="utf-8") as f:
			text = f.read()
		for key in thresholds:
			m = re.search(r"^\s*" + key + r"\s*=\s*([\d.]+)\s*;", text, re.MULTILINE)
			if m: thresholds[key] = float(m.group(1))
	except (OSError, ValueError):
		pass
	return thresholds


def _validate_thresholds(values):
	out = {}
	for key in DEFAULT_THRESHOLDS:
		try:
			out[key] = round(float(values[key]), 1)
		except (KeyError, TypeError, ValueError):
			msg = f"The {THRESHOLD_LABELS[key]} threshold must be a number."
			raise ValueError(msg) from None
		if not (0 <= out[key] <= 100):
			msg = f"The {THRESHOLD_LABELS[key]} threshold must be between 0 and 100."
			raise ValueError(msg)
	if not (out["greylist"] <= out["add_header"] <= out["reject"]):
		msg = "Thresholds must satisfy greylist <= add header <= reject."
		raise ValueError(msg)
	return out


def set_thresholds(env, values):
	t = _validate_thresholds(values)
	_write(os.path.join(rspamd_dir(env), "actions.conf"),
		"# MeetrMail --- Set on the Spam page of the control panel.\n"
		f"greylist = {t['greylist']};\nadd_header = {t['add_header']};\nreject = {t['reject']};\n")
	_install(env, "actions.conf")
	_reload_rspamd()
	return "OK"


# ### Allow and block lists

def _lists_path(env):
	return os.path.join(rspamd_dir(env), "lists.json")


def get_lists(env):
	lists = { k: [] for k in LIST_KINDS }
	try:
		with open(_lists_path(env), encoding="utf-8") as f:
			data = json.load(f)
		for k in LIST_KINDS:
			lists[k] = [str(v) for v in data.get(k, [])]
	except (OSError, ValueError, AttributeError):
		pass
	return lists


def _normalize_entry(kind, value):
	value = value.strip().lower()
	if kind.endswith("_senders"):
		if ADDRESS_RE.match(value) or DOMAIN_RE.match(value):
			return value
		msg = "Enter an email address (user@example.com) or a domain name (example.com)."
		raise ValueError(msg)
	try:
		return str(ipaddress.ip_network(value, strict=False)) if "/" in value else str(ipaddress.ip_address(value))
	except ValueError:
		msg = "Enter an IP address or a network in CIDR form (203.0.113.0/24)."
		raise ValueError(msg) from None


def _write_maps(env, lists):
	d = rspamd_dir(env)
	for prefix in ("allow", "block"):
		senders = lists[prefix + "_senders"]
		_write(os.path.join(d, f"{prefix}_sender_addr.map"), "".join(s + "\n" for s in senders if "@" in s))
		_write(os.path.join(d, f"{prefix}_sender_domain.map"), "".join(s + "\n" for s in senders if "@" not in s))
		_write(os.path.join(d, f"{prefix}_ip.map"), "".join(s + "\n" for s in lists[prefix + "_ips"]))


def change_list(env, kind, action, value):
	if kind not in LIST_KINDS:
		msg = "Unknown list."
		raise ValueError(msg)
	if action not in {"add", "remove"}:
		msg = "Invalid action."
		raise ValueError(msg)
	lists = get_lists(env)
	if action == "add":
		value = _normalize_entry(kind, value)
		# An entry can only be on one side at once.
		other = kind.replace("allow", "X").replace("block", "allow").replace("X", "block")
		if value in lists[other]:
			msg = f"{value} is on the {other.replace('_', ' ')} list; remove it there first."
			raise ValueError(msg)
		if value not in lists[kind]:
			lists[kind].append(value)
	else:
		value = value.strip().lower()
		lists[kind] = [v for v in lists[kind] if v != value]
	_write(_lists_path(env), json.dumps(lists, indent=1))
	_write_maps(env, lists) # Rspamd re-reads maps by itself; no reload needed
	return "OK"


# ### Per-recipient thresholds

def _user_thresholds_path(env):
	return os.path.join(rspamd_dir(env), "user_thresholds.json")


def get_user_thresholds(env):
	try:
		with open(_user_thresholds_path(env), encoding="utf-8") as f:
			data = json.load(f)
		return data if isinstance(data, dict) else {}
	except (OSError, ValueError):
		return {}


def _render_settings(data):
	out = ["# MeetrMail --- Set on the Spam page of the control panel.", "settings {"]
	for i, (addr, t) in enumerate(sorted(data.items())):
		out.append(f'  meetrmail_user_{i} {{')
		out.append('    priority = high;')
		out.append(f'    rcpt = "{addr}";')
		out.append('    apply {')
		out.append('      actions {')
		out.append(f'        greylist = {t["greylist"]};')
		out.append(f'        "add header" = {t["add_header"]};')
		out.append(f'        reject = {t["reject"]};')
		out.append('      }')
		out.append('    }')
		out.append('  }')
	out.append("}")
	return "\n".join(out) + "\n"


def set_user_thresholds(env, address, values, remove=False):
	from mailconfig import get_mail_users
	address = address.strip().lower()
	if address not in get_mail_users(env):
		msg = f"{address} is not a mail user on this box."
		raise ValueError(msg)
	data = get_user_thresholds(env)
	if remove:
		data.pop(address, None)
	else:
		data[address] = _validate_thresholds(values)
	_write(_user_thresholds_path(env), json.dumps(data, indent=1))
	_write(os.path.join(rspamd_dir(env), "settings.conf"), _render_settings(data))
	_install(env, "settings.conf")
	_reload_rspamd()
	return "OK"


def get_overview(env):
	return {
		"stats": get_stats(env),
		"thresholds": get_thresholds(env),
		"defaults": DEFAULT_THRESHOLDS,
		"lists": get_lists(env),
		"user_thresholds": get_user_thresholds(env),
	}


# ### The Spam folder

def _doveadm(args):
	return utils.shell("check_output", ["/usr/bin/doveadm", *args], capture_stderr=False, trap=True)


def _check_user(env, address):
	from mailconfig import get_mail_users
	if address not in get_mail_users(env):
		msg = f"{address} is not a mail user on this box."
		raise ValueError(msg)


def _decode_header(value):
	try:
		return str(email.header.make_header(email.header.decode_header(value or "")))
	except (ValueError, LookupError):
		return value or ""


def _parse_json_rows(text):
	text = text.strip()
	if not text: return []
	try:
		data = json.loads(text)
		return data if isinstance(data, list) else [data]
	except ValueError:
		rows = []
		for line in text.splitlines():
			line = line.strip().strip(",[]")
			if line:
				try: rows.append(json.loads(line))
				except ValueError: pass
		return rows


def _score(msg):
	m = re.search(r"score=(-?[\d.]+)", msg.get("X-Spam-Status", "") or "") \
		or re.search(r"\[(-?[\d.]+) /", msg.get("X-Spamd-Result", "") or "")
	return m.group(1) if m else None


def list_spam_folder(env, address, limit=200):
	# The newest messages in the user's Spam folder.
	_check_user(env, address)
	code, out = _doveadm(["-f", "json", "fetch", "-u", address, "uid date.received size.virtual hdr", "mailbox", "Spam", "all"])
	if code != 0:
		return { "messages": [], "total": 0, "error": "Could not read that Spam folder." }
	rows = _parse_json_rows(out)
	messages = []
	for r in rows[-limit:]:
		msg = email.parser.HeaderParser().parsestr(r.get("hdr", ""))
		try: size = int(r.get("size.virtual", 0))
		except (TypeError, ValueError): size = 0
		messages.append({
			"uid": str(r.get("uid", "")),
			"received": r.get("date.received", ""),
			"from": _decode_header(msg.get("From")),
			"subject": _decode_header(msg.get("Subject")),
			"score": _score(msg),
			"size": size,
		})
	messages.reverse() # newest first
	return { "messages": messages, "total": len(rows) }


def _check_uid(uid):
	if not re.fullmatch(r"\d{1,12}", uid or ""):
		msg = "Invalid message."
		raise ValueError(msg)
	return uid


def release_spam_message(env, address, uid):
	# Move a message from Spam back to the Inbox.
	_check_user(env, address)
	code, out = _doveadm(["move", "-u", address, "INBOX", "mailbox", "Spam", "uid", _check_uid(uid)])
	if code != 0:
		msg = "Could not move that message."
		raise ValueError(msg)
	return "OK"


def delete_spam_message(env, address, uid):
	_check_user(env, address)
	code, out = _doveadm(["expunge", "-u", address, "mailbox", "Spam", "uid", _check_uid(uid)])
	if code != 0:
		msg = "Could not delete that message."
		raise ValueError(msg)
	return "OK"


# ### Daily digest

RSPAMD_LINE_RE = re.compile(
	r"^(?P<ts>\S+(?: +\d+ +[\d:]+)?)\s.*?rspamd_task_write_log:.*?"
	r"\(default: [A-Z] \((?P<action>[a-z ]+)\): \[(?P<score>-?[\d.]+)/[-\d.]+\]\s*\[(?P<symbols>[^\]]*)\]"
)


def _line_time(ts):
	# Syslog lines start either "2026-09-29T03:00:01+00:00" or "Sep 29 03:00:01".
	try:
		return datetime.datetime.fromisoformat(ts).replace(tzinfo=None)
	except ValueError:
		return None


def build_digest(env, hours=24):
	from collections import Counter
	from mailconfig import get_mail_users

	since = datetime.datetime.now() - datetime.timedelta(hours=hours)
	actions, symbols = Counter(), Counter()
	try:
		with open("/var/log/mail.log", encoding="utf-8", errors="replace") as f:
			for line in f:
				m = RSPAMD_LINE_RE.match(line)
				if not m: continue
				t = _line_time(m.group("ts"))
				if t is not None and t < since: continue
				actions[m.group("action")] += 1
				if m.group("action") in {"add header", "reject", "soft reject", "rewrite subject"}:
					for sym in m.group("symbols").split(","):
						sym = sym.strip().split("(")[0]
						if sym: symbols[sym] += 1
	except OSError:
		pass

	lines = [f"Spam filtering summary for the last {hours} hours", ""]
	if actions:
		total = sum(actions.values())
		lines.append(f"Messages scanned: {total}")
		for name, n in actions.most_common():
			lines.append(f"  {name}: {n}")
		lines += ["", "Most common reasons for spam verdicts:"]
		lines += [f"  {sym}: {n}" for sym, n in symbols.most_common(10)] or ["  (none)"]
	else:
		lines.append("No Rspamd activity found in the mail log.")

	lines += ["", "Messages waiting in Spam folders:"]
	any_spam = False
	for address in get_mail_users(env):
		code, out = _doveadm(["-f", "tab", "mailbox", "status", "-u", address, "messages", "Spam"])
		m = (re.search(r"messages=(\d+)", out) or re.search(r"(\d+)\s*$", out)) if code == 0 else None
		if m and int(m.group(1)) > 0:
			lines.append(f"  {address}: {m.group(1)}")
			any_spam = True
	if not any_spam:
		lines.append("  (none)")
	return "\n".join(lines) + "\n"


if __name__ == "__main__":
	env = utils.load_environment()
	if "--digest" in sys.argv:
		sys.stdout.write(build_digest(env))
	else:
		print("Usage: spam.py --digest")
