"""Regression coverage for reliable supplementary validation evidence."""

from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch


class FoundationValidationTests(unittest.TestCase):
    def test_failed_rerun_cannot_retain_previous_success(self):
        script = Path(__file__).resolve().parents[1] / 'check-foundation-sources.py'
        main = runpy.run_path(str(script))['main']
        with tempfile.TemporaryDirectory(prefix='agentdesk-validation-') as directory:
            output = Path(directory)
            (output / 'result.json').write_text('{"hostUnitTests": 5}')
            (output / 'host-unit-tests.log').write_text('Previous successful test run')
            with patch.dict(main.__globals__, {'OUTPUT': output}):
                with patch.dict(main.__globals__, {'query': self.unavailable_tool}):
                    with self.assertRaisesRegex(RuntimeError, 'Tool unavailable'):
                        main()
            self.assertFalse((output / 'result.json').exists())
            self.assertFalse((output / 'host-unit-tests.log').exists())

    @staticmethod
    def unavailable_tool(*_arguments):
        raise RuntimeError('Tool unavailable')


if __name__ == '__main__':
    unittest.main()
