# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioning follows [SemVer](https://semver.org/).

## [1.1.0] — 2026-08-18

### Changed

- All script output, help text and comments switched to **English**
- `README.md` is now English; the German version lives alongside as
  `README.de.md`
- Classification identifiers in `wp-harden-htaccess` are English
  (`dangerous`, `options-risk`, `external-redirect`, `unknown`, …)

### Added

- `wp-fix-ownership` — check file ownership and fix it interactively
- `wp-harden-htaccess` — roll out a hardened `.htaccess`, with inventory,
  classification of carried-over rules and automatic rollback
- `.gitattributes` enforces LF line endings for shell scripts

### Fixed

- Removed `Options +FollowSymLinks` from all `.htaccess` templates — it needs
  `AllowOverride Options`, which panels usually do not grant, and caused a 500
- Replaced `AddType text/plain .php` with `RemoveHandler` — on fcgid the
  former overrode the handler mapping and broke PHP for the whole directory
  tree
- Rollback in `wp-harden-htaccess` now also checks an asset in the core
  directory, not just the home page

## [1.0.0] — 2026-08-16

First release. Built during a real incident; every detection pattern is tested
against actual findings **and** against legitimate counter-examples.

### Included

- `wp-db-audit` — database and configuration: cron hooks with random-looking
  names, redirect payload, diverging `home`/`siteurl`, administrator accounts
- `wp-asset-scan` — filesystem: JS injections, fake landing pages,
  `index.php` loaders, PHP in unusual places, mu-plugins, obfuscation, dumps
  in the webroot, checksums for core, plugins and themes
- `wp-cron-list` — cron table across all sites, random names flagged
- `wp-user-audit` — score user accounts, rotate auth salts
- `wp-redirect-cleanup` (v7) — clean one installation in four passes
- `wp-cleanup-all` — run the cleanup across all sites
- `wp-rotate-db-passwords` — rotate database passwords, with rollback
- `wp-move-to-subdir` — move an install into `public_html/wordpress/`
- `check-usrlocalbin-access` — check the tools are usable per account
- `apply-blocklist` — blocking rules from `blocklist-domains.txt`

### Known limitations

- Serialised values in `wp_options`, `postmeta` and `comments` are reported
  but not cleaned automatically — a blind cut destroys the length prefixes.
- Commercial themes and plugins have no checksums. They are named and
  explicitly marked as unverified.
- The path assumption is `/home/<user>/public_html[/wordpress]`.

[1.1.0]: https://github.com/mradeka/wp-redirect-toolkit/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/mradeka/wp-redirect-toolkit/releases/tag/v1.0.0
