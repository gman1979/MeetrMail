MeetrMail
=========

Version 1.0.0

**MeetrMail is an independent, customized mail server stack based on v76 of the
[Mail-in-a-Box](https://github.com/mail-in-a-box/mailinabox) project.**

MeetrMail is not affiliated with or endorsed by the Mail-in-a-Box project. We are grateful to
Joshua Tauberer ([@JoshData](https://github.com/JoshData)) and the
[Mail-in-a-Box contributors](https://github.com/mail-in-a-box/mailinabox/graphs/contributors),
whose work this project is built on. MeetrMail keeps the same core (Postfix, Dovecot, nginx,
Nextcloud, Roundcube and the rest) and goes its own way from here with its own features.

MeetrMail is developed and maintained by Grant, the project lead, who has final say over its
direction.

**See [FORK.md](FORK.md) for what changed from Mail-in-a-Box v76, how to install, and how to test.**

* * *

In The Box
----------

MeetrMail turns a fresh Ubuntu 24.04 LTS 64-bit machine into a working mail server by installing
and configuring various components.

The components installed are:

* SMTP ([postfix](http://www.postfix.org/)), IMAP ([Dovecot](http://dovecot.org/)), CardDAV/CalDAV ([Nextcloud](https://nextcloud.com/)), and Exchange ActiveSync ([z-push](http://z-push.org/)) servers
* Webmail ([Roundcube](http://roundcube.net/)), mail filter rules (thanks to Roundcube and Dovecot), and email client autoconfig settings (served by [nginx](http://nginx.org/))
* Spam filtering and greylisting ([Rspamd](https://rspamd.com/))
* DNS ([nsd4](https://www.nlnetlabs.nl/projects/nsd/)) with [SPF](https://en.wikipedia.org/wiki/Sender_Policy_Framework), DKIM ([OpenDKIM](http://www.opendkim.org/)), [DMARC](https://en.wikipedia.org/wiki/DMARC), [DNSSEC](https://en.wikipedia.org/wiki/DNSSEC), [DANE TLSA](https://en.wikipedia.org/wiki/DNS-based_Authentication_of_Named_Entities), [MTA-STS](https://tools.ietf.org/html/rfc8461), and [SSHFP](https://tools.ietf.org/html/rfc4255) policy records automatically set
* TLS certificates are automatically provisioned using [Let's Encrypt](https://letsencrypt.org/) for protecting https and all of the other services on the box
* Backups ([duplicity](http://duplicity.nongnu.org/)), firewall ([ufw](https://launchpad.net/ufw)), intrusion protection ([fail2ban](http://www.fail2ban.org/wiki/index.php/Main_Page)), and basic system monitoring ([munin](http://munin-monitoring.org/))

It also includes system management tools:

* Comprehensive health monitoring that checks each day that services are running, ports are open, TLS certificates are valid, and DNS records are correct
* A control panel for adding/removing mail users, aliases, custom DNS records, configuring backups, etc.
* An API for all of the actions on the control panel

For more information on how MeetrMail handles your privacy, see the [security details page](security.md).


Installation
------------

Start with a completely fresh Ubuntu 24.04 LTS 64-bit machine dedicated to MeetrMail. Clone this
repository, then:

	$ sudo setup/start.sh

After the first install, re-run setup at any time with:

	$ sudo meetrmail-setup

See [FORK.md](FORK.md) for the one-line install, sandbox mode, and testing.


Contributing and Development
----------------------------

See [CONTRIBUTING](CONTRIBUTING.md) to get started.


License
-------

MeetrMail keeps the licensing of Mail-in-a-Box: the code in this repository is dedicated to the
public domain under [CC0 1.0 Universal](LICENSE). Anyone may use, modify, fork and redistribute it
for any purpose.

That dedication covers only the setup scripts, configuration and management code in this
repository. The software MeetrMail installs (Postfix, Dovecot, nginx, Nextcloud, Roundcube,
Rspamd, OpenDKIM, and the rest) is not part of this repository. Those projects are developed and
distributed separately, mostly through Ubuntu's package archive, and each remains under its own
license.


Acknowledgements
----------------

MeetrMail is based on [Mail-in-a-Box](https://mailinabox.email/), created by Joshua Tauberer and
its contributors. Mail-in-a-Box was itself inspired in part by the
["NSA-proof your email in 2 hours"](http://sealedabstract.com/code/nsa-proof-your-e-mail-in-2-hours/)
blog post by Drew Crawford and [Sovereign](https://github.com/sovereign/sovereign) by Alex Payne.

Entries in [CHANGELOG.md](CHANGELOG.md) up to and including Version 76 are the Mail-in-a-Box
project's release history.
