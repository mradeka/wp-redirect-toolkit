# Script Reference

Twelve scripts. All are dry run without `--apply`, all support `--help`.

| Script | Purpose | Writes? | Run as |
|---|---|---|---|
| [`wp-db-audit`](#wp-db-audit) | database and configuration | no | root |
| [`wp-asset-scan`](#wp-asset-scan) | filesystem and checksums | only `--apply` | root |
| [`wp-cron-list`](#wp-cron-list) | list cron hooks | only `--delete` | root |
| [`wp-user-audit`](#wp-user-audit) | score accounts, rotate salts | only `--delete` / `--shuffle-salts` | root |
| [`wp-redirect-cleanup`](#wp-redirect-cleanup) | clean one installation | only `--apply` | site user |
| [`wp-cleanup-all`](#wp-cleanup-all) | cleanup across all sites | only `--apply` | root |
| [`wp-rotate-db-passwords`](#wp-rotate-db-passwords) | rotate DB passwords | only `--apply` | root |
| [`wp-fix-ownership`](#wp-fix-ownership) | check and fix file ownership | only after selection | root |
| [`wp-harden-htaccess`](#wp-harden-htaccess) | roll out a hardened `.htaccess` | only `--apply` | root |
| [`wp-move-to-subdir`](#wp-move-to-subdir) | move into `public_html/wordpress/` | only `--apply` | root |
| [`apply-blocklist`](#apply-blocklist) | block or search domains | only `--apply` | root |
| [`check-usrlocalbin-access`](#check-usrlocalbin-access) | usability per account | no | root |

---

## wp-db-audit

Read-only inventory of the **database**.

```bash
sudo wp-db-audit                   # all sites
sudo wp-db-audit --only siteuser
sudo wp-db-audit --quiet           # findings only, for cron
```

Checks: cron hooks with random-looking names (12+ chars, letters and digits,
no separators), payload in `wp_posts`, diverging `home`/`siteurl`,
administrator accounts.

Exit code 0 = clean, 1 = findings.

Formerly called `wp-cron-audit` — the name promised cron and delivered
everything. `install.sh` removes the old name when installing.

---

## wp-asset-scan

Everything that lives in the **filesystem**.

```bash
sudo wp-asset-scan
sudo wp-asset-scan --path /home/SITE/public_html
sudo wp-asset-scan --suspicious    # suspects in detail
sudo wp-asset-scan --apply         # remove JS injections
```

| Check | Approach |
|---|---|
| JS injection | only the last 800 bytes of each `.js` — that is where appended code sits, minified files included |
| Protocol marker | `"//https:` inside a string |
| Landing pages | `.htm`/`.html` with meta refresh, filenames containing "coming soon" |
| PHP in wrong places | `uploads/`, `cache/`, `languages/` (translations excluded) |
| `index.php` loader | judged by content, not checksum |
| Checksums | core, plugins, themes |
| mu-plugins, obfuscation, `auto_prepend`, dumps in the webroot | |

**On cleaning JS:** only the injected statement is cut out, not the whole
line — in minified files all code often sits on one line. Every modified file
is backed up alongside. HTML and PHP findings are never deleted automatically.

---

## wp-cron-list

```bash
sudo wp-cron-list                 # full table
sudo wp-cron-list --suspicious    # flagged rows only
sudo wp-cron-list --delete        # remove them, with a prompt
```

Three levels: known core and plugin hooks plain, unrecognised but readable in
yellow, random-looking in red.

With `--delete` the script first checks whether a PHP file registers the hook.
If code is found, deleting is pointless — it recreates the entry.

---

## wp-user-audit

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

> The obvious rule "login ≠ Unix user → delete" hits far too much: editors,
> authors and shop customers never match the home directory name, and
> `wp user delete` takes their posts with them. Accounts with their own
> content are skipped entirely without `--reassign`.

`--shuffle-salts` regenerates the auth keys. Every login becomes invalid —
including your own. Passwords are unchanged.

---

## wp-redirect-cleanup

```bash
wp-redirect-cleanup --path /home/SITE/public_html/wordpress \
                    --wp-bin /home/SITE/wp \
                    --backup /home/SITE/backups
# then the same line with --apply
```

| Option | Meaning |
|---|---|
| `--path` | directory containing `wp-config.php` (required) |
| `--domain` | **omit it** — read from the payload |
| `--url` / `--siteurl` | derived when one of the two is clean |
| `--wp-bin` | path to the phar if `wp` is not usable |
| `--backup` | **outside `public_html`** |

**Four passes**, narrowest first:

1. cut everything before the first `\r\n` — the common case
2. cut after `</script>` — rows consisting only of the payload
3. excise from mid-content, rejoining both sides
4. cached oEmbed markup created while `home` was hijacked

Rows left empty go to the **trash** for `post`/`page`. Disposable types are
deleted.

Aborts when `home` **and** `siteurl` carry the same domain — there is nothing
to derive from, and continuing would be guesswork.

---

## wp-cleanup-all

```bash
sudo wp-cleanup-all             # dry run
sudo wp-cleanup-all --summary   # one line per site
sudo wp-cleanup-all --apply
```

Finds the installations, determines the owner, runs the cleanup as that user,
places the phar in the user's home if needed, logs to `/root/wp-cleanup-logs`.

---

## wp-rotate-db-passwords

```bash
sudo wp-rotate-db-passwords
sudo wp-rotate-db-passwords --apply
sudo wp-rotate-db-passwords --defaults-file /etc/mysql/debian.cnf
```

Two things a naive loop gets wrong:

- **Shared DB users** are rotated once and written into every matching
  `wp-config.php`. Rotating per install would lock out every site but the last.
- **Rollback**: if writing or the connection test fails, both the MySQL
  password and `wp-config.php` are restored.

The generated password contains no quotes, backslashes, dollar signs, slashes
or `&` — each would need different escaping in PHP, SQL and sed.

Passwords are recorded in `/root/wp-db-credentials.txt` (mode 600).

---

## wp-fix-ownership

```bash
sudo wp-fix-ownership              # check, then select interactively
sudo wp-fix-ownership --report     # check only
sudo wp-fix-ownership --all --yes
sudo wp-fix-ownership --no-chmod   # ownership only
```

Selection by number: `2 5 7`, range `2-5`, mixed `1 3-5 8`, all `a`.

If a `wp core download` or an update accidentally runs as root, the files end
up owned by root. The symptoms look independent:

| Area | Symptom |
|---|---|
| core | updates ask for FTP credentials |
| `uploads` | media uploads fail |
| generated theme assets | site loses its styling |

The overview names the affected area, because uploads and updates break
independently. For verification `get_filesystem_method()` is called — the same
function WordPress uses to decide about the FTP prompt.

---

## wp-harden-htaccess

```bash
sudo wp-harden-htaccess --inventory   # FIRST: what is actually in there?
sudo wp-harden-htaccess               # dry run
sudo wp-harden-htaccess --apply --strict
sudo wp-harden-htaccess --restore
```

**Why existing files are not simply deleted:** on fcgid sites the `.htaccess`
sets the PHP version. Remove that line and the site runs with the server
default — or PHP stops running and the browser downloads the source.

Every line is classified:

| Category | Handling |
|---|---|
| `php-handler` | always carried over, even with `--strict` |
| `dangerous` (`auto_prepend_file`, `eval(`) | **never** carried over |
| `options-risk` (any `Options` line except `Options -Indexes`) | **never** carried over — needs `AllowOverride Options`, otherwise Apache returns 500 |
| `rewrite`, `access`, `standard`, `redirect`, `external-redirect` | carried over, dropped with `--strict` |
| `unknown` | carried over, dropped with `--strict` |

> These category names also appear in the output of `--inventory`.

Safeguards: backup to `/root/htaccess-backups`, `apachectl configtest`, HTTP
status before and after the change with automatic rollback, and an
effectiveness test that uploads a probe file and removes it again.

---

## wp-move-to-subdir

```bash
sudo wp-move-to-subdir --path /home/SITE/public_html
sudo wp-move-to-subdir --path /home/SITE/public_html --apply
```

**Not a cleanup measure** — a layout change that touches every file of a live
site. One site at a time.

`siteurl` → `https://domain/wordpress`, **`home` stays unchanged**. Checks
`AllowOverride` first and removes stale rewrite rules along with their
`RewriteCond` lines.

> Afterwards `core verify-checksums` permanently reports a mismatch for
> `index.php`. That is correct — see [False Positives](False-Positives).

---

## apply-blocklist

```bash
./apply-blocklist.sh hosts               # print rules only
sudo ./apply-blocklist.sh dnsmasq --apply
./apply-blocklist.sh scan                # search the installations
./apply-blocklist.sh grep                # print the search pattern
```

Block by DNS, not by IP — the domains sit behind CDN addresses shared with
thousands of legitimate sites.

---

## check-usrlocalbin-access

```bash
sudo check-usrlocalbin-access
sudo check-usrlocalbin-access --all
```

Separates four things that get confused: `dir` (traversable), `exec`
(executable bit set), `run` (actually runs — this is where `open_basedir`
bites) and `PATH`. Plus `jail` and a functional test per account.

For chrooted accounts `sudo -u` runs **outside** the jail and works, while an
SSH login by the same user does not see `/usr/local/bin`.
