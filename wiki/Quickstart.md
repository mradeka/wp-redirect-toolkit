# Quickstart

Three commands that **change nothing**. Afterwards you know whether and where
something is wrong.

---

## 1. Install

```bash
git clone https://github.com/mradeka/wp-redirect-toolkit.git
cd wp-redirect-toolkit
chmod +x install.sh
sudo ./install.sh
```

`install.sh` then checks by itself whether Bash, PHP, the MySQL client, curl
and WP-CLI are present and reports what is missing. Details and edge cases:
[INSTALL.md](https://github.com/mradeka/wp-redirect-toolkit/blob/main/INSTALL.md)
(German).

> **WP-CLI 2.7 or newer.** Older versions return nothing for `--fields`
> combined with `--format=csv`. The scripts catch that with a fallback and say
> so, but updating avoids several edge cases:
> ```bash
> curl -fL -o /tmp/wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
> sudo install -m 755 /tmp/wp-cli.phar /usr/local/bin/wp
> ```
> Note the repository: **`wp-cli/builds`**, not `wp-cli/wp-cli`.

---

## 2. Can every account use the tools?

```bash
sudo check-usrlocalbin-access
```

The cleanup deliberately runs **as the site user**, not as root — otherwise
root-owned files appear and later block theme CSS generation.

If the `run` column says `NO` while `exec` is fine, `open_basedir` restricts
the account to its home. Remedy:

```bash
find /home -maxdepth 4 -name wp-config.php 2>/dev/null | while read -r C; do
  U=$(stat -c '%U' "$C"); H=$(getent passwd "$U" | cut -d: -f6)
  [ -d "$H" ] && install -m 755 -o "$U" -g "$(id -gn "$U")" /usr/local/bin/wp "${H}/wp"
done
```

---

## 3. Take stock

```bash
sudo wp-db-audit        # database: cron hooks, payload, URLs, accounts
sudo wp-asset-scan      # filesystem: JS, landing pages, loaders, checksums
```

Neither changes anything. `wp-db-audit` returns 0 when everything is clean and
1 on findings, which makes it suitable for cron.

**What now?**

| Result | Next step |
|---|---|
| Both clean | [Hardening](Hardening) — to keep it that way |
| Findings reported | [Incident Playbook](Incident-Playbook) |
| A finding looks harmless | [Known False Positives](False-Positives) |
| A command fails | [Troubleshooting](Troubleshooting) |

---

## Regular checks

```cron
# /etc/cron.d/wp-toolkit
MAILTO=admin@example.tld
0  6 * * 1 root /usr/local/bin/wp-db-audit --quiet
30 6 * * 1 root /usr/local/bin/wp-asset-scan
```

Reports only when there is something to report.
