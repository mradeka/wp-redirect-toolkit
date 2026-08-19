# FAQ

---

## Using the tools

### Can I try the scripts safely?

Yes. Without `--apply` they change nothing. `wp-db-audit`,
`check-usrlocalbin-access` and `wp-cron-list` (without `--delete`) never write
at all.

A backup is taken before every writing action — database dump, file copy, or
both.

### Why do I not have to pass `--domain`?

Because the target domain differs per site. In the case examined, three
installations carried three different domains of the same campaign. With a
hard-coded domain a scan reports affected sites as clean — so the script reads
it from the payload itself.

### Why as the site user and not as root?

Because root-owned files cause trouble later. Concretely: Enfold writes its
stylesheets to `wp-content/uploads/dynamic_avia/`. If that directory suddenly
belongs to root, the theme can no longer write there — and the site loses its
styling without any error appearing.

### My site still redirects after the cleanup.

Check in this order:

```bash
curl -s https://DOMAIN/ | grep -c 'BAD-DOMAIN'
```

If that is 0, the server serves clean HTML — then it is your browser cache. A
meta-refresh page is fully cacheable. Private window or another device.

If it is greater than 0, see [Troubleshooting](Troubleshooting).

### Can I undo a run?

| Script | Way back |
|---|---|
| `wp-redirect-cleanup` | `wp db import` of the dump in the `--backup` directory |
| `wp-harden-htaccess` | `wp-harden-htaccess --restore` |
| `wp-asset-scan` | `.bak-<timestamp>` alongside the file |
| `wp-rotate-db-passwords` | rolls back itself on failure; old passwords are in `/root/wp-db-credentials.txt` |
| `wp-move-to-subdir` | tarball and dump in the site user's `tmp/` |
| `wp-fix-ownership` | previously executable files noted under `/root` |

---

## Design decisions

### Why are not all findings cleaned automatically?

Because one reported finding too many is far more harmless than one deleted
file too few. Cleaned automatically is only what is unambiguous: the known
payload in `post_content`, JS lines with a domain from the blocklist,
disposable row types in the database.

Not automatic: serialised values in `wp_options`, `postmeta` and `comments` —
a blind cut destroys the length prefixes there. Nor HTML and PHP files, which
may well be legitimate.

### Why does `wp-user-audit` not just delete every account whose name differs from the directory?

Because that hits far too much. A WordPress login has no relation to the Unix
account: editors, authors and shop customers never match the home directory
name. And `wp user delete` takes their posts with them.

Instead a scoring system across role, registration date, mail domain, post
count and name shape. Accounts with their own content are skipped entirely
without `--reassign`.

### Why does `wp-harden-htaccess` not simply delete existing files?

Because on fcgid sites the PHP version lives in `.htaccess`
(`AddHandler fcgid-script .php`). Remove that line and the site runs with the
server default — or PHP stops running and the browser downloads the source.

Conversely nothing is carried over blindly either: after an incident an
injected rule may sit in there. Every line is classified; `--inventory` shows
the result.

### Why two audit scripts instead of one?

The split follows the data source: `wp-db-audit` asks the database,
`wp-asset-scan` looks at files. Previously both lived in one script called
`wp-cron-audit` — the name promised cron and delivered everything.

Together they give the full picture. Run only one and the other infection
route stays undetected.

### Why is WordPress core not searched for malicious patterns?

Because `verify-checksums` is the better answer: a byte comparison against the
original rather than a pattern search. Almost every false positive that had to
be fixed came from searching directories whose integrity is verifiable anyway
— see [False Positives](False-Positives).

---

## Assessing the situation

### Is cleaning enough, or does the server have to be rebuilt?

It depends on how far the access reached.

**Cleaning is defensible** when everything points at database access: no
modified files, clean checksums, no mu-plugins, no foreign accounts — and the
follow-up checks stay at 0.

**Rebuilding is the honest conclusion** when the panel logs show a foreign
session with a browser shell (`/xterm/`, `/filemin/`, `/shell/`). Its
keystrokes appear in no log; what happened during that time cannot be
reconstructed.

Then: new host, fresh system, restore **content** — database content and
uploads, no executable files. Core, themes and plugins from their original
sources.

### How do I know whether access still exists?

From the follow-up check. If the count rises from 0 again, someone is still
in. Do not clean a second time — take the site offline:

```bash
a2dissite YOUR-SITE.conf && systemctl reload apache2
```

Cron hooks are a good early indicator: they come back within the hour if code
recreates them.

### Do I have to inform my visitors?

That is a legal question, not a technical one. In the EU a notification duty
under GDPR Art. 33/34 may apply when personal data is affected — and with
database access to `wp_users` it usually is. The deadline is short (72 hours
from becoming aware).

Whether it applies in your case can only be judged by someone with a legal
view of the specifics. Useful for that assessment: which tables were affected,
whether shop or form data was involved, and how long the access lasted.

---

## About the project

### Can I use this for other campaigns?

Partly. The generic checks — cron hooks with random names, `home`/`siteurl`
comparison, checksums, PHP in wrong places, `auto_prepend` — are
campaign-independent.

The cleanup is tailored to the payload pattern described here. With a
different structure the cuts do not apply, and the scripts say so honestly
rather than doing something wrong.

### How do I report a false positive?

[Open an issue](https://github.com/mradeka/wp-redirect-toolkit/issues) with
the script, the message, the path and — if known — why the file is legitimate.
That is the most useful kind of feedback; every entry in the false-positive
catalogue led to an improvement.

### Does this work without a hosting panel?

Yes. The only assumption is the path
`/home/<user>/public_html[/wordpress]`. Only individual hints in the output are
panel-specific.
