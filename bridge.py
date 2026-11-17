#!/usr/bin/env python3
"""One-shot JSON bridge between the bar and the shared tracker database.

Local mode (default): run the request against this machine's database.

Remote mode: when ~/.config/omarchy/time-tracker/remote.json names an SSH
target, the request is sent to the bridge on that "home" machine instead, so
several machines share one timer and one history. The request travels on
stdin, never in a command line, and the home side runs it with --serve, which
accepts fewer commands than the local bar (nothing that writes files there).
"""
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tracker

MAX_REQUEST = 16384
MAX_RESPONSE = 4 * 1024 * 1024
LOCAL_COMMANDS = {'add-company', 'companies', 'add-project', 'projects', 'select', 'start', 'stop', 'status', 'report',
                  'records', 'timezone', 'vault', 'auto-obsidian', 'retry-obsidian', 'delete-record', 'clear-records', 'clockify-sync'}
# Over SSH: no settings or vault changes, and no files written on the home machine.
REMOTE_COMMANDS = {'add-company', 'companies', 'add-project', 'projects', 'select', 'start', 'stop', 'status', 'report',
                   'records', 'delete-record', 'clear-records', 'clockify-sync'}
REMOTE_FORBIDDEN_FLAGS = {'--pdf', '--obsidian', '--output'}
TARGET_RE = re.compile(r'^(?:[A-Za-z0-9._-]+@)?[A-Za-z0-9][A-Za-z0-9.-]*$')
REMOTE_BRIDGE_RE = re.compile(r'^[A-Za-z0-9._/~-]+/bridge\.py$')
DEFAULT_REMOTE_BRIDGE = '~/.config/omarchy/plugins/peter.time-tracker/bridge.py'
SSH_TIMEOUT = 30


def remote_config_path():
    base = os.environ.get('XDG_CONFIG_HOME') or str(Path.home() / '.config')
    return Path(base) / 'omarchy' / 'time-tracker' / 'remote.json'


def load_remote(path=None):
    """The configured home machine, or None for local mode.

    The file must be a regular file owned by you and not writable by others,
    since it decides where your timer requests go."""
    path = Path(path or remote_config_path())
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o022:
            raise ValueError('remote.json must be a regular file owned by you and not writable by others.')
        raw = os.read(fd, 4097)
    finally:
        os.close(fd)
    if len(raw) > 4096:
        raise ValueError('remote.json is too large.')
    try:
        config = json.loads(raw)
    except ValueError:
        raise ValueError('remote.json is not valid JSON.')
    if not isinstance(config, dict) or set(config) - {'host', 'bridge'}:
        raise ValueError('remote.json may contain only "host" and "bridge".')
    host = config.get('host')
    if not isinstance(host, str) or not TARGET_RE.match(host):
        raise ValueError('remote.json "host" must look like user@machine.')
    remote_bridge = config.get('bridge', DEFAULT_REMOTE_BRIDGE)
    if not isinstance(remote_bridge, str) or not REMOTE_BRIDGE_RE.match(remote_bridge) or '..' in remote_bridge:
        raise ValueError('remote.json "bridge" must be a plain path ending in /bridge.py.')
    return dict(host=host, bridge=remote_bridge)


def ssh_command(remote):
    control = str(Path.home() / '.ssh' / 'time-tracker-%C')
    return ['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
            '-o', 'ControlMaster=auto', '-o', 'ControlPath=' + control, '-o', 'ControlPersist=10m',
            '--', remote['host'], '/usr/bin/python3 -E -s -B ' + remote['bridge'] + ' --serve']


def forward(remote, raw):
    """Send one request to the home machine and return its JSON reply as text."""
    try:
        done = subprocess.run(ssh_command(remote), input=raw.encode('utf-8'), capture_output=True,
                              timeout=SSH_TIMEOUT, check=False)
    except subprocess.TimeoutExpired:
        raise ValueError(f"No reply from {remote['host']} within {SSH_TIMEOUT}s.")
    except OSError as exc:
        raise ValueError(f'Cannot run ssh: {exc.strerror}')
    out = done.stdout[:MAX_RESPONSE + 1]
    if len(out) > MAX_RESPONSE:
        raise ValueError('Reply from the home machine is too large.')
    try:
        reply = json.loads(out.decode('utf-8'))
    except ValueError:
        detail = done.stderr.decode('utf-8', 'replace').strip().splitlines()[-1:] or ['no output']
        raise ValueError(f"Cannot reach the tracker on {remote['host']}: {detail[0][:200]}")
    if not isinstance(reply, dict) or not isinstance(reply.get('ok'), bool):
        raise ValueError('Unexpected reply from the home machine.')
    return json.dumps(reply)


def parse_request(raw, remote=False):
    if len(raw.encode('utf-8')) > MAX_REQUEST:
        raise ValueError('Request exceeds 16 KiB.')
    request = json.loads(raw)
    if not isinstance(request, dict) or set(request) - {'args'}:
        raise ValueError('Expected a JSON object containing only args.')
    args = request.get('args', [])
    if not isinstance(args, list) or len(args) > 20 or any(not isinstance(a, str) or len(a) > 4096 for a in args):
        raise ValueError('Expected at most 20 string arguments, each at most 4096 characters.')
    allowed = REMOTE_COMMANDS if remote else LOCAL_COMMANDS
    if args and (args[0] not in allowed or any(a in ('-h', '--help', '--db') or a.startswith('--db=') for a in args)):
        if remote and args[0] in LOCAL_COMMANDS:
            raise ValueError('That action is only available on the home machine.')
        raise ValueError('Unsupported bar request.')
    if remote and any(a.split('=', 1)[0] in REMOTE_FORBIDDEN_FLAGS for a in args):
        raise ValueError('PDF and Obsidian exports are only available on the home machine.')
    return tracker.parser().parse_args(args) if args else None


def run_local(raw, remote=False):
    db = None
    try:
        args = parse_request(raw, remote=remote)
        db = tracker.connect(tracker.os.environ.get('TIME_TRACKER_DB', str(tracker.DEFAULT_DB)))
        db.execute('BEGIN IMMEDIATE')
        result = None
        if args:
            result = tracker.execute(db, args)
        status = tracker.execute(db, tracker.parser().parse_args(['status']))
        companies = [dict(r) for r in db.execute('SELECT * FROM companies ORDER BY name')]
        projects = [dict(r) for r in db.execute('SELECT * FROM projects ORDER BY name')]
        db.commit()
        print(json.dumps(dict(ok=True, result=result, status=status, companies=companies, projects=projects)))
    except Exception as exc:
        if db:
            db.rollback()
        print(json.dumps(dict(ok=False, error=str(exc))))
        return 1
    finally:
        if db:
            db.close()
    return 0


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    # Home side of remote mode: the request arrives on stdin over SSH. Never
    # forwarded again, whatever this machine's own remote.json says.
    if argv == ['--serve']:
        raw = sys.stdin.read(MAX_REQUEST + 1)
        if len(raw) > MAX_REQUEST:
            print(json.dumps(dict(ok=False, error='Request exceeds 16 KiB.')))
            return 1
        return run_local(raw, remote=True)
    if len(argv) != 1:
        print(json.dumps(dict(ok=False, error='Expected one JSON request.')))
        return 1
    try:
        remote = load_remote()
        if remote:
            parse_request(argv[0], remote=True)  # refuse early, without a round trip
            print(forward(remote, argv[0]))
            return 0
    except Exception as exc:
        print(json.dumps(dict(ok=False, error=str(exc))))
        return 1
    return run_local(argv[0])


if __name__ == '__main__':
    sys.exit(main())
