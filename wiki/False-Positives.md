# Known False Positives

Everything listed here is **harmless**. It is documented because it was
actually reported during development — each entry led to an improvement.

The pattern behind them is always the same: a name or pattern search across
directories whose integrity can also be established by checksum. Hence the
rule: **checksums before pattern matching.**

---

## The universal test

Before reading a file, ask whether it differs from the original at all:

```bash
sudo -u SITEUSER -H wp --path=/path/to/install core verify-checksums
sudo -u SITEUSER -H wp --path=/path/to/install plugin verify-checksums --all
sudo -u SITEUSER -H wp --path=/path/to/install theme  verify-checksums --all
```

If that reports nothing about your file, it is byte-identical with the
original — then you do not need to judge the content at all.

**Exceptions:** translations and commercial extensions have no checksums. More
on those below.

---

## `page-coming-soon.php` in the theme

```
wp-content/themes/twentytwentyfive/patterns/page-coming-soon.php
wp-content/themes/twentytwentyfive/assets/images/coming-soon-bg-image.webp
```

**Legitimate.** The default theme ships its own "Coming soon" block pattern.
Recognisable by `@package WordPress` in the header, the `Slug:` and
`Categories:` entries, and Gutenberg block markup with `esc_html_e()`.

A fake landing page from the campaign contains a redirect instead.

*Fixed:* theme, plugin, `wp-includes` and `wp-admin` directories are excluded,
and the file must actually contain a redirect.

---

## `index.php` in subdirectory installs

```
Warning: File doesn't verify against checksums: index.php
```

**Legitimate and permanent.** With the "WordPress in its own directory"
layout, the `require` path in the loader points at the core directory:

```php
require __DIR__ . '/wordpress/wp-blog-header.php';
```

The checksum can never match there.

> **Never** overwrite it with `wp core download --force` — that undoes the
> adjustment and the site becomes unreachable.

*Fixed:* checksums run against the installation directory; the loader is
judged by content. A finding is: obfuscation constructs, loading from the
network, `header("Location: …")`, an `include` of anything other than
`wp-blog-header.php`/`wp-load.php`/`wp-settings.php`, or more than 15 lines of
code.

---

## `class-pclzip.php` in core

```
wp-admin/includes/class-pclzip.php
```

**Legitimate.** The bundled ZIP library. `gzinflate`/`gzdeflate` are its
actual job, and the `eval(` found there sits in a **commented-out** line left
over from older versions.

*Fixed:* core is no longer searched for obfuscation — checksums cover it. Only
`wp-content/` is searched, and a finding requires the *combination* of
execution and obfuscation (`eval(base64_decode(…))`), not a single function.

---

## `class-wp-filesystem-*.php` / `file.php` in core

**Legitimate.** `base64_decode` is used there for **verification**: MD5
checksums are stored base64-encoded, and package signatures are checked with
ED25519. `base64_encode` builds HTTP basic auth headers for loopback requests.

That is the opposite of obfuscation.

---

## `*.l10n.php` under `wp-content/languages/`

```
wp-content/languages/admin-de_DE.l10n.php
```

**Legitimate.** Since WordPress 6.5 language packs also ship in PHP format
because it loads faster than `.mo`. The file consists solely of `return [...]`
with translation pairs; recognisable by `'x-generator'=>'GlotPress/…'`.

*Fixed:* `.l10n.php` is skipped, as is any other file there that only contains
a `return` array. A PHP file under `languages/` that actually executes code is
still reported.

**Careful:** translations are **not** covered by `core verify-checksums`. When
in doubt, fetch them again:

```bash
wp language core update
wp language plugin update --all
```

---

## `view_*.php` under `wp-content/cache/`

```
wp-content/cache/view_<hash>.php    →  "WP Super Cache Log Viewer"
```

**Legitimate, but unwanted.** WP Super Cache creates this debug log viewer
when debugging is enabled in the plugin settings.

Why it should go anyway: the associated log file records **cookies and server
paths**. On top of that its access check joins username and password with
`&&`, so either one alone is enough.

```bash
# disable under Settings → WP Super Cache → Debug, then:
rm -f wp-content/cache/view_*.php wp-content/cache/<hash>.php
```

This finding is **correct** — `wp-content/cache` is deliberately not excluded.
The result of the check is: legitimate, but switch it off.

---

## "File should not exist" in core

```
Warning: File should not exist: wp-includes/js/dist/…/latex-to-mathml.js
Success: WordPress installation verifies against checksums.
```

**Usually legitimate.** Note the last line: no file is *modified*. The
warnings concern files that are *present* but not listed in the checksums for
this version.

Typical causes: a development or RC version, or leftovers from a version
change. Check:

```bash
wp core version --extra
```

Do not leave it unchecked all the same — a backdoor would appear in the same
category. Only PHP files are suspicious:

```bash
grep -rlE 'eval\(|base64_decode|\$_(GET|POST|REQUEST|COOKIE)' \
  wp-includes/assets/ wp-includes/blocks/*/*.asset.php 2>/dev/null
```

`*.asset.php` normally contains only a `return array(...)`.

---

## Commercial themes and plugins

```
Warning: Could not retrieve the checksums for version 7.1 of theme enfold, skipping.
```

**Not an error — but not reassurance either.** Enfold, Divi, Avada, WP Rocket,
ACF Pro and the like are not in the official repository and are therefore
**not verified**.

The script deliberately does not suppress this message; it lists the affected
extensions. On suspicion only a comparison helps:

```bash
diff -rq wp-content/themes/enfold/ /path/to/extracted/original/enfold/
```

> Take the original from your **own customer account**, never from a bundle
> site. Nulled versions are a standard infection route — a `diff` against one
> of those would confirm the compromise rather than rule it out.

---

## What is **not** a false positive

| Finding | Why to take it seriously |
|---|---|
| PHP file in `wp-content/uploads/` | executable code never belongs there |
| `auto_prepend_file` in `.htaccess` or `.user.ini` | loads code on **every** request |
| mu-plugins you do not recognise | always loaded, no activation needed |
| Cron hook with a random name | no plugin names hooks that way |
| `"//https://` in a JS file | no developer writes a URL that way |
| `home` and `siteurl` on different hosts | classic sign of a hijack |
| Database dump in the webroot | contains password hashes, retrievable via browser |

---

## Reporting a new false positive

[Open an issue](https://github.com/mradeka/wp-redirect-toolkit/issues) with:

- which script and which message
- the path (feel free to replace domain and username)
- why the file is legitimate, if you know
