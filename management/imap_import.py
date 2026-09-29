#!/usr/local/lib/meetrmail/env/bin/python

# Imports the mail of an account on another IMAP server into a mailbox on this
# box, using Dovecot's own `doveadm sync` with the imapc backend. That needs no
# extra software, keeps message flags and dates, and can be run again to pick up
# mail that arrived at the old server in the meantime.
#
# It is a one-way, additive copy: nothing is changed on the source server and
# nothing already in the destination mailbox is removed.
#
# The source password never appears on a command line (where any local user
# could read it with `ps`). It is written to a private config file that is
# removed as soon as the job ends.
#
# Jobs run in a background thread of the management daemon and record their
# state in $STORAGE_ROOT/mail/import/<id>.json.

import json
import os
import re
import subprocess
import threading
import time
import uuid

_lock = threading.Lock()
_procs = {} # job id => Popen, for cancelling
LOG_LINES = 200

HOST_RE = re.compile(r"^(?=.{1,253}$)[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$")

# Folders that are not worth copying by default. Importing a source Spam folder
# would also teach the spam filter that everything in it is spam.
SPAM_FOLDERS = ("Spam", "Junk", "Junk E-mail", "Junk Email", "Bulk Mail", "[Gmail]/Spam", "INBOX.Spam", "INBOX.Junk")


def import_dir(env):
	d = os.path.join(env["STORAGE_ROOT"], "mail/import")
	os.makedirs(d, mode=0o700, exist_ok=True)
	return d


def _job_path(env, job_id):
	if not re.fullmatch(r"[0-9a-f]{32}", job_id or ""):
		msg = "Invalid job."
		raise ValueError(msg)
	return os.path.join(import_dir(env), job_id + ".json")


def _save(env, job):
	path = _job_path(env, job["id"])
	tmp = path + ".tmp"
	with open(tmp, "w", encoding="utf-8") as f:
		json.dump(job, f)
	os.chmod(tmp, 0o600)
	os.replace(tmp, path)


def get_job(env, job_id):
	try:
		with open(_job_path(env, job_id), encoding="utf-8") as f:
			job = json.load(f)
	except (OSError, ValueError):
		msg = "No such import."
		raise ValueError(msg) from None
	# A job left "running" by a daemon that has since restarted is not running.
	if job["state"] == "running" and job_id not in _procs:
		job["state"] = "failed"
		job["log"] = [*job.get("log", []), "The management daemon restarted while this import was running."][-LOG_LINES:]
	return job


def list_jobs(env, limit=20):
	jobs = []
	d = import_dir(env)
	for name in os.listdir(d):
		if name.endswith(".json"):
			try:
				jobs.append(get_job(env, name[:-5]))
			except ValueError:
				continue
	jobs.sort(key=lambda j: j["started"], reverse=True)
	for j in jobs:
		j["log"] = j["log"][-5:] # the list view only needs a hint
	return jobs[:limit]


def start_import(env, dest, host, port, security, username, password, verify_cert, skip_spam):
	from mailconfig import get_mail_users

	if dest not in get_mail_users(env):
		msg = f"{dest} is not a mail user on this box."
		raise ValueError(msg)
	host = (host or "").strip()
	if not HOST_RE.match(host):
		msg = "Enter the source server's host name."
		raise ValueError(msg)
	try:
		port = int(port)
		if not (1 <= port <= 65535): raise ValueError
	except (TypeError, ValueError):
		msg = "The port must be a number from 1 to 65535."
		raise ValueError(msg) from None
	if security not in {"imaps", "starttls", "none"}:
		msg = "Invalid connection security."
		raise ValueError(msg)
	username = (username or "").strip()
	if not username or "\n" in username or "\r" in username:
		msg = "Enter the username on the source server."
		raise ValueError(msg)
	if not password or "\n" in password or "\r" in password:
		msg = "Enter the password for the source account."
		raise ValueError(msg)

	with _lock:
		for j in list_jobs(env, limit=1000):
			if j["dest"] == dest and j["state"] == "running":
				msg = f"An import into {dest} is already running."
				raise ValueError(msg)

		job = {
			"id": uuid.uuid4().hex, "dest": dest, "host": host, "port": port, "username": username,
			"state": "running", "started": time.time(), "finished": None, "returncode": None, "log": [],
		}
		_save(env, job)

		conf = os.path.join(import_dir(env), job["id"] + ".conf")
		fd = os.open(conf, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
		with os.fdopen(fd, "w", encoding="utf-8") as f:
			f.write("!include /etc/dovecot/dovecot.conf\n")
			f.write(f"imapc_host = {host}\nimapc_port = {port}\nimapc_user = {username}\nimapc_password = {password}\n")
			f.write(f"imapc_ssl = {security}\nimapc_ssl_verify = {'yes' if verify_cert else 'no'}\n")
			f.write("imapc_features = rfc822.size fetch-headers\n")

		cmd = ["/usr/bin/doveadm", "-c", conf, "sync", "-1", "-R", "-u", dest]
		if skip_spam:
			for name in SPAM_FOLDERS:
				cmd += ["-x", name]
		cmd.append("imapc:")

		threading.Thread(target=_run, args=(env, job, cmd, conf), daemon=True).start()
	return job["id"]


def _run(env, job, cmd, conf):
	log = []
	try:
		proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace", env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin"}) # noqa: S603
		_procs[job["id"]] = proc
		for line in proc.stdout:
			log.append(line.rstrip())
			del log[:-LOG_LINES]
			job["log"] = log
			_save(env, job)
		proc.wait()
		job["returncode"] = proc.returncode
		if job["state"] != "cancelled":
			job["state"] = "finished" if proc.returncode == 0 else "failed"
	except OSError as e:
		log.append(str(e))
		job["state"] = "failed"
	finally:
		_procs.pop(job["id"], None)
		job["finished"] = time.time()
		job["log"] = log
		_save(env, job)
		try: os.remove(conf)
		except OSError: pass


def cancel_import(env, job_id):
	job = get_job(env, job_id)
	proc = _procs.get(job_id)
	if job["state"] != "running" or proc is None:
		msg = "That import is not running."
		raise ValueError(msg)
	# _run() sees the state and records "cancelled" instead of "failed".
	job["state"] = "cancelled"
	_save(env, job)
	proc.terminate()
	return "OK"
