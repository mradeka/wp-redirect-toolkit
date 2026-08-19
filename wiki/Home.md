# wp-redirect-toolkit

Tools to analyse and clean a WordPress compromise where a redirect was written
**straight into the database** — without modifying a single PHP file.

Built during a real incident on a host with ten WordPress installations. Every
detection pattern is tested against actual findings **and** against legitimate
counter-examples.

---

## Where do you want to start?

**"My site redirects to a foreign domain."**
→ [Incident Playbook](Incident-Playbook) — the sequence from first diagnosis
to the follow-up check the next day.

**"I just want to know whether something is wrong."**
→ [Quickstart](Quickstart) — three commands that change nothing.

**"The script reports a file that looks legitimate."**
→ [Known False Positives](False-Positives) — the catalogue of harmless cases,
with reasoning.

**"A command fails."**
→ [Troubleshooting](Troubleshooting)

**"What does each script do?"**
→ [Script Reference](Script-Reference)

**"How do I prevent this in future?"**
→ [Hardening](Hardening)

**"How did the attacker do it?"**
→ [Anatomy of the Attack](Attack-Anatomy)

---

## The idea in three sentences

The payload lives in the database, not in files. `post_modified` was
untouched, row types WordPress never writes that way were affected, and
`wp core verify-checksums` reported nothing — so there was no PHP backdoor,
someone had database access.

The target domain differs **per site**. A scan with a hard-coded domain
reports affected sites as clean, which is why the cleanup script reads it from
the payload itself.

After cleaning, the browser often keeps redirecting although the server
returns clean HTML. A meta-refresh page is fully cacheable — verify in a
private window or with `curl`.

---

## Two audit scripts, split by data source

| | `wp-db-audit` | `wp-asset-scan` |
|---|---|---|
| Source | database and WP options | filesystem |
| Checks | cron hooks, payload in `wp_posts`, `home`/`siteurl`, accounts | JS injections, landing pages, loaders, PHP in wrong places, mu-plugins, obfuscation, checksums |
| Writes | never | only with `--apply` |

Run only one of them and the other infection route stays undetected.

---

## Principles

- **Dry run is the default.** Every writing action sits behind `--apply`.
- **Back up before changing.** A database dump or file copy before anything is
  overwritten.
- **Only clean unambiguous findings automatically.** Anything ambiguous is
  reported, not touched.
- **Checksums before pattern matching.** Where `verify-checksums` applies it is
  the better answer — and the reason behind almost every false positive that
  had to be fixed.

---

## Important note

With a root-level compromise **no** cleanup is complete. These tools help with
cleaning up and with understanding — in case of doubt they do not replace
rebuilding the server. See [Incident Playbook](Incident-Playbook), section
"When to rebuild".
