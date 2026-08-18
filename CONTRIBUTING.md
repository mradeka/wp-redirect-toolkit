# Contributing

Contributions are welcome — especially feedback from real incidents: false
positives, variants that were not detected, environments where something does
not run.

## Reporting false positives

The most useful kind of issue. Every false positive so far followed the same
pattern: a name or pattern search across directories whose integrity can also
be established by checksum. Past examples: the theme pattern
`page-coming-soon.php`, the adjusted `index.php` in subdirectory installs,
`class-pclzip.php` in core, translation files `*.l10n.php`.

Please include:

- which script and which message
- the path of the file (feel free to replace domain and username)
- why the file is legitimate, if you know

## Adding detection patterns

Additions to `blocklist-domains.txt` and to the search patterns need a source:
your own observation with a date, or a publicly available report. Please no
domains on suspicion alone.

## Code conventions

- **Bash 4+**, `set -uo pipefail`. No `set -e`: the scripts should continue
  after a single failed check and report at the end.
- **Dry run is the default.** Every writing action sits behind `--apply`.
- **Back up before changing.** A database dump or a file copy before anything
  is overwritten.
- **Only clean unambiguous findings automatically.** Anything ambiguous is
  reported, not touched. One reported finding too many beats one deleted file
  too few.
- **Checksums before pattern matching.** Where `wp core verify-checksums` or
  `wp plugin/theme verify-checksums` applies, that is the better answer.
- **Do not swallow error messages.** No `2>/dev/null` where the user needs the
  cause.
- **No `--force` without a prompt** when deleting real content.

## Before opening a pull request

```bash
for f in *.sh; do bash -n "$f"; done
shellcheck -S warning *.sh
for f in *.sh; do [ "$f" = install.sh ] || bash "$f" --help >/dev/null; done
```

The same three steps run in CI. For new detection logic, please test against a
small fixture tree and show the result in the pull request — both the detected
case and a legitimate counter-example.

## Language

**Code, comments, option names and all output are English.** That includes
error messages and help text — someone installing the toolkit should not run
into German messages.

Documentation: `README.md` is English and authoritative. `README.de.md` is the
German translation; when an option changes, both need updating. `INSTALL.md`,
`INCIDENT.md` and the wiki are German.

Issues and pull requests are welcome in either language.
