import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bridge


def write_config(folder, data, mode=0o600):
    path = Path(folder) / 'remote.json'
    path.write_text(json.dumps(data) if not isinstance(data, str) else data)
    path.chmod(mode)
    return path


class RemoteConfigTests(unittest.TestCase):
    def test_missing_config_means_local(self):
        with tempfile.TemporaryDirectory() as folder:
            self.assertIsNone(bridge.load_remote(Path(folder) / 'remote.json'))

    def test_valid_config(self):
        with tempfile.TemporaryDirectory() as folder:
            path = write_config(folder, {'host': 'me@home-box'})
            self.assertEqual(bridge.load_remote(path), {'host': 'me@home-box', 'bridge': bridge.DEFAULT_REMOTE_BRIDGE})

    def test_rejects_option_shaped_or_odd_hosts(self):
        for host in ('-oProxyCommand=evil', 'me@-oFoo', 'me@home box', 'me@home;id', '', 'a@b@c', 'me@$(id)'):
            with tempfile.TemporaryDirectory() as folder, self.subTest(host=host):
                with self.assertRaises(ValueError):
                    bridge.load_remote(write_config(folder, {'host': host}))

    def test_rejects_odd_bridge_paths(self):
        for path in ('~/x/bridge.py; id', '~/x/bridge.sh', '~/../../tmp/bridge.py', '$HOME/bridge.py', 'bridge.py --db=/x'):
            with tempfile.TemporaryDirectory() as folder, self.subTest(path=path):
                with self.assertRaises(ValueError):
                    bridge.load_remote(write_config(folder, {'host': 'me@home', 'bridge': path}))

    def test_rejects_unknown_keys_and_unsafe_files(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(ValueError):
                bridge.load_remote(write_config(folder, {'host': 'me@home', 'command': 'x'}))
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(ValueError):
                bridge.load_remote(write_config(folder, {'host': 'me@home'}, mode=0o666))
        with tempfile.TemporaryDirectory() as folder:
            real = write_config(folder, {'host': 'me@home'})
            link = Path(folder) / 'link.json'
            link.symlink_to(real)
            with self.assertRaises(OSError):
                bridge.load_remote(link)


class RemoteRequestTests(unittest.TestCase):
    def test_remote_allowlist(self):
        self.assertIsNotNone(bridge.parse_request(json.dumps({'args': ['stop']}), remote=True))
        for args in (['vault', '/tmp'], ['timezone', 'UTC'], ['auto-obsidian', 'on'], ['retry-obsidian'],
                     ['report', 'daily', '--pdf'], ['report', 'daily', '--pdf', '--output=/tmp/x.pdf'],
                     ['report', 'daily', '--obsidian'], ['status', '--db', '/tmp/x'], ['status', '--db=/tmp/x']):
            with self.subTest(args=args), self.assertRaises(ValueError):
                bridge.parse_request(json.dumps({'args': args}), remote=True)

    def test_local_still_allows_home_only_actions(self):
        self.assertIsNotNone(bridge.parse_request(json.dumps({'args': ['timezone', 'UTC']})))

    def test_ssh_command_keeps_request_off_the_command_line(self):
        cmd = bridge.ssh_command({'host': 'me@home', 'bridge': bridge.DEFAULT_REMOTE_BRIDGE})
        self.assertEqual(cmd[0], 'ssh')
        self.assertIn('BatchMode=yes', cmd)
        self.assertEqual(cmd[-3:-1], ['--', 'me@home'])
        self.assertTrue(cmd[-1].endswith('bridge.py --serve'))

    def test_forward_sends_request_on_stdin(self):
        reply = {'ok': True, 'result': None, 'status': {}, 'companies': [], 'projects': []}
        done = subprocess.CompletedProcess([], 0, json.dumps(reply).encode(), b'')
        raw = json.dumps({'args': ['start', '--note', "x'; rm -rf ~ #"]})
        with mock.patch('subprocess.run', return_value=done) as run:
            self.assertEqual(json.loads(bridge.forward({'host': 'me@home', 'bridge': 'b/bridge.py'}, raw)), reply)
        self.assertEqual(run.call_args.kwargs['input'], raw.encode())
        self.assertNotIn('rm -rf', ' '.join(run.call_args.args[0]))

    def test_forward_reports_unreachable_host(self):
        done = subprocess.CompletedProcess([], 255, b'', b'ssh: connect to host home port 22: No route to host\n')
        with mock.patch('subprocess.run', return_value=done):
            with self.assertRaisesRegex(ValueError, 'No route to host'):
                bridge.forward({'host': 'me@home', 'bridge': 'b/bridge.py'}, '{}')

    def test_forward_rejects_non_reply_json(self):
        for out in (b'[]', b'{"result": 1}', b'x' * (bridge.MAX_RESPONSE + 2)):
            done = subprocess.CompletedProcess([], 0, out, b'')
            with self.subTest(out=out[:20]), mock.patch('subprocess.run', return_value=done):
                with self.assertRaises(ValueError):
                    bridge.forward({'host': 'me@home', 'bridge': 'b/bridge.py'}, '{}')


class ServeTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.env = mock.patch.dict(os.environ, {'TIME_TRACKER_DB': str(Path(self.folder.name) / 'db' / 't.db'),
                                                'XDG_CONFIG_HOME': self.folder.name})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.folder.cleanup()

    def serve(self, request):
        out = io.StringIO()
        with mock.patch('sys.stdin', io.StringIO(json.dumps(request))), redirect_stdout(out):
            code = bridge.main(['--serve'])
        return code, json.loads(out.getvalue())

    def test_serve_runs_locally_and_never_forwards(self):
        # Even with its own remote.json, the home side must not forward again.
        conf = Path(self.folder.name) / 'omarchy' / 'time-tracker'
        conf.mkdir(parents=True)
        write_config(conf, {'host': 'me@elsewhere'})
        with mock.patch('subprocess.run') as run:
            code, reply = self.serve({'args': ['add-company', 'Acme']})
        run.assert_not_called()
        self.assertEqual(code, 0)
        self.assertEqual([c['name'] for c in reply['companies']], ['Acme'])

    def test_serve_refuses_home_only_actions(self):
        code, reply = self.serve({'args': ['vault', self.folder.name]})
        self.assertEqual(code, 1)
        self.assertIn('home machine', reply['error'])

    def test_serve_bounds_stdin(self):
        out = io.StringIO()
        with mock.patch('sys.stdin', io.StringIO('x' * (bridge.MAX_REQUEST + 10))), redirect_stdout(out):
            self.assertEqual(bridge.main(['--serve']), 1)

    def test_client_forwards_when_configured(self):
        conf = Path(self.folder.name) / 'omarchy' / 'time-tracker'
        conf.mkdir(parents=True)
        write_config(conf, {'host': 'me@home'})
        reply = {'ok': True, 'result': None, 'status': {}, 'companies': [], 'projects': []}
        out = io.StringIO()
        with mock.patch('bridge.forward', return_value=json.dumps(reply)) as fwd, redirect_stdout(out):
            self.assertEqual(bridge.main([json.dumps({'args': ['status']})]), 0)
        fwd.assert_called_once()
        self.assertFalse((Path(self.folder.name) / 'db').exists())  # no local database touched

    def test_client_refuses_home_only_action_before_connecting(self):
        conf = Path(self.folder.name) / 'omarchy' / 'time-tracker'
        conf.mkdir(parents=True)
        write_config(conf, {'host': 'me@home'})
        out = io.StringIO()
        with mock.patch('bridge.forward') as fwd, redirect_stdout(out):
            self.assertEqual(bridge.main([json.dumps({'args': ['vault', '/tmp']})]), 1)
        fwd.assert_not_called()


if __name__ == '__main__':
    unittest.main()
