#!/usr/bin/env python3
"""Apply the changes waiting in Supabase to this repository.

Jonathan, 10 Nov 2026: no more zips to download and upload. A change
is queued as a row of public.code_changes (migration 306): the output
of `git format-patch --binary --stdout`, gzipped and base64. This
script, run by .github/workflows/apply_changes.yml, takes the pending
rows in order, applies each with `git am`, pushes to main and starts
the build (a push made by a workflow does not start it by itself).

Refused, with the reason written on the row: a patch whose checksum
does not match, one that does not apply, and one that touches .github/
(a workflow cannot change workflow files; those are uploaded by hand).
After a refusal the later rows wait: they may build on the refused one.

See docs/AUTO_APPLY.md.
"""
import base64
import datetime
import gzip
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

SUPABASE_URL = os.environ.get('SUPABASE_URL', '').rstrip('/')
SERVICE_KEY = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')
GH_TOKEN = os.environ.get('GH_TOKEN', '')
REPO = os.environ.get('GITHUB_REPOSITORY', '')
RUN_URL = (f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/{REPO}"
           f"/actions/runs/{os.environ.get('GITHUB_RUN_ID', '')}")
BRANCH = 'main'

report = {'applied': [], 'failed': [], 'waiting': []}


def sb(path, method='GET', body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        f'{SUPABASE_URL}/rest/v1/{path}', data=data, method=method,
        headers={'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}',
                 'Content-Type': 'application/json', 'Prefer': 'return=minimal'})
    try:
        with urllib.request.urlopen(req) as r:
            txt = r.read().decode()
            return json.loads(txt) if txt else None
    except urllib.error.HTTPError as e:
        raise RuntimeError(f'{e.code} {e.read().decode()[:300]}') from None


def git(*args, check=True):
    p = subprocess.run(['git', *args], capture_output=True, text=True)
    if check and p.returncode:
        raise RuntimeError(f"git {' '.join(args[:2])}: {(p.stderr or p.stdout).strip()[-600:]}")
    return p


def mark(row_id, **fields):
    fields.setdefault('run_url', RUN_URL)
    sb(f'code_changes?id=eq.{row_id}', 'PATCH', fields)


def tell(title, message):
    """A ping on the founders' phones; never stops the run."""
    try:
        sb('rpc/notify_phone', 'POST', {'p_title': title, 'p_message': message})
    except Exception:  # noqa: BLE001
        pass


def start_build():
    """A push made with the workflow's own token starts no workflow, so
    the build is started by name."""
    req = urllib.request.Request(
        f'https://api.github.com/repos/{REPO}/actions/workflows/build.yml/dispatches',
        data=json.dumps({'ref': BRANCH}).encode(), method='POST',
        headers={'Authorization': f'Bearer {GH_TOKEN}',
                 'Accept': 'application/vnd.github+json',
                 'Content-Type': 'application/json',
                 'X-GitHub-Api-Version': '2022-11-28'})
    with urllib.request.urlopen(req) as r:
        return r.status


def apply_one(row):
    """Applies one row's patch as commits on top of HEAD. Returns the
    files it changed; raises with a plain reason when it is refused."""
    raw = base64.b64decode(row.get('patch') or '', validate=False)
    if not raw:
        raise RuntimeError('the patch is empty')
    if hashlib.sha256(raw).hexdigest() != (row.get('sha256') or ''):
        raise RuntimeError('the checksum does not match: it arrived damaged')
    patch = gzip.decompress(raw)
    before = git('rev-parse', 'HEAD').stdout.strip()
    with tempfile.NamedTemporaryFile(suffix='.patch', delete=False) as fh:
        fh.write(patch)
        path = fh.name
    p = git('am', '--3way', path, check=False)
    if p.returncode:
        git('am', '--abort', check=False)
        git('reset', '--hard', before, check=False)
        raise RuntimeError('it does not apply to the code as it is now: '
                           + (p.stderr or p.stdout).strip()[-400:])
    files = [f for f in git('diff', '--name-only', before, 'HEAD').stdout.split('\n') if f]
    if not files:
        git('reset', '--hard', before, check=False)
        raise RuntimeError('it changes nothing')
    if any(f.startswith('.github/') for f in files):
        git('reset', '--hard', before, check=False)
        raise RuntimeError('it touches .github/ (workflow files are uploaded by hand): '
                           + ', '.join(f for f in files if f.startswith('.github/')))
    return files


def push():
    for attempt in range(3):
        p = git('push', 'origin', f'HEAD:{BRANCH}', check=False)
        if p.returncode == 0:
            return
        # someone uploaded in the meantime: put ours on top and try again
        r = git('pull', '--rebase', 'origin', BRANCH, check=False)
        if r.returncode:
            git('rebase', '--abort', check=False)
            raise RuntimeError('main changed in a way these changes do not fit on: '
                               + (r.stderr or r.stdout).strip()[-300:])
    raise RuntimeError('GitHub did not take the push: ' + (p.stderr or p.stdout).strip()[-300:])


def main():
    if not (SUPABASE_URL and SERVICE_KEY):
        print('missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY; nothing done')
        return 0
    rows = sb('code_changes?status=eq.pending&order=id.asc'
              '&select=id,message,patch,sha256') or []
    if not rows:
        print('nothing waiting')
        return 0
    git('config', 'user.name', 'Claude')
    git('config', 'user.email', 'noreply@anthropic.com')
    start = git('rev-parse', 'HEAD').stdout.strip()
    done = []
    for i, row in enumerate(rows):
        try:
            files = apply_one(row)
            done.append((row, files))
        except Exception as e:  # noqa: BLE001
            mark(row['id'], status='failed', error=str(e)[:900])
            report['failed'].append({'id': row['id'], 'message': row['message'], 'why': str(e)})
            report['waiting'] = [r['id'] for r in rows[i + 1:]]
            tell('A change did not go in',
                 f"{row['message']}: {str(e)[:160]}")
            break
    if done:
        try:
            push()
        except Exception as e:  # noqa: BLE001
            git('reset', '--hard', start, check=False)
            for row, _ in done:
                mark(row['id'], status='failed', error=str(e)[:900])
                report['failed'].append({'id': row['id'], 'message': row['message'], 'why': str(e)})
            tell('Changes could not be pushed', str(e)[:200])
            done = []
    if done:
        sha = git('rev-parse', 'HEAD').stdout.strip()
        now = datetime.datetime.now(datetime.timezone.utc).isoformat()
        for row, files in done:
            mark(row['id'], status='applied', applied_sha=sha, applied_at=now, error=None)
            report['applied'].append({'id': row['id'], 'message': row['message'], 'files': files})
        try:
            report['build_started'] = start_build()
        except Exception as e:  # noqa: BLE001
            report['build_error'] = str(e)[:300]
        tell('Changes are in, building now',
             '; '.join(row['message'] for row, _ in done)[:240])
    print(json.dumps(report, indent=2))
    return 1 if report['failed'] else 0


if __name__ == '__main__':
    sys.exit(main())
