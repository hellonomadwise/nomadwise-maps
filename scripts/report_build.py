#!/usr/bin/env python3
"""Write how this build ended into Supabase (public.build_runs).

The last job of build.yml (Jonathan, 10 Nov 2026: "if you can spot
failures that would be great"). Claude cannot open GitHub's Actions
page, so each run leaves one row: the result of the build and deploy
jobs and, on a failure, which step failed and the end of that job's
log. A failed run also pings the founders' phones. Never fails the
run itself.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request

SUPABASE_URL = os.environ.get('SUPABASE_URL', '').rstrip('/')
SERVICE_KEY = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')
GH_TOKEN = os.environ.get('GH_TOKEN', '')
REPO = os.environ.get('GITHUB_REPOSITORY', '')
RUN_ID = os.environ.get('GITHUB_RUN_ID', '')
API = 'https://api.github.com'
GH_HEADERS = {'Authorization': f'Bearer {GH_TOKEN}',
              'Accept': 'application/vnd.github+json',
              'X-GitHub-Api-Version': '2022-11-28'}
STAMP = re.compile(r'^\d{4}-\d\d-\d\dT[\d:.]+Z ')


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def gh(path):
    with urllib.request.urlopen(urllib.request.Request(API + path, headers=GH_HEADERS)) as r:
        return json.loads(r.read().decode())


def job_log(job_id):
    """The job's log as text. GitHub answers with a redirect to a
    signed address, which must be fetched without our token."""
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        with opener.open(urllib.request.Request(
                f'{API}/repos/{REPO}/actions/jobs/{job_id}/logs', headers=GH_HEADERS)) as r:
            return r.read().decode('utf-8', 'replace')
    except urllib.error.HTTPError as e:
        where = e.headers.get('Location') if e.code in (301, 302, 303, 307) else None
        if not where:
            raise
    with urllib.request.urlopen(where) as r:
        return r.read().decode('utf-8', 'replace')


def tail_of(log, limit=7000):
    """The 80 lines up to the last error mark, without time stamps."""
    lines = [STAMP.sub('', ln) for ln in log.splitlines()]
    marks = [i for i, ln in enumerate(lines) if '##[error]' in ln]
    end = (marks[-1] + 1) if marks else len(lines)
    return '\n'.join(lines[max(0, end - 80):end])[-limit:]


def sb(path, body, prefer):
    req = urllib.request.Request(
        f'{SUPABASE_URL}/rest/v1/{path}', data=json.dumps(body).encode(), method='POST',
        headers={'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}',
                 'Content-Type': 'application/json', 'Prefer': prefer})
    with urllib.request.urlopen(req) as r:
        return r.status


def overall(build, deploy):
    if 'failure' in (build, deploy):
        return 'failure'
    if build == 'success' and deploy == 'success':
        return 'success'
    return 'cancelled'


def main():
    build = os.environ.get('BUILD_RESULT', '')
    deploy = os.environ.get('DEPLOY_RESULT', '')
    result = overall(build, deploy)
    failed, tail = [], ''
    if result == 'failure':
        try:
            jobs = gh(f'/repos/{REPO}/actions/runs/{RUN_ID}/jobs?per_page=50').get('jobs') or []
            for j in jobs:
                if j.get('conclusion') != 'failure':
                    continue
                steps = [s['name'] for s in (j.get('steps') or [])
                         if s.get('conclusion') == 'failure']
                failed.append(f"{j.get('name')} > {', '.join(steps) or 'unknown step'}")
                if not tail:
                    try:
                        tail = tail_of(job_log(j['id']))
                    except Exception as e:  # noqa: BLE001
                        tail = f'(the log could not be read: {e})'
        except Exception as e:  # noqa: BLE001
            failed.append(f'(the jobs could not be read: {e})')
    row = {
        'run_id': int(RUN_ID or 0),
        'run_number': int(os.environ.get('GITHUB_RUN_NUMBER') or 0),
        'attempt': int(os.environ.get('GITHUB_RUN_ATTEMPT') or 1),
        'sha': os.environ.get('GITHUB_SHA', ''),
        'event': os.environ.get('GITHUB_EVENT_NAME', ''),
        'result': result, 'build': build, 'deploy': deploy,
        'failed': '; '.join(failed)[:500] or None,
        'log_tail': tail or None,
        'run_url': f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/{REPO}"
                   f'/actions/runs/{RUN_ID}',
    }
    print(json.dumps({k: v for k, v in row.items() if k != 'log_tail'}, indent=2))
    if not (SUPABASE_URL and SERVICE_KEY):
        print('no Supabase keys; not recorded')
        return
    try:
        sb('build_runs?on_conflict=run_id', row, 'resolution=merge-duplicates,return=minimal')
    except Exception as e:  # noqa: BLE001
        print(f'not recorded: {e}')
    if result == 'failure':
        try:
            sb('rpc/notify_phone',
               {'p_title': f"Build #{row['run_number']} failed",
                'p_message': (row['failed'] or 'see the run')[:200],
                'p_tags': 'warning'}, 'return=minimal')
        except Exception:  # noqa: BLE001
            pass


if __name__ == '__main__':
    try:
        main()
    except Exception as e:  # noqa: BLE001
        print(f'report_build: {e}')
    sys.exit(0)
