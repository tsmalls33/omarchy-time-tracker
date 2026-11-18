import importlib.util
from pathlib import Path
import tempfile
import unittest
from datetime import datetime

spec = importlib.util.spec_from_file_location('tracker', Path(__file__).resolve().parents[1] / 'tracker.py')
t = importlib.util.module_from_spec(spec)
spec.loader.exec_module(t)


class TrackerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / 'tracker.db'
        self.db = t.connect(self.path)
        self.run_cmd('timezone', 'America/Curacao')
        self.run_cmd('add-company', 'Acme')
        self.run_cmd('add-company', 'Other')
        self.run_cmd('add-project', 'Website', '--company', 'Acme')
        self.run_cmd('select', '--company', 'Acme', '--project', 'Website')

    def tearDown(self):
        self.db.close()
        self.tmp.cleanup()

    def run_cmd(self, *args, now=1800000000):
        return t.execute(self.db, t.parser().parse_args(list(args)), now)

    def test_persistence_selection_and_no_overlap(self):
        self.run_cmd('start', now=100)
        self.db.close()
        self.db = t.connect(self.path)
        self.assertEqual(self.run_cmd('status', now=160)['running']['seconds'], 60)
        with self.assertRaises(ValueError):
            self.run_cmd('start', now=160)
        self.run_cmd('select', '--company', 'Other')
        stopped = self.run_cmd('stop', now=3700)
        self.assertEqual((stopped['company'], stopped['project'], stopped['seconds']), ('Acme', 'Website', 3600))
        self.assertEqual(self.run_cmd('start', now=3800)['company'], 'Other')

    def test_midnight_and_company_project_filters(self):
        start = datetime.fromisoformat('2026-09-06T23:30:00-04:00').timestamp()
        self.run_cmd('start', now=start)
        self.run_cmd('stop', now=start + 7200)
        result = self.run_cmd('report', 'monthly', '--date', '2026-09-07')
        self.assertEqual([r['seconds'] for r in result['daily']], [1800, 5400])
        self.assertEqual(result['total_hours'], 2)
        week = self.run_cmd('report', 'weekly', '--date', '2026-09-07', '--company', 'Acme', '--project', 'Website')
        self.assertEqual(week['total_hours'], 1.5)
        self.assertEqual(self.run_cmd('report', 'yearly', '--date', '2026-09-07', '--company', 'Other')['total_hours'], 0)

    def test_running_report_clipped_at_year_boundary(self):
        start = datetime.fromisoformat('2025-12-31T23:00:00-04:00').timestamp()
        self.run_cmd('start', now=start)
        result = self.run_cmd('report', 'yearly', '--date', '2026-01-01', now=start+7200)
        self.assertEqual(result['total_hours'], 1)
        self.assertTrue(result['includes_running_timer'])

    def test_dst_actual_elapsed_time(self):
        self.run_cmd('timezone', 'America/New_York')
        for beginning, finish, expected in [
            ('2026-03-08T00:00:00-05:00', '2026-03-09T00:00:00-04:00', 23),
            ('2026-11-01T00:00:00-04:00', '2026-11-02T00:00:00-05:00', 25),
        ]:
            start = datetime.fromisoformat(beginning).timestamp()
            end = datetime.fromisoformat(finish).timestamp()
            self.run_cmd('start', now=start)
            self.run_cmd('stop', now=end)
            result = self.run_cmd('report', 'daily', '--date', beginning[:10], now=end)
            self.assertEqual(result['total_hours'], expected)

    def test_general_time_and_invalid_project(self):
        self.assertIsNone(self.run_cmd('start', '--no-project', now=100)['project'])
        self.run_cmd('stop', now=200)
        with self.assertRaises(ValueError):
            self.run_cmd('start', '--company', 'Other', '--project', 'Website')
        self.assertIsNone(self.run_cmd('status')['running'])

    def test_calendar_bounds(self):
        a, b = t.period_bounds('monthly', t.date(2024, 2, 29))
        self.assertEqual((b-a).days, 29)
        self.assertEqual(t.period_bounds('monthly', t.date(2026, 12, 7))[1], t.date(2027, 1, 1))


    def test_start_at_custom_time(self):
        tz = t.ZoneInfo('America/Curacao')
        now = datetime(2026, 11, 18, 17, 30, tzinfo=tz).timestamp()
        at = lambda h, m: datetime(2026, 11, 18, h, m, tzinfo=tz).timestamp()
        for text, (h, m) in {'1600': (16, 0), '16:00': (16, 0), '0900': (9, 0), '900': (9, 0), '4pm': (16, 0),
                             '9am': (9, 0), '9:30am': (9, 30), '12am': (0, 0), '12pm': (12, 0), '0000': (0, 0), ' 4 PM ': (16, 0)}.items():
            self.assertEqual(t.parse_start_at(text, now, tz), at(h, m), text)
        for bad in ('2400', '1260', '16', '13pm', '0am', 'abc', '', '16000', '1800'):
            with self.assertRaises(ValueError, msg=bad):
                t.parse_start_at(bad, now, tz)
        started = self.run_cmd('start', '--at', '1600', now=now)
        self.assertEqual(started['seconds'], 5400)
        self.run_cmd('stop', now=now + 60)
        with self.assertRaises(ValueError):   # overlaps the session just stopped
            self.run_cmd('start', '--at', '1700', now=now + 120)
        self.assertEqual(self.run_cmd('start', now=now + 120)['seconds'], 0)

    def test_edit_record(self):
        tz = t.ZoneInfo('America/Curacao')
        at = lambda d, h, m: datetime(2026, 11, d, h, m, tzinfo=tz).timestamp()
        now = at(18, 20, 0)
        first = self.run_cmd('start', '--at', '0900', now=at(18, 12, 0))['id']
        self.run_cmd('stop', now=at(18, 10, 0))
        second = self.run_cmd('start', '--at', '1300', now=at(18, 14, 0))['id']
        self.run_cmd('stop', now=at(18, 15, 0))
        edited = self.run_cmd('edit-record', str(first), '--start', '0830', '--end', '11am', now=now)['edited']
        self.assertEqual(edited['seconds'], 9000)
        self.assertEqual(edited['start'][:16], '2026-11-18T08:30')
        moved = self.run_cmd('edit-record', str(first), '--start', '2026-11-17 22:00', '--end', '2026-11-17 23:30', now=now)
        self.assertEqual(moved['edited']['start'][:10], '2026-11-17')
        self.assertFalse(moved['clockify_updated'])
        for bad in (['--start', '2026-11-18 12:00', '--end', '1400'],  # overlaps the 13:00 session
                    ['--start', '2026-11-17 23:45'],           # after its end
                    ['--end', '2026-11-19 09:00'],             # in the future
                    ['--start', '2026-02-30 09:00'],           # not a date
                    ['--start', 'soon']):
            with self.assertRaises(ValueError, msg=bad):
                self.run_cmd('edit-record', str(first), *bad, now=now)
        with self.assertRaises(ValueError):
            self.run_cmd('edit-record', '999', '--start', '0900', now=now)

    def test_edit_record_updates_linked_clockify_entry(self):
        import clockify_sync
        tz = t.ZoneInfo('America/Curacao')
        at = lambda h, m: datetime(2026, 11, 18, h, m, tzinfo=tz).timestamp()
        rid = self.run_cmd('start', '--at', '0900', now=at(10, 0))['id']
        self.run_cmd('stop', now=at(10, 0))
        self.db.execute("UPDATE sessions SET clockify_id='6afca1051841a5734b5d6b90' WHERE id=?", (rid,))
        calls = []
        original = clockify_sync.run_cli
        clockify_sync.run_cli = lambda *argv, quiet_id=False: calls.append(argv) or '6afca1051841a5734b5d6b90'
        try:
            result = self.run_cmd('edit-record', str(rid), '--end', '1030', now=at(12, 0))
        finally:
            clockify_sync.run_cli = original
        self.assertTrue(result['clockify_updated'])
        self.assertEqual(calls[0][:2], ('edit', '6afca1051841a5734b5d6b90'))
        self.assertTrue(calls[0][3].startswith('--when-to-close='))

if __name__ == '__main__':
    unittest.main()
