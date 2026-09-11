"""Behavior checks for repository Markdown staging."""
import tempfile
import unittest
from pathlib import Path
from website.prepare import rewrite_markdown, prepare, GITHUB


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ['README.md', 'docs/guide.md', 'src/example.ts', 'docs/old.md']:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('# Example\n')
        self.pages = {'README.md': 'project.md', 'docs/guide.md': 'guides/start.md'}

    def rewrite(self, text, source='docs/guide.md', authored=False):
        return rewrite_markdown(text, source, self.pages.get(source, 'index.md'), self.root, self.pages, authored)

    def test_selected_links_resolve_from_source_and_keep_fragment(self):
        self.assertEqual(self.rewrite('[home](../README.md#hello)'), '[home](../project.md#hello)')

    def test_unselected_sources_link_to_github(self):
        self.assertEqual(self.rewrite('[source](../src/example.ts#L2)'), f'[source]({GITHUB}/src/example.ts#L2)')
        self.assertEqual(self.rewrite('[old](old.md)'), f'[old]({GITHUB}/docs/old.md)')

    def test_external_and_fragment_links_unchanged(self):
        value = '[web](https://example.com) [mail](mailto:a@b.c) [here](#example)'
        self.assertEqual(self.rewrite(value), value)

    def test_code_fences_and_inline_code_preserved(self):
        value = '```md\n[home](../README.md)\n```\n~~~md\n[home](../README.md)\n~~~\n`[home](../README.md)`\n'
        self.assertEqual(self.rewrite(value), value)

    def test_reference_links_and_titles(self):
        self.assertEqual(self.rewrite('[home]: ../README.md "Title"\n'), '[home]: ../project.md "Title"\n')

    def test_authored_routes_are_already_site_relative(self):
        value = '[start](guides/start.md#example)'
        self.assertEqual(self.rewrite(value, 'website/content/index.md', True), value)

    def test_missing_link_fails(self):
        with self.assertRaisesRegex(ValueError, 'Missing local link'):
            self.rewrite('[broken](missing.md)')

    def test_preparation_is_deterministic_and_checks_missing_sources(self):
        output = self.root / 'generated'
        prepare(self.root, output, self.pages, asset_dirs=())
        first = (output / 'guides/start.md').read_bytes()
        (output / 'stale.md').write_text('stale')
        prepare(self.root, output, self.pages, asset_dirs=())
        self.assertFalse((output / 'stale.md').exists())
        self.assertEqual((output / 'guides/start.md').read_bytes(), first)
        with self.assertRaises(FileNotFoundError):
            prepare(self.root, output, {'missing.md': 'missing.md'}, asset_dirs=())


if __name__ == '__main__':
    unittest.main()
