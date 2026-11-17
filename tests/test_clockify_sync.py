from datetime import date
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import tracker
import clockify_sync


def entry(eid, start, end, client='Acme', project='Site', description='Work'):
    return {'id': eid, 'description': description, 'timeInterval': {'start': start, 'end': end},
            'project': {'name': project, 'clientName': client}}


A = 'a' * 24
B = 'b' * 24
C = 'c' * 24


class ClockifySyncTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.db = tracker.connect(Path(self.folder.name) / 't.db')

    def tearDown(self):
        self.db.close()
        self.folder.cleanup()

    def run_sync(self, entries, since=None, today=date(2026, 11, 17), clients=(), projects=(), **kw):
        calls = []

        def fetcher(a, b):
            calls.append((a, b))
            return entries
        result = clockify_sync.sync(self.db, tracker.setting, since=since, today=today, fetcher=fetcher,
                                    catalog=lambda: (list(clients), list(projects)), **kw)
        return result, calls

    def sessions(self):
        return self.db.execute('''SELECT s.clockify_id, c.name, p.name, s.start, s.end, s.note FROM sessions s
            JOIN companies c ON c.id=s.company_id LEFT JOIN projects p ON p.id=s.project_id ORDER BY s.start''').fetchall()

    def test_first_sync_reads_everything_and_maps_client_to_company(self):
        result, calls = self.run_sync([entry(A, '2026-11-10T09:00:00Z', '2026-11-10T10:30:00Z')])
        self.assertEqual(calls, [(clockify_sync.FIRST_SYNC, '2026-11-17')])
        self.assertEqual(result['added'], 1)
        row = self.sessions()[0]
        self.assertEqual(tuple(row[:3]), (A, 'Acme', 'Site'))
        self.assertEqual(row[4] - row[3], 5400)
        self.assertEqual(tracker.setting(self.db, 'clockify_synced_through'), '2026-11-17')

    def test_resync_is_idempotent_and_incremental(self):
        data = [entry(A, '2026-11-10T09:00:00Z', '2026-11-10T10:00:00Z')]
        self.run_sync(data)
        result, calls = self.run_sync(data, today=date(2026, 11, 20))
        self.assertEqual(calls, [('2026-11-10', '2026-11-20')])  # 7 days before the last sync
        self.assertEqual((result['added'], result['updated'], result['unchanged']), (0, 0, 1))
        self.assertEqual(len(self.sessions()), 1)

    def test_edits_in_clockify_update_local_copy(self):
        self.run_sync([entry(A, '2026-11-10T09:00:00Z', '2026-11-10T10:00:00Z')])
        result, _ = self.run_sync([entry(A, '2026-11-10T09:00:00Z', '2026-11-10T11:00:00Z', project='Other', description='Fixed')])
        self.assertEqual(result['updated'], 1)
        row = self.sessions()[0]
        self.assertEqual((row[2], row[5], row[4] - row[3]), ('Other', 'Fixed', 7200))

    def test_deleted_in_clockify_is_removed_within_window_only(self):
        self.run_sync([entry(A, '2026-11-10T09:00:00Z', '2026-11-10T10:00:00Z'),
                       entry(B, '2026-01-05T09:00:00Z', '2026-01-05T10:00:00Z')])
        result, _ = self.run_sync([], since='2026-11-01')
        self.assertEqual(result['removed'], 1)
        self.assertEqual([r[0] for r in self.sessions()], [B])  # older than the window: kept

    def test_local_sessions_are_never_touched(self):
        acme = self.db.execute("INSERT INTO companies(name) VALUES ('Acme')").lastrowid
        self.db.execute('INSERT INTO sessions(company_id,start,end,note) VALUES (?,?,?,?)', (acme, 1.79e9, 1.79e9 + 60, 'mine'))
        result, _ = self.run_sync([], since='2020-01-01')
        self.assertEqual(result['removed'], 0)
        self.assertEqual(len(self.sessions()), 1)

    def test_running_and_invalid_entries_are_skipped(self):
        result, _ = self.run_sync([entry(A, '2026-11-17T09:00:00Z', None), entry('not-an-id', '2026-11-17T09:00:00Z', '2026-11-17T10:00:00Z'),
                                   entry(B, '2026-11-17T10:00:00Z', '2026-11-17T09:00:00Z'), 'junk'])
        self.assertEqual((result['added'], result['skipped_running'], result['skipped_invalid']), (0, 1, 3))
        self.assertIsNone(tracker.active(self.db))

    def test_running_entry_is_not_deleted_as_missing(self):
        self.run_sync([entry(A, '2026-11-10T09:00:00Z', '2026-11-10T10:00:00Z')])
        result, _ = self.run_sync([entry(A, '2026-11-10T09:00:00Z', None)])  # reopened? still "seen"
        self.assertEqual(result['removed'], 0)

    def test_no_client_and_hostile_text_are_cleaned(self):
        evil = 'x‮<img src=https://example.invalid/t>\n\x00' + 'y' * 5000
        self.run_sync([entry(C, '2026-11-10T09:00:00Z', '2026-11-10T10:00:00Z', client='', project=evil, description=evil)])
        row = self.sessions()[0]
        self.assertEqual(row[1], clockify_sync.NO_CLIENT)
        for text in (row[2], row[5]):
            self.assertNotIn('‮', text)
            self.assertNotIn('\x00', text)
            self.assertNotIn('\n', text)
        self.assertLessEqual(len(row[2]), 200)
        self.assertLessEqual(len(row[5]), 2000)

    def test_clients_and_projects_arrive_without_entries(self):
        result, _ = self.run_sync([], clients=[{'name': 'Newco'}, {'name': 'Gone', 'archived': True}, 'junk'],
                                  projects=[{'name': 'Kickoff', 'clientName': 'Newco'}, {'name': 'Solo', 'clientName': ''},
                                            {'name': 'Old', 'clientName': 'Newco', 'archived': True}])
        names = {r[0] for r in self.db.execute('SELECT name FROM companies')}
        self.assertEqual(names, {'Newco', clockify_sync.NO_CLIENT})
        projects = {(r[0], r[1]) for r in self.db.execute(
            'SELECT c.name, p.name FROM projects p JOIN companies c ON c.id=p.company_id')}
        self.assertEqual(projects, {('Newco', 'Kickoff'), (clockify_sync.NO_CLIENT, 'Solo')})
        self.assertEqual((result['new_companies'], result['new_projects']), (1, 2))
        again, _ = self.run_sync([], clients=[{'name': 'newco'}], projects=[{'name': 'kickoff', 'clientName': 'Newco'}])
        self.assertEqual((again['new_companies'], again['new_projects']), (0, 0))

    def test_dry_run_does_not_record_sync(self):
        self.run_sync([], dry_run=True)
        self.assertIsNone(tracker.setting(self.db, 'clockify_synced_through'))


class FetchTests(unittest.TestCase):
    def fetch_with(self, code, out=b'[]', err=b''):
        done = subprocess.CompletedProcess([], code, out, err)
        with mock.patch('shutil.which', return_value='/usr/bin/clockify-cli'), \
                mock.patch('subprocess.run', return_value=done) as run:
            return clockify_sync.fetch('2026-11-01', '2026-11-17'), run

    def test_calls_cli_non_interactively_with_argv(self):
        result, run = self.fetch_with(0, b'[]')
        self.assertEqual(result, [])
        self.assertEqual(run.call_args.args[0],
                         ['/usr/bin/clockify-cli', '--interactive=0', 'report', '2026-11-01', '2026-11-17', '--json'])

    def test_rate_limit_message(self):
        with self.assertRaisesRegex(ValueError, 'rate limit'):
            self.fetch_with(1, b'', b'get time entries: Too many requests! (code: 429)')

    def test_rejects_non_list_output(self):
        for out in (b'{}', b'not json'):
            with self.subTest(out=out), self.assertRaises(ValueError):
                self.fetch_with(0, out)

    def test_catalog_calls_client_and_project_lists(self):
        done = subprocess.CompletedProcess([], 0, b'[]', b'')
        with mock.patch('shutil.which', return_value='/usr/bin/clockify-cli'), \
                mock.patch('subprocess.run', return_value=done) as run:
            self.assertEqual(clockify_sync.fetch_catalog(), ([], []))
        self.assertEqual([c.args[0][2:] for c in run.call_args_list], [['client', 'list', '--json'], ['project', 'list', '--json']])

    def test_missing_cli(self):
        with mock.patch('shutil.which', return_value=None), self.assertRaisesRegex(ValueError, 'not installed'):
            clockify_sync.fetch('2026-11-01', '2026-11-17')


class SchemaTests(unittest.TestCase):
    def test_existing_database_gains_column(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'old.db'
            tracker.connect(path).close()
            db = tracker.connect(path)  # second open: migration must be idempotent
            cols = {r[1] for r in db.execute('PRAGMA table_info(sessions)')}
            db.close()
            self.assertIn('clockify_id', cols)


if __name__ == '__main__':
    unittest.main()
