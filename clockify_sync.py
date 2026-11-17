"""Two-way sync between the tracker and Clockify, run only when asked.

Pull: completed Clockify time entries come into the tracker database.
Push: finished sessions tracked here (from a chosen start date on) are created
in Clockify, together with any client or project Clockify does not have yet.

Clockify stays the system of record for whatever is tracked there (another
machine, the phone app); this copies those entries in on demand so reports
cover everything. A sync makes three clockify-cli calls: `client list`,
`project list` (so new clients and projects arrive even before any time is
logged against them) and `report <since> today` for the entries (the CLI
pages through those itself). The CLI holds the API key; this module never
sees it.

Mapping: Clockify client -> company, project -> project, description -> note.
Entries are matched on their Clockify id: edits in Clockify update the local
copy, and entries deleted in Clockify are removed, within the synced window.
A running Clockify timer is skipped until it stops.

A pushed session stores the id Clockify gives it, so from then on it is an
ordinary synced entry and is never sent twice. A session that overlaps time
Clockify already has is not sent, so an hour is never counted twice. Each
push is one request (Free plan: 30 an hour), so a sync sends at most
PUSH_LIMIT sessions and reports how many are still waiting.
"""
from datetime import datetime, timedelta, timezone, date
import json
import re
import shutil
import subprocess
import unicodedata

CLI_TIMEOUT = 50          # stays under the bar bridge's 60 s watchdog
MAX_OUTPUT = 32 * 1024 * 1024
LOOKBACK_DAYS = 7         # later syncs re-read this far before the last one, to catch edits
FIRST_SYNC = '2020-01-01'
NO_CLIENT = 'Clockify (no client)'
PUSH_LIMIT = 15
ID_RE = re.compile(r'^[0-9a-f]{24}$')
BIDI = set('‪‫‬‭‮⁦⁧⁨⁩')


def clean(value, limit):
    """Clockify text made safe for the tracker's own rules: no control or
    bidirectional override characters, bounded length."""
    if not isinstance(value, str):
        return ''
    text = ''.join(' ' if unicodedata.category(c) in ('Cc', 'Cs') or c in BIDI else c for c in value)
    return ' '.join(text.split())[:limit]


def parse_time(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    except ValueError:
        return None
    return parsed.timestamp() if parsed.tzinfo else None


def fetch(since, until):
    return run_cli('report', since, until)


def fetch_catalog():
    """All clients and (unarchived) projects in the workspace."""
    return run_cli('client', 'list'), run_cli('project', 'list')


def run_cli(*argv, quiet_id=False):
    """Run clockify-cli with argv (never a shell). Returns its JSON list, or with
    quiet_id the single Clockify id it printed (for the `add`/`manual` calls)."""
    cli = shutil.which('clockify-cli')
    if not cli:
        raise ValueError('clockify-cli is not installed (AUR: clockify-cli).')
    try:
        done = subprocess.run([cli, '--interactive=0', *argv, '--quiet' if quiet_id else '--json'],
                              capture_output=True, timeout=CLI_TIMEOUT, check=False)
    except subprocess.TimeoutExpired:
        raise ValueError(f'clockify-cli did not finish within {CLI_TIMEOUT}s.')
    if done.returncode != 0:
        message = done.stderr.decode('utf-8', 'replace').strip() or done.stdout.decode('utf-8', 'replace').strip()
        first = message.splitlines()[0] if message else f'exit {done.returncode}'
        if '429' in message or 'Too many requests' in message:
            raise ValueError('Clockify rate limit reached (Free plan: 30 requests per hour). Try again later.')
        raise ValueError('clockify-cli: ' + clean(first, 200))
    if len(done.stdout) > MAX_OUTPUT:
        raise ValueError('clockify-cli returned too much data.')
    if quiet_id:
        new_id = done.stdout.decode('utf-8', 'replace').strip()
        if not ID_RE.match(new_id):
            raise ValueError('clockify-cli did not return a Clockify id.')
        return new_id
    try:
        items = json.loads(done.stdout or b'[]')
    except ValueError:
        raise ValueError('clockify-cli did not return JSON.')
    if not isinstance(items, list):
        raise ValueError('clockify-cli returned an unexpected shape.')
    return items


def company_id(db, name, cache):
    key = name.casefold()
    if key not in cache:
        row = db.execute('SELECT id FROM companies WHERE name=? COLLATE NOCASE', (name,)).fetchone()
        cache[key] = row[0] if row else db.execute('INSERT INTO companies(name) VALUES (?)', (name,)).lastrowid
    return cache[key]


def project_id(db, cid, name, cache):
    if not name:
        return None
    key = (cid, name.casefold())
    if key not in cache:
        row = db.execute('SELECT id FROM projects WHERE company_id=? AND name=? COLLATE NOCASE', (cid, name)).fetchone()
        cache[key] = row[0] if row else db.execute('INSERT INTO projects(company_id,name) VALUES (?,?)', (cid, name)).lastrowid
    return cache[key]


def import_catalog(db, clients, projects, companies, project_cache, stats):
    """Create any Clockify client (as a company) or project not here yet."""
    for client in clients:
        name = clean(client.get('name'), 200) if isinstance(client, dict) else ''
        if name and not (isinstance(client, dict) and client.get('archived') is True):
            if name.casefold() not in companies and not db.execute(
                    'SELECT 1 FROM companies WHERE name=? COLLATE NOCASE', (name,)).fetchone():
                stats['new_companies'] += 1
            cid = company_id(db, name, companies)
            link(db, 'companies', cid, client.get('id'))
    for project in projects:
        if not isinstance(project, dict) or project.get('archived') is True:
            continue
        name = clean(project.get('name'), 200)
        if not name:
            continue
        cid = company_id(db, clean(project.get('clientName'), 200) or NO_CLIENT, companies)
        if not db.execute('SELECT 1 FROM projects WHERE company_id=? AND name=? COLLATE NOCASE', (cid, name)).fetchone():
            stats['new_projects'] += 1
        link(db, 'projects', project_id(db, cid, name, project_cache), project.get('id'))


def link(db, table, local_id, remote_id):
    """Remember which Clockify client/project a local company/project is."""
    if local_id is None or not isinstance(remote_id, str) or not ID_RE.match(remote_id):
        return
    db.execute(f'UPDATE {table} SET clockify_id=NULL WHERE clockify_id=? AND id<>?', (remote_id, local_id))
    db.execute(f'UPDATE {table} SET clockify_id=? WHERE id=?', (remote_id, local_id))


def sync(db, setting, since=None, today=None, fetcher=fetch, catalog=fetch_catalog, dry_run=False):
    """Run inside the caller's transaction. Returns counts for the bar."""
    today = today or date.today()
    if since is None:
        last = setting(db, 'clockify_synced_through')
        since = (date.fromisoformat(last) - timedelta(days=LOOKBACK_DAYS)).isoformat() if last else FIRST_SYNC
    else:
        since = date.fromisoformat(since).isoformat()
    clients, projects_list = catalog()
    entries = fetcher(since, today.isoformat())
    window_lo = datetime.combine(date.fromisoformat(since), datetime.min.time()).astimezone().timestamp()

    stats = dict(since=since, added=0, updated=0, removed=0, unchanged=0, skipped_running=0, skipped_invalid=0,
                 new_companies=0, new_projects=0)
    companies, projects, seen = {}, {}, set()
    import_catalog(db, clients, projects_list, companies, projects, stats)
    for entry in entries:
        if not isinstance(entry, dict):
            stats['skipped_invalid'] += 1
            continue
        cid_remote = entry.get('id')
        interval = entry.get('timeInterval') if isinstance(entry.get('timeInterval'), dict) else {}
        start, end = parse_time(interval.get('start')), parse_time(interval.get('end'))
        if not isinstance(cid_remote, str) or not ID_RE.match(cid_remote) or start is None:
            stats['skipped_invalid'] += 1
            continue
        seen.add(cid_remote)
        if end is None:
            stats['skipped_running'] += 1
            continue
        if end < start:
            stats['skipped_invalid'] += 1
            continue
        project = entry.get('project') if isinstance(entry.get('project'), dict) else {}
        company = clean(project.get('clientName'), 200) or NO_CLIENT
        project_name = clean(project.get('name'), 200)
        note = clean(entry.get('description'), 2000)
        cid = company_id(db, company, companies)
        pid = project_id(db, cid, project_name, projects)
        link(db, 'companies', cid, project.get('clientId'))
        link(db, 'projects', pid, entry.get('projectId'))
        row = db.execute('SELECT id, company_id, project_id, start, end, note FROM sessions WHERE clockify_id=?',
                         (cid_remote,)).fetchone()
        values = (cid, pid, start, end, note)
        if row is None:
            db.execute('INSERT INTO sessions(company_id,project_id,start,end,note,clockify_id) VALUES (?,?,?,?,?,?)',
                       values + (cid_remote,))
            stats['added'] += 1
        elif tuple(row[1:]) != values:
            db.execute('UPDATE sessions SET company_id=?, project_id=?, start=?, end=?, note=? WHERE id=?',
                       values + (row[0],))
            stats['updated'] += 1
        else:
            stats['unchanged'] += 1

    # Within the window just read, a Clockify-sourced session that Clockify no
    # longer returns was deleted there.
    for (sid, remote) in db.execute('SELECT id, clockify_id FROM sessions WHERE clockify_id IS NOT NULL AND start >= ?',
                                    (window_lo,)).fetchall():
        if remote not in seen:
            db.execute('DELETE FROM obsidian_jobs WHERE session_id=?', (sid,))
            db.execute('DELETE FROM sessions WHERE id=?', (sid,))
            stats['removed'] += 1

    if not dry_run:
        setting(db, 'clockify_synced_through', today.isoformat())
        setting(db, 'clockify_synced_at', datetime.now(timezone.utc).isoformat(timespec='seconds'))
    stats['dry_run'] = dry_run
    return stats


def local_midnight(day):
    return datetime.combine(date.fromisoformat(day), datetime.min.time()).astimezone().timestamp()


def clockify_time(epoch):
    return datetime.fromtimestamp(epoch, timezone.utc).strftime('%Y-%m-%d %H:%M:%S')


def push(db, setting, run=run_cli, today=None, limit=PUSH_LIMIT):
    """Send finished local sessions (from clockify_push_since on) to Clockify.

    Commits after each created entry, so an id Clockify has handed out is never
    lost to a later failure (which would send the session twice). Stops at the
    first error and reports it; what was sent stays sent."""
    today = today or date.today()
    since = setting(db, 'clockify_push_since')
    if not since:
        since = setting(db, 'clockify_push_since', today.isoformat())
    stats = dict(push_since=since, pushed=0, push_waiting=0, push_overlaps=0, pushed_without_project=0,
                 created_clients=0, created_projects=0, push_error=None)
    rows = db.execute('''SELECT s.id, s.start, s.end, s.note, s.company_id, s.project_id,
            c.name AS company, c.clockify_id AS client_cid, p.name AS project, p.clockify_id AS project_cid
            FROM sessions s JOIN companies c ON c.id=s.company_id LEFT JOIN projects p ON p.id=s.project_id
            WHERE s.clockify_id IS NULL AND s.end IS NOT NULL AND s.start >= ? ORDER BY s.start''',
                      (local_midnight(since),)).fetchall()
    db.commit()   # keep what the pull just saved, whatever happens below
    db.execute('BEGIN IMMEDIATE')
    clients, projects = {}, {}
    for row in rows:
        if db.execute('''SELECT 1 FROM sessions WHERE clockify_id IS NOT NULL AND start < ? AND end > ?''',
                      (row['end'], row['start'])).fetchone():
            stats['push_overlaps'] += 1
            continue
        if stats['pushed'] >= limit:
            stats['push_waiting'] += 1
            continue
        try:
            client = None
            if row['company'] != NO_CLIENT:
                client = row['client_cid'] or clients.get(row['company_id'])
                if not client:
                    client = run('client', 'add', '--name=' + row['company'], quiet_id=True)
                    link(db, 'companies', row['company_id'], client)
                    stats['created_clients'] += 1
                clients[row['company_id']] = client
            project = None
            if row['project_id']:
                project = row['project_cid'] or projects.get(row['project_id'])
                if not project:
                    argv = ['project', 'add', '--name=' + row['project'], '--random-color']
                    if client:
                        argv.append('--client=' + client)
                    project = run(*argv, quiet_id=True)
                    link(db, 'projects', row['project_id'], project)
                    stats['created_projects'] += 1
                projects[row['project_id']] = project
            else:
                stats['pushed_without_project'] += 1   # Clockify ties a client to time only through a project
            argv = ['manual', '--tz=UTC', '--when=' + clockify_time(row['start']),
                    '--when-to-close=' + clockify_time(row['end']), '--description=' + (row['note'] or '')]
            if project:
                argv.append('--project=' + project)
            entry = run(*argv, quiet_id=True)
            db.execute('UPDATE sessions SET clockify_id=? WHERE id=?', (entry, row['id']))
            stats['pushed'] += 1
        except ValueError as exc:
            stats['push_error'] = str(exc)
            stats['push_waiting'] += 1
            db.commit()
            db.execute('BEGIN IMMEDIATE')
            break
        db.commit()
        db.execute('BEGIN IMMEDIATE')
    else:
        return stats
    # Count what the error left unsent.
    stats['push_waiting'] += sum(1 for r in rows[rows.index(row) + 1:])
    return stats
