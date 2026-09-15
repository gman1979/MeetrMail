# MeetrMail on Ubuntu 24.04

MeetrMail is an independent, customized mail server stack based on v76 of the
[Mail-in-a-Box](https://github.com/mail-in-a-box/mailinabox) project, ported from Ubuntu
22.04 to 24.04. Same box, same one-command install, newer everything underneath.

Version: **1.0.0** (see [VERSION](VERSION)). Branch: `noble-php83-py312-rspamd`, forked from upstream `v76`.

---

## Installing

On a fresh **Ubuntu 24.04 LTS** machine, as root:

```bash
curl -L https://raw.githubusercontent.com/OWNER/REPO/noble-php83-py312-rspamd/setup/bootstrap.sh | sudo -E bash
```

Replace `OWNER/REPO` with the MeetrMail repository, and set `SOURCE_DEFAULT` at the top of `setup/bootstrap.sh` to
match so the command is self-contained.

Or from a clone:

```bash
sudo setup/start.sh
```

Either way it is the same interactive install as v76 — it asks for your email address and hostname
and does the rest. Re-run `sudo meetrmail-setup` at any time; setup is idempotent.

### Upgrading a box installed under the Mail-in-a-Box names

A box set up before the rename still has `/etc/mailinabox.conf`, the `mailinabox` service and the
`sudo mailinabox` command. Run setup from the updated source tree once (`sudo setup/start.sh`);
`setup/rename-migration.sh` moves the settings, API key, migration counter and backup SSH key to
the MeetrMail names, removes the old service and generated files, and setup recreates them. After
that, use `sudo meetrmail-setup`.

### Installing in sandbox mode, for testing

```bash
sudo MEETRMAIL_SANDBOX=1 setup/start.sh
```

See [Sandbox mode](#sandbox-mode) below.

---

## What changed from v76

| | v76 | here |
|---|---|---|
| Ubuntu | 22.04 | **24.04** |
| PHP | 8.0 (from `ppa:ondrej/php`) | **8.3** (Ubuntu archive) |
| Management daemon Python | system 3.10 + `pip` | **3.12**, installed by `uv` |
| `cryptography` | pinned `==37.0.2` | current (50.x), locked in `uv.lock` |
| Spam filtering | spampd + SpamAssassin | **Rspamd** |
| Greylisting | postgrey | **Rspamd** `greylist` module |
| Spam learning | dovecot-antispam | **Dovecot IMAPSieve** + `rspamc` |
| Nextcloud | 26.0.13, via an upgrade ladder | **33.0.9**, fresh install |
| Exchange/ActiveSync | Z-Push | **removed** |
| DKIM / DMARC | OpenDKIM + OpenDMARC | unchanged, deliberately |
| Third-party apt repos | ondrej/php, duplicity | **Rspamd only** (opt-out available) |

### Why Rspamd

Noble ships SpamAssassin 4.0.0, a major release, and `/etc/default/spamassassin` no longer exists.
Nobody has validated spampd's in-process `Mail::SpamAssassin` embed against SA 4, so keeping the v76
stack would mean debugging someone else's untested integration. Rspamd is a Postfix/Dovecot pairing
that a great many people run, and the unknowns are in configuration you can actually reach.

It also replaces four packages with one, and moves greylisting, Bayes tokens and fuzzy hashes into a
single Redis instance.

### Greylisting behaves differently from postgrey

Worth knowing, because it is a change users will notice.

postgrey deferred **every** first contact from an unknown sender. Rspamd's greylist module defers
only mail that scores into the greylist band — 4.0 to 6.0 by default, set in
`/etc/rspamd/local.d/actions.conf`. Ordinary correspondence from a new contact is no longer delayed
by several minutes; borderline mail still is, and obvious spam is tagged or refused outright without
bothering to greylist it at all.

That is the modern consensus and generally the better trade, but if you want blanket greylisting
back, lower the `greylist` action threshold toward zero in that file.

### Why DKIM signing stays with OpenDKIM

Rspamd can sign DKIM, and eventually it should — that would let OpenDKIM and OpenDMARC be deleted
entirely. But DKIM is the single thing that decides whether Gmail accepts mail from this box, and
moving it means rewriting key generation in `management/dns_update.py` and validation in
`management/status_checks.py`.

So this fork keeps OpenDKIM and OpenDMARC exactly as v76 had them. Rspamd still *verifies* SPF, DKIM
and DMARC with its own modules for scoring — which is better than v76, where SpamAssassin
regex-matched OpenDMARC's `Authentication-Results` header.

Moving DKIM signing into Rspamd is a separate, unhurried piece of work.

---

## Sandbox mode

Sandbox mode lets you install and test the whole box on a laptop, VM or container, with no public
DNS, no PTR record, no Let's Encrypt and no outbound port 25.

It is not a different build. Every package is installed and every service configured exactly as in
live mode — only the steps that require the public internet are stubbed out, and the box's own DNS is
pointed at itself so that everything else can be exercised locally.

| | live | sandbox |
|---|---|---|
| Spamhaus DBL/ZEN checks, port 25 probe at install | yes | skipped |
| ufw firewall | yes | skipped (containers often have no iptables) |
| swapfile, pollinate, `/dev/urandom` reseed | yes | skipped |
| TLS certificate | Let's Encrypt | the self-signed one `ssl.sh` already makes |
| The box's own domains resolve via | the public internet | bind9 → local nsd |
| Rspamd internet reputation modules | on | off (no DNS timeouts per message) |
| Greylist delay | 300s | 10s, so the defer/release cycle can be tested |
| Reserved TLDs (`.test`, `.localhost`) as mail domains | rejected | accepted |
| Control panel checks needing the internet | enforced | reported as informational |

### Switching modes

```bash
sudo meetrmail-mode status     # which mode, and what that means
sudo meetrmail-mode sandbox    # switch to sandbox
sudo meetrmail-mode live       # switch to live
```

Switching re-runs setup, which is idempotent. Mail, users, aliases, DKIM keys and spam-filter
training all live under `STORAGE_ROOT` and are not touched.

---

## Testing

### In a container, from your own machine

```bash
tests/sandbox/run-container-test.sh
```

Builds an Ubuntu 24.04 systemd container under rootless podman, runs the full installer in sandbox
mode, and then runs the self-test suite inside it. Needs no root on the host, no open port 25 and no
real domain.

```bash
tests/sandbox/run-container-test.sh --shell   # poke around inside
tests/sandbox/run-container-test.sh --clean   # remove container and image
```

### On the box itself

```bash
sudo tests/sandbox/selftest.sh
```

88 checks covering services, listening ports (including that the private ones are *not* public),
configuration validity, versions, local DNS, TLS, and mail end to end:

* a locally-submitted message is delivered and **OpenDKIM signed it**, with the right `d=` domain
* a clean inbound message is delivered promptly, and one scoring into the greylist band is
  **deferred and then released on retry** (the threshold is lowered for that one check and put back)
* the delivered message carries `Authentication-Results` and Rspamd's headers
* a GTUBE test message is refused or filed into Spam — not delivered to the INBOX
* moving a message into Spam over IMAP actually trains the filter, checked by watching Rspamd's
  learn counter rather than by assuming the plumbing works
* Redis and Rspamd restart cleanly — "it is running" and "it can start" are not the same claim, and
  a service that only fails at the next reboot is the worst kind
* Roundcube, Nextcloud and the control panel all respond
* IMAP authentication works over cURL's `imap://`, which is the path Nextcloud's `user_external` uses

### What testing cannot cover

Nothing that depends on a third party's opinion of your box. Before pointing production MX at it:

- [ ] outbound port 25 confirmed open; rDNS/PTR resolves to the box hostname
- [ ] the IP is not on a major blocklist
- [ ] a message to Gmail shows `dkim=pass spf=pass dmarc=pass` in the headers
- [ ] a message to Outlook lands in Inbox, not Junk
- [ ] inbound mail from outside reaches INBOX
- [ ] greylisting defers then accepts a real remote sender (check the mail log)
- [ ] drag a message to Spam, confirm Rspamd learned it (`rspamadm stat`)
- [ ] IMAP and SMTP from your actual clients, TLS verified
- [ ] CardDAV and CalDAV sync from a real device
- [ ] control panel status checks all green
- [ ] `nsd-checkconf` clean; your zone resolves from a third-party resolver
- [ ] certbot issued a real certificate and the renewal dry run passes
- [ ] a backup completes

---

## Operating notes

### The Rspamd web interface

Bound to loopback only. Reach it over an SSH tunnel:

```bash
ssh -L 11334:127.0.0.1:11334 you@your-box
```

then open `http://127.0.0.1:11334`. The password is in
`$STORAGE_ROOT/mail/rspamd/controller_password.txt` on the box.

### Training the spam filter

Move a message into the Spam folder to train it as spam; move one out to train it as ham. Dovecot's
IMAPSieve calls `rspamc` for you. Check what it has learned with `rspamadm stat`.

The training data lives in Redis, and Redis's data directory is deliberately set to
`$STORAGE_ROOT/mail/rspamd/redis` rather than the packaged `/var/lib/redis`. v76 kept SpamAssassin's
bayes database under `STORAGE_ROOT` so it was backed up and survived a restore; leaving Redis at its
default would have silently dropped months of training from the backup set. `management/backup.py`
stops Rspamd and then Redis before the backup runs, so the snapshot is consistent.

That needs a small systemd drop-in, `/etc/systemd/system/redis-server.service.d/meetrmail.conf`:
Ubuntu's unit runs with `ProtectHome=yes`, which makes `/home` invisible to the process entirely.
The drop-in turns that off for Redis alone and grants write access to exactly that one directory,
leaving the rest of the unit's hardening in place.

### Avoiding the Rspamd apt repository

The box takes Rspamd from the project's own repository, with its signing key pinned by fingerprint
and apt-pinned to the `rspamd` package alone. Ubuntu's universe has 3.8.1, two majors behind, with no
security-update guarantee — not what you want parsing hostile input on a public mail server.

To use Ubuntu's package instead, and have no third-party apt sources at all:

```bash
sudo RSPAMD_PACKAGE_SOURCE=ubuntu setup/start.sh
```

### Version checking in the control panel

Upstream's control panel checks for updates by fetching `https://mailinabox.email/setup.sh` and
comparing the `TAG=` in it with the box's git tag. MeetrMail's version comes from the `VERSION`
file instead. In a fork that tag will never match, so the panel
would show a permanent, unactionable "a new version is available" error — which teaches people to
ignore the status page.

So version checking is off by default here. To turn it on against your own fork, add to
`/etc/meetrmail.conf`:

```
VERSION_CHECK_URL=https://raw.githubusercontent.com/OWNER/REPO/BRANCH/VERSION
```

Any URL whose body is a version number such as `1.0.0`, or contains a `TAG=<version>` line, works.

### Python dependencies

The management daemon runs on its own CPython, installed by `uv` from `management/pyproject.toml`
and `management/uv.lock`. The system interpreter is never modified, so noble's PEP 668
`EXTERNALLY-MANAGED` marker never comes into it.

To change a dependency: edit `management/pyproject.toml`, run `uv lock` in that directory, and commit
both files.

---

## Still to do

* Move DKIM signing and DMARC into Rspamd; delete OpenDKIM and OpenDMARC. Requires rewriting key
  generation in `dns_update.py` and validation in `status_checks.py`. Budget a day and test against
  Gmail before cutting over.
* The control panel UI is untouched from v76.
* `tools/readable_bash.py` uses `cgi.escape`, removed from Python 3.8. It was already broken in v76
  and is only used to generate documentation.

### Looking ahead to 26.04

* PHP 8.4 removed `ext/imap` from core. This no longer affects Nextcloud —
  `user_external` 4.0.0 authenticates over cURL's `imap://` protocol instead — but Roundcube still
  needs `php-imap`.
* `php-pspell` is deprecated in 8.4; Roundcube's spellcheck will need revisiting.
* `uv` makes the Python side release-independent, so that part should not need work again.
* `setup/preflight.sh` and `setup/bootstrap.sh` both pin `24.04` exactly. Add `26.04` there
  deliberately, once tested.
