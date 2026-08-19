# Publishing the wiki

This file does **not** belong in the wiki — it only describes how the other
pages get there. Delete or ignore it before pushing.

## One-off: enable the wiki

On GitHub go to the repository → **Settings** → **Features** → tick **Wikis**.
Then open the **Wiki** tab, click *Create the first page* and save it — before
that the wiki repository does not exist and cannot be cloned.

## Uploading the pages

```bash
git clone https://github.com/mradeka/wp-redirect-toolkit.wiki.git
cd wp-redirect-toolkit.wiki

cp /path/to/wiki-en/*.md .
rm -f PUBLISH.md

git add -A
git commit -m "Wiki: playbook, script reference, false positives, hardening"
git push
```

## Structure

| File | Becomes |
|---|---|
| `Home.md` | landing page |
| `_Sidebar.md` | navigation on the right (every page) |
| `_Footer.md` | footer (every page) |
| `Quickstart.md` | page "Quickstart" |
| `Incident-Playbook.md` | page "Incident Playbook" |
| `Script-Reference.md`, `False-Positives.md`, `Troubleshooting.md`, `FAQ.md`, `Attack-Anatomy.md`, `Hardening.md` | one page each |

Internal links work via the filename without extension:
`[False Positives](False-Positives)`. Hyphens stay in the link but are shown
as spaces in the heading.

## Relation to the README

| | Content |
|---|---|
| README.md | what the project is, installation, option tables (English) |
| README.de.md | German translation |
| INSTALL.md | detailed installation, prerequisites, edge cases (German) |
| INCIDENT.md | the documented incident as a report (German) |
| Wiki | guides, reference, false positives, FAQ (English) |

Deliberately duplicated: the short installation and the script options.
Someone landing in the wiki should not have to switch to the README first.

## Maintenance

When an option changes, two places need updating: `README.md` in the main
repository and `Script-Reference.md` in the wiki. A new false positive belongs
in `False-Positives.md` — with the path, the reason, and the improvement that
followed from it.
