# Troubleshooting

Every message here actually occurred during development.

---

## Overview

| Message | Cause | Section |
|---|---|---|
| `wp: command not found` | WP-CLI missing | [WP-CLI](#wp-cli) |
| `Could not open input file: /usr/local/bin/wp` | account may not use the file | [open_basedir](#could-not-open-input-file) |
| `curl: (22) … 404` downloading WP-CLI | wrong repository | [WP-CLI](#wp-cli) |
| `WP-CLI cannot read this install` | path or read permissions | [Install not readable](#wp-cli-cannot-read-this-install) |
| `could not read cron events` / `users` | WP-CLI older than 2.7 | [Old WP-CLI](#old-wp-cli-version) |
| `sudo: unable to execute ./script: Permission denied` | script sits in `/root` | [Permissions](#permission-denied-when-calling-a-script) |
| `X is not in the sudoers file` | `sudo -u` as non-root | [sudoers](#is-not-in-the-sudoers-file) |
| `./install.sh: Permission denied` | executable bit missing | [Permissions](#permission-denied-when-calling-a-script) |
| `No MySQL admin access` | no DB admin access | [MySQL](#no-mysql-admin-access) |
| `grep: binary file matches` | binary characters in the log | [Reading logs](#grep-binary-file-matches) |
| `PR_CONNECT_RESET_ERROR` in the tunnel | `localhost` instead of `127.0.0.1` | [SSH tunnel](#pr_connect_reset_error) |
| Site unstyled after cleanup | `home`/`siteurl` hijacked | [Layout broken](#site-without-styling) |
| Redirect despite a clean `curl` | browser cache | [Cache](#redirect-despite-a-clean-curl) |
| `auto-detection … home AND siteurl` | nothing to derive from | [Auto-detection](#auto-detection-aborts) |
| Upload fails, updates ask for FTP | PHP runs as `www-data`, or files owned by root | [mod_php](#upload-fails-and-updates-ask-for-ftp) |

---

## WP-CLI

```bash
curl -fL -o /tmp/wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
ls -la /tmp/wp-cli.phar          # around 7 MB
php /tmp/wp-cli.phar --version
sudo install -m 755 /tmp/wp-cli.phar /usr/local/bin/wp
```

Two pitfalls:

- The repository is **`wp-cli/builds`**, not `wp-cli/wp-cli`. The latter
  returns a 404.
- The `-f` matters: without it curl writes the HTTP error page into the file.
  The result is a phar that PHP rejects with `Could not open input file`.

---

## `Could not open input file`

A **PHP** error, not a shell error — the file is found but cannot be opened.

```bash
ls -la /usr/local/bin/wp
head -c 200 /usr/local/bin/wp        # must start with "#!/usr/bin/env php"
sudo -u SITEUSER -H php -i | grep -E 'open_basedir|disable_functions'
```

If `head` shows HTML, the download was broken → fetch it again.

If `open_basedir` is set, it restricts the account to its home. The phar then
belongs there:

```bash
install -m 755 -o SITEUSER -g SITEUSER /usr/local/bin/wp /home/SITEUSER/wp
```

and pass `--wp-bin /home/SITEUSER/wp`. `wp-cleanup-all` does this itself.

> Do **not** put the phar in `public_html` — it is reachable through the
> browser there.

---

## `WP-CLI cannot read this install`

```bash
sudo -u SITEUSER -H wp --path=/path config get table_prefix   # the real message
stat -c '%U:%G %a' /path/wp-config.php
namei -l /path/wp-config.php                                  # permissions along the path
find /home/SITEUSER -maxdepth 3 -name wp-config.php           # is it elsewhere?
```

`namei -l` is the most useful of the four — often a parent directory is the
problem, not the file itself.

---

## Old WP-CLI version

Versions before 2.7 return nothing for `--fields` combined with
`--format=csv`. The scripts catch that with a fallback (yellow note "parsed
the table"), but:

```bash
wp cli update --allow-root
```

Update the copies in home directories too:

```bash
find /home -maxdepth 2 -type f \( -name 'wp' -o -name '.wp-cli.phar' \) | while read -r W; do
  U=$(stat -c '%U' "$W")
  install -m 755 -o "$U" -g "$(id -gn "$U")" /usr/local/bin/wp "$W"
done
```

---

## `Permission denied` when calling a script

**After `git clone`:** the executable bit does not survive every clone
(`core.fileMode=false`, restrictive `umask`).

```bash
chmod +x install.sh && sudo ./install.sh
# or without changing permissions:
sudo bash install.sh
```

**With `sudo -u SITEUSER ./script.sh`:** if the script sits in `/root` (mode
700), the site user may not even enter the directory.

```bash
install -m 755 /root/script.sh /usr/local/bin/script
sudo -u SITEUSER -H /usr/local/bin/script ...
```

Do not forget the `-H` — otherwise `$HOME` points at `/root` and backups land
there.

---

## `is not in the sudoers file`

`sudo -u` was called as a non-root user. If you are already logged in as the
site user, call the script directly:

```bash
/usr/local/bin/wp-redirect-cleanup --path ... --wp-bin ...
```

The added "This incident has been reported" is sudo's standard wording, not an
alarm.

---

## `No MySQL admin access`

```bash
mysql -e 'SELECT 1'                                         # see the real message
mysql --defaults-file=/etc/mysql/debian.cnf -e 'SELECT 1'   # maintenance account
grep -iE 'pass|login' /etc/webmin/mysql/config              # panel password
```

Your own credentials file:

```bash
umask 077
printf '[client]\nuser=root\npassword=%s\n' 'PASSWORD' > /root/.my.cnf
chmod 600 /root/.my.cnf
```

Resetting via `--skip-grant-tables` is the last resort — the database is
briefly open without permission checks.

---

## `grep: binary file matches`

```bash
grep -a 'PATTERN' /var/webmin/miniserv.log
```

The `-a` forces text output for log files containing binary characters.

---

## `PR_CONNECT_RESET_ERROR`

The tunnel is up but the connection is dropped immediately.

**Cause in almost every case: IPv6.** `bind=127.0.0.1` binds to IPv4 only;
`localhost` resolves to `::1` first.

- In the tunnel (right-hand field / remote server): **`127.0.0.1`**
- In the browser: `https://127.0.0.1:10000`

Verify:

```bash
ss -tlnp | grep 10000            # on the server
curl -kI https://127.0.0.1:10000 # also on the server
ssh -v -N -L 10000:127.0.0.1:10000 user@host
```

If `miniserv.conf` has `ssl=0`, you are speaking `https://` to an HTTP port —
use `http://127.0.0.1:10000` instead. Through the tunnel that is fine, the
link is encrypted by SSH.

For referer errors, add to `/etc/webmin/config`:

```
referers=127.0.0.1
```

---

## Firewall locks out your own access

Cloud firewalls are **default-deny**: once a firewall is assigned, only what
is explicitly allowed gets through. A single rule for port 10000 therefore
closes SSH as well.

Allow: 22, 80, 443, 25, optionally 465/587/143/993 and ICMP — **each rule for
`0.0.0.0/0` and `::/0`**.

```bash
ssh -4 -v user@host
ssh -6 -v user@host
```

If only one of the two works, the rule for the other address family is
missing.

---

## Site without styling

Almost always `home` or `siteurl` is hijacked: every asset is served with the
malicious domain as its base and goes nowhere.

```bash
wp option get home && wp option get siteurl
```

Emergency override in `wp-config.php`, above `/* That's all */`:

```php
define('WP_HOME','https://www.example.de');
define('WP_SITEURL','https://www.example.de/wordpress');
```

With Enfold there is more: the generated stylesheets live in
`wp-content/uploads/dynamic_avia/` and are not restored by a theme update. Use
Enfold → Performance → "Delete old CSS and JS files", then save under General
Styling.

---

## Redirect despite a clean `curl`

```bash
curl -s https://DOMAIN/ | grep -c 'BAD-DOMAIN'    # 0
```

If the server returns clean HTML but the browser still redirects:

1. **Browser cache.** A meta-refresh page is fully cacheable. Private window
   or another device.
2. **A linked asset.** Check JS and CSS files too:
   ```bash
   sudo wp-asset-scan --path /home/SITE/public_html
   ```
3. **Service worker.** DevTools → Application → Service Workers, unregister if
   present. Those survive clearing the cache.

The definitive test is the DevTools network tab: the *Initiator* column names
exactly the file and line that triggered the navigation.

---

## Auto-detection aborts

```
auto-detection unusable: 'DOMAIN' appears in home AND siteurl
```

Either both options really are hijacked — then there is no clean value to
derive from — or detection picked up your own domain. Same remedy either way:

```bash
# find the real target domain
wp db query "SELECT DISTINCT SUBSTRING_INDEX(SUBSTRING_INDEX(post_content,'url=',-1),'\"',1) \
             FROM wp_posts WHERE post_content LIKE '<meta http-equiv=%' LIMIT 5;"
# find the public address
grep -rh ServerName /etc/apache2/sites-enabled/ | sort -u
```

Then pass them explicitly:

```bash
wp-redirect-cleanup --path ... --domain BAD-DOMAIN \
  --url https://www.example.de --siteurl https://www.example.de/wordpress
```

---

## Upload fails and updates ask for FTP

Symptoms that belong together even though they look independent:

- "The uploaded file could not be moved to wp-content/uploads/…"
- WordPress asks for FTP credentials when updating
- `WP_DEBUG_LOG` creates no file

Common cause: the PHP process does not own the files. On panel servers PHP
normally runs under the site user via `mod_fcgid`/suexec. If `mod_php` is also
active, its `SetHandler` overrides that — and PHP runs as `www-data` on
**every** site.

Find out which identity PHP actually runs under:

```bash
D=/home/SITE/public_html/wordpress
cat > "$D/whoami.php" <<'EOF'
<?php $u=posix_getpwuid(posix_geteuid()); echo $u['name']."\n";
echo is_writable(__DIR__.'/wp-content/uploads/'.date('Y/m')) ? "writable\n" : "NOT writable\n";
EOF
chown SITE:SITE "$D/whoami.php"
curl -s "https://DOMAIN/wordpress/whoami.php"
rm -f "$D/whoami.php"
```

If it says `www-data`, `mod_php` is the cause:

```bash
ls -la /etc/apache2/mods-enabled/ | grep -i php
a2dismod php8.3
apachectl configtest && systemctl restart apache2
```

> This is more than an operational problem: under `mod_php` all domains share
> one process identity. Code on one compromised site can then reach the files
> of every other. After an incident it is worth checking **when** the modules
> were enabled:
> ```bash
> ls -la /etc/apache2/mods-enabled/php*.*
> grep -i php8 /var/log/apt/history.log | tail
> ```

> If `wp-fix-ownership` reports 0 while files are visibly owned by root,
> check who owns `wp-config.php`. Versions before 1.1.0 derived the expected
> user from that file — if it was root-owned, everything looked correct.
> Fixed since; update the toolkit if you see this.

**Second possible cause: files owned by root.** If PHP runs under the right
user but WordPress still asks for FTP, core is probably owned by root — for
example after a `wp core download` as root:

```bash
sudo wp-fix-ownership --report     # overview across all sites
sudo wp-fix-ownership              # fix interactively
```

Uploads and updates break independently: uploads only need write access to
`uploads/`, updates need the whole core owned by the site user. A site can
therefore upload files and still ask for FTP.

If the test shows the right user but `uploads` is still not writable, check
the **month directory** rather than the parent — a `2026/08` owned by root
blocks it despite a correct `uploads`:

```bash
find /home/SITE/public_html/wordpress/wp-content/uploads ! -user SITE | head
chown -R SITE:SITE /home/SITE/public_html/wordpress/wp-content/uploads
```

---

## After an aborted run

| Script | Backup |
|---|---|
| `wp-redirect-cleanup` | DB dump in the `--backup` directory |
| `wp-rotate-db-passwords` | `/root/wp-db-credentials.txt` (written before the change), `wp-config.php` copy under `/root` |
| `wp-asset-scan` | `<file>.bak-<timestamp>` alongside |
| `wp-harden-htaccess` | `/root/htaccess-backups`, `--restore` puts it back |
| `wp-move-to-subdir` | tarball and DB dump in the site user's `tmp/` |
| `wp-fix-ownership` | previously executable files noted under `/root` |

Restore a database:

```bash
sudo -u SITE -H wp --path=/path db import /path/to/dump.sql
```
