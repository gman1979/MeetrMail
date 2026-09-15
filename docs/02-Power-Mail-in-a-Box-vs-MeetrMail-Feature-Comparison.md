# Power Mail-in-a-Box v60.5 vs Mail-in-a-Box v76

**What Power MIAB added, what upstream has added since, and what we could port to our Ubuntu 24.04 fork**

| | |
|---|---|
| Power MIAB repository | [github.com/ddavness/power-mailinabox](https://github.com/ddavness/power-mailinabox) |
| Power MIAB version compared | **v60.5** (tagged 21 Nov 2022) |
| Upstream compared | **Mail-in-a-Box v76** (24 May 2026), as the base of MeetrMail |
| Method | Both codebases read and compared directly — admin panel templates, API routes, setup scripts — not just the READMEs |
| Licence | Both **CC0 1.0** (public domain), so code can be ported freely |

---

## Contents

1. [Summary](#1-summary)
2. [The state of Power MIAB](#2-the-state-of-power-miab)
3. [Admin panel menus side by side](#3-admin-panel-menus-side-by-side)
4. [Features Power MIAB has that MeetrMail does not](#4-features-power-miab-has-that-meetrmail-does-not)
5. [Advertised features that upstream already has](#5-advertised-features-that-upstream-already-has)
6. [What MeetrMail has that Power MIAB v60.5 does not](#6-what-meetrmail-has-that-power-miab-v605-does-not)
7. [Porting recommendations](#7-porting-recommendations)
8. [How to port safely](#8-how-to-port-safely)

---

## 1. Summary

The fuller menu bar you noticed is partly **layout** — Power MIAB puts "Advanced" in its own top-level
menu and gives normal users a "Your Account" menu (see [section 3](#3-admin-panel-menus-side-by-side)) —
and partly **real extra pages**. Its admin panel has **four pages ours doesn't**:

- **SMTP Relays** — send outgoing mail through an external relay service
- **PGP Keyring** — manage OpenPGP keys on the server
- **WKD** — publish OpenPGP keys so mail apps can find them automatically
- **Manage Password** — lets ordinary (non-admin) users change their own password

It also adds three smaller features inside existing pages:

- **"Backup Now" buttons** (full and incremental) on the Backup page
- **TTL (cache time) per custom DNS record**
- **A default quota** applied to new mailboxes

Plus a **redesigned admin panel** on Bootstrap 5 / jQuery 3.6. Ours is still on Bootstrap 3.4 /
jQuery 2.2, both end-of-life.

The catch: **Power MIAB stopped at v60.5 in late 2022.** Upstream Mail-in-a-Box moved on through
sixteen more releases, including security fixes Power MIAB never received. Power MIAB also still uses
SpamAssassin, postgrey and Z-Push, and supports only Ubuntu 20.04/22.04 and Debian 11. It's a useful
source of **features to copy**, not something to merge into MeetrMail.

**Suggested order:** Manage Password → Backup Now → *(decide on the admin panel redesign)* → Default
Quota → DNS TTLs → SMTP Relays (with Phase 5b) → PGP/WKD only if wanted. Details in
[section 7](#7-porting-recommendations).

---

## 2. The state of Power MIAB

| | Power MIAB | Our fork |
|---|---|---|
| Latest release | v60.5 — November 2022 | Based on v76 — May 2026 |
| Last commit on `main` | 12 February 2023 | Active |
| Supported OS | Debian 11, Ubuntu 20.04, Ubuntu 22.04 | Ubuntu 24.04 |
| PHP | 8.0 (PPA) | 8.3 (Ubuntu archive) |
| Python packages | pip, `cryptography==2.2.2` pinned | uv + lockfile, `cryptography` 50.0.1 |
| Spam filtering | spampd + SpamAssassin + postgrey | Rspamd + Redis |
| ActiveSync | Z-Push | Removed |
| Admin panel | Bootstrap 5.2.2, jQuery 3.6.1 | Bootstrap 3.4.1, jQuery 2.2.4 |

Power MIAB pins `cryptography==2.2.2` (2018), an even older version than v76's `37.0.2`. It wouldn't
install on Python 3.12 either.

Power MIAB also has several **unreleased work-in-progress branches** that were never merged. Two are
worth a look later:

- `dev-cmd-imap-importer` — a command-line tool for importing mail from another IMAP server (useful
  for migrating mailboxes onto the box)
- `dev-roundcube-pw-miab-driver` — a Roundcube password-change plugin that talks to the Mail-in-a-Box
  API

Others (`dev-nginx-upstream-conf`, `dev-refactor-admin-panel-deep`, etc.) are unfinished.

---

## 3. Admin panel menus side by side

### Why Power MIAB's top bar looks fuller

Part of the difference is **layout**, not extra features. Power MIAB turns our "Advanced Pages"
sub-section into its own top-level **Advanced** menu, and gives non-admin users a separate **Your
Account** menu.

**Top-level menus, logged in as an admin:**

| Power MIAB v60.5 | Our fork (v76) |
|---|---|
| System | System |
| **Advanced** | *(inside System, under an "Advanced Pages" heading)* |
| Mail | Mail |
| Contacts/Calendar | Contacts/Calendar |
| Web | Web |

**Top-level menus, logged in as a normal user:**

| Power MIAB v60.5 | Our fork (v76) |
|---|---|
| **Your Account** (Manage Password, Two-Factor) | — |
| Mail Guide | Mail |
| Contacts/Calendar | Contacts/Calendar |

### System menu

| Power MIAB v60.5 | Our fork (v76) | Notes |
|---|---|---|
| Status Checks | Status Checks | Same page |
| TLS (SSL) Certificates | TLS (SSL) Certificates | Same page |
| Backup Status | Backup Status | Power MIAB adds "Backup Now" buttons |
| **SMTP Relays** | — | **Power MIAB only** |

### Advanced menu (Power MIAB) / "Advanced Pages" section (ours)

| Power MIAB v60.5 | Our fork (v76) | Notes |
|---|---|---|
| Custom DNS | Custom DNS | Power MIAB adds a TTL field |
| External DNS | External DNS | Same |
| **PGP Keyring Management** | — | **Power MIAB only** |
| **WKD Management** | — | **Power MIAB only** |
| Munin Monitoring | Munin Monitoring | Same |

### Mail menu (admin)

| Power MIAB v60.5 | Our fork (v76) | Notes |
|---|---|---|
| Mail Guide | Instructions | Same page; ours has the ActiveSync section removed |
| Users | Users | Power MIAB adds a default quota |
| Aliases | Aliases | Same |
| Your Account → Two-Factor Authentication | Your Account → Two-Factor Authentication | Same |

### Your Account menu (normal users)

| Power MIAB v60.5 | Our fork (v76) | Notes |
|---|---|---|
| **Manage Password** | — | **Power MIAB only** |
| Two-Factor Authentication | — | Our normal users have no account menu at all |

**Porting the layout itself is a small change:** splitting "Advanced" into its own top-level menu and
adding a "Your Account" menu is a few lines in `management/templates/index.html`, independent of the
features behind them.

### Behind the menus

Power MIAB's management server has **61** API routes; ours has **49**. The extra ones:

```
POST /system/backup/new            Backup Now
GET/POST /system/default-quota     Default quota
GET/POST /system/smtp/relay        SMTP relay settings
GET  /system/pgp/                  List keys
GET  /system/pgp/<fpr>              View a key
DELETE /system/pgp/<fpr>            Delete a key
GET  /system/pgp/<fpr>/export      Export a key
POST /system/pgp/import            Import a key
GET/POST /system/pgp/wkd           WKD settings
```

---

## 4. Features Power MIAB has that MeetrMail does not

Effort ratings are relative: **S** = an evening, **M** = a weekend, **L** = several weekends.

### 4.1 SMTP Relays — Effort: M · Value: High

**What it does.** Instead of delivering outgoing mail directly on port 25, the box sends it through a
relay service — for example Mailgun, Amazon SES, SMTP2GO or your hosting provider's relay. The page
lets you set:

- Relay host, port, username and password
- "Authorized servers" — added to your SPF record so receivers accept mail from the relay
- The relay's own DKIM selector and public key, published in your DNS

**How it works.** Configures Postfix's `relayhost` with SASL login (`smtp_sasl_password_maps` using
`/etc/postfix/sasl_passwd`). Settings are stored in the box's `settings.yaml`. `dns_update.py` adds the
relay's SPF entries and DKIM record automatically.

**Why it matters to us.** Many VPS providers block outbound port 25 or give new IPs poor reputation.
A relay is the standard way around both. Your box works fine directly today, but this is a useful
fallback if deliverability ever drops or you move providers.

**Porting notes.**
- The Postfix part is straightforward.
- The DNS part (SPF and relay DKIM records) touches `dns_update.py` — the same file **Phase 5b** (moving
  DKIM into Rspamd) will change. Do them together, or do the relay first and design 5b around it.
- The saved password must never appear in logs or error messages.
- The page is written for Bootstrap 5, so its HTML would need adapting to our Bootstrap 3 panel.

**Size in Power MIAB:** `smtp-relays.html` (322 lines) plus routes in `daemon.py` and changes to
`mail-postfix.sh` and `dns_update.py`.

---

### 4.2 Manage Password (for non-admin users) — Effort: S · Value: Medium

**What it does.** A page where a normal mail user can change their own password — which changes it
for both the admin panel and email.

**Our fork already has the API** (`POST /mail/users/password`). Power MIAB only adds the page and a menu
entry. Right now a non-admin user has to use Roundcube's password plugin or ask an admin.

**Porting notes.** The template is 57 lines. The main work is the menu entry that shows only for
non-admin users, and adapting the markup to Bootstrap 3. **The easiest item on this list.**

---

### 4.3 Backup Now — Effort: S · Value: Medium

**What it does.** "Create Full Backup Now" and "Create Incremental Backup Now" buttons on the Backup
page, so you don't have to wait for the 1 am nightly run.

**Relevant to you now:** you haven't yet tested duplicity. This button would make a first test backup
a single click.

**Porting notes.**
- The route is short. It calls the same `perform_backup()` the nightly job uses.
- **Warning:** Power MIAB runs the backup *inside the web request*. A backup stops Postfix, Dovecot and
  PHP while it runs, and the web request times out after about 10 minutes. On a mailbox of any size,
  a better port starts the backup in the background and lets the page check on it.
- Ask for confirmation first — clicking it takes mail offline for the duration.

---

### 4.4 Default Quota — Effort: S · Value: Low–Medium

**What it does.** Sets a quota automatically applied to every new mailbox.

**Upstream already has per-user quotas** (v73, July 2025), so MeetrMail can set a quota on each user.
Power MIAB adds only the default. Adding it is small: one setting, one route, one field on the Users page.

---

### 4.5 Custom DNS TTLs — Effort: S–M · Value: Low–Medium

**What it does.** Adds a TTL field to each custom DNS record, so you can choose how long other DNS
servers cache it. Power MIAB defaults to 24 hours, with limits of 30 seconds to 30 days.

**Why it's useful.** Lowering a TTL before changing a record (moving a website, changing providers)
makes the change take effect quickly. Your go-live checklist had "lower TTLs" as a step.

**Porting notes.** Changes how custom records are stored and how zone files are written, both in
`dns_update.py`. Existing records need to keep working with no TTL set. Test with `nsd-checkconf` and
by querying from outside.

---

### 4.6 PGP Keyring — Effort: M · Value: Low (niche)

**What it does.** Creates an OpenPGP keypair for the box (under `$STORAGE_ROOT/.gnupg`) and provides a
page to import, view, export and delete public keys.

**Stated purpose.** The foundation for WKD (below) and, eventually, encrypting backups with PGP.
**That backup-encryption feature was never finished** in Power MIAB.

**Porting notes.** Adds `setup/pgp.sh`, `management/pgp.py` (178 lines) and `pgp-keyring.html` (298
lines). Needs `gnupg`, which MeetrMail already installs for the Rspamd repository key. Only worth doing
if you plan to use WKD.

---

### 4.7 WKD (Web Key Directory) — Effort: M · Value: Low (niche)

**What it does.** Publishes your users' OpenPGP public keys at
`https://openpgpkey.<domain>/.well-known/openpgpkey/...`, so PGP-capable mail apps such as
Thunderbird and GnuPG can find a recipient's key automatically and send them encrypted mail.

**How it works.** `management/wkd.py` (254 lines) builds the key directory. A new nginx file
(`conf/nginx-openpgpkey.conf`) serves it, and `dns_update.py` adds an `openpgpkey.` record for each
mail domain.

**Porting notes.** Needs the PGP Keyring first. The new `openpgpkey.` subdomain also needs a TLS
certificate and a status check. Only worthwhile if you or your users
actually use PGP email.

---

### 4.8 Redesigned admin panel — Effort: L · Value: Medium–High long term

**What it does.** Rewrites every admin page on Bootstrap 5.2.2 and jQuery 3.6.1.

**Why it matters.** Our panel (from v76) uses:

- **Bootstrap 3.4.1** — end-of-life since 2019
- **jQuery 2.2.4** — end-of-life, with published cross-site-scripting vulnerabilities fixed in 3.5.0

The practical risk is limited because the panel is admin-only and behind a login, but it's the oldest
part of the stack.

**Porting notes.** This is the "Track B" work from the original plan. **Don't copy Power MIAB's panel
wholesale**: it's the v60.5 panel, so it lacks everything upstream added to the UI in v61–v76
(per-user quotas, backup status in status checks, S3 region and credentials, accessibility fixes,
bookmarkable pages). Use it as a reference. Do the UI refresh **before** porting several new pages,
or each page gets written twice (Bootstrap 3 now, Bootstrap 5 later).

---

## 5. Advertised features that upstream already has

Power MIAB's README lists some features that upstream Mail-in-a-Box has since added, or that were
never really different:

| Power MIAB feature | Status in MeetrMail |
|---|---|
| Account quotas | **Present.** Upstream added per-user quotas to the panel in v73. Power MIAB's only extra is the default quota. |
| Per-domain nginx configuration | **Present in practice.** In v60.5's released code this is the same `www/custom.yaml` proxy and redirect system upstream has. Upstream's version is *newer* (v69 added WebSocket proxying). A separate nginx branch in Power MIAB was never released. |
| Backups to S3 / B2 / rsync | **Present** in upstream, with later fixes (S3 region, S3-compatible services, B2 key fix, rsync default port) that Power MIAB v60.5 lacks. |
| MTA-STS | **Present** in both. |
| Two-factor authentication | **Present** in both. |
| Debian 11 support | Power MIAB only — not relevant to us. |

---

## 6. What MeetrMail has that Power MIAB v60.5 does not

### From upstream Mail-in-a-Box v61–v76

| Release | Change |
|---|---|
| v67, v68 | **SMTP smuggling protection** — fixes a 2023 flaw that allowed forged email |
| v62–v75 | **Roundcube security updates** through 1.6.15 |
| v73 | Per-user mailbox quotas in the admin panel |
| v73 | Backup status shown in status checks |
| v73 | S3 credentials via environment variables; fix for non-AWS S3 services |
| v71 | Old TLS certificates deleted automatically |
| v71 | Spamhaus checks for IPv6 too; better secondary-nameserver checks |
| v71 | DSA and EC keys accepted for TLS certificates |
| v71 | Nightly tasks at 1 am local time; full backups only on weekends |
| v69 | WebSocket proxy support for custom web locations |
| v64 | Backups fixed for newer duplicity; B2 key fix; OpenDMARC reports turned off |
| v62 | Bookmarkable admin pages; rsync public key copy button |
| v61.1 | rsync backups on the default port fixed |

### From our own fork

- Ubuntu 24.04, PHP 8.3, Python 3.12 via uv with a lockfile
- Rspamd + Redis instead of SpamAssassin, postgrey, razor, pyzor and dovecot-antispam
- Nextcloud 33.0.9 with the official app packages
- No ActiveSync / Z-Push
- Sandbox mode, `meetrmail-mode` switch and an 88-check self-test
- Dovecot quota-status and munin-node locked to localhost
- Redis training data backed up and safe across reboots
- Self-signed certificate that modern clients accept
- The php8.0, `systemctl link`, fail2ban and other fixes in the port document

---

## 7. Porting recommendations

| Order | Feature | Effort | Value | Why this position |
|---|---|---|---|---|
| 1 | **Manage Password** | S | Medium | API already exists; smallest change; useful to every user |
| 2 | **Backup Now** | S | Medium | Helps with the backup testing you still need to do (run it in the background, not in the request) |
| 3 | **Default Quota** | S | Low–Med | Small; builds on existing per-user quotas |
| 4 | **Custom DNS TTLs** | S–M | Low–Med | Useful for future moves; touches `dns_update.py` |
| 5 | **SMTP Relays** | M | High (as a fallback) | Plan together with Phase 5b — both touch DNS and DKIM |
| — | *Admin panel redesign* | L | Med–High | Do **before** items 1–5 if possible, so new pages are only written once |
| 6 | **PGP Keyring** | M | Low | Only if WKD is wanted |
| 7 | **WKD** | M | Low | Only if you or your users use PGP email |

**A realistic plan:**

1. **Now:** Manage Password and Backup Now, written for the current Bootstrap 3 panel. Both are small
   and useful immediately.
2. **Next:** decide on the admin panel redesign. If yes, do it before adding more pages.
3. **Then:** Default Quota and DNS TTLs.
4. **With Phase 5b:** SMTP Relays, since both change how DKIM and SPF are published.
5. **Only if needed:** PGP Keyring and WKD.

---

## 8. How to port safely

**Don't merge or rebase Power MIAB into MeetrMail.** The two codebases split in 2022, Power MIAB is
built on PHP 8.0 and SpamAssassin, and a merge would conflict in almost every file we changed. Port
**one feature at a time**, using Power MIAB's code as a reference.

For each feature:

1. **Read Power MIAB's version** — its template, routes and any setup or DNS changes
   (`git clone https://github.com/ddavness/power-mailinabox && git checkout v60.5`).
2. **Rewrite it for our codebase** — Python 3.12, current `cryptography` and Flask, the Bootstrap 3
   panel (unless the redesign is done), and the PHP version read from `/etc/meetrmail.conf` rather
   than hard-coded.
3. **Add it to the self-test** (`tests/sandbox/selftest.sh`) — at minimum, that its API route
   responds and that any new listening port is bound to localhost.
4. **Test in the sandbox first:**
   ```bash
   tests/sandbox/run-container-test.sh
   ```
5. **Put it on its own git branch** and merge it only after it passes on the live box.
6. **Keep the licence note.** Both projects are CC0, so no permission is needed, but a comment
   crediting Power MIAB is good practice.

Features that touch **DNS** (TTLs, SMTP relay, WKD) need extra checking after deployment:
`nsd-checkconf`, a lookup from an outside resolver, and the admin panel's status checks. Test
anything touching **outgoing mail** (SMTP relay) by sending to Gmail and checking for
`dkim=pass spf=pass dmarc=pass` again.

---

*Sources: [ddavness/power-mailinabox](https://github.com/ddavness/power-mailinabox) at tag `v60.5`
(admin templates, `management/daemon.py`, `setup/`, `README.md`) and MeetrMail's upstream Mail-in-a-Box
v76 `CHANGELOG.md` and source.*
