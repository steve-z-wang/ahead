# Documentation website

The documentation uses MkDocs Material. All website pages live in `website/content/` and are built directly from those files. Repository and package READMEs provide entry points to the documentation.

## Preview locally

From the repository root, with Python 3.12 or newer:

```bash
python3 -m venv website/.venv
website/.venv/bin/python -m pip install -r website/requirements.txt
website/.venv/bin/python -m mkdocs serve -f website/mkdocs.yml
```

Open the URL printed by MkDocs. Changes to `website/content/` reload the preview automatically. Add pages to the navigation in `website/mkdocs.yml`. Use relative Markdown links between pages and GitHub links when referring to implementation source.

The architecture SVG lives in `website/content/assets/`; its editable Excalidraw source is `website/assets/architecture.excalidraw`. Styles live in `website/content/stylesheets/`.

## Validate and build

```bash
website/.venv/bin/python -m unittest website/test_examples.py
website/.venv/bin/python -m mkdocs build --strict -f website/mkdocs.yml
website/.venv/bin/python website/check_links.py
```

The static output is `website/site/`. Do not edit this generated directory. Relative navigation supports both the local preview and the GitHub Pages project path `/ahead/`.

Run `python3 website/check_examples.py` after building the repository and resolving the example and Dart dependencies. This typechecks snippets from `website/content/` and compiles the schema examples; it also runs in `scripts/test.sh`. Use `bash integration/e2e/run.sh` to check HTTP and SQLite behavior.

## CI and publication

The Documentation workflow builds and checks relevant pull requests and pushes. A successful build on `main` automatically deploys to GitHub Pages. Pull requests and other branches produce review artifacts without deploying.

Pages must use **Settings → Pages → Build and deployment → Source → GitHub Actions**. To redeploy manually, open **Actions → Documentation → Run workflow**, select **main**, and run it. The deployment URL appears in the workflow environment. Dispatching from another branch builds an artifact only.

Source links point to `main` and become available after merge. Dependency updates should regenerate the pinned `requirements.txt` from a clean virtual environment and pass the checks above.
