# MeetrMail 1.0.0 — Release Changelog

**Released:** 18 September 2026
**Based on:** [Mail-in-a-Box](https://github.com/mail-in-a-box/mailinabox) v76 (24 May 2026)
**Platform:** Ubuntu 24.04 LTS (noble), single server
**License:** CC0 1.0 Universal, unchanged from upstream

MeetrMail 1.0.0 is the first release of MeetrMail, an independent, customized mail server stack
based on v76 of the Mail-in-a-Box project. It is not affiliated with or endorsed by that project.
Our thanks go to Joshua Tauberer and the Mail-in-a-Box contributors, whose work this is built on.

This release covers two bodies of work: porting the v76 codebase to Ubuntu 24.04 with a modernized
spam-filtering and Python stack, and rebranding the result as MeetrMail.

---

## Contents

1. [At a glance](#1-at-a-glance)
2. [Platform and packages](#2-platform-and-packages)
3. [Spam filtering: Rspamd replaces four components](#3-spam-filtering-rspamd-replaces-four-components)
4. [Python: uv and a lockfile](#4-python-uv-and-a-lockfile)
5. [PHP 8.3](#5-php-83)
6. [Nextcloud 33](#6-nextcloud-33)
7. [Exchange / ActiveSync removed](#7-exchange--activesync-removed)
8. [Sandbox mode](#8-sandbox-mode)
9. [Testing](#9-testing)
10. [Security hardening](#10-security-hardening)
11. [Bugs fixed that were found by installing](#11-bugs-fixed-that-were-found-by-installing)
12. [Rebranding to MeetrMail](#12-rebranding-to-meetrmail)
13. [Versioning](#13-versioning)
14. [Upgrading an existing box](#14-upgrading-an-existing-box)
15. [Known limitations](#15-known-limitations)

---

## 1. At a glance

| | Mail-in-a-Box v76 | MeetrMail 1.0.0 |
|---|---|---|
| Ubuntu | 22.04 | **24.04 LTS** |
| PHP | 8.0 (from `ppa:ondrej/php`) | **8.3** (Ubuntu archive) |
| Management daemon Python | system 3.10 + `pip` | **3.12**, installed by `uv`, locked |
| Spam filtering | spampd + SpamAssassin | **Rspamd** |
| Greylisting | postgrey | **Rspamd** `greylist` module |
| Spam learning | dovecot-antispam | **Dovecot IMAPSieve** + `rspamc` |
| Nextcloud | 26.0.13, via an upgrade ladder | **33.0.9**, fresh install |
| Exchange / ActiveSync | Z-Push | **removed** |
| DKIM / DMARC | OpenDKIM + OpenDMARC | unchanged, deliberately |
| Third-party apt repos | ondrej/php, duplicity | **Rspamd only** (opt-out available) |
| Local testing | Vagrant VM | **Sandbox mode** + container harness |
| Setup command | `sudo mailinabox` | `sudo meetrmail-setup` |

Unchanged on purpose: Postfix, Dovecot, nginx, nsd, OpenDKIM, OpenDMARC, Roundcube, duplicity,
fail2ban, munin, and the control panel's features and API surface.

---

## 2. Platform and packages

Every package name was verified against the real noble package indexes before any code changed.

| Component | v76 on 22.04 | MeetrMail on 24.04 |
|---|---|---|
| Postfix | 3.6 | 3.8.6 |
| Dovecot | 2.3.16 | 2.3.21 |
| nsd | 4.3.9 | 4.8.0 |
| fail2ban | 0.11 | 1.0.2 |
| PHP | 8.0 (PPA) | 8.3.6 |
| duplicity | PPA build | 2.1.4 |

**Added:** `rspamd` (from the Rspamd repository), `redis-server`, `gnupg`, `uv` 0.12.6 with its own
CPython 3.12, `bind9-host` and `bind9-dnsutils` (so DNS tools are always present).

**Removed:** `spampd`, `spamassassin`, `postgrey`, `razor`, `pyzor`, `dovecot-antispam`,
`libmail-dkim-perl`, `ntp` (a transitional package on noble that fights `systemd-timesyncd`),
`php-soap` and `libawl-php` (Z-Push only), setup's use of `virtualenv` and `python3-pip`, and the
`ondrej/php` and `duplicity-team` PPAs.

**Changed:** `libmagic1` → `libmagic1t64` (noble's 64-bit `time_t` transition). `python3` is now
installed at the very start of setup, because `tools/editconf.py` and `setup/migrate.py` run before
anything else would have installed it.

**nsd 4.8:** `setup/dns.sh` now runs `nsd-checkconf` on the generated config immediately after
install, so an unsupported directive fails with a precise message instead of a mysterious service
failure later. It also creates `/etc/nsd/nsd.conf.d` before the config references it.

---

## 3. Spam filtering: Rspamd replaces four components

**Why.** Noble ships SpamAssassin 4.0.0, a major release, and `/etc/default/spamassassin` no longer
exists. Nobody has validated spampd's in-process `Mail::SpamAssassin` embed against SA 4, so keeping
the v76 stack would have meant debugging someone else's untested integration. Rspamd is a
well-trodden Postfix/Dovecot pairing, replaces four packages with one, and consolidates greylisting,
Bayes tokens and fuzzy hashes into a single Redis instance.

**Where it runs.** v76 put spampd in the delivery path. Rspamd instead checks mail during the SMTP
conversation, as a milter, and Postfix then delivers straight to Dovecot:

- **Port 25 (incoming):** OpenDKIM → OpenDMARC → Rspamd. Rspamd runs last so it can see the
  `Authentication-Results` header the other two add.
- **Ports 465/587 (your users sending):** OpenDKIM only.

Because it runs before the message is accepted, greylisting no longer needs a separate daemon.

**Greylisting behaves differently, and users will notice.** postgrey deferred *every* first contact
from an unknown sender. Rspamd defers only mail scoring into the greylist band (4.0–6.0 by default,
in `/etc/rspamd/local.d/actions.conf`). Ordinary mail from a new contact is no longer delayed by
minutes; borderline mail still is, and obvious spam is tagged or refused outright. To restore
blanket greylisting, lower the `greylist` action threshold toward zero.

**Spam learning** moved from dovecot-antispam to Dovecot IMAPSieve calling `rspamc`: moving a message
into Spam trains it as spam, moving it out trains it as ham.

**DKIM signing deliberately stays with OpenDKIM.** Rspamd can sign DKIM, and eventually it should —
that would let OpenDKIM and OpenDMARC be removed entirely. But DKIM decides whether Gmail accepts
mail from the box, and moving it means rewriting key generation in `management/dns_update.py` and
validation in `management/status_checks.py`. Rspamd still *verifies* SPF, DKIM and DMARC with its own
modules for scoring, which is better than v76, where SpamAssassin regex-matched OpenDMARC's headers.

**Redis storage and two fixes it required.** Redis data lives under `STORAGE_ROOT` so it is backed up
with everything else:

1. Ubuntu's Redis service runs with `ProtectHome=yes`, which hides `/home` from it entirely. A
   systemd drop-in turns that off for Redis only, and allows writes to that one folder.
2. **A failure that only appeared after a reboot.** A folder-permission change later in setup took
   the data folder away from the `redis` user. Redis kept running because it had already started, so
   the box looked healthy until the next reboot — at which point Redis would fail and **Rspamd would
   keep running without it**, quietly losing greylisting, Bayes and fuzzy matching. Permissions are
   now set before Redis is restarted, and the self-test restarts both to prove they come back.

`backup.py` stops Rspamd, then Redis, before backing up, and restarts them in reverse order, so the
saved copy is consistent.

---

## 4. Python: uv and a lockfile

| | v76 | MeetrMail 1.0.0 |
|---|---|---|
| Interpreter | System Python 3.10 | CPython 3.12.14, installed by uv |
| Installer | `pip install --upgrade` (floating versions) | `uv sync --frozen` from a lockfile |
| Dependency list | Inline in a shell script | `management/pyproject.toml` |
| Reproducibility | None — versions drift on every install | `management/uv.lock` pins every package and hash |
| uv itself | — | v0.12.6, pinned, SHA-256 verified |

uv installs its own CPython, so the system Python is never modified and noble's PEP 668
`EXTERNALLY-MANAGED` marker is irrelevant. `cryptography` is no longer pinned to 37.0.2.

A new `setup/uv.sh` installs uv before the setup questions run, since those questions validate an
email address with Python. duplicity runs on the *system* Python, so its `b2sdk` and `boto3` go into
a separate environment built against `/usr/bin/python3`, which `backup.py` puts on duplicity's path.
Setup fails loudly if those backends aren't importable, rather than at 3am when the first backup runs.

---

## 5. PHP 8.3

`PHP_VER=8.0` → `PHP_VER=8.3`, from noble's stock archive rather than a PPA. Every required module
exists there: `cli fpm sqlite3 gd imap curl dev xml mbstring zip intl gmp bcmath apcu imagick common
pspell`.

---

## 6. Nextcloud 33

| | v76 | MeetrMail 1.0.0 |
|---|---|---|
| Nextcloud | 26.0.13 | **33.0.9** |
| contacts | 5.5.3 | 8.8.1 |
| calendar | 4.7.6 | 6.5.4 |
| user_external | 3.3.0 | 4.0.0 |

**Why 33:** PHP 8.3 is a supported version for it, and `user_external` 4.0.0 — which lets you log in
to Nextcloud with your mail password — supports Nextcloud 31 to 34 only. Each app's `info.xml` was
checked.

- **The upgrade ladder is gone.** v76 stepped old installs through Nextcloud 20 → 25 one version at a
  time. If an existing install of a different major version is found, setup now stops and explains
  why instead of risking a broken upgrade.
- **Apps come from official release packages.** v76 downloaded GitHub's automatic source archives,
  which unpack into the wrong folder name and omit the built JavaScript — a latent bug in v76 itself.

---

## 7. Exchange / ActiveSync removed

Z-Push was unused, so it was removed rather than carried forward to PHP 8.3: `setup/zpush.sh` and
`conf/zpush/` deleted; the nginx locations for `/Microsoft-Server-ActiveSync` and
`/autodiscover/autodiscover.xml` removed; `autodiscover.` subdomains no longer created or checked;
and the Exchange sections removed from the control panel's mail and sync guides, which would
otherwise describe a feature that no longer exists. The general CalDAV/CardDAV proxy stays — normal
contacts and calendar apps use it.

---

## 8. Sandbox mode

**New in MeetrMail.** Sandbox mode installs and runs the whole box on a laptop, VM or container with
no public DNS, no PTR record, no Let's Encrypt and no outbound port 25. It is not a different build:
every package is installed and every service configured as in live mode, and only the steps that
require the public internet are stubbed out.

| | Live | Sandbox |
|---|---|---|
| Spamhaus and port-25 checks during install | Yes | Skipped |
| ufw firewall | Yes | Skipped (containers often have no iptables) |
| Swapfile, pollinate, random-seed step | Yes | Skipped |
| TLS certificate | Let's Encrypt | Self-signed |
| The box's own domains resolve through | The internet | Local bind9 → local nsd |
| Rspamd internet reputation checks | On | Off |
| Greylist delay | 300 s | 10 s, so the cycle can be tested |
| `.test` / `.localhost` as mail domains | Rejected | Allowed |
| Status checks needing the internet | Errors | Informational |
| Nightly Let's Encrypt renewal | Yes | Skipped |

```bash
sudo MEETRMAIL_SANDBOX=1 setup/start.sh     # install in sandbox mode
sudo meetrmail-mode status                  # which mode am I in?
sudo meetrmail-mode live                    # switch to live (re-runs setup)
sudo meetrmail-mode sandbox                 # switch back
```

`tools/sandbox-dns-forward` points bind9 at the local nsd for the box's own domains and disables
DNSSEC validation for just those domains, since their signing keys aren't registered with the real
internet. Switching to live mode removes this cleanly. Mail, users, aliases, DKIM keys and
spam-filter training live under `STORAGE_ROOT` and are never touched by a mode switch.

---

## 9. Testing

```bash
tests/sandbox/run-container-test.sh    # on your computer: builds a 24.04 container and installs
sudo tests/sandbox/selftest.sh         # on the box: 88 checks
```

The self-test covers services running; ports listening, and internal ports **not** exposed; config
file validity; software versions; local DNS; TLS; and mail end to end — outgoing DKIM signing,
greylisting deferring and then accepting, spam headers, GTUBE test spam being refused, moving a
message to Spam actually training the filter, Redis and Rspamd surviving a restart, and the web pages
responding.

**Result: 88 passed, 0 failed.**

---

## 10. Security hardening

Two issues that already existed in v76, found by the self-test checking that internal services aren't
reachable from outside:

| Service | v76 | MeetrMail 1.0.0 | Why it matters |
|---|---|---|---|
| Dovecot quota-status (port 12340) | All interfaces | **Localhost only** | It answers differently for mailboxes that exist and ones that don't, so it could be used to discover valid addresses. Postfix only ever connects over localhost. |
| munin-node (port 4949) | All interfaces, app-level allow list | **Localhost only** | The munin master is on the same box. |

ufw would normally block both on a live box; now they are closed regardless of firewall state.

---

## 11. Bugs fixed that were found by installing

Each was found by installing into a real Ubuntu 24.04 container, not by reading code.

| Bug | What would have happened |
|---|---|
| `php8.0-fpm.sock` hard-coded in nginx | Every PHP page fails: webmail, Nextcloud, control panel |
| `systemctl link` on a unit already in `/lib/systemd/system` | systemd 255 refuses to enable it; the management daemon and munin never start at boot |
| Both `classifier-bayes.conf` and `statistic.conf` in Rspamd's `local.d` | Rspamd refuses to start ("classifier has no statfiles defined") |
| Redis data folder permissions set after Redis restarts | Silent loss of greylisting, Bayes and fuzzy matching after the next reboot |
| Nightly Let's Encrypt renewal attempted on a sandbox box | Nightly failures on a box with no public DNS |

---

## 12. Rebranding to MeetrMail

A complete rename, with no functional change of its own.

**Command line**

| Was | Now |
|---|---|
| `sudo mailinabox` | `sudo meetrmail-setup` |
| — (new in MeetrMail) | `meetrmail-mode` |
| — (new in MeetrMail) | `MEETRMAIL_SANDBOX=1` |

**Paths and services**

| Was | Now |
|---|---|
| `/etc/mailinabox.conf` | `/etc/meetrmail.conf` |
| `/usr/local/lib/mailinabox` | `/usr/local/lib/meetrmail` |
| `/var/lib/mailinabox` | `/var/lib/meetrmail` |
| `/var/cache/mailinabox` | `/var/cache/meetrmail` |
| `mailinabox.service` | `meetrmail.service` |
| `/root/.ssh/id_rsa_miab` | `/root/.ssh/id_rsa_meetrmail` |
| `$STORAGE_ROOT/mailinabox.version` | `$STORAGE_ROOT/meetrmail.version` |
| `mailinabox-*` cron jobs, `miab-*` fail2ban filters | `meetrmail-*` |
| `/mailinabox.mobileconfig` | `/meetrmail.mobileconfig` |

**Files renamed:** `api/mailinabox.yml` → `api/meetrmail.yml`, `conf/mailinabox.service` →
`conf/meetrmail.service`, the fail2ban filter files, and the two documents under `docs/`.

**User-visible text** in the control panel, setup, status checks, the API spec, mobile-config
profiles, the Postfix SMTP banner and the default web page now say MeetrMail. Project links point to
`meetrmail.net`.

**Attribution and licensing**

- The README states plainly that MeetrMail is an independent stack based on Mail-in-a-Box v76, that
  it is not affiliated with or endorsed by that project, and thanks its authors.
- Licensing is unchanged: **CC0 1.0 Universal**, so anyone may fork MeetrMail in turn. The README
  clarifies that this covers only the code in this repository — Postfix, Dovecot, nginx, Nextcloud,
  Roundcube, Rspamd, OpenDKIM and the rest are distributed separately under their own licenses.
- Links to upstream GitHub issues and forum threads are kept as citations, the Mail-in-a-Box release
  history is preserved in `CHANGELOG.md`, and comments describing upstream behavior still name it.

---

## 13. Versioning

The version lives in a single `VERSION` file, read by setup, the control panel status checks,
`management/status_checks.py --version` and the API spec. It no longer depends on `git describe`, so
the version is correct even when the source is copied to a server without its `.git` folder.

Update checking remains off by default: upstream's check compares against a tag that a fork never
matches, which would show a permanent, unactionable "new version available" error. To enable it, set
`VERSION_CHECK_URL` in `/etc/meetrmail.conf` to a URL whose body is a version number or contains a
`TAG=<version>` line.

---

## 14. Upgrading an existing box

A box installed under the old Mail-in-a-Box names is migrated automatically by
`setup/rename-migration.sh` on the first setup run from the MeetrMail source:

```bash
cd ~/meetrmail && sudo setup/start.sh
```

It moves the settings file, the migration counter, the API key and generated client configs, and the
backup SSH key (whose public half may already be authorized on a remote backup server); stops and
removes the old service; and deletes generated files under their old names, which setup then recreates
under the new ones. Mail, users, DKIM keys and TLS certificates are untouched. You will need to sign
in to the control panel again. After this first run, use `sudo meetrmail-setup`.

**Take a backup or snapshot first.** The migration path is new.

---

## 15. Known limitations

- **DKIM signing still runs through OpenDKIM**, not Rspamd. Moving it is separate, unhurried work.
- **The Rspamd apt repository** is the one remaining third-party repository. Install with
  `RSPAMD_PACKAGE_SOURCE=ubuntu` to use noble's own Rspamd instead.
- **Nextcloud major-version upgrades from an older box are not supported.** Setup stops and explains
  rather than attempting a risky upgrade.
- **Ubuntu 24.04 only.** Setup refuses to run on any other release.

---

*MeetrMail is developed and maintained by Grant. Based on Mail-in-a-Box v76 by Joshua Tauberer and
contributors, used under CC0 1.0.*
