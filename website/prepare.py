"""Stage the selected repository guides without modifying their source files."""
from pathlib import Path
import posixpath
import re
import shutil
from urllib.parse import quote, unquote, urlsplit, urlunsplit

ROOT = Path(__file__).resolve().parents[1]
GITHUB = 'https://github.com/steve-z-wang/local-first-state/blob/main'
PAGES = {
    'website/content/index.md': 'index.md',
    'website/content/concepts.md': 'concepts.md',
    'README.md': 'project.md',
    **{path: path for path in (
        'examples/rust-round-trip/README.md',
        'packages/client-js/README.md', 'packages/dart/README.md',
        'packages/server/README.md', 'packages/persistence-prisma/README.md',
        'packages/nest/README.md', 'crates/lfs-compiler/README.md',
        'integration/README.md', 'integration/rust/README.md',
        'integration/platform/README.md',
        'docs/architecture/compatibility-and-recovery.md',
        'docs/implementation-progress.md', 'docs/architecture/code-organization.md',
        'docs/architecture/concepts-and-naming.md', 'docs/next-things.md',
        'docs/documentation.md',
    )},
}
# Match ordinary inline destinations and reference definitions. Code is excluded
# before these patterns run. Angle brackets support paths containing spaces.
INLINE = re.compile(r'(\]\(\s*)(<[^>\n]+>|[^\s()]+)(?=\s|\))')
REFERENCE = re.compile(r'(^ {0,3}\[[^]\n]+\]:\s*)(<[^>\n]+>|\S+)', re.MULTILINE)
CODE = re.compile(r'(`+)(.*?)(?<!`)\1(?!`)', re.DOTALL)
FENCE = re.compile(r'^\s*(`{3,}|~{3,})(.*)$')


def rewrite_markdown(text, source, route, root, pages, authored=False):
    """Resolve prose links from the original file, keeping code examples intact."""
    def destination(value):
        angle = value.startswith('<') and value.endswith('>')
        raw = value[1:-1] if angle else value
        parts = urlsplit(raw)
        if parts.scheme or parts.netloc or not parts.path:
            return value
        path = unquote(parts.path)
        if authored:
            candidate = posixpath.normpath(posixpath.join(posixpath.dirname(route), path))
            if candidate in pages.values() or candidate.startswith(('assets/', 'stylesheets/')):
                return value
        candidate = posixpath.normpath(posixpath.join(posixpath.dirname(source), path))
        if candidate in pages:
            target = posixpath.relpath(pages[candidate], posixpath.dirname(route) or '.')
        else:
            resolved = (root / candidate).resolve()
            if not resolved.is_relative_to(root.resolve()) or not resolved.exists():
                raise ValueError(f'Missing local link in {source}: {raw}')
            target = GITHUB + '/' + quote(candidate, safe='/')
        result = urlunsplit((*urlsplit(target)[:2], urlsplit(target).path, parts.query, parts.fragment))
        return f'<{result}>' if angle else result

    def prose(value):
        pieces = []
        cursor = 0
        for match in CODE.finditer(value):
            pieces.append(links(value[cursor:match.start()]))
            pieces.append(match.group())
            cursor = match.end()
        pieces.append(links(value[cursor:]))
        return ''.join(pieces)

    def links(value):
        for pattern in (INLINE, REFERENCE):
            value = pattern.sub(lambda m: m[1] + destination(m[2]), value)
        return value

    output, pending = [], []
    fence_char, fence_length = None, 0
    for line in text.splitlines(keepends=True):
        match = FENCE.match(line.rstrip('\r\n'))
        if fence_char:
            output.append(line)
            if match and match[1][0] == fence_char and len(match[1]) >= fence_length and not match[2].strip():
                fence_char = None
        elif match:
            output.append(prose(''.join(pending)))
            pending = []
            output.append(line)
            fence_char, fence_length = match[1][0], len(match[1])
        else:
            pending.append(line)
    output.append(prose(''.join(pending)))
    return ''.join(output)


def prepare(root=ROOT, output=None, pages=PAGES, asset_dirs=('stylesheets', 'assets')):
    root = Path(root)
    output = Path(output) if output else root / 'website/.generated'
    # Validate and transform before replacing the previous successful staging.
    rendered = {}
    for source, route in pages.items():
        with (root / source).open(encoding='utf-8', newline='') as stream:
            rendered[route] = rewrite_markdown(stream.read(), source, route, root, pages,
                                               source.startswith('website/content/'))
    for name in asset_dirs:
        if not (root / 'website' / name).is_dir():
            raise FileNotFoundError(f'Missing website asset directory: {name}')
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    for route, content in rendered.items():
        target = output / route
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open('w', encoding='utf-8', newline='') as stream:
            stream.write(content)
    for name in asset_dirs:
        shutil.copytree(root / 'website' / name, output / name)
    return len(rendered)


if __name__ == '__main__':
    print(f'Staged {prepare()} documentation pages.')
