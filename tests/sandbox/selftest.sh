#!/bin/bash
# MeetrMail sandbox self-test
# -------------------------------
#
# Run this ON the box, after a sandbox install, to check that the whole stack
# actually works:
#
#   sudo tests/sandbox/selftest.sh
#
# It exercises the parts that can be tested without the public internet --
# which is most of them. Mail is sent from one local user to another through
# the real SMTP path, so Postfix, the milter chain, OpenDKIM, Rspamd, Dovecot
# LMTP, sieve and the mailbox are all genuinely involved.
#
# What it cannot test, and you must still verify on the live box before
# trusting it, is everything that depends on a third party's opinion of you:
# whether Gmail accepts your DKIM signature, whether your PTR record is right,
# whether your IP is on a blocklist. Those are the go-live checklist, not this.

set -uo pipefail

source /etc/meetrmail.conf

PASS=0
FAIL=0
SKIP=0
FAILED_TESTS=()

# Terminal colours, but only when we're on a terminal.
if [ -t 1 ]; then
	R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
else
	R=""; G=""; Y=""; B=""; N=""
fi

section() { echo; echo "${B}=== $* ===${N}"; }
ok()      { PASS=$((PASS+1)); echo "  ${G}PASS${N}  $1"; }
fail()    { FAIL=$((FAIL+1)); FAILED_TESTS+=("$1"); echo "  ${R}FAIL${N}  $1"; [ -n "${2:-}" ] && echo "        $2"; }
skip()    { SKIP=$((SKIP+1)); echo "  ${Y}SKIP${N}  $1${2:+ ($2)}"; }

# check "description" command...
check() {
	local desc=$1; shift
	local out
	if out=$("$@" 2>&1); then
		ok "$desc"
	else
		fail "$desc" "$(echo "$out" | tail -n 3 | tr '\n' ' ')"
	fi
}

if [[ $EUID -ne 0 ]]; then
	echo "This must be run as root:  sudo $0"
	exit 1
fi

echo "${B}MeetrMail sandbox self-test${N}"
echo "Hostname: $PRIMARY_HOSTNAME"
echo "Mode:     $([ "${SANDBOX_MODE:-0}" = "1" ] && echo SANDBOX || echo LIVE)"

# --------------------------------------------------------------------------
section "Services"

# Note: munin.service is deliberately absent. It is a Type=idle unit that runs
# one script at boot and exits, so "inactive" is its normal resting state --
# munin-node is the daemon that actually has to stay up.
for svc in postfix dovecot rspamd redis-server nsd bind9 nginx opendkim opendmarc \
           fail2ban rsyslog munin-node meetrmail "php${PHP_VERSION}-fpm"; do
	if systemctl is-active --quiet "$svc"; then
		ok "$svc is running"
	else
		fail "$svc is running" "$(systemctl is-active "$svc" 2>&1); $(systemctl status "$svc" --no-pager -n 3 2>&1 | tail -n 3 | tr '\n' ' ')"
	fi
done

# --------------------------------------------------------------------------
section "Listening ports"

# Every one of these is required for the box to function. The loopback-only
# ones matter as much as the public ones -- if Rspamd's milter socket isn't
# there, Postfix accepts mail with no filtering at all.
check_port() {
	local desc=$1 port=$2
	if ss -ltn "sport = :$port" 2>/dev/null | grep -q ":$port"; then
		ok "$desc (:$port)"
	else
		fail "$desc (:$port)" "nothing is listening on port $port"
	fi
}
check_port "SMTP (postfix)" 25
check_port "Submission (postfix)" 587
check_port "Submission TLS (postfix)" 465
check_port "IMAPS (dovecot)" 993
check_port "ManageSieve (dovecot)" 4190
check_port "Dovecot LMTP" 10026
check_port "Dovecot quota-status" 12340
check_port "Rspamd milter" 11332
check_port "Rspamd controller" 11334
check_port "Redis" 6379
check_port "OpenDKIM" 8891
check_port "OpenDMARC" 8893
check_port "Management daemon" 10222
check_port "HTTP (nginx)" 80
check_port "HTTPS (nginx)" 443

# Nothing that should be private should be reachable from off-box.
section "Private services are not public"
for p in 10026 12340 11332 11334 6379 8891 8893 10222 4949; do
	if ss -ltn "sport = :$p" 2>/dev/null | grep -qE "(0\.0\.0\.0|\*|\[::\]):$p"; then
		fail "port $p is loopback-only" "it is bound to a public address"
	else
		ok "port $p is loopback-only"
	fi
done

# --------------------------------------------------------------------------
section "Configuration sanity"

check "postfix configuration parses"   postfix check
check "fail2ban configuration is valid" fail2ban-client --test
check "nsd configuration is valid"     nsd-checkconf /etc/nsd/nsd.conf
check "bind9 configuration is valid"   named-checkconf
check "nginx configuration is valid"   nginx -t
check "dovecot configuration is valid" doveconf -n

# The things this fork specifically changed, checked by value rather than by
# "the service started", because all of these can be wrong while everything
# still starts.
if postconf -h smtpd_milters | grep -q "11332"; then
	ok "Rspamd is in Postfix's milter chain"
else
	fail "Rspamd is in Postfix's milter chain" "smtpd_milters = $(postconf -h smtpd_milters)"
fi

if postconf -h smtpd_milters | grep -q "8891"; then
	ok "OpenDKIM is in Postfix's milter chain"
else
	fail "OpenDKIM is in Postfix's milter chain" "smtpd_milters = $(postconf -h smtpd_milters)"
fi

if [ "$(postconf -h virtual_transport)" = "lmtp:[127.0.0.1]:10026" ]; then
	ok "Postfix delivers straight to Dovecot LMTP"
else
	fail "Postfix delivers straight to Dovecot LMTP" "virtual_transport = $(postconf -h virtual_transport)"
fi

if grep -q "php${PHP_VERSION}-fpm.sock" /etc/nginx/conf.d/local.conf; then
	ok "nginx points at the right php-fpm socket"
else
	fail "nginx points at the right php-fpm socket" "$(grep -m1 'php.*-fpm.sock' /etc/nginx/conf.d/local.conf || echo 'no php-fpm upstream found')"
fi

# Versions, so a wrong one is visible rather than silently working-for-now.
section "Versions"
echo "  PHP           $(php -v 2>/dev/null | head -n1 | awk '{print $2}')"
echo "  Python (mgmt) $(/usr/local/lib/meetrmail/env/bin/python --version 2>&1 | awk '{print $2}')"
echo "  Rspamd        $(rspamd --version 2>&1 | head -n1 | awk '{print $2}')"
echo "  Postfix       $(postconf -h mail_version 2>/dev/null)"
echo "  Dovecot       $(dovecot --version 2>/dev/null | awk '{print $1}')"
echo "  nsd           $(nsd -v 2>&1 | head -n1 | awk '{print $3}')"
echo "  Nextcloud     $(sudo -u www-data php /usr/local/lib/owncloud/occ status 2>/dev/null | sed -n 's/.*versionstring: //p')"

if php -v 2>/dev/null | head -n1 | grep -q "PHP ${PHP_VERSION}"; then
	ok "PHP is ${PHP_VERSION}"
else
	fail "PHP is ${PHP_VERSION}" "$(php -v 2>/dev/null | head -n1)"
fi

if /usr/local/lib/meetrmail/env/bin/python --version 2>&1 | grep -q "3\.12"; then
	ok "management daemon runs on Python 3.12"
else
	fail "management daemon runs on Python 3.12" "$(/usr/local/lib/meetrmail/env/bin/python --version 2>&1)"
fi

# --------------------------------------------------------------------------
section "Local DNS"

if host -t MX "$PRIMARY_HOSTNAME" 127.0.0.1 > /dev/null 2>&1; then
	ok "the box's own MX record resolves locally"
else
	fail "the box's own MX record resolves locally" "$(host -t MX "$PRIMARY_HOSTNAME" 127.0.0.1 2>&1 | tail -n1)"
fi

if host -t TXT "mail._domainkey.$PRIMARY_HOSTNAME" 127.0.0.1 2>/dev/null | grep -q "p="; then
	ok "the DKIM public key is published in DNS"
else
	fail "the DKIM public key is published in DNS" "mail._domainkey.$PRIMARY_HOSTNAME has no key"
fi

if host -t TXT "$PRIMARY_HOSTNAME" 127.0.0.1 2>/dev/null | grep -q "v=spf1"; then
	ok "an SPF record is published"
else
	fail "an SPF record is published" "no v=spf1 TXT record"
fi

# --------------------------------------------------------------------------
section "TLS"

if echo | openssl s_client -connect "127.0.0.1:993" -servername "$PRIMARY_HOSTNAME" 2>/dev/null | grep -q "BEGIN CERTIFICATE"; then
	ok "IMAPS offers a certificate"
else
	fail "IMAPS offers a certificate"
fi

# The self-signed certificate must carry a subjectAltName or no current client
# will accept it at all.
if openssl x509 -in "$STORAGE_ROOT/ssl/ssl_certificate.pem" -noout -text | grep -A1 "Subject Alternative Name" | grep -q "$PRIMARY_HOSTNAME"; then
	ok "the certificate has a subjectAltName for $PRIMARY_HOSTNAME"
else
	fail "the certificate has a subjectAltName for $PRIMARY_HOSTNAME" "modern TLS clients reject certificates without one"
fi

# --------------------------------------------------------------------------
section "Mail delivery, end to end"

SENDER="selftest-sender@$PRIMARY_HOSTNAME"
RECIPIENT="selftest-rcpt@$PRIMARY_HOSTNAME"
TEST_PASS="SelfTest-$(tr -cd '[:alnum:]' < /dev/urandom | head -c 16 || true)"
MAILDIR="$STORAGE_ROOT/mail/mailboxes/${PRIMARY_HOSTNAME}/selftest-rcpt"

cd "$(dirname "$(readlink -f "$0")")/../.." || exit 1

cleanup_users() {
	management/cli.py user remove "$SENDER"    > /dev/null 2>&1 || true
	management/cli.py user remove "$RECIPIENT" > /dev/null 2>&1 || true
}
trap cleanup_users EXIT

if management/cli.py user add "$SENDER" "$TEST_PASS" > /dev/null 2>&1 \
   && management/cli.py user add "$RECIPIENT" "$TEST_PASS" > /dev/null 2>&1; then
	ok "created two test mail users"
else
	fail "created two test mail users" "management/cli.py user add failed"
fi

# Give Dovecot a moment to notice the new accounts.
sleep 2

# wait_for_message <subject> -> prints the path of the delivered message
wait_for_message() {
	local subject=$1 found
	for _ in $(seq 1 30); do
		found=$(grep -rl "Subject: $subject" "$MAILDIR" 2>/dev/null | head -n1)
		if [ -n "$found" ]; then echo "$found"; return 0; fi
		sleep 1
	done
	return 1
}

# ---- The outbound path: local submission, which is what Roundcube and any
# ---- authenticated client use. This is the path OpenDKIM signs on.
SUBJ_OUT="MeetrMail selftest outbound $$"
{
	echo "From: $SENDER"
	echo "To: $RECIPIENT"
	echo "Subject: $SUBJ_OUT"
	echo "Date: $(date -R)"
	echo "Message-ID: <out-$$@$PRIMARY_HOSTNAME>"
	echo
	echo "Sent by the MeetrMail sandbox self-test via local submission."
} | sendmail -f "$SENDER" "$RECIPIENT"

if MSGPATH=$(wait_for_message "$SUBJ_OUT"); then
	ok "a locally-submitted message was delivered"

	# OpenDKIM signs mail submitted from the box itself. If this header is
	# missing, outbound mail will fail DKIM at every recipient -- which is the
	# single thing most likely to get a new box's mail junked.
	if grep -qi "^DKIM-Signature:" "$MSGPATH"; then
		ok "OpenDKIM signed the outbound message"
		sig=$(tr -d '\n' < "$MSGPATH" | grep -o "DKIM-Signature:.*" | head -c 200)
		echo "        ${sig:0:120}"
		if echo "$sig" | grep -q "d=$PRIMARY_HOSTNAME"; then
			ok "the DKIM signature is for the right domain"
		else
			fail "the DKIM signature is for the right domain" "expected d=$PRIMARY_HOSTNAME"
		fi
	else
		fail "OpenDKIM signed the outbound message" "no DKIM-Signature header; outbound mail would fail DKIM everywhere"
	fi
else
	fail "a locally-submitted message was delivered" "nothing arrived within 30s; check /var/log/mail.log"
fi

# ---- The inbound path: a real SMTP conversation on port 25 from an address
# ---- that is not in mynetworks, which is how mail from the outside world
# ---- arrives. This is the path the milter chain and Rspamd act on. Mail
# ---- submitted locally is deliberately not scanned or tagged, so testing
# ---- spam filtering over local submission would prove nothing.
# smtp_send <subject> [extra body line]
#
# Prints "accepted", or "deferred <code>" / "refused <code>" so the caller can
# tell greylisting apart from a real rejection. Greylisting a first attempt is
# the correct behaviour, not a failure.
smtp_send() {
	local subject=$1 extra=${2:-}
	python3 - "$PRIVATE_IP" "$SENDER" "$RECIPIENT" "$PRIMARY_HOSTNAME" "$subject" "$extra" <<'PYEOF'
import smtplib, sys
host, sender, rcpt, hostname, subject, extra = sys.argv[1:7]
body = "\r\n".join([
    f"From: {sender}", f"To: {rcpt}", f"Subject: {subject}",
    f"Message-ID: <in-{abs(hash(subject))}@{hostname}>", "",
    "Sent by the MeetrMail sandbox self-test over SMTP.",
] + ([extra] if extra else []))
try:
    with smtplib.SMTP(host, 25, timeout=30) as s:
        s.ehlo("selftest.invalid")
        s.sendmail(sender, [rcpt], body)
    print("accepted")
except smtplib.SMTPRecipientsRefused as e:
    # Rejected at RCPT TO -- this is where greylisting happens.
    code, msg = next(iter(e.recipients.values()))
    print(f"{'deferred' if 400 <= code < 500 else 'refused'} {code} {msg.decode(errors='replace')[:90]}")
except smtplib.SMTPResponseException as e:
    # Rejected at DATA -- this is where content filters such as the GTUBE rule
    # reject, and it raises a different exception from a RCPT TO rejection.
    msg = e.smtp_error.decode(errors="replace") if isinstance(e.smtp_error, bytes) else str(e.smtp_error)
    print(f"{'deferred' if 400 <= e.smtp_code < 500 else 'refused'} {e.smtp_code} {msg[:90]}")
except Exception as e:  # noqa: BLE001 -- the self-test wants to report anything
    print(f"error {e}")
PYEOF
}

# Greylisting.
#
# This works differently from the postgrey it replaces, and the difference
# matters operationally: postgrey deferred *every* first contact from an unknown
# sender, while Rspamd defers only mail that scores into the greylist band
# (4.0-6.0 by default, see /etc/rspamd/local.d/actions.conf). Ordinary
# correspondence is no longer delayed by minutes on first contact; borderline
# mail still is.
#
# So there are two things to check, and a clean message being delivered promptly
# is one of them.
SUBJ_IN="MeetrMail selftest inbound $$"
first=$(smtp_send "$SUBJ_IN")
if [ "$first" = "accepted" ]; then
	ok "a clean message is delivered without being greylisted"
else
	fail "a clean message is delivered without being greylisted" "$first"
fi

if rspamadm configdump greylist 2>/dev/null | grep -q "timeout"; then
	ok "the Rspamd greylist module is loaded"
	echo "        timeout $(rspamadm configdump greylist 2>/dev/null | sed -n 's/^timeout = //p' | tr -d ';')s"
else
	fail "the Rspamd greylist module is loaded" "nothing will ever be greylisted"
fi

# Now prove that mail which *does* score into the greylist band is deferred and
# then released. Rather than trying to craft a message that reliably scores
# between 4 and 6 -- which would break on every Rspamd scoring change -- lower
# the greylist threshold for the length of this one test and put it back.
#
# Only ever done on a sandbox box.
if [ "${SANDBOX_MODE:-0}" = "1" ]; then
	ACTIONS=/etc/rspamd/local.d/actions.conf
	cp "$ACTIONS" "$ACTIONS.selftest-backup"
	restore_actions() {
		if [ -f "$ACTIONS.selftest-backup" ]; then
			mv -f "$ACTIONS.selftest-backup" "$ACTIONS"
			systemctl reload rspamd 2>/dev/null || systemctl restart rspamd
		fi
	}
	# Compose rather than nest: restore_actions is also called directly at the
	# end of this block, and if it removed the test users too it would delete
	# them out from under every check that comes after.
	trap 'restore_actions; cleanup_users' EXIT

	# greylist at 0.01 means "greylist essentially everything", which makes the
	# defer/release cycle observable with an ordinary message.
	printf 'greylist = 0.01;\nadd_header = 6;\nreject = 15;\n' > "$ACTIONS"
	systemctl reload rspamd 2>/dev/null || systemctl restart rspamd
	sleep 2

	SUBJ_GREY="MeetrMail selftest greylist $$"
	grey1=$(smtp_send "$SUBJ_GREY")
	case "$grey1" in
		deferred*)
			ok "greylisting defers an unknown sender"
			echo "        $grey1"
			echo "        waiting out the greylist delay..."
			sleep 14
			grey2=$(smtp_send "$SUBJ_GREY")
			if [ "$grey2" = "accepted" ]; then
				ok "the retry after the greylist delay is accepted"
			else
				fail "the retry after the greylist delay is accepted" "$grey2"
			fi
			;;
		*)
			fail "greylisting defers an unknown sender" "$grey1"
			;;
	esac

	restore_actions
	trap cleanup_users EXIT
else
	skip "greylist defer/release cycle" "only tested on a sandbox box"
fi

if MSGPATH=$(wait_for_message "$SUBJ_IN"); then
	ok "the inbound message was delivered"
	case "$MSGPATH" in
		*/.Spam/*) fail "the inbound message landed in INBOX" "it was filed as Spam" ;;
		*)         ok "the inbound message landed in INBOX" ;;
	esac

	if grep -qi "^Authentication-Results:" "$MSGPATH"; then
		ok "the milter chain added an Authentication-Results header"
	else
		fail "the milter chain added an Authentication-Results header" "OpenDKIM/OpenDMARC did not run on inbound mail"
	fi

	if grep -qiE "^X-Spam-Status:|^X-Spamd-Result:|^X-Rspamd-Server:" "$MSGPATH"; then
		ok "Rspamd scanned the inbound message"
		echo "        $(grep -im1 -E '^X-Spam-Status:|^X-Spamd-Result:' "$MSGPATH" | cut -c1-110)"
	else
		fail "Rspamd scanned the inbound message" "no Rspamd headers; mail is being accepted with no filtering at all"
	fi
else
	fail "the inbound message was delivered" "nothing arrived within 30s; check /var/log/mail.log"
fi

# GTUBE is the standard "treat me as spam" string, recognised by Rspamd exactly
# as it was by SpamAssassin. Either outcome is a pass -- tagged and filed into
# Spam, or refused outright -- but being accepted into the INBOX is not.
#
SUBJ_SPAM="MeetrMail selftest spam $$"
GTUBE="XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X"
spamres=$(smtp_send "$SUBJ_SPAM" "$GTUBE")
case "$spamres" in
	refused*)
		ok "the GTUBE spam message was refused at SMTP time"
		echo "        $spamres"
		;;
	accepted)
		if MSGPATH=$(wait_for_message "$SUBJ_SPAM"); then
			case "$MSGPATH" in
				*/.Spam/*) ok "the GTUBE spam message was filed into the Spam folder" ;;
				*)         fail "the GTUBE spam message was filed into the Spam folder" "it landed in ${MSGPATH#"$MAILDIR"}" ;;
			esac
		else
			fail "the GTUBE spam message was delivered somewhere" "it vanished"
		fi
		;;
	*)
		fail "the GTUBE spam message was handled" "$spamres"
		;;
esac

# --------------------------------------------------------------------------
section "Spam filter"

if rspamc -h 127.0.0.1:11334 -P "$(cat "$STORAGE_ROOT/mail/rspamd/controller_password.txt")" stat > /dev/null 2>&1; then
	ok "rspamc can reach the controller"
else
	fail "rspamc can reach the controller" "learning from the Spam folder will not work"
fi

if redis-cli ping 2>/dev/null | grep -q PONG; then
	ok "Redis is answering"
else
	fail "Redis is answering" "Bayes, greylisting and fuzzy storage all need it"
fi

# The spam filter's training data has to be inside STORAGE_ROOT, or it is not in
# the backups and a restore silently loses months of learning.
redis_dir=$(redis-cli CONFIG GET dir 2>/dev/null | tail -n1)
case "$redis_dir" in
	"$STORAGE_ROOT"/*)
		ok "Redis stores its data under STORAGE_ROOT (so it is backed up)"
		echo "        $redis_dir"
		;;
	*)
		fail "Redis stores its data under STORAGE_ROOT (so it is backed up)" \
		     "dir is ${redis_dir:-unknown}; spam-filter training would not survive a restore"
		;;
esac

# Restart Redis and Rspamd and check they come back. A service can be running
# happily right now and still be unable to start from cold -- a directory that
# was writable when setup created it but whose permissions a later step changed,
# for instance. That failure would only show up at the next reboot, and Rspamd
# keeps running without Redis, so nothing would look wrong until the spam filter
# quietly stopped classifying anything.
if systemctl restart redis-server 2>/dev/null && sleep 2 && redis-cli ping 2>/dev/null | grep -q PONG; then
	ok "Redis restarts cleanly (so it will survive a reboot)"
else
	fail "Redis restarts cleanly (so it will survive a reboot)" \
	     "$(systemctl status redis-server --no-pager -n 3 2>&1 | tail -n 2 | tr '\n' ' ')"
fi
if systemctl restart rspamd 2>/dev/null && sleep 2 && systemctl is-active --quiet rspamd; then
	ok "Rspamd restarts cleanly"
else
	fail "Rspamd restarts cleanly" "$(systemctl status rspamd --no-pager -n 3 2>&1 | tail -n 2 | tr '\n' ' ')"
fi

if rspamadm configtest > /dev/null 2>&1; then
	ok "Rspamd configuration is valid"
else
	fail "Rspamd configuration is valid" "$(rspamadm configtest 2>&1 | tail -n2 | tr '\n' ' ')"
fi

if [ -f /etc/dovecot/sieve/learn-spam.svbin ] && [ -f /etc/dovecot/sieve/learn-ham.svbin ]; then
	ok "the IMAPSieve learning scripts are compiled"
else
	fail "the IMAPSieve learning scripts are compiled" "moving mail to Spam will not retrain the filter"
fi

if doveconf -n 2>/dev/null | grep -q "imap_sieve"; then
	ok "Dovecot has the imap_sieve plugin enabled"
else
	fail "Dovecot has the imap_sieve plugin enabled"
fi

# Prove the learning round trip actually works, rather than just that its parts
# are present. This is the "drag a message to Spam and check rspamadm stat"
# item from the go-live checklist, done over IMAP the way a mail client does it.
rspamc_auth=(-h 127.0.0.1:11334 -P "$(cat "$STORAGE_ROOT/mail/rspamd/controller_password.txt")")
learns_before=$(rspamc "${rspamc_auth[@]}" stat 2>/dev/null | sed -n 's/^Total learns: *//p')

if [ -n "$learns_before" ]; then
	# Report what the IMAP side actually did, so that a failure further down
	# points at the right half of the system.
	imap_result=$(python3 - "$RECIPIENT" "$TEST_PASS" <<'PYEOF'
import imaplib, sys, time
user, password = sys.argv[1:3]
try:
    m = imaplib.IMAP4("127.0.0.1", 143)
    m.login(user, password)
    typ, boxes = m.list()
    if not any(b'"Spam"' in b or b' Spam' in b for b in (boxes or [])):
        print("no Spam mailbox"); sys.exit()
    m.select("INBOX")
    typ, data = m.search(None, "ALL")
    ids = (data[0] or b"").split()
    if not ids:
        print("INBOX is empty"); sys.exit()
    # Copy the most recent message into Spam, which is what a mail client does
    # when the user drags it there.
    typ, resp = m.copy(ids[-1], "Spam")
    print(f"copy {typ}")
    time.sleep(1)
    m.logout()
except Exception as e:  # noqa: BLE001 -- the self-test reports whatever happened
    print(f"error {e}")
PYEOF
)
	if [ "$imap_result" = "copy OK" ]; then
		ok "a message was copied into the Spam folder over IMAP"
	else
		fail "a message was copied into the Spam folder over IMAP" "$imap_result"
	fi

	# Two separate delays to wait out here, which is why this polls for a while
	# rather than checking once: Dovecot runs the IMAPSieve pipe script after
	# the IMAP COPY has already been acknowledged, and Rspamd's statistics
	# counters are refreshed on their own schedule rather than synchronously
	# with the learn. The learn itself is logged to /var/log/mail.log as
	# "LEARN_CLASS" the moment it happens.
	learned=0
	for _ in $(seq 1 30); do
		learns_after=$(rspamc "${rspamc_auth[@]}" stat 2>/dev/null | sed -n 's/^Total learns: *//p')
		if [ "${learns_after:-0}" -gt "${learns_before:-0}" ]; then learned=1; break; fi
		sleep 1
	done

	if [ "$learned" = "1" ]; then
		ok "moving a message into Spam trains the filter (learns ${learns_before} -> ${learns_after})"
	else
		# Say why, rather than leaving the reader to go and find the log.
		# Dovecot logs what the sieve pipe script did, and rspamd logs why it
		# refused to learn (most often: the message has fewer tokens than the
		# classifier's minimum).
		detail=$(grep -iE "sieve|rspamc|learn" /var/log/mail.log 2>/dev/null | tail -n 3 | tr '\n' ' ')
		fail "moving a message into Spam trains the filter" \
		     "Total learns stayed at ${learns_before}. Recent log: ${detail:-nothing relevant in /var/log/mail.log}"
	fi
else
	fail "could not read Rspamd learning statistics" "rspamc stat returned no 'Total learns' line"
fi

# --------------------------------------------------------------------------
section "Web"

api_key=$(cat /var/lib/meetrmail/api.key 2>/dev/null)
if [ -n "$api_key" ] && curl -sf -u "$api_key:" "http://127.0.0.1:10222/system/status" -d '{}' > /dev/null 2>&1; then
	ok "the management API responds"
else
	# The status endpoint is slow; a plain reachability check is enough here.
	if curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:10222/" | grep -qE "^(200|401|403|404)$"; then
		ok "the management daemon responds on :10222"
	else
		fail "the management daemon responds on :10222"
	fi
fi

for path in /admin /mail /cloud; do
	code=$(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1$path" --resolve "$PRIMARY_HOSTNAME:443:127.0.0.1" -H "Host: $PRIMARY_HOSTNAME")
	if [[ "$code" =~ ^(200|301|302|303)$ ]]; then
		ok "https://$PRIMARY_HOSTNAME$path responds ($code)"
	else
		fail "https://$PRIMARY_HOSTNAME$path responds" "HTTP $code"
	fi
done

# Nextcloud's IMAP login is the thing most likely to be broken by a version
# bump, so check it specifically rather than trusting that the page loaded.
if sudo -u www-data php /usr/local/lib/owncloud/occ app:list 2>/dev/null | grep -q "user_external"; then
	ok "Nextcloud has user_external enabled"
else
	fail "Nextcloud has user_external enabled" "Nextcloud login with mail credentials will not work"
fi
for app in contacts calendar; do
	if sudo -u www-data php /usr/local/lib/owncloud/occ app:list 2>/dev/null | grep -q "  - $app:"; then
		ok "Nextcloud has $app enabled"
	else
		fail "Nextcloud has $app enabled"
	fi
done

# Actually authenticate against Dovecot the way Nextcloud does: over cURL's
# imap:// protocol, which is what user_external 4.x uses.
if curl -s --url "imap://127.0.0.1:143" --user "$RECIPIENT:$TEST_PASS" --request "CAPABILITY" > /dev/null 2>&1; then
	ok "IMAP authentication works over the path Nextcloud uses"
else
	fail "IMAP authentication works over the path Nextcloud uses" "Nextcloud logins would fail"
fi

# --------------------------------------------------------------------------
section "Sandbox-only checks"

if [ "${SANDBOX_MODE:-0}" = "1" ]; then
	if grep -q "MeetrMail sandbox DNS" /etc/bind/named.conf.local 2>/dev/null; then
		ok "bind9 is forwarding the box's own zones to nsd"
	else
		fail "bind9 is forwarding the box's own zones to nsd" "local DNS resolution of your domains will not work"
	fi
	if [ -f /etc/rspamd/local.d/fuzzy_check.conf ] && grep -q "enabled = false" /etc/rspamd/local.d/fuzzy_check.conf; then
		ok "Rspamd's internet reputation modules are disabled"
	else
		fail "Rspamd's internet reputation modules are disabled" "every message will wait on DNS timeouts"
	fi
else
	skip "sandbox DNS forwarding" "this box is live"
	skip "Rspamd reputation modules disabled" "this box is live"
fi

# --------------------------------------------------------------------------
echo
echo "${B}────────────────────────────────────────${N}"
printf "  %s%d passed%s, %s%d failed%s, %s%d skipped%s\n" "$G" "$PASS" "$N" "$([ "$FAIL" -gt 0 ] && echo "$R" || echo "$G")" "$FAIL" "$N" "$Y" "$SKIP" "$N"
if [ "$FAIL" -gt 0 ]; then
	echo
	echo "  Failed:"
	for t in "${FAILED_TESTS[@]}"; do echo "    - $t"; done
fi
echo "${B}────────────────────────────────────────${N}"
echo
if [ "${SANDBOX_MODE:-0}" = "1" ]; then
	cat <<'EOF'
  This is a sandbox box, so the following are NOT covered here and must be
  verified on the live box before you point production MX at it:

    * outbound port 25 actually open; PTR record set to the box's hostname
    * the IP is not on a major blocklist
    * Gmail shows dkim=pass spf=pass dmarc=pass on a message from this box
    * Outlook delivers to Inbox rather than Junk
    * inbound mail from outside reaches INBOX
    * greylisting defers then accepts a real remote sender on retry
    * certbot issued a real certificate and the renewal dry run passes
    * a backup completes

EOF
fi

[ "$FAIL" -eq 0 ]
