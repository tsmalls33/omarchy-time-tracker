#!/usr/bin/env python3
"""Persistent local work timer. Python 3.10+, no third-party dependencies."""
import argparse
import json
import os
import re
from pathlib import Path
import sqlite3
import sys
import unicodedata
from storage import private_file, secure_directory
from datetime import datetime, date, time, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

UTC = timezone.utc
DEFAULT_DB = Path(os.environ.get('XDG_DATA_HOME', str(Path.home() / '.local/share'))) / 'codex-time-tracker/tracker.sqlite3'


def local_timezone():
    candidates = [os.environ.get('TZ', '').lstrip(':')]
    localtime = str(Path('/etc/localtime').resolve())
    if '/zoneinfo/' in localtime:
        candidates.append(localtime.split('/zoneinfo/', 1)[1])
    for name in candidates:
        if not name:
            continue
        try:
            ZoneInfo(name)
            return name
        except (ValueError, ZoneInfoNotFoundError):
            continue
    return 'UTC'


def connect(path):
    path = Path(path).expanduser()
    parent = secure_directory(path.parent, private=path.parent.absolute() == DEFAULT_DB.parent.absolute())
    path = parent / path.name
    private_file(path, create=True, database=True)
    for suffix in ('-journal', '-wal', '-shm'):
        private_file(Path(str(path) + suffix))
    db = sqlite3.connect(path, timeout=15, isolation_level=None)
    db.row_factory = sqlite3.Row
    db.execute('PRAGMA trusted_schema=OFF')
    db.execute('PRAGMA foreign_keys=ON')
    db.executescript('''
        CREATE TABLE IF NOT EXISTS companies (
            id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE COLLATE NOCASE);
        CREATE TABLE IF NOT EXISTS projects (
            id INTEGER PRIMARY KEY, company_id INTEGER NOT NULL REFERENCES companies(id),
            name TEXT NOT NULL COLLATE NOCASE, UNIQUE(company_id, name));
        CREATE TABLE IF NOT EXISTS sessions (
            id INTEGER PRIMARY KEY, company_id INTEGER NOT NULL REFERENCES companies(id),
            project_id INTEGER REFERENCES projects(id), start REAL NOT NULL,
            end REAL CHECK(end >= start), note TEXT NOT NULL DEFAULT '');
        CREATE UNIQUE INDEX IF NOT EXISTS one_running_timer ON sessions((1)) WHERE end IS NULL;
        CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS obsidian_jobs (
            session_id INTEGER PRIMARY KEY REFERENCES sessions(id), job_key TEXT NOT NULL UNIQUE,
            vault TEXT NOT NULL, payload TEXT NOT NULL, path TEXT, error TEXT);
    ''')
    db.execute("INSERT OR IGNORE INTO settings VALUES ('timezone', ?)", (local_timezone(),))
    # Sessions copied in from Clockify remember their source id (clockify_sync.py).
    # Companies and projects remember their Clockify client/project for pushes.
    for table in ('sessions', 'companies', 'projects'):
        if 'clockify_id' not in {row[1] for row in db.execute(f'PRAGMA table_info({table})')}:
            db.execute(f'ALTER TABLE {table} ADD COLUMN clockify_id TEXT')
        db.execute(f'CREATE UNIQUE INDEX IF NOT EXISTS {table}_clockify_id ON {table}(clockify_id) WHERE clockify_id IS NOT NULL')
    return db


def setting(db, key, value=None):
    if value is not None:
        db.execute('INSERT OR REPLACE INTO settings VALUES (?, ?)', (key, str(value)))
    row = db.execute('SELECT value FROM settings WHERE key=?', (key,)).fetchone()
    return row[0] if row else None


def company(db, name=None):
    if name is None:
        row = db.execute('SELECT * FROM companies WHERE id=?', (setting(db, 'company'),)).fetchone()
    else:
        row = db.execute('SELECT * FROM companies WHERE name=? COLLATE NOCASE', (name.strip(),)).fetchone()
    if row is None:
        raise ValueError('Company not found. Add or select a company first.')
    return row


def project(db, cid, name):
    if name is None:
        return None
    row = db.execute('SELECT * FROM projects WHERE company_id=? AND name=? COLLATE NOCASE', (cid, name.strip())).fetchone()
    if row is None:
        raise ValueError('Project not found for this company. Add it first.')
    return row['id']


def active(db):
    return db.execute('SELECT * FROM sessions WHERE end IS NULL').fetchone()


def session_detail(db, row, now):
    result = dict(row)
    result['company'] = db.execute('SELECT name FROM companies WHERE id=?', (row['company_id'],)).fetchone()[0]
    result['project'] = db.execute('SELECT name FROM projects WHERE id=?', (row['project_id'],)).fetchone()[0] if row['project_id'] else None
    result['seconds'] = max(0, (row['end'] if row['end'] is not None else now) - row['start'])
    tz = ZoneInfo(setting(db, 'timezone'))
    for key in ('start', 'end'):
        result[key] = datetime.fromtimestamp(row[key], tz).isoformat() if row[key] is not None else None
    return result


def period_bounds(period, day):
    if period == 'daily':
        return day, day + timedelta(days=1)
    if period == 'weekly':
        start = day - timedelta(days=day.weekday())
        return start, start + timedelta(days=7)
    if period == 'monthly':
        start = day.replace(day=1)
        return start, date(day.year + (day.month == 12), day.month % 12 + 1, 1)
    return date(day.year, 1, 1), date(day.year + 1, 1, 1)


def report(db, args, now):
    tz = ZoneInfo(setting(db, 'timezone'))
    day = date.fromisoformat(args.date) if args.date else datetime.fromtimestamp(now, tz).date()
    first, last = period_bounds(args.period, day)
    lo = datetime.combine(first, time.min, tz).timestamp()
    hi = datetime.combine(last, time.min, tz).timestamp()
    cid = company(db, args.company)['id'] if args.company else None
    if args.project and cid is None:
        raise ValueError('--project requires --company for reports.')
    pid = project(db, cid, args.project) if args.project else None
    daily = {}
    running_included = False
    for row in db.execute('''SELECT s.*, c.name AS company, p.name AS project FROM sessions s
            JOIN companies c ON c.id=s.company_id LEFT JOIN projects p ON p.id=s.project_id
            WHERE s.start < ? AND COALESCE(s.end, ?) > ?''', (hi, now, lo)):
        if cid is not None and row['company_id'] != cid:
            continue
        if pid is not None and row['project_id'] != pid:
            continue
        start, end = max(lo, row['start']), min(hi, row['end'] if row['end'] is not None else now)
        running_included |= row['end'] is None and end > start
        while start < end:
            local_day = datetime.fromtimestamp(start, tz).date()
            midnight = datetime.combine(local_day + timedelta(days=1), time.min, tz).timestamp()
            stop = min(end, midnight)
            key = (local_day.isoformat(), row['company'], row['project'])
            daily[key] = daily.get(key, 0) + stop - start
            start = stop
    rows = [dict(date=d, company=c, project=p, seconds=round(s, 3), hours=round(s/3600, 6))
            for (d, c, p), s in sorted(daily.items(), key=lambda x: (x[0][0], x[0][1], x[0][2] or ''))]
    totals = {}
    for (_, c, p), seconds in daily.items():
        totals[c, p] = totals.get((c, p), 0) + seconds
    companies = {}
    for (c, _), seconds in totals.items():
        companies[c] = companies.get(c, 0) + seconds
    return dict(period=args.period, start=first.isoformat(), end_exclusive=last.isoformat(),
                timezone=str(tz), includes_running_timer=running_included,
                total_seconds=round(sum(daily.values()), 3), total_hours=round(sum(daily.values())/3600, 6),
                companies=[dict(company=c, seconds=round(s, 3), hours=round(s/3600, 6)) for c, s in sorted(companies.items())],
                projects=[dict(company=c, project=p, seconds=round(s, 3), hours=round(s/3600, 6))
                          for (c, p), s in sorted(totals.items(), key=lambda x: (x[0][0], x[0][1] or ''))], daily=rows)


START_AT_RE = re.compile(r'^(?:(\d{1,2}):(\d{2})|(\d{3,4})|(\d{1,2}))\s*(am|pm)?$')
START_AT_HELP = 'Start time must look like 1600, 16:00, 0900 or 4pm.'


def parse_clock(value):
    """(hour, minute) from "1600", "16:00", "0900", "4pm" or "9:30am"; 0000-2359 only."""
    m = START_AT_RE.match((value or '').strip().lower().replace('.', ''))
    if not m:
        raise ValueError(START_AT_HELP)
    colon_h, colon_m, digits, bare_h, meridiem = m.groups()
    if colon_h is not None:
        hour, minute = int(colon_h), int(colon_m)
    elif digits is not None:
        hour, minute = int(digits[:-2]), int(digits[-2:])
    elif meridiem:            # "4pm"
        hour, minute = int(bare_h), 0
    else:                     # "16" alone is ambiguous
        raise ValueError(START_AT_HELP)
    if meridiem:
        if not 1 <= hour <= 12:
            raise ValueError('With am/pm the hour must be 1-12.')
        hour = hour % 12 + (12 if meridiem == 'pm' else 0)
    if hour > 23 or minute > 59:
        raise ValueError('Start time must be between 0000 and 2359.')
    return hour, minute


def parse_start_at(value, now, tz):
    """Epoch for a wall-clock time today. A time later than now is refused."""
    start = datetime.combine(datetime.fromtimestamp(now, tz).date(), time(*parse_clock(value)), tz).timestamp()
    if start > now:
        raise ValueError('Start time is later than now.')
    return start


def parse_when(value, day, tz, label):
    """Epoch for "YYYY-MM-DD HH:MM" (any clock form above), or a clock alone on `day`."""
    text = (value or '').strip()
    parts = text.split(None, 1)
    if parts and re.match(r'^\d{4}-\d{2}-\d{2}$', parts[0]):
        try:
            day = date.fromisoformat(parts[0])
        except ValueError:
            raise ValueError(f'{label}: {parts[0]} is not a real date.')
        text = parts[1] if len(parts) > 1 else ''
    try:
        clock = parse_clock(text)
    except ValueError:
        raise ValueError(f'{label} must look like 2026-11-18 16:00, or just 1600 / 4pm for the same day.')
    return datetime.combine(day, time(*clock), tz).timestamp()


def validate_text(value, label, limit, blank=False):
    if not isinstance(value, str) or len(value) > limit:
        raise ValueError(f'{label} must be at most {limit} characters.')
    if any(unicodedata.category(c) in ('Cc', 'Cs') or c in '\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069' for c in value):
        raise ValueError(f'{label} cannot contain control or bidirectional override characters.')
    if not blank and not value.strip():
        raise ValueError(f'{label} cannot be blank.')
    return value.strip() if not blank else value


def execute(db, args, now=None):
    now = datetime.now(UTC).timestamp() if now is None else now
    cmd = args.command
    if cmd == 'add-company':
        name = validate_text(args.name, 'Company name', 200)
        db.execute('INSERT INTO companies(name) VALUES (?)', (name,))
        return dict(company(db, name))
    if cmd == 'companies':
        return [dict(r) for r in db.execute('SELECT * FROM companies ORDER BY name')]
    if cmd == 'add-project':
        cid = company(db, args.company)['id']
        name = validate_text(args.name, 'Project name', 200)
        cursor = db.execute('INSERT INTO projects(company_id,name) VALUES (?,?)', (cid, name))
        return dict(id=cursor.lastrowid, company_id=cid, name=name)
    if cmd == 'projects':
        cid = company(db, args.company)['id']
        return [dict(r) for r in db.execute('SELECT * FROM projects WHERE company_id=? ORDER BY name', (cid,))]
    if cmd == 'select':
        c = company(db, args.company)
        pid = project(db, c['id'], args.project)
        setting(db, 'company', c['id'])
        setting(db, 'project', pid or '')
        return dict(company=c['name'], project=args.project)
    if cmd == 'start':
        validate_text(args.note, 'Note', 2000, blank=True)
        if active(db):
            raise ValueError('A timer is already running. Stop it before starting another.')
        c = company(db, args.company)
        pid = project(db, c['id'], args.project)
        if not args.company and not args.project and not args.no_project:
            pid = setting(db, 'project') or None
        start = now
        if args.at:
            start = parse_start_at(args.at, now, ZoneInfo(setting(db, 'timezone')))
            last = db.execute('SELECT MAX(end) FROM sessions').fetchone()[0]
            if last is not None and start < last:
                ended = datetime.fromtimestamp(last, ZoneInfo(setting(db, 'timezone'))).strftime('%H:%M')
                raise ValueError(f'Start time overlaps the previous session, which ended at {ended}.')
        cursor = db.execute('INSERT INTO sessions(company_id,project_id,start,note) VALUES (?,?,?,?)', (c['id'], pid, start, args.note))
        return session_detail(db, db.execute('SELECT * FROM sessions WHERE id=?', (cursor.lastrowid,)).fetchone(), now)
    if cmd == 'stop':
        row = active(db)
        if row is None:
            raise ValueError('No timer is running.')
        if now < row['start']:
            raise ValueError('System clock is before the timer start. Correct the system clock before stopping.')
        db.execute('UPDATE sessions SET end=? WHERE id=?', (now, row['id']))
        result = session_detail(db, db.execute('SELECT * FROM sessions WHERE id=?', (row['id'],)).fetchone(), now)
        if setting(db, 'obsidian_autolog') == 'on':
            from obsidian_autolog import enqueue, deliver
            enqueue(db, result, setting(db, 'obsidian_vault') or '', setting(db, 'timezone'))
            # Persist the stop and its delivery job together before touching the vault.
            db.commit()
            result.update(deliver(db, row['id']))
        return result
    if cmd == 'status':
        row = active(db)
        selected = db.execute('SELECT name FROM companies WHERE id=?', (setting(db, 'company'),)).fetchone()
        selected_project = db.execute('SELECT name FROM projects WHERE id=?', (setting(db, 'project'),)).fetchone()
        return dict(running=session_detail(db, row, now) if row else None,
                    selected_company=selected[0] if selected else None,
                    selected_project=selected_project[0] if selected_project else None,
                    obsidian_vault=setting(db, 'obsidian_vault') or '',
                    obsidian_autolog=setting(db, 'obsidian_autolog') == 'on',
                    obsidian_pending=db.execute('SELECT count(*) FROM obsidian_jobs WHERE path IS NULL').fetchone()[0],
                    timezone=setting(db, 'timezone'),
                    clockify_synced_at=setting(db, 'clockify_synced_at'),
                    clockify_push_since=setting(db, 'clockify_push_since'))
    if cmd == 'auto-obsidian':
        if args.mode == 'on':
            from obsidian_export import vault_directory
            vault = setting(db, 'obsidian_vault')
            if not vault:
                raise ValueError('Save an Obsidian vault before enabling automatic logging.')
            vault_directory(vault)
        setting(db, 'obsidian_autolog', args.mode)
        return dict(obsidian_autolog=args.mode == 'on')
    if cmd == 'retry-obsidian':
        from obsidian_autolog import deliver
        jobs = db.execute('SELECT session_id FROM obsidian_jobs WHERE path IS NULL ORDER BY session_id LIMIT 50').fetchall()
        db.commit()
        results = [deliver(db, job['session_id']) for job in jobs]
        output = dict(delivered=sum('obsidian_path' in r for r in results), attempted=len(results))
        successful = [r for r in results if 'obsidian_path' in r]
        if successful:
            output.update(successful[-1])
        failed = [r['warning'] for r in results if 'warning' in r]
        if failed:
            output['warning'] = failed[0]
        return output
    if cmd == 'vault':
        if args.clear:
            setting(db, 'obsidian_vault', '')
            setting(db, 'obsidian_autolog', 'off')
        elif args.path:
            from obsidian_export import vault_directory
            setting(db, 'obsidian_vault', str(vault_directory(args.path)))
        return dict(obsidian_vault=setting(db, 'obsidian_vault') or '')
    if cmd == 'timezone':
        ZoneInfo(args.name)
        setting(db, 'timezone', args.name)
        return dict(timezone=args.name)
    if cmd == 'report':
        if args.output and not args.pdf:
            raise ValueError('--output requires --pdf.')
        result = report(db, args, now)
        if args.pdf:
            try:
                from pdf_report import export_pdf
            except ImportError as exc:
                raise ValueError('PDF export requires ReportLab. Install it with: sudo pacman -S --needed python-reportlab') from exc
            result['pdf_path'] = export_pdf(result, args.output, args.company, args.project)
        elif args.obsidian:
            from obsidian_export import export_obsidian
            vault = setting(db, 'obsidian_vault')
            if not vault:
                raise ValueError('Save your Obsidian vault folder before exporting.')
            result.update(export_obsidian(db, result, vault, now, args.company, args.project))
        return result
    if cmd == 'records':
        if not 1 <= args.limit <= 10000:
            raise ValueError('Record limit must be between 1 and 10000.')
        cid = company(db, args.company)['id'] if args.company else None
        rows = db.execute('SELECT * FROM sessions WHERE (? IS NULL OR company_id=?) ORDER BY start DESC LIMIT ?', (cid, cid, args.limit))
        return [session_detail(db, r, now) for r in rows]
    if cmd == 'clockify-sync':
        from clockify_sync import sync, push
        result = sync(db, setting, since=args.since, dry_run=args.dry_run)
        if not args.dry_run and not args.no_push:
            result.update(push(db, setting))
        return result
    if cmd == 'clockify-push-since':
        day = date.fromisoformat(args.date).isoformat()
        setting(db, 'clockify_push_since', day)
        return dict(clockify_push_since=day)
    if cmd == 'edit-record':
        row = db.execute('SELECT * FROM sessions WHERE id=?', (args.id,)).fetchone()
        if row is None:
            raise ValueError('Record not found.')
        if row['end'] is None:
            raise ValueError('Stop the running timer before editing its record.')
        tz = ZoneInfo(setting(db, 'timezone'))
        start = parse_when(args.start, datetime.fromtimestamp(row['start'], tz).date(), tz, 'Start') if args.start else row['start']
        end = parse_when(args.end, datetime.fromtimestamp(start, tz).date(), tz, 'End') if args.end else row['end']
        if end <= start:
            raise ValueError('End must be after start.')
        if end > now:
            raise ValueError('End is later than now.')
        clash = db.execute('SELECT start, end FROM sessions WHERE id<>? AND start < ? AND COALESCE(end, ?) > ? ORDER BY start LIMIT 1',
                           (args.id, end, now, start)).fetchone()
        if clash:
            fmt = lambda e: datetime.fromtimestamp(e, tz).strftime('%Y-%m-%d %H:%M') if e is not None else 'now'
            raise ValueError(f"Overlaps another session ({fmt(clash['start'])} to {fmt(clash['end'])}).")
        clockify = False
        if row['clockify_id']:
            # Linked to Clockify: change it there too (one request), or the next
            # sync would put Clockify's old times back.
            from clockify_sync import edit_entry
            edit_entry(row['clockify_id'], start, end)
            clockify = True
        db.execute('UPDATE sessions SET start=?, end=? WHERE id=?', (start, end, args.id))
        detail = session_detail(db, db.execute('SELECT * FROM sessions WHERE id=?', (args.id,)).fetchone(), now)
        return dict(edited=detail, clockify_updated=clockify)
    if cmd in ('delete-record', 'clear-records'):
        if not args.confirm:
            raise ValueError('Deletion requires --confirm. Exported PDFs and Obsidian notes will remain.')
        # A savepoint keeps sessions and their delivery jobs atomic, even for direct callers.
        db.execute('SAVEPOINT delete_records')
        try:
            if cmd == 'clear-records':
                if active(db):
                    raise ValueError('Stop the running timer before clearing records.')
                db.execute('DELETE FROM obsidian_jobs')
                deleted = db.execute('DELETE FROM sessions').rowcount
            else:
                row = db.execute('SELECT * FROM sessions WHERE id=?', (args.id,)).fetchone()
                if row is None:
                    raise ValueError('Record not found.')
                if row['end'] is None:
                    raise ValueError('Stop the running timer before deleting its record.')
                db.execute('DELETE FROM obsidian_jobs WHERE session_id=?', (args.id,))
                deleted = db.execute('DELETE FROM sessions WHERE id=?', (args.id,)).rowcount
            db.execute('RELEASE delete_records')
        except Exception:
            db.execute('ROLLBACK TO delete_records')
            db.execute('RELEASE delete_records')
            raise
        return dict(deleted_records=deleted, deleted_id=args.id if cmd == 'delete-record' else None)


class ArgumentParser(argparse.ArgumentParser):
    def __init__(self, *args, **kwargs):
        kwargs['allow_abbrev'] = False
        super().__init__(*args, **kwargs)

    def error(self, message):
        raise ValueError(message)


def parser():
    p = ArgumentParser(description=__doc__, allow_abbrev=False)
    p.add_argument('--db', default=os.environ.get('TIME_TRACKER_DB', str(DEFAULT_DB)))
    sub = p.add_subparsers(dest='command', required=True)
    sub.add_parser('add-company').add_argument('name')
    sub.add_parser('companies')
    for cmd in ('add-project', 'projects', 'select', 'start', 'records', 'report'):
        child = sub.add_parser(cmd)
        child.add_argument('--company')
        if cmd == 'add-project':
            child.add_argument('name')
        if cmd in ('select', 'start', 'report'):
            group = child.add_mutually_exclusive_group()
            group.add_argument('--project')
            if cmd == 'start':
                group.add_argument('--no-project', action='store_true')
        if cmd == 'select':
            child._option_string_actions['--company'].required = True
        if cmd == 'start':
            child.add_argument('--note', default='')
            child.add_argument('--at', help='Start time today instead of now: 1600, 16:00, 0900, 4pm')
        if cmd == 'records':
            child.add_argument('--limit', type=int, default=100)
        if cmd == 'report':
            child.add_argument('period', choices=['daily', 'weekly', 'monthly', 'yearly'])
            child.add_argument('--date', help='Any date in the requested period, YYYY-MM-DD')
            formats = child.add_mutually_exclusive_group()
            formats.add_argument('--pdf', action='store_true', help='Export a styled PDF report')
            formats.add_argument('--obsidian', action='store_true', help='Export Markdown records to the saved Obsidian vault')
            child.add_argument('--output', help='PDF destination (default: Documents/Time Tracker Reports)')
    sub.add_parser('stop')
    sub.add_parser('status')
    sub.add_parser('timezone').add_argument('name')
    sub.add_parser('auto-obsidian').add_argument('mode', choices=['on', 'off'])
    sub.add_parser('retry-obsidian')
    clockify = sub.add_parser('clockify-sync', help='Copy completed Clockify entries in (needs clockify-cli)')
    clockify.add_argument('--since', help='Re-read from this date, YYYY-MM-DD (default: 7 days before the last sync)')
    clockify.add_argument('--dry-run', action='store_true', help='Report what would change without saving (no push)')
    clockify.add_argument('--no-push', action='store_true', help='Only pull from Clockify; send nothing')
    sub.add_parser('clockify-push-since', help='Send sessions from this date on to Clockify').add_argument('date', help='YYYY-MM-DD')
    edit = sub.add_parser('edit-record', help='Change when a finished session started and ended')
    edit.add_argument('id', type=int)
    edit.add_argument('--start', help='"YYYY-MM-DD HH:MM", or a time alone (1600, 4pm) for the same day')
    edit.add_argument('--end', help='As --start; a time alone means the (new) start day')
    for cmd in ('delete-record', 'clear-records'):
        child = sub.add_parser(cmd)
        if cmd == 'delete-record':
            child.add_argument('id', type=int)
        child.add_argument('--confirm', action='store_true', help='Permanently delete database records and their pending Obsidian jobs; keep exported files')
    vault = sub.add_parser('vault')
    destination = vault.add_mutually_exclusive_group()
    destination.add_argument('path', nargs='?', help='Existing local Obsidian vault folder')
    destination.add_argument('--clear', action='store_true', help='Forget the saved vault without removing notes')
    return p


def main():
    db = None
    try:
        args = parser().parse_args()
        db = connect(args.db)
        db.execute('BEGIN IMMEDIATE')
        result = execute(db, args)
        db.commit()
        print(json.dumps(result, indent=2, ensure_ascii=False))
    except (ValueError, sqlite3.Error, ZoneInfoNotFoundError, OSError) as exc:
        if db:
            db.rollback()
        print(json.dumps({'error': str(exc)}), file=sys.stderr)
        return 1
    finally:
        if db:
            db.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
