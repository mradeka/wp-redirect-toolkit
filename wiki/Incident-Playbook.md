# Incident Playbook

The sequence from first diagnosis to the follow-up check the next day. The
order is not arbitrary — step 5 before 6 and 7 is the most important point on
this page.

---

## 0. Do not clean first

The reflex is to start scrubbing. A better order is:
**preserve → understand → close → clean → verify.**

Cleaning while the way in is still open means doing the work twice — and it
destroys the traces that show how someone got in.

```bash
# preserve evidence before logs rotate
mkdir -p /root/forensics-$(date +%F) && chmod 700 /root/forensics-$(date +%F)
cp -a /var/webmin/miniserv.log /var/webmin/webmin.log /root/forensics-$(date +%F)/ 2>/dev/null
cp -a /var/log/apache2/*access*.log /root/forensics-$(date +%F)/ 2>/dev/null
```

---

## 1. Narrow down the symptom

```bash
curl -s https://YOUR-DOMAIN/ | grep -iE 'http-equiv="refresh"|location\.replace'
curl -sI https://YOUR-DOMAIN/ | grep -i location
```

| Observation | Meaning |
|---|---|
| Meta refresh or `location.replace` in the HTML | payload in page content → database |
| `Location:` header | redirect at server level → `.htaccess` or vhost |
| curl clean, browser redirects | browser cache, or conditional on user agent |

For the last row, check with a mobile user agent — the campaign targets touch
devices:

```bash
curl -s -A "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) Mobile/15E148" \
  "https://YOUR-DOMAIN/?nocache=$RANDOM" | grep -c 'refresh'
```

---

## 2. Take stock across all sites

```bash
sudo wp-db-audit
sudo wp-asset-scan
sudo wp-cron-list --suspicious
sudo wp-user-audit
```

All read-only. Note per site: target domain, number of affected rows, whether
`home`/`siteurl` are hijacked, whether files are affected.

**The target domain differs per site.** Do not hard-code it anywhere — the
scripts read it from the payload themselves.

---

## 3. Dry run of the cleanup

```bash
sudo wp-cleanup-all
```

Read the output before going further. Three blocks matter:

- **`rows matching the payload pattern`** — number of affected rows. 0 means
  either clean, or the pattern does not fit.
- **`[HIT]` lines from the filesystem and checksums.** If PHP shows up in
  `uploads` or a core file is modified, this is **not** purely a database
  matter — sort out the files first.
- **Hits in options, postmeta, comments.** These are deliberately not cleaned
  automatically: they hold serialised values, and a blind cut destroys the
  length prefixes.

---

## 4. Clean

```bash
sudo wp-cleanup-all --apply
sudo wp-asset-scan --apply
```

A database dump is written before every change. Then by hand:

```bash
systemctl reload php8.*-fpm          # clear opcache
```

And in the browser: **private window or another device.** A meta-refresh page
is fully cacheable — after cleaning, your own browser often keeps redirecting
although the server serves clean HTML.

---

## 5. Close the way in — BEFORE the credentials

This is where the order matters. Rotating passwords first only locks you out.

```bash
# panel local only
# /etc/webmin/miniserv.conf:  bind=127.0.0.1
/etc/webmin/restart
ss -tlnp | grep -E '10000|3306'
```

Access afterwards through an SSH tunnel:

```bash
ssh -L 10000:127.0.0.1:10000 user@host
```

Use `127.0.0.1` in the tunnel **and** in the browser, not `localhost` — the
latter resolves to `::1` first, where the panel no longer listens after
`bind=127.0.0.1`. Symptom: `PR_CONNECT_RESET_ERROR`.

Do not forget the cloud firewall: it is default-deny. After adding a single
rule everything else is closed — so allow 22, 80, 443, 25 and whatever else
you need explicitly, **each rule for `0.0.0.0/0` and `::/0`**.

Details: [Hardening](Hardening).

---

## 6. Rotate credentials

```bash
sudo wp-rotate-db-passwords            # dry run
sudo wp-rotate-db-passwords --apply
```

By hand as well: the panel root account **and every domain account**, SSH
keys, WordPress administrators.

Also check whether private SSH keys without a passphrase sit on the server —
panels put them there when a domain is created:

```bash
for K in /root/.ssh/id_* /home/*/.ssh/id_*; do
  [ -f "$K" ] && [[ "$K" != *.pub ]] || continue
  ssh-keygen -y -P '' -f "$K" >/dev/null 2>&1 && echo "NO PASSPHRASE: $K"
done
```

Anyone with root could have taken those keys. A clean `authorized_keys` alone
is therefore not reassuring.

---

## 7. Invalidate sessions

```bash
sudo wp-user-audit --shuffle-salts
```

Regenerates the `AUTH_KEY`/`SALT` constants. Every existing login becomes
invalid — including your own. It does not change passwords.

---

## 8. Block the domains

```bash
sudo apply-blocklist dnsmasq --apply
apply-blocklist scan
```

Block by DNS, not by IP: the domains sit behind CDN addresses shared with
thousands of legitimate sites.

---

## 9. Follow-up check

After an hour and the next day:

```bash
sudo wp-db-audit --quiet
sudo wp-asset-scan
```

**If the count rises from 0 again, access still exists.** Do not clean a
second time — take the site offline:

```bash
a2dissite YOUR-SITE.conf && systemctl reload apache2
```

---

## When to rebuild

Check the panel logs for unfamiliar sessions:

```bash
grep -iE 'record-login|record-failed' /var/webmin/webmin.log | tail -40
grep -a -oE '"(GET|POST) [^ ?]+' /var/webmin/miniserv.log | sort | uniq -c | sort -rn | head -20
```

Watch for `/xterm/`, `/filemin/`, `/shell/` — a browser shell means root
access, and its keystrokes appear in **no** log. What happened during that
time cannot be reconstructed.

In that case the honest conclusion is a rebuild: new host, fresh system,
restore **content** from backups — database content and uploads, no executable
files. Fetch core, themes and plugins from their original sources.

Cleaning in place is then a bet that you found everything.
