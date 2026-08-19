# Hardening

What to do after the cleanup — and what made the incident possible in the
first place.

The order matters: **close the way in first, then rotate credentials.** The
other way round only locks you out.

---

## 1. Take the panel off the internet

The single biggest lever. A reachable panel with a terminal module turns one
known password into full root access.

```bash
# /etc/webmin/miniserv.conf
bind=127.0.0.1
```

```bash
/etc/webmin/restart
ss -tlnp | grep 10000        # must show 127.0.0.1:10000
```

Access afterwards through an SSH tunnel:

```bash
ssh -L 10000:127.0.0.1:10000 user@host
```

Then open `https://127.0.0.1:10000` in the browser.

> **`127.0.0.1`, not `localhost`** — neither in the tunnel nor in the browser.
> `localhost` resolves to `::1` first, where the panel no longer listens after
> `bind=127.0.0.1`. Symptom: `PR_CONNECT_RESET_ERROR`.

In MobaXterm: Tools → MobaSSHTunnel → Local port forwarding, right-hand field
(remote server) `127.0.0.1`, port 10000. Add the SSH key in the gear icon and
enable auto-reconnect.

**Alternative:** WireGuard or Tailscale on the host, panel bound to the VPN
address. Then no port needs to be open at all.

### If it really must be public

Sorted by effectiveness:

1. **Keep it updated.** `cat /etc/webmin/version` — older releases had
   root-level RCE vulnerabilities.
2. **IP allowlist** (Webmin Configuration → IP Access Control). With a static
   address this removes almost the whole attack surface.
3. **Two-factor authentication** (Webmin Users → TOTP).
4. **Never log in as root.** Create an account with only the modules needed.
5. **Remove dangerous modules:** `xterm`, `filemin`, `custom`, `shell`,
   `mysql`, `upload`. That is where the RCE chains land.
6. **Brute-force protection** in `miniserv.conf`:
   ```
   blockhost_failures=3
   blockhost_time=3600
   passdelay=1
   logouttime=10
   ssl=1
   ```

Even with all of that, the tunnel remains the stronger answer.

---

## 2. Firewall

Cloud firewalls are **default-deny**. Once one is assigned, only what is
explicitly allowed gets through — a single rule for port 10000 therefore
closes SSH as well.

| Port | Purpose |
|---|---|
| 22 | SSH — the basis for the tunnel |
| 80, 443 | websites |
| 25 | inbound mail |
| 465, 587 | submission |
| 143, 993 | IMAP |
| ICMP | diagnostics |

**Each rule for `0.0.0.0/0` AND `::/0`.** If the host is reachable over IPv6
and the rule only covers IPv4, it looks like a total outage.

```bash
ssh -4 -v user@host
ssh -6 -v user@host
```

On the host as well:

```bash
ufw deny 10000/tcp
ss -tlnp | grep -E '3306|10000'    # verify from OUTSIDE, not locally
```

---

## 3. SSH

```bash
# /etc/ssh/sshd_config
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
```

```bash
sshd -t && systemctl reload ssh
```

Keep a working session open until you have successfully reconnected in a
second window.

Generate keys on the **workstation**, not on the server:

```bash
ssh-keygen -t ed25519 -C "workstation"
```

With a passphrase. If the laptop is stolen, an unprotected key is immediately
usable.

### Private keys on the server

Panels create key pairs when a domain is set up — and leave the private half
in the home directory:

```bash
for K in /root/.ssh/id_* /home/*/.ssh/id_*; do
  [ -f "$K" ] && [[ "$K" != *.pub ]] || continue
  ssh-keygen -y -P '' -f "$K" >/dev/null 2>&1 && echo "NO PASSPHRASE: $K"
done
```

Anyone with root access could have taken these and later log in as any of
those users — without it showing up in `authorized_keys`. They are not needed
on the server:

```bash
grep -rn 'IdentityFile' /home/*/.ssh/config /root/.ssh/config 2>/dev/null
mkdir -p /root/keys-old && chmod 700 /root/keys-old
mv /home/*/.ssh/id_rsa /root/keys-old/ 2>/dev/null
```

Check first whether they are used for outbound connections, then move them —
and replace the corresponding `authorized_keys` entries.

---

## 4. Roll out `.htaccess`

```bash
sudo wp-harden-htaccess --inventory     # see what is there first
sudo wp-harden-htaccess                 # dry run
sudo wp-harden-htaccess --apply
```

Included: directory listings off, protection for `wp-config.php`, dumps,
archives and dot files, **no PHP execution in `uploads/`**, XML-RPC blocked,
security headers, protection against user enumeration.

The most important part is the PHP block in `uploads/`. An uploaded PHP file
is the classic route to a backdoor — and a second `.htaccess` directly in that
directory keeps working even if the main file is overwritten.

> Afterwards save permalinks once in wp-admin and test login, media upload and
> the block editor.

The prerequisite is `AllowOverride All`. Without it the whole file is silently
ignored — the script checks for this and runs an effectiveness test at the
end.

---

## 5. Credentials

```bash
sudo wp-rotate-db-passwords --apply
sudo wp-user-audit --shuffle-salts
```

By hand as well: the panel root account **and every domain account**,
WordPress administrators, SSH keys.

Do not forget services that use the same credentials — backup scripts, the
site users' `~/.my.cnf`, phpMyAdmin, your own cron jobs.

---

## 6. Block the domains

```bash
sudo apply-blocklist dnsmasq --apply
```

By DNS, not by IP — the domains sit behind CDN addresses shared with thousands
of legitimate sites.

---

## 7. Ongoing checks

```cron
MAILTO=admin@example.tld
0  6 * * 1 root /usr/local/bin/wp-db-audit --quiet
30 6 * * 1 root /usr/local/bin/wp-asset-scan
```

After an incident, more closely as well: after an hour and the next day.

And keep an eye on this if a mail server runs on the host:

```bash
mailq | tail
grep -c 'status=sent' /var/log/mail.log
```

A compromised host gets used as a spam relay — and that lands you on
blocklists, which outlasts the incident itself.

---

## 8. Keep PHP per-site

Check that PHP runs under the site user, not `www-data`:

```bash
sudo check-usrlocalbin-access
```

With `mod_fcgid`/suexec every site runs under its own identity. If `mod_php`
is also enabled, its `SetHandler` overrides that and all domains share one
process identity — code on one compromised site can then reach the files of
every other.

```bash
ls -la /etc/apache2/mods-enabled/ | grep -i php
a2dismod php8.3 && apachectl configtest && systemctl restart apache2
```

---

## Lasting habits

- **No dumps in the webroot.** Always keep `--backup` outside `public_html`.
- **No phar files in the webroot.** Not even briefly.
- **Avoid nulled themes and plugins.** Enfold, Divi and the like from your own
  customer account — bundle sites are a standard infection route, and a
  checksum comparison is useless against it.
- **`DISALLOW_FILE_EDIT`** in `wp-config.php` takes the edge off the backend
  file editor.
- **Set the PHP version in the panel**, not in `.htaccess`. Then the file no
  longer depends on it and a uniform baseline across all sites is achievable.
- **Check file ownership** after every manual intervention:
  ```bash
  sudo wp-fix-ownership --report
  ```
