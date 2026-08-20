# wp-redirect-toolkit

[![shellcheck](https://github.com/mradeka/wp-redirect-toolkit/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/mradeka/wp-redirect-toolkit/actions/workflows/shellcheck.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

🇩🇪 [Deutsche Fassung](README.de.md)

Tools to analyse and clean a WordPress compromise where a redirect was written
**straight into the database** — without modifying a single PHP file.

Built during a real incident on a host with ten WordPress installations. The
full account, including the reasoning, is in [INCIDENT.md](INCIDENT.md)
(German).

Guides, a troubleshooting reference and the catalogue of known false positives
live in the
[wiki](https://github.com/mradeka/wp-redirect-toolkit/wiki).

Every script is **dry run by default** and writes nothing until `--apply` is
given. A backup is taken before any change.

---

## Contents

| Script | Purpose | Writes? | Run as |
|---|---|---|---|
| [`wp-db-audit`](#wp-db-audit) | Database and config: cron hooks, payload, URLs, accounts | no | root |
| [`wp-asset-scan`](#wp-asset-scan) | Filesystem: JS, landing pages, loaders, checksums | only `--apply` | root |
| [`wp-cron-list`](#wp-cron-list) | List WP-Cron hooks, flag random-looking names | only `--delete` | root |
| [`wp-user-audit`](#wp-user-audit) | Score user accounts, rotate auth salts | only `--delete` / `--shuffle-salts` | root |
| [`wp-redirect-cleanup`](#wp-redirect-cleanup) | Clean one installation (v7) | only `--apply` | site user |
| [`wp-cleanup-all`](#wp-cleanup-all) | Run the cleanup across all sites | only `--apply` | root |
| [`wp-rotate-db-passwords`](#wp-rotate-db-passwords) | Rotate database passwords | only `--apply` | root |
| [`wp-fix-ownership`](#wp-fix-ownership) | Check file ownership, fix interactively | only after selection | root |
| [`wp-health-check`](#wp-health-check) | Functional check: does everything still work? | only with `--fix` | root |
| [`wp-harden-htaccess`](#wp-harden-htaccess) | Roll out a hardened `.htaccess` | only `--apply` | root |
| [`wp-move-to-subdir`](#wp-move-to-subdir) | Move an install into `public_html/wordpress/` | only `--apply` | root |
| [`apply-blocklist`](#apply-blocklist) | Block or search the campaign's domains | only `--apply` | root |
| [`check-usrlocalbin-access`](#check-usrlocalbin-access) | Check each account can use the tools | no | root |

---

## The attack pattern

The same block was prepended to every row in `wp_posts.post_content`:

```html
<meta http-equiv="refresh" content="7; url=https://BAD.DOMAIN/TOKEN" />
<script>(window.matchMedia("(pointer:coarse)").matches|| … )
  &&location.replace("https://BAD.DOMAIN/TOKEN");</script>
```

Four things show this was database access rather than a PHP backdoor:
`post_modified` was untouched, row types WordPress never writes that way were
hit (`wp_global_styles`, `wp_navigation`), no file was modified, and the `home`
option had been rewritten.

**The target domain differs per site** (`urshort.com`, `ushort.company`,
`ushort.org`). That is why `wp-redirect-cleanup` detects it from the payload
itself — a scan with a hard-coded domain reports affected sites as clean.

---

## Installation

Short version. The full guide with troubleshooting is in
[INSTALL.md](INSTALL.md) (German).

Requirements: Bash 4+, WP-CLI 2.7+, MySQL/MariaDB, `curl`, `sudo`.

```bash
git clone https://github.com/mradeka/wp-redirect-toolkit.git
cd wp-redirect-toolkit
chmod +x install.sh
sudo ./install.sh
```

`chmod +x` is needed because the executable bit does not survive every clone
(`core.fileMode=false`, restrictive `umask`). Alternatively: `sudo bash install.sh`.

### WP-CLI

```bash
curl -fL -o /tmp/wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
php /tmp/wp-cli.phar --version
sudo install -m 755 /tmp/wp-cli.phar /usr/local/bin/wp
```

Note the repository: **`wp-cli/builds`**, not `wp-cli/wp-cli`. Versions before
2.7 return nothing for `--fields` combined with `--format=csv`; the scripts
handle that with a fallback, but updating avoids several edge cases.

### When an account cannot use `/usr/local/bin/wp`

Symptom: `Could not open input file: /usr/local/bin/wp` although the file
exists. Usually `open_basedir` in the PHP CLI config, or a chroot jail. Put a
copy in the account's home:

```bash
install -m 755 -o USER -g USER /usr/local/bin/wp /home/USER/wp
```

and pass `--wp-bin /home/USER/wp`. `wp-cleanup-all` does this itself; use
`check-usrlocalbin-access` to check every account at once.

---

## Recommended workflow

```
1.  check-usrlocalbin-access      tools usable everywhere?
2.  wp-db-audit                   inventory, changes nothing
3.  wp-asset-scan                 filesystem: JS, landing pages, PHP
4.  wp-cleanup-all                dry run across all sites
5.  wp-cleanup-all --apply        clean the database
6.  wp-asset-scan --apply         remove JS injections
7.  ─── close the way in ───      panel on 127.0.0.1, firewall, passwords
8.  wp-rotate-db-passwords --apply
9.  wp-user-audit --shuffle-salts invalidate all sessions
10. apply-blocklist dnsmasq --apply
11. wp-db-audit + wp-asset-scan   re-check after 1h and the next day
```

Step 7 before 8 and 9 is what matters. Rotating credentials while the way in
is still open only locks you out.

---

## The two audit scripts

The split follows the **data source**, not the topic:

| | `wp-db-audit` | `wp-asset-scan` |
|---|---|---|
| Source | database and WP options | filesystem |
| Checks | cron hooks, payload in `wp_posts`, `home`/`siteurl`, admin accounts | JS injections, landing pages, `index.php` loaders, PHP in wrong places, mu-plugins, obfuscation, dumps in the webroot, checksums for core/plugins/themes |
| Writes | never | only `--apply`, and only JS lines with a known domain |

Run only one and the other infection route stays undetected.

---

## The scripts

### wp-db-audit

Read-only inventory of what lives in the **database**.

```bash
sudo wp-db-audit                   # all sites
sudo wp-db-audit --only siteuser
sudo wp-db-audit --quiet           # findings only, suitable for cron
```

| Check | What for |
|---|---|
| WP-Cron hooks | random-looking names (12+ chars, letters and digits, no separators) — no plugin names hooks that way |
| Redirect payload | `post_content` starting with `<meta http-equiv="refresh"`, including the target domain |
| `home` / `siteurl` | do they point at different hosts — is one of them hijacked |
| Administrator accounts | count and names; unusually many are flagged |

Exit code 0 = clean, 1 = findings. As a weekly check:

```cron
0 6 * * 1 /usr/local/bin/wp-db-audit --quiet
```

### wp-asset-scan

Everything that lives in the **filesystem**.

```bash
sudo wp-asset-scan
sudo wp-asset-scan --path /home/SITE/public_html
sudo wp-asset-scan --suspicious    # show suspects in detail
sudo wp-asset-scan --apply         # remove JS injections
```

| Check | Approach |
|---|---|
| JS injection | only the last 800 bytes of each `.js` — that is where appended code sits, minified files included |
| Protocol marker | `"//https:` inside a string — no developer writes a URL that way |
| Landing pages | `.htm`/`.html` with meta refresh, filenames containing "coming soon" |
| PHP in wrong places | `uploads/`, `cache/`, `languages/` (translation files excluded) |
| `index.php` loader | judged by content, not by checksum |
| Checksums | core, plugins and themes; extensions that cannot be verified are named |
| mu-plugins, obfuscation, `auto_prepend_file`, dumps in the webroot | |

Two levels: **HIT** (a domain from the blocklist appears, removable with
`--apply`) and **SUSPECT** (redirect pattern without a known domain, reported
only — legitimate scripts assign to `location` too).

> **On cleaning JS:** only the injected statement is cut out, not the whole
> line. In minified files all code often sits on a single line, so deleting
> line-wise would destroy the script. Every modified file is backed up
> alongside. HTML and PHP findings are never deleted automatically.

**On `index.php` in subdirectory installs:** the loader in the webroot is
*always* modified — its `require` path points at the core directory, so the
checksum can never match. Checksums therefore run against the installation
directory, and the loader is judged by content instead: obfuscation or
execution constructs, loading from the network, a `header("Location: …")`
redirect, an `include` of anything other than `wp-blog-header.php` /
`wp-load.php` / `wp-settings.php`, or more than 15 lines of code.

**On commercial themes and plugins:** checksums only exist for extensions from
the official WordPress repository. Enfold, Divi, Avada, WP Rocket, ACF Pro and
similar are not there — WP-CLI reports `Could not retrieve the checksums` and
skips them. The script does not suppress that; it lists the affected
extensions and states they were **not** verified. On suspicion, compare
against the original:

```bash
diff -rq wp-content/themes/enfold/ /path/to/extracted/original/enfold/
```

> Take the original from your own customer account, never from a bundle site —
> that is a standard infection route for exactly these extensions.

**On obfuscation searches:** grepping for `eval`, `base64_decode` or
`gzinflate` alone produces false positives — WordPress core itself contains
such calls. `wp-admin/includes/class-pclzip.php` uses `gzinflate`/`gzdeflate`
to handle ZIP archives and carries a commented-out `eval(`. Therefore core is
not searched (checksums cover it, more reliably than any pattern), a **hit**
requires the *combination* of execution and obfuscation, and single functions
are reported as a hint only with `--suspicious`.

**On translation files:** since WordPress 6.5 language packs also ship as PHP
(`*.l10n.php`) under `wp-content/languages/`. They are excluded, as is any
file there that only contains a `return [...]` array. A PHP file under
`languages/` that actually executes code is still reported.

### wp-cron-list

```bash
sudo wp-cron-list                 # full table
sudo wp-cron-list --suspicious    # flagged rows only
sudo wp-cron-list --delete        # remove them, with a prompt
```

Three levels: known core and plugin hooks plain, unrecognised but readable in
yellow, random-looking in red.

With `--delete` the script first checks whether any PHP file registers the
hook. If code is found, deleting is pointless — it recreates the entry.

### wp-user-audit

```bash
sudo wp-user-audit
sudo wp-user-audit --since 2026-07-15
sudo wp-user-audit --delete --reassign 1
sudo wp-user-audit --shuffle-salts
```

Scoring instead of name matching: +3 administrator whose login differs from
the Unix user, +2 registered after the incident date, +2 foreign mail domain,
+1 no posts, +1 machine-looking name, −3 old and with content, −3 plain
subscriber from before the incident. Suspicion from 4 points.

> The obvious rule "WordPress login ≠ Unix user → delete" hits far too much:
> editors, authors and shop customers never match the home directory name, and
> `wp user delete` takes their posts with them. Accounts with their own
> content are skipped entirely without `--reassign`.

`--shuffle-salts` regenerates the `AUTH_KEY`/`SALT` constants. Every existing
session becomes invalid — including your own. It does not change passwords.

### wp-redirect-cleanup

```bash
wp-redirect-cleanup --path /home/SITE/public_html/wordpress \
                    --wp-bin /home/SITE/wp \
                    --backup /home/SITE/backups
# then the same line with --apply
```

| Option | Meaning |
|---|---|
| `--path` | directory containing `wp-config.php` (required) |
| `--domain` | injected domain — **omit it**, it is read from the payload |
| `--url` | public address (`home`); derived otherwise |
| `--siteurl` | where core lives; differs for subdirectory installs |
| `--wp-bin` | path to the WP-CLI phar if `wp` is not usable |
| `--backup` | dump directory — **outside `public_html`** |
| `--apply` | write changes |

**Four passes**, narrowest first:

1. cut everything before the first `\r\n` — the common case
2. cut after the closing `</script>` — rows that consist only of the payload
3. excise from mid-content by rejoining both sides; repeated for rows carrying
   it more than once
4. remove cached oEmbed markup built while `home` was hijacked

Rows left empty go to the **trash** for `post`/`page` rather than being
deleted. Disposable types are removed.

The script aborts when `home` **and** `siteurl` carry the same domain — there
is nothing left to derive from, and continuing would be guesswork.

Not automated: serialised values in `wp_options`, `postmeta` and `comments` —
a blind cut destroys the length prefixes there. They are reported and edited
via `wp option get/set`.

### wp-cleanup-all

```bash
sudo wp-cleanup-all             # dry run
sudo wp-cleanup-all --summary   # one line per site
sudo wp-cleanup-all --apply
```

Finds the installations, determines the owner from `wp-config.php`, runs the
cleanup as that user, places the phar in the user's home if needed, and logs
per site to `/root/wp-cleanup-logs`.

### wp-rotate-db-passwords

```bash
sudo wp-rotate-db-passwords                   # dry run
sudo wp-rotate-db-passwords --apply
sudo wp-rotate-db-passwords --defaults-file /etc/mysql/debian.cnf
```

Two things a naive loop gets wrong:

- **Shared DB users.** If several installs use the same `DB_USER`, the
  password is rotated once and written into every matching `wp-config.php`.
  Rotating per install would lock out every site but the last.
- **Rollback.** If writing or the connection test fails, both the MySQL
  password and `wp-config.php` are restored.

The generated password deliberately contains no quotes, backslashes, dollar
signs, slashes or `&` — each would need different escaping in PHP, SQL and sed.

Passwords are recorded in `/root/wp-db-credentials.txt` (mode 600).

### wp-fix-ownership

Checks whether files belong to their site user across all installations, then
offers a selection of which to fix.

```bash
sudo wp-fix-ownership              # check, then select interactively
sudo wp-fix-ownership --report     # check only
sudo wp-fix-ownership --all --yes
sudo wp-fix-ownership --no-chmod   # ownership only
```

Selection by number: single (`2 5 7`), range (`2-5`), mixed (`1 3-5 8`), all
(`a`), abort (`q`).

If a `wp core download`, an update or a script accidentally runs as root, the
files end up owned by root. The symptoms look like separate problems:

| Affected area | Symptom |
|---|---|
| core (`wp-admin`, `wp-includes`, root) | updates ask for FTP credentials |
| `wp-content/uploads` | media uploads fail |
| generated theme assets (`uploads/dynamic_avia/`) | site loses its styling |

Uploads and updates break independently: uploads only need write access to
`uploads/`, updates need the whole core owned by the site user. The overview
therefore names the affected area.

For verification the script calls `get_filesystem_method()` — the very
function WordPress uses to decide whether to ask for FTP. `direct` means
updates work again.

### wp-harden-htaccess

```bash
sudo wp-harden-htaccess --inventory   # FIRST: what is actually in there?
sudo wp-harden-htaccess               # dry run
sudo wp-harden-htaccess --apply --strict
sudo wp-harden-htaccess --restore
```

**Why existing files are not simply deleted.** A uniform baseline across all
sites is the right goal, but blanket deletion breaks two things:

- **PHP handlers.** On fcgid sites `.htaccess` sets the PHP version
  (`AddHandler fcgid-script .php`, `AddType application/x-httpd-php81 .php`).
  Remove that line and the site falls back to the server default — or PHP
  stops running and the browser downloads the source.
- **Domain redirects** with SEO value, and blocks written by caching plugins.

Conversely nothing may be carried over blindly: after an incident an injected
rule may sit in there. Every line is therefore **classified**:

| Category | Handling |
|---|---|
| `php-handler` | always carried over, even with `--strict` |
| `dangerous` (`auto_prepend_file`, `auto_append_file`, `eval(`) | **never** carried over, reported |
| `options-risk` (any `Options` line except `Options -Indexes`) | **never** carried over — needs `AllowOverride Options`, otherwise Apache returns 500 |
| `rewrite`, `access`, `standard`, `redirect`, `external-redirect` | carried over, dropped with `--strict` |
| `unknown` | carried over, dropped with `--strict` — inspect first |

`--inventory` prints this breakdown for all sites without changing anything.
That is the right first step when the files have grown historically and differ
from site to site.

Safeguards: backup to `/root/htaccess-backups`, `apachectl configtest`, HTTP
status measured before and after **for both the home page and a core asset**
with automatic rollback, and an effectiveness test that uploads a harmless
probe file and removes it again.

> Longer term it is cleaner to set the PHP version in the panel or vhost
> rather than in `.htaccess`. Then the file no longer depends on it and a
> uniform baseline across all sites becomes achievable.

### wp-move-to-subdir

```bash
sudo wp-move-to-subdir --path /home/SITE/public_html
sudo wp-move-to-subdir --path /home/SITE/public_html --apply
sudo wp-move-to-subdir --path … --skip-apache-check --apply
```

**Not a cleanup measure** — a layout change that touches every file of a live
site. One site at a time, not in bulk.

- core moves to `wordpress/`, a loader `index.php` stays in the webroot
- `siteurl` → `https://domain/wordpress`, **`home` stays unchanged** — the
  public address does not move
- `AllowOverride` is checked first; without `All` the root `.htaccess` would
  be ignored and the move aborts
- stale rewrite rules whose target does not exist (typically a leftover
  `/my_subdir/`) are removed along with their `RewriteCond` lines; custom
  rules are kept
- PHP execution in `uploads/` is blocked, permissions are set
- file and database backups are taken first

> **Expected side effect:** afterwards `core verify-checksums` permanently
> reports a mismatch for `index.php`. That is correct — the file carries the
> adjusted `require` path. Do not overwrite it with `wp core download --force`.

### apply-blocklist

```bash
./apply-blocklist.sh hosts               # print rules only
sudo ./apply-blocklist.sh dnsmasq --apply
./apply-blocklist.sh unbound
./apply-blocklist.sh firewalld           # IP rules (see warning)
./apply-blocklist.sh scan                # search the installations
./apply-blocklist.sh grep                # print the search pattern
```

`blocklist-domains.txt` holds the domains observed in this incident
(`urshort.com`, `ushort.company`, `ushort.org`) plus those published by Sal
Aguilar (WPSecurityAnalyzer) in May 2026 for the same campaign
(`ushort.observer`, `ushort.info`, `u-short.net`, `urshort.live`,
`ushort.today`, `ushort.com`, `ushort.dev`).

> **Block by DNS, not by IP.** The domains resolve to CDN and shared hosting
> addresses that change and are shared with thousands of legitimate sites — an
> IP rule hits far too much and works only briefly. Also check `ushort.com`
> separately: short generic domains change hands.

### wp-health-check

The security tools ask "is anything malicious here?". This one asks **"does
everything still work?"** — every check exists because that failure actually
happened, and because the symptom pointed somewhere other than the cause.

```bash
sudo wp-health-check                 # check every site
sudo wp-health-check --only siteuser
sudo wp-health-check --quiet         # failures only, for cron
sudo wp-health-check --fix           # offer two safe repairs
```

| Check | Catches |
|---|---|
| php identity | `mod_php` overriding fcgid → PHP runs as `www-data` → uploads fail, updates ask for FTP, no debug.log |
| update method | `get_filesystem_method()` — `ftpext` means root-owned files |
| ownership | uploads and updates break independently |
| permalinks | an empty `permalink_structure` means no rewrite rules → `/wp-json/` 404s → block editor fails with "response is not a valid JSON response" |
| rest api | tested **both ways**: `/wp-json/` and `?rest_route=`. If only the second works, the rewrite rules are the problem, not WordPress |
| uploads exec | PHP in `uploads/` must not run |
| media delivery | …while images must still be served. A rule that blocks both is worse than no rule |
| home/siteurl | for a subdirectory layout they differ on purpose |
| home page, wp-cron | reachability and a cron backlog |

> **All URLs are built from `siteurl`, not `home`.** With a subdirectory
> install the asset path contains the directory — testing against `home`
> returns a 404 that looks like protection but is just a wrong address. That
> mistake cost real time during the incident.

Exit code 0 = healthy, 1 = problems, so it fits into cron. `--fix` offers
exactly two repairs, each with a prompt: setting a permalink structure (it
warns that every URL changes) and discarding theme cache files written under a
foreign identity.

### check-usrlocalbin-access

```bash
sudo check-usrlocalbin-access
sudo check-usrlocalbin-access --all
sudo check-usrlocalbin-access --bin php
```

Separates four things that get confused: `dir` (traversable), `exec`
(executable bit set), `run` (actually runs — this is where `open_basedir`
bites) and `PATH`. Plus `jail` and a functional test per account.

For chrooted accounts `sudo -u` runs **outside** the jail and works, while an
SSH login by the same user does not see `/usr/local/bin`. For those accounts a
copy in the home directory is the right answer.

---

## After the cleanup

Cleaning rows fixes the symptom, not the cause.

- [ ] Take Webmin and phpMyAdmin off the internet:
      `bind=127.0.0.1` in `/etc/webmin/miniserv.conf`, then `/etc/webmin/restart`
- [ ] Access via SSH tunnel: `ssh -L 10000:127.0.0.1:10000 user@host` — use
      **`127.0.0.1`** in the tunnel *and* the browser, not `localhost`
      (resolves to `::1` first, where the panel no longer listens →
      `PR_CONNECT_RESET_ERROR`)
- [ ] Cloud firewalls are default-deny: allow 22, 80, 443, 25 and the rest
      explicitly, each rule for `0.0.0.0/0` **and** `::/0`
- [ ] Check the panel logs for unfamiliar sessions and unknown accounts
- [ ] Rotate credentials: database, all administrator accounts, salts, SSH,
      panel
- [ ] `last`, `lastb`, `authorized_keys` in every home directory. Also check
      for **private keys without a passphrase** — panels leave them there, and
      anyone with root could have taken them
- [ ] `mailq | tail` — a compromised host running a mail server gets used as a
      relay
- [ ] Re-check after an hour and the next day

If the count rises from 0 again, access still exists — take the vhost offline
rather than cleaning a second time. If the panel logs show an unfamiliar
session with a browser shell (`/xterm/`, `/filemin/`), assume full host
compromise: those keystrokes appear in no log, and a rebuild is the only
defensible answer.

---

## Common failures

| Symptom | Cause |
|---|---|
| `wp: command not found` | WP-CLI not installed |
| `Could not open input file: /usr/local/bin/wp` | `open_basedir` or a jail blocks the path |
| `WP-CLI cannot read this install` | wrong path or `wp-config.php` not readable |
| `sudo: unable to execute ./script: Permission denied` | script sits in `/root` (mode 700) |
| `X is not in the sudoers file` | `sudo -u` called as non-root |
| `could not read cron events` / `users` | WP-CLI older than 2.7 |
| `PR_CONNECT_RESET_ERROR` in the tunnel | `localhost` instead of `127.0.0.1` (IPv6) |
| Site unstyled after cleanup | `home`/`siteurl` hijacked |
| Redirect despite a clean `curl` | browser cache |
| `curl 404` downloading WP-CLI | the repository is `wp-cli/builds` |
| Upload fails, updates ask for FTP | PHP runs as `www-data` (mod_php active instead of fcgid), or files owned by root |
| `Option FollowSymLinks not allowed here` | the `AllowOverride` whitelist excludes it — use `Options -Indexes` only |

---

## Contributing

Feedback from real incidents is the most valuable input — especially false
positives and variants that were not detected. See
[CONTRIBUTING.md](CONTRIBUTING.md).

Security issues **in these scripts** should not be filed as public issues but
reported through GitHub's private reporting — see [SECURITY.md](SECURITY.md).

## Disclaimer

These scripts modify databases and configuration files of production websites.
They back up before every change and do nothing without `--apply` — still:
read the dry run first, then apply, and a backup outside the server never
hurts.

With a root-level compromise no cleanup is complete. When in doubt, rebuild.

## License

MIT
