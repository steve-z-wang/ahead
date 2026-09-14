"""Keep snippet verification active for code inside language tabs."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from website.check_examples import snippets


class SnippetTests(unittest.TestCase):
    def test_extracts_each_language_without_swallowing_prose(self):
        markdown = '''# Read a record

=== "TypeScript"

    ```ts
    import { Client } from './client.ts';
    await client.transaction(async tx => {
      await tx.read('Entry', { id: 'entry-1' });
    });
    ```

=== "Flutter"

    ```dart
    final entry = await client.models.entry.get(id);
    ```

## More details

Shared explanation.

```ts
await client.close();
```
'''
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'guide.md').write_text(markdown)
            with patch('website.check_examples.ROOT', root):
                ts = snippets('ts', ['guide.md'])
                dart = snippets('dart', ['guide.md'])
        self.assertEqual([code for _, code in ts], [
            "await client.transaction(async tx => {\n  await tx.read('Entry', { id: 'entry-1' });\n});\n",
            'await client.close();\n',
        ])
        self.assertEqual(dart, [('guide.md:14', 'final entry = await client.models.entry.get(id);\n')])


if __name__ == '__main__':
    unittest.main()
