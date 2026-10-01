"""Regression checks for GitLab Performance Tool result handling; fixtures use upstream string metrics."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from report import render, render_resources

class ReportTests(unittest.TestCase):
    def test_failure_missing_metrics_and_exclusion_of_duplicate_failure_reports(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            data = {'version':'19.4.0', 'gpt_version':'2.17.0', 'option':'60s_40rps', 'overall_result':False, 'overall_result_score':50,
                    'test_results':[{'name':'api_example', 'result':True, 'ttfb_p90':'123.45', 'ttfb_p90_threshold':'500', 'rps_result':'40.0', 'rps_threshold':'32.0', 'success_rate':'100.00', 'success_rate_threshold':'99'}, {'result':False}]}
            (root/'run_results.json').write_text(json.dumps(data))
            (root/'failed_test_results').mkdir()
            (root/'failed_test_results'/'duplicate_results.json').write_text(json.dumps(data))
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertFalse(render(root,root/'charts'))
            summaries=json.loads((root/'charts'/'summary.json').read_text())
            self.assertEqual(len(summaries),1)
            self.assertEqual(summaries[0]['failed_tests'],['unidentified_test_2'])
            self.assertEqual(summaries[0]['passed'],1)
            for ext in ('png','svg'):
                self.assertTrue((root/'charts'/f'run_results-01.{ext}').stat().st_size > 100)

    def test_no_report_is_not_a_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError,'No GitLab Performance Tool aggregate'):
                render(Path(tmp),Path(tmp)/'charts')

    def test_missing_full_suite_result_cannot_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root/'run_results.json').write_text(json.dumps({
                'overall_result': True, 'test_results': [{'name': 'completed', 'result': True}]}))
            (root/'suite-coverage.json').write_text(json.dumps([
                {'name': 'completed', 'status': 'passed'},
                {'name': 'lost_result', 'status': 'not_reported'},
                {'name': 'licensed_feature', 'status': 'blocked', 'reason': 'Missing license'}]))
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertFalse(render(root, root/'charts'))
            report = (root/'charts/summary.md').read_text()
            self.assertIn('Inventory: **3**', report)
            self.assertIn('missing results: **1**', report)
            self.assertIn('Missing license', report)

    def test_generator_resource_units_and_throttling(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            samples = [
                {'time':'2026-01-01T00:00:00Z','phase':'benchmark','cpu':'usage_usec 0\nnr_periods 0\nnr_throttled 0','cpu_limit':'300000 100000','memory_bytes':str(1024**3),'memory_limit_bytes':str(12*1024**3)},
                {'time':'2026-01-01T00:00:10Z','phase':'benchmark','cpu':'usage_usec 5000000\nnr_periods 100\nnr_throttled 10','cpu_limit':'300000 100000','memory_bytes':str(2*1024**3),'memory_limit_bytes':str(12*1024**3)}]
            (root/'generator-resources.jsonl').write_text('\n'.join(map(json.dumps,samples)))
            render_resources(root,root)
            data=json.loads((root/'generator-resources.json').read_text())
            self.assertEqual(data['max_sampled_cpu_cores'],.5)
            self.assertEqual(data['max_sampled_memory_gib'],2)
            self.assertEqual(data['throttled_period_percent'],10)

if __name__ == '__main__':
    unittest.main()
