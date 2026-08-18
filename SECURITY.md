# Security Policy

## What these scripts do — and what that means

This toolkit reaches deep into production systems: it reads and writes
WordPress databases, edits `wp-config.php`, rotates database passwords and
deletes files. It is meant for servers you administer yourself.

Every writing script is a dry run without `--apply` and takes a backup before
any change. That does not replace your own backup outside the server.

## Two files that need protection

- **`/root/wp-db-credentials.txt`** — written by `wp-rotate-db-passwords`,
  contains database passwords in clear text. Mode 600, owned by root, and it
  must never end up in a repository, a ticket or a backup you hand on. The
  bundled `.gitignore` excludes it.
- **`/root/wp-cleanup-logs/`** — logs of cleanup runs. They may contain paths,
  usernames and target domains.

## Reporting a vulnerability

If you find a security problem in these scripts — a command injection through
a filename, an unsafe temporary file, a privilege escalation — please do
**not** open a public issue.

Use GitHub's private reporting instead: `Security` → `Report a vulnerability`.

Please include:

- which script and which version are affected
- how to reproduce the problem
- what an attacker could achieve with it

## What does not belong here

This repository is not a support channel for compromised WordPress sites. If
your own site is affected, the
[WordPress support community](https://wordpress.org/support/) is the better
place.

## About the attacker domains

`blocklist-domains.txt` lists domains from an observed campaign. They are
meant for blocking — do not open them in a browser. If a domain has changed
hands and is listed unfairly, an issue is the right way to say so.
