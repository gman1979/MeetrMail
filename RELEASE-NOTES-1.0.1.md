# MeetrMail 1.0.1

The first MeetrMail release with its own control-panel features. Requires Ubuntu 24.04 LTS.

## New

- **Custom DNS TTL** per record (30 seconds to 30 days).
- **Spam Filtering** page: thresholds (global and per mailbox), allow/block lists, Rspamd statistics,
  Spam folder browser, nightly summary email.
- **Quotas** page and a default quota for new mailboxes.
- **Import Mail**: copy an account from another IMAP server.
- **Fail2ban** page: jails, banned addresses, manual ban and unban.

## Fixed

- Scripts are now committed as executable, so `git clone` followed by `sudo setup/start.sh` works.

## Upgrading

```bash
cd ~/meetrmail && git pull          # or extract the release archive over your install
sudo meetrmail-setup
```

Hard-reload the control panel (Ctrl+Shift+R) afterwards. No data migration is needed.

See [CHANGELOG.md](CHANGELOG.md) for details.
