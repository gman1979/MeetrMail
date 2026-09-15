# Porting Mail-in-a-Box v76 to Ubuntu 24.04 for MeetrMail

**How MeetrMail was built from upstream Mail-in-a-Box v76 on Ubuntu 24.04 LTS (noble)**

| | |
|---|---|
| Upstream base | Mail-in-a-Box v76 (git tag `v76-base` in MeetrMail) |
| Fork branch | `noble-php83-py312-rspamd` |
| Target | Ubuntu 24.04 LTS, single VPS |
| Result | Installs with one command; 88/88 sandbox self-test checks passing; live box sending and receiving with Gmail and Outlook |

---

## Contents

1. [Why v76 does not install on 24.04](#1-why-v76-does-not-install-on-2404)
2. [The approach](#2-the-approach)
3. [Operating system and packages](#3-operating-system-and-packages)
4. [PHP: what broke and what we changed](#4-php-what-broke-and-what-we-changed)
5. [Python: what broke and what we changed](#5-python-what-broke-and-what-we-changed)
6. [Nextcloud](#6-nextcloud)
7. [The spam system: SpamAssassin to Rspamd](#7-the-spam-system-spamassassin-to-rspamd)
8. [Z-Push / ActiveSync removed](#8-z-push--activesync-removed)
9. [Bugs found only by actually installing](#9-bugs-found-only-by-actually-installing)
10. [Security hardening found along the way](#10-security-hardening-found-along-the-way)
11. [Sandbox mode and the test harness](#11-sandbox-mode-and-the-test-harness)
12. [Package summary: added and removed](#12-package-summary-added-and-removed)
13. [What is still open](#13-what-is-still-open)

---

## 1. Why v76 does not install on 24.04

Upstream v76 supports Ubuntu 22.04 only. Running it on 24.04 fails in several independent places,
any one of which stops the install:

| Blocker | Where | What happens on 24.04 |
|---|---|---|
| OS version gate | `setup/preflight.sh` | Refuses anything but 22.04 |
| PHP 8.0 from `ppa:ondrej/php` | `setup/system.sh`, `setup/functions.sh` | Third-party PPA for an EOL PHP; 24.04 ships 8.3 |
| PEP 668 | `setup/questions.sh`, `setup/management.sh` | noble's pip 24.0 refuses `pip3 install` into the system Python: `error: externally-managed-environment` |
| `cryptography==37.0.2` | `setup/management.sh` | No wheel for Python 3.12; pip falls back to a source build needing an old Rust toolchain |
| SpamAssassin 4.0 | `setup/spamassassin.sh` | Major version jump; `/etc/default/spamassassin` no longer exists; spampd's embedding of SpamAssassin untested against 4.0 |
| Hard-coded `php8.0` paths | nginx config, backup code, tools | Every PHP page returns an error; backups abort |
| `systemctl link` | `setup/management.sh`, `setup/munin.sh` | systemd 255 refuses to enable the unit — management daemon never starts at boot |

Sections 4–9 go through each of these.

---

## 2. The approach

The goal was the **smallest diff from v76 that runs correctly on 24.04** — not a rewrite. The plan
was worked in phases:

| Phase | Work |
|---|---|
| 1 | Preflight gate, trivial package fixes, remove PPAs |
| 2 | Python daemon on 3.12 via `uv` |
| 3 | PHP 8.3, remove Z-Push |
| 4 | Fresh Nextcloud 33 install |
| 5a | Rspamd for spam + greylisting (OpenDKIM/OpenDMARC kept) |
| — | Sandbox mode, test harness, and fixes found by testing |

Two decisions shaped everything else:

**OpenDKIM and OpenDMARC stayed exactly as v76 had them.** Rspamd can do DKIM signing, but moving it
means rewriting key generation in `management/dns_update.py` and validation in
`management/status_checks.py`. DKIM decides whether Gmail accepts your mail, so that change was
deferred to a later, unhurried "Phase 5b". The successful Gmail/Outlook tests confirm this held up.

**Every change was tested by actually installing it.** A static read of the code found the obvious
problems. A real install in an Ubuntu 24.04 container found eight more that would have stopped or
silently broken a live box (see [section 9](#9-bugs-found-only-by-actually-installing)).

---

## 3. Operating system and packages

### Preflight

`setup/preflight.sh` and `setup/bootstrap.sh` now accept **exactly** Ubuntu 24.04 — an exact match,
not "24.04 or newer". A box should refuse to install on an untested release rather than half-work.

### Third-party apt repositories

| Repository | v76 | Fork | Why |
|---|---|---|---|
| `ppa:ondrej/php` | Yes (PHP 8.0) | **Removed** | noble ships PHP 8.3 with every module needed |
| `ppa:duplicity-team/duplicity-release-git` | Yes | **Removed** | noble ships duplicity 2.1.4 in main |
| Rspamd project repo (`rspamd.com/apt-stable`) | No | **Added** | See [section 7](#7-the-spam-system-spamassassin-to-rspamd) |

The Rspamd repository is the only third-party source left. Its signing key is pinned by fingerprint
(`3FA347D5E599BE4595CA2576FFA232EDBF21E25E`) and apt-pinned so it can supply only the `rspamd`
package. Setting `RSPAMD_PACKAGE_SOURCE=ubuntu` uses Ubuntu's package instead and leaves no
third-party repositories at all. The choice is saved in `/etc/meetrmail.conf` so a later re-run of
setup can't silently switch.

### Individual package changes

| Package | Change | Reason |
|---|---|---|
| `ntp` | Removed | On noble it's a transitional package pulling in `ntpsec`, which fights `systemd-timesyncd`. MIAB never configured it. |
| `libmagic1` | → `libmagic1t64` | Renamed in noble's 64-bit `time_t` transition. The old name still resolves, but naming the real package is safer. |
| `bind9-host`, `bind9-dnsutils` | Added to base packages | v76 only installed `host` from the network checks, so a box that skipped them had no DNS tools. |
| `python3` | Installed at the very start of setup | `tools/editconf.py` and `setup/migrate.py` use `#!/usr/bin/python3` and run before anything else installs it. |

### Versions verified against the noble archive

Every package name was checked against the real noble package indexes before any code was changed:

| Component | v76 on 22.04 | Fork on 24.04 |
|---|---|---|
| Postfix | 3.6 | 3.8.6 |
| Dovecot | 2.3.16 | 2.3.21 |
| nsd | 4.3.9 | 4.8.0 |
| fail2ban | 0.11 | 1.0.2 |
| PHP | 8.0 (PPA) | 8.3.6 |
| duplicity | PPA build | 2.1.4 |

### nsd 4.8

nsd jumped five minor versions. `setup/dns.sh` now runs `nsd-checkconf` on the generated config
straight after install, so an unsupported directive fails immediately with a precise message rather
than as a mysterious service failure later. It also creates `/etc/nsd/nsd.conf.d` before the config
references it.

---

## 4. PHP: what broke and what we changed

### The version change

`PHP_VER=8.0` → `PHP_VER=8.3` in `setup/functions.sh`. All required modules exist in noble's stock
archive: `cli fpm sqlite3 gd imap curl dev xml mbstring zip intl gmp bcmath apcu imagick common pspell`.
Roundcube 1.6.15 supports PHP 8.3 without changes.

### Hard-coded PHP 8.0 paths — the part that would have hurt

Changing the variable was not enough. v76 had `8.0` written directly into files that never read the
variable:

| File | Hard-coded | Effect on 8.3 |
|---|---|---|
| `conf/nginx-top.conf` | `php8.0-fpm.sock` | **Every PHP page on the box fails** — webmail, Nextcloud, the admin panel |
| `management/backup.py` | `service php8.0-fpm stop` | The backup aborts at that line |
| `tools/owncloud-restore.sh`, `tools/owncloud-unlockadmin.sh` | `$PHP_VER` | That variable only exists during setup, never afterwards |

**Fix:** setup now records `PHP_VERSION=8.3` in `/etc/meetrmail.conf`. A new helper,
`get_php_version()` in `management/utils.py`, reads it (falling back to detecting the installed
php-fpm). The nginx template uses a `PHP_VERSION` placeholder that is filled in when the web config
is generated.

### PHP dependencies that changed shape

- **`php-soap`, `libawl-php`** — only needed by Z-Push, so they went with it.
- **`php8.3-imap`** — kept, because **Roundcube needs it**. See the Nextcloud finding in
  [section 6](#6-nextcloud): Nextcloud no longer does.

---

## 5. Python: what broke and what we changed

### Problem 1 — PEP 668

Ubuntu 24.04's pip (24.0) enforces PEP 668. The system Python is marked "externally managed", and
`pip3 install` into it aborts with `error: externally-managed-environment`. v76 did this twice:

- `setup/questions.sh` — installed `email_validator` globally to validate the admin's email address
- `setup/management.sh` — installed `b2sdk` and `boto3` globally for duplicity's backup backends

The quick workaround, `--break-system-packages`, does exactly what the name says. We didn't use it.

### Problem 2 — the `cryptography` pin

v76 pinned `cryptography==37.0.2` (May 2022). There's no wheel for Python 3.12, so pip tries to build
from source, which needs an old Rust toolchain and `setuptools-rust`.

### The fix: `uv`

[`uv`](https://github.com/astral-sh/uv) installs its own CPython, so the management daemon never
touches the system Python at all.

| | v76 | Fork |
|---|---|---|
| Interpreter | System Python 3.10 | CPython 3.12.14, installed by uv |
| Installer | `pip install --upgrade` (floating versions) | `uv sync --frozen` from a lockfile |
| Dependency list | Inline in a shell script | `management/pyproject.toml` |
| Reproducibility | None — versions drift on every install | `management/uv.lock` pins every package and hash |
| uv itself | — | v0.12.6, pinned, SHA-256 verified |

A new `setup/uv.sh` installs uv before the setup questions run, since the questions need Python.

**How each v76 pip call was replaced:**

- **Email validation during setup** → a new `setup_python` helper runs `mailconfig.py` in a cached,
  temporary uv environment containing `email_validator` and `idna`.
- **The daemon's packages** → `uv sync --frozen` builds `/usr/local/lib/meetrmail/env`.
- **duplicity's `b2sdk` and `boto3`** → duplicity runs on the *system* Python, so these go into a
  separate environment built against `/usr/bin/python3`. `backup.py` adds that environment to
  duplicity's `PYTHONPATH`. Setup checks the packages are importable and stops if they aren't.

### The `cryptography` 37 → 50 jump

Unpinning resolved to cryptography 50.0.1 — thirteen major versions newer. That kind of jump can
break things, so the code that uses it was tested directly rather than assumed to work:

| Function tested | Result |
|---|---|
| Loading certificate chains | ✅ |
| `check_certificate` (validity, expiry, self-signed detection) | ✅ |
| `create_csr` (certificate signing requests) | ✅ |
| TOTP two-factor codes (`pyotp`) | ✅ |
| QR code generation | ✅ |

All passed. One follow-up: cryptography 50 deprecated the timezone-naive `not_valid_before` /
`not_valid_after` properties, and `ssl_certificates.py` logged a warning for every certificate on
every status check. It now uses the timezone-aware `_utc` versions.

### Other Python findings

| Finding | Detail |
|---|---|
| `email_validator` 2.3 rejects `.test`, `.localhost`, `.invalid` | Correct for a live box (mail to those domains can never arrive), but it blocked sandbox installs. Those domains are now allowed **in sandbox mode only**. |
| `boto3` is used by the daemon itself | Not just by duplicity — the admin panel lists S3 regions. Leaving it out caused an HTTP 500 on `/admin` during testing. |
| `tools/readable_bash.py` uses `cgi.escape` | Removed from Python back in 3.8, so this documentation tool was already broken in v76. Not part of the running system; left as-is. |

### Python dependencies in MeetrMail

From `management/pyproject.toml`, locked in `uv.lock`: `rtyaml`, `exclusiveprocess`, `flask`,
`gunicorn`, `email_validator`, `dnspython`, `idna`, `postfix-mta-sts-resolver`, `cryptography`,
`pyotp`, `qrcode[pil]`, `b2sdk`, `boto3`, `python-dateutil`, `expiringdict`, `psutil`.

---

## 6. Nextcloud

Nextcloud is used here only for contacts and calendar.

### Version

| | v76 | Fork |
|---|---|---|
| Nextcloud | 26.0.13 | **33.0.9** |
| contacts | 5.5.3 | 8.8.1 |
| calendar | 4.7.6 | 6.5.4 |
| user_external | 3.3.0 | 4.0.0 |

**Why 33:** PHP 8.3 is one of its supported versions, and `user_external` 4.0.0 — the app that lets
you log in to Nextcloud with your mail password — supports Nextcloud 31 to 34 only. Nextcloud 35
would leave it unsupported. Each app's own `info.xml` was checked to confirm it supports 33.

### Changes

- **Removed the upgrade ladder.** v76 stepped old installs through Nextcloud 20 → 25 one version at a
  time. A fresh install doesn't need that. If an existing install of a *different* major version is
  found, setup now stops and explains why, rather than risk a broken upgrade.
- **Apps download from the official release packages.** v76 downloaded GitHub's automatic source
  archives, which unpack into a folder like `contacts-5.5.3/` (Nextcloud needs it to be `contacts/`)
  and don't include the built JavaScript. That was a latent problem in v76 itself.
- **Checksums use SHA-256.** Nextcloud doesn't publish SHA-1.
- **Installation uses `occ maintenance:install`.** v76 wrote a config file and loaded the web page
  as the web server user, which hid the reason for any failure.
- **`forcessl` → `overwriteprotocol`.** Nextcloud dropped `forcessl` long ago.

### Finding: Nextcloud login no longer needs PHP's IMAP extension

`user_external` 4.0.0 logs in to Dovecot using **cURL's built-in `imap://` support**, not PHP's
`ext/imap`. Two consequences:

1. Nextcloud login doesn't depend on `php-imap`. Only Roundcube does.
2. PHP 8.4 (in Ubuntu 26.04) removes `ext/imap` from core. That was expected to break Nextcloud
   login on the next upgrade. **It won't.**

---

## 7. The spam system: SpamAssassin to Rspamd

### Why replace it

Keeping SpamAssassin looked safer but wasn't. noble ships **SpamAssassin 4.0.0**, a major version,
and `/etc/default/spamassassin` — which v76 edits — no longer exists. v76 runs SpamAssassin through
`spampd`, and that pairing hadn't been tested against 4.0. Rspamd with Postfix and Dovecot is a very
widely used, well-documented setup.

### What was removed, what replaced it

| v76 component | Job | Replaced by |
|---|---|---|
| `spampd` + `spamassassin` | Spam scoring | Rspamd, connected to Postfix as a milter |
| `postgrey` | Greylisting | Rspamd's `greylist` module |
| `razor`, `pyzor` | Shared spam signatures | Rspamd's fuzzy hashing and reputation |
| `dovecot-antispam` | Learn from Spam-folder moves | Dovecot IMAPSieve + `rspamc` |
| `libmail-dkim-perl` | DKIM checks inside SpamAssassin | Rspamd's own DKIM checks |
| — | — | `redis-server` (new: stores Bayes data, greylist records, fuzzy hashes) |

`dovecot-antispam` hasn't had a release since 2017, so replacing it is worthwhile on its own.

### How mail flows now

**v76** — spampd sat in the *delivery* path:

```
Postfix ──LMTP :10025──▶ spampd (SpamAssassin) ──LMTP :10026──▶ Dovecot
```

**Fork** — Rspamd checks mail *while the sender is still connected*, then Postfix delivers directly:

```
            ┌─ OpenDKIM :8891 ─ OpenDMARC :8893 ─ Rspamd :11332 ─┐  (milters)
Postfix ────┤                                                      ├──LMTP :10026──▶ Dovecot
            └──────────────────────────────────────────────────────┘
```

Because Rspamd runs during the SMTP conversation, it can tell a sender "try again later" before the
message is accepted. That's why greylisting no longer needs a separate daemon.

- **Port 25 (incoming):** milter chain is OpenDKIM → OpenDMARC → Rspamd. Rspamd runs last so it can
  see the `Authentication-Results` header the other two add.
- **Ports 465/587 (your users sending):** OpenDKIM only. Your own outgoing mail is signed but never
  greylisted or spam-scored.

### Configuration notes

- **Package source:** the Rspamd project's repository (Rspamd 4.1.5) rather than Ubuntu universe
  (3.8.1). Universe carries no security-update guarantee, and this is the component reading untrusted
  mail from the internet.
- **Loopback only:** all three Rspamd listeners (11332, 11333, 11334) and Redis (6379).
- **Web interface:** reach it over an SSH tunnel —
  `ssh -L 11334:127.0.0.1:11334 you@your-box`, then open `http://127.0.0.1:11334`. The password is in
  `$STORAGE_ROOT/mail/rspamd/controller_password.txt` and is stored hashed in Rspamd's config.
- **Spam headers:** Rspamd adds `X-Spam-Status` — the same header SpamAssassin added — so the existing
  "move spam to the Spam folder" Sieve rule works unchanged. It matches `X-Spam` too.
- **One `Authentication-Results` header:** Rspamd doesn't add its own; OpenDKIM/OpenDMARC already do.
- **DKIM signing turned off in Rspamd,** so outgoing mail isn't signed twice.
- **Thresholds:** greylist at 4, add spam header at 6, reject at 15. The reject threshold is high on
  purpose — on a personal box, losing a real message costs more than one spam reaching the Spam folder.

### Greylisting works differently now

Worth knowing, because it's a visible change:

- **postgrey** delayed **every** first message from a new sender.
- **Rspamd** delays only messages that score in the greylist range (4–6). Ordinary mail from a new
  contact arrives straight away; borderline mail is still delayed; obvious spam is marked or rejected.

To get postgrey-style "delay everything" behaviour back, lower the `greylist` value in
`/etc/rspamd/local.d/actions.conf`.

### Training the filter

Moving a message **into** Spam teaches Rspamd it's spam; moving one **out** teaches it that it isn't.
This works whether the mail app moves the message or uploads it into the folder. Messages that the
server itself files into Spam don't count, so the filter can't learn from its own decisions.

### Where the training data lives — and a bug that only appeared on reboot

The Bayes training data lives in Redis. In v76, SpamAssassin kept its data under `STORAGE_ROOT`, so it
was backed up. Redis defaults to `/var/lib/redis`, **outside the backup**, so we moved it to
`$STORAGE_ROOT/mail/rspamd/redis`. That needed two further fixes:

1. Ubuntu's Redis service is locked down with `ProtectHome=yes`, which hides `/home` from it
   completely. A small systemd override (`/etc/systemd/system/redis-server.service.d/meetrmail.conf`)
   turns that off **for Redis only** and allows writes to that one folder.
2. **A problem that only shows up after a reboot.** A folder-permission change later in the setup
   script took the data folder away from the `redis` user. Redis kept running because it had already
   started — but it couldn't start again. The box would look healthy until the next reboot. Then Redis
   would fail, and **Rspamd would keep running without it**, quietly losing greylisting, Bayes and
   fuzzy matching. Permissions are now set before Redis is restarted, and the self-test restarts Redis
   and Rspamd to prove they come back.

`backup.py` stops Rspamd, then Redis, before backing up, and restarts them in reverse order, so the
saved copy is consistent.

---

## 8. Z-Push / ActiveSync removed

Not used, so removed completely rather than carried forward to PHP 8.3:

- Deleted `setup/zpush.sh` and `conf/zpush/`, and removed it from `setup/start.sh`
- Removed the nginx locations for `/Microsoft-Server-ActiveSync` and `/autodiscover/autodiscover.xml`
- Stopped creating and checking `autodiscover.` subdomains
- Removed the Exchange/ActiveSync sections from the admin panel's mail and sync guides, which would
  otherwise describe a feature that no longer exists
- `php-soap` and `libawl-php` removed with it

The general CalDAV/CardDAV proxy in nginx stays — normal contacts and calendar apps use it.

---

## 9. Bugs found only by actually installing

Each of these was found by installing MeetrMail in a real Ubuntu 24.04 container, not by reading code.

| # | Bug | What would have happened |
|---|---|---|
| 1 | `php8.0-fpm.sock` hard-coded in nginx | Every PHP page fails: webmail, Nextcloud, admin panel |
| 2 | `systemctl link` on a unit already in `/lib/systemd/system` | systemd 255 refuses to enable it; management daemon and munin never start at boot |
| 3 | Both `classifier-bayes.conf` and `statistic.conf` in Rspamd's `local.d` | Rspamd refuses to start ("classifier has no statfiles defined") |
| 4 | `postgrey` still installed by `mail-postfix.sh` | Two greylisting systems running; postgrey was doing the work, not Rspamd |
| 5 | Redis data-folder permissions set in the wrong order | Redis fails at next reboot; spam filtering silently degrades |
| 6 | Redis blocked from `/home` by its systemd lockdown | Redis won't start at all |
| 7 | fail2ban won't start if `/var/log/auth.log` doesn't exist yet | No brute-force protection on a fresh box, with no warning |
| 8 | `tr < /dev/urandom \| head` with `set -o pipefail` | Setup exits with code 141 (a broken-pipe error) |
| 9 | `boto3` missing from the daemon's environment | Admin panel returns HTTP 500 |
| 10 | `sievec` doesn't read plugin settings on its own | Spam-learning scripts can't be compiled |
| 11 | `resolved.conf` missing on minimal images | Setup crashes |

Also changed:

- **The self-signed certificate now has a `subjectAltName`.** Current mail and web clients reject a
  certificate without one outright, rather than just warning. That affects sandbox testing and the
  period on a live box before Let's Encrypt issues a real certificate.
- **The admin panel's update check is off by default.** v76 compares itself to upstream's latest
  version, which a fork never matches, so it would show a permanent "new version available" error.
  To turn it back on for your own MeetrMail, set `VERSION_CHECK_URL` in `/etc/meetrmail.conf`.
- **Some generated config files are now rewritten on every setup run.** Previously some were only
  written when missing, so later fixes never reached existing boxes.

---

## 10. Security hardening found along the way

The self-test checks that internal-only services aren't reachable from the internet. That found two
issues that already existed in v76:

| Service | v76 | Fork | Why it matters |
|---|---|---|---|
| Dovecot quota-status (port 12340) | Listening on all interfaces | **Localhost only** | It answers differently for addresses that exist and ones that don't, so anyone could use it to discover valid mailboxes. Postfix only ever connects over localhost. |
| munin-node (port 4949) | Listening on all interfaces, protected by an app-level allow list | **Localhost only** | The munin master is on the same box; nothing needs to reach it from outside. |

The firewall (ufw) would normally block both ports on a live box. Now they're closed regardless of
firewall settings.

---

## 11. Sandbox mode and the test harness

### Sandbox mode

Lets you install the full box on a laptop, VM or container with no public DNS, no reverse DNS, no
Let's Encrypt and no outbound port 25. It installs exactly the same packages and configuration —
only the steps that need the public internet are changed:

| | Live | Sandbox |
|---|---|---|
| Spamhaus and port-25 checks during install | Yes | Skipped |
| ufw firewall | Yes | Skipped |
| Swapfile, pollinate, random-seed step | Yes | Skipped |
| TLS certificate | Let's Encrypt | Self-signed |
| The box's own domains resolve through | The internet | Local bind9 → local nsd |
| Rspamd internet reputation checks | On | Off |
| Greylist delay | 300 s | 10 s (so it can be tested) |
| `.test` / `.localhost` addresses | Rejected | Allowed |
| Status checks that need the internet | Errors | Informational |
| Nightly Let's Encrypt renewal | Yes | Skipped |

**How the box resolves its own domains:** `tools/sandbox-dns-forward` tells bind9 to send queries for
the box's own domains straight to nsd, and turns off DNSSEC validation for just those domains (their
signing keys aren't registered with the real internet). Switching to live mode removes this cleanly.

```bash
sudo MEETRMAIL_SANDBOX=1 setup/start.sh     # install in sandbox mode
sudo meetrmail-mode status                  # which mode am I in?
sudo meetrmail-mode live                    # switch to live (re-runs setup)
sudo meetrmail-mode sandbox                 # switch back
```

### Test harness

```bash
tests/sandbox/run-container-test.sh    # on your computer: builds a 24.04 container and installs
sudo tests/sandbox/selftest.sh         # on the box: 88 checks
```

The self-test covers services running; ports listening, and internal ports **not** exposed;
config-file validity; software versions; local DNS; TLS; and mail from start to finish — outgoing
DKIM signing, greylisting delaying and then accepting, spam headers, GTUBE test spam being refused,
moving a message to Spam actually training the filter, Redis and Rspamd surviving a restart, and the
web pages responding.

**Final result: 88 passed, 0 failed.**

---

## 12. Package summary: added and removed

### Removed

| Package | Reason |
|---|---|
| `spampd` | Replaced by Rspamd |
| `spamassassin` | Replaced by Rspamd |
| `postgrey` | Replaced by Rspamd greylisting |
| `razor`, `pyzor` | Replaced by Rspamd fuzzy/reputation |
| `dovecot-antispam` | Replaced by Dovecot IMAPSieve |
| `libmail-dkim-perl` | Only needed by SpamAssassin |
| `ntp` | Conflicts with systemd-timesyncd on noble |
| `php-soap`, `libawl-php` | Only needed by Z-Push |
| Z-Push | Not used |
| `virtualenv`, `python3-pip` use by setup | Replaced by uv |
| `ppa:ondrej/php`, `ppa:duplicity-team` | Not needed on noble |

### Added

| Package | Reason |
|---|---|
| `rspamd` (Rspamd repo) | Spam filtering and greylisting |
| `redis-server` | Rspamd's data store |
| `gnupg` | Verifying the Rspamd repository key |
| `uv` 0.12.6 + CPython 3.12 | Python for the management daemon |
| `bind9-host`, `bind9-dnsutils` | DNS tools always available |

### Changed

| Package | From → To |
|---|---|
| PHP | 8.0 → 8.3 |
| `libmagic1` | → `libmagic1t64` |
| Nextcloud | 26.0.13 → 33.0.9 |
| `cryptography` | 37.0.2 → 50.0.1 |

### Unchanged

Postfix, Dovecot, nginx, nsd, bind9, **OpenDKIM, OpenDMARC**, Roundcube 1.6.15, certbot, duplicity,
fail2ban, munin.

---

## 13. What is still open

### Backups (duplicity) — not yet tested end to end

What *has* been confirmed: duplicity installs from the archive, the `b2sdk`/`boto3` backup
environment is built and importable (setup would have stopped otherwise), `backup.py` no longer has
PHP 8.0 hard-coded, and it stops and restarts Rspamd and Redis correctly.

What *hasn't*: an actual backup and restore. The container tests never ran one. To test:

```bash
cd ~/meetrmail
sudo management/backup.py            # run a backup now (add --full for a full backup)
sudo management/backup.py --status   # list the backups that exist
sudo management/backup.py --verify   # check the backup against the live files
sudo management/backup.py --list     # list files inside the backup
```

To test a restore without touching live data, restore into a scratch directory:

```bash
sudo management/backup.py --restore /tmp/restore-test
```

Or use **System → Backup Status** in the admin panel, then confirm files appear in the backup
location (by default `$STORAGE_ROOT/backup/encrypted`). Try restoring one file to a temporary folder
before relying on it. Note that a backup briefly stops Postfix, Dovecot and PHP.

### Deferred work

- **Phase 5b:** move DKIM signing and DMARC into Rspamd, then remove OpenDKIM and OpenDMARC. Needs
  rewrites in `dns_update.py` and `status_checks.py`. Test against Gmail before switching over.
- **Admin panel:** unchanged from v76 — still Bootstrap 3.4.1 and jQuery 2.2.4, both end-of-life.
  See the Power MIAB comparison document.
- **Ubuntu 26.04:** add `26.04` to the version checks only once tested. PHP 8.4's `php-pspell`
  deprecation will affect Roundcube's spellchecker.
