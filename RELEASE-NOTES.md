# MeetrMail 1.0.0

**MeetrMail is an independent, customized mail server stack based on v76 of the
[Mail-in-a-Box](https://github.com/mail-in-a-box/mailinabox) project.** It is not affiliated with or
endorsed by that project. Our thanks to Joshua Tauberer and the Mail-in-a-Box contributors, whose
work this is built on.

This first release ports the v76 codebase to **Ubuntu 24.04 LTS**, replaces the spam-filtering and
Python stacks, adds a sandbox mode for local testing, and rebrands the result as MeetrMail.

Requires a fresh **Ubuntu 24.04 LTS** 64-bit machine dedicated to MeetrMail.

```bash
git clone <this repo> meetrmail && cd meetrmail
sudo setup/start.sh          # first install
sudo meetrmail-setup         # re-run setup any time afterwards
```

## What's different from Mail-in-a-Box v76

| | v76 | MeetrMail 1.0.0 |
|---|---|---|
| Ubuntu | 22.04 | **24.04 LTS** |
| PHP | 8.0 (from a PPA) | **8.3** (Ubuntu archive) |
| Management daemon Python | system 3.10 + `pip` | **3.12** via `uv`, pinned in a lockfile |
| Spam filtering | spampd + SpamAssassin | **Rspamd** |
| Greylisting | postgrey | **Rspamd** `greylist` module |
| Spam learning | dovecot-antispam | **Dovecot IMAPSieve** + `rspamc` |
| Nextcloud | 26.0.13, via an upgrade ladder | **33.0.9**, fresh install |
| Exchange / ActiveSync | Z-Push | **removed** |
| Third-party apt repos | ondrej/php, duplicity | **Rspamd only** (opt-out available) |
| Local testing | Vagrant VM | **Sandbox mode** + container harness |

Postfix, Dovecot, nginx, nsd, OpenDKIM, OpenDMARC, Roundcube, duplicity, fail2ban, munin and the
control panel's features and API are unchanged.

## Highlights

- **Rspamd replaces four packages.** Spam filtering, greylisting, Bayes and fuzzy hashes now run in
  one service backed by Redis, checked during the SMTP conversation rather than at delivery.
- **Reproducible Python.** `uv` installs its own CPython 3.12 and every dependency is pinned in
  `management/uv.lock`. The system Python is never modified.
- **Sandbox mode.** Install and exercise the whole box on a laptop, VM or container with no public
  DNS, no Let's Encrypt and no outbound port 25 — same packages, same configuration.
  Switch with `sudo meetrmail-mode sandbox|live|status`.
- **A real test harness.** `tests/sandbox/run-container-test.sh` builds an Ubuntu 24.04 container and
  installs into it; `sudo tests/sandbox/selftest.sh` runs 88 on-box checks covering services, exposed
  ports, config validity, DNS, TLS and mail end to end. **88 passed, 0 failed.**
- **Two exposures closed** that existed in v76: Dovecot's quota-status service (port 12340) and
  munin-node (port 4949) now listen on localhost only, regardless of firewall state.
- **Five install-time bugs fixed**, found by installing into a real 24.04 container — including a
  Redis permission bug that would silently disable greylisting, Bayes and fuzzy matching after the
  next reboot.

## Behavior change worth knowing

**Greylisting is no longer blanket.** postgrey deferred *every* first contact from an unknown sender.
Rspamd defers only mail scoring into the greylist band (4.0–6.0 by default, in
`/etc/rspamd/local.d/actions.conf`). Ordinary mail from a new contact arrives without a delay of
several minutes; borderline mail is still deferred, and obvious spam is refused outright. To restore
blanket greylisting, lower the `greylist` action threshold toward zero.

## Rebranding

| Was | Now |
|---|---|
| `sudo mailinabox` | `sudo meetrmail-setup` |
| — (new in MeetrMail) | `meetrmail-mode` |
| — (new in MeetrMail) | `MEETRMAIL_SANDBOX=1` |
| `/etc/mailinabox.conf` | `/etc/meetrmail.conf` |
| `/usr/local/lib/mailinabox`, `/var/lib/mailinabox` | `/usr/local/lib/meetrmail`, `/var/lib/meetrmail` |
| `mailinabox.service` | `meetrmail.service` |
| `/root/.ssh/id_rsa_miab` | `/root/.ssh/id_rsa_meetrmail` |

The version now lives in the `VERSION` file, read by setup, the control panel and the API, so it is
correct even when the source is copied to a server without its `.git` folder. Update checking stays
off by default; set `VERSION_CHECK_URL` in `/etc/meetrmail.conf` to enable it.

## Upgrading a box installed under the Mail-in-a-Box names

Run setup once from the MeetrMail source and the rename is handled for you:

```bash
cd ~/meetrmail && sudo setup/start.sh
```

`setup/rename-migration.sh` moves the settings, API key, migration counter and backup SSH key, stops
and removes the old service, and lets setup recreate the generated files under the new names. Mail,
users, DKIM keys and TLS certificates are untouched; you'll sign in to the control panel again.
**Take a backup or snapshot first** — this migration path is new.

## Known limitations

- DKIM signing still runs through OpenDKIM, not Rspamd. Rspamd verifies SPF, DKIM and DMARC for
  scoring.
- The Rspamd apt repository is the one remaining third-party repository. Use
  `RSPAMD_PACKAGE_SOURCE=ubuntu` to install noble's own Rspamd instead.
- Nextcloud major-version upgrades from an older box are not supported; setup stops and explains.
- Ubuntu 24.04 only. Setup refuses to run on any other release.

## Documentation

- [FORK.md](FORK.md) — install, sandbox mode, testing, operating notes
- [CHANGELOG-MeetrMail-1.0.0.md](CHANGELOG-MeetrMail-1.0.0.md) — the full release changelog
- [docs/01-MeetrMail-Ubuntu-24.04-Port.md](docs/01-MeetrMail-Ubuntu-24.04-Port.md) — how the port was done
- [CHANGELOG.md](CHANGELOG.md) — MeetrMail plus the Mail-in-a-Box release history through v76

## License

CC0 1.0 Universal, carried over from Mail-in-a-Box. This covers the code in this repository only;
Postfix, Dovecot, nginx, Nextcloud, Roundcube, Rspamd, OpenDKIM and the rest are distributed
separately under their own licenses.
