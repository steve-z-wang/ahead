# Documentation website

The English website uses MkDocs Material. It reuses selected repository Markdown through `prepare.py`; website-only introductions live in `content/`. Edit the original guide, not `.generated/` or `site/`.

## Preview locally

From the repository root, with Python 3.12 or newer:

```bash
python3 -m venv website/.venv
website/.venv/bin/python -m pip install -r website/requirements.txt
website/.venv/bin/python website/prepare.py
website/.venv/bin/python -m mkdocs serve -f website/mkdocs.yml
```

Open the URL printed by MkDocs. After changing repository Markdown, homepage content, CSS or assets, rerun `prepare.py` to refresh the preview's staged inputs.

## Validate and build

```bash
website/.venv/bin/python -m unittest website/test_prepare.py
website/.venv/bin/python website/prepare.py
website/.venv/bin/python -m mkdocs build --strict -f website/mkdocs.yml
website/.venv/bin/python website/check_links.py
```

The static output is `website/site/`. Relative navigation supports both the local preview and the configured GitHub Pages project path `/otter-sync/`.

`prepare.py` has an explicit source-to-route map. Selected guide links become site links; links to other existing repository files become GitHub `blob/main` links. Fenced and inline code are preserved. Website-authored Markdown uses site-relative destinations. Ordinary inline Markdown links and reference definitions are supported; use these forms instead of raw HTML links for repository references. Missing selected pages and unresolved local Markdown links fail preparation. To add a page, update both the map and `mkdocs.yml` navigation. Historical documents can remain repository links without joining the navigation.

## CI and manual publication

The Documentation workflow builds and uploads a downloadable static artifact for relevant pull requests and pushes. It does not publish on either event.

After this change is merged to `main`, a repository administrator can select **Settings → Pages → Build and deployment → Source → GitHub Actions**. Review the `github-pages` environment's branch protection and approval rules. Then open **Actions → Documentation → Run workflow**, select **main**, and run it. Only that explicit main-branch dispatch can run the Pages deployment job. A dispatch from another branch builds an artifact only. The deployment URL appears in the workflow environment.

No live Pages settings are changed by adding these files. Source links use the main branch, so new guide paths become available there after merge. Dependency updates should regenerate the fully pinned `requirements.txt` from a clean virtual environment and pass the checks above.
