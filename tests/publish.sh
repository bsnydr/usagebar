#!/usr/bin/env bash
# Behavior tests for publish.sh (UsageBar). Bash wrapper; fixtures built with Python3 stdlib.
# Python is a dev/CI dependency only. Uses local bare origins, isolated git env, no network.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
[ -f "$ROOT/publish.sh" ] || { echo 'publish.sh not found next to tests/' >&2; exit 2; }
export UB_ROOT="$ROOT"
exec python3 -I - "$@" <<'PY'
import os, sys, shutil, subprocess, tempfile
J = os.path.join
ROOT = os.environ['UB_ROOT']
NL = chr(10)
# markers are assembled from fragments so this public source never holds them whole
KEY = '-----BEGIN ' + 'RSA PRIVATE ' + 'KEY-----'
TOKEN = 'gh' + 'p_' + 'Ab12' * 9

def redact(s):
    return s.replace(KEY, '<key-marker>').replace(TOKEN, '<token-marker>')

class F:
    def __init__(s, base):
        s.base, s.last = base, ''
        s.home, s.origin, s.work = J(base, 'home'), J(base, 'origin.git'), J(base, 'work')
        for d in ('home', 'nohooks', 'tmp'):
            os.makedirs(J(base, d))
        ident = {'NAME': 'Fixture User', 'EMAIL': 'fixture@example.invalid'}
        s.env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': s.home,
                 'XDG_CONFIG_HOME': s.home, 'TMPDIR': J(base, 'tmp'), 'LC_ALL': 'C',
                 'GIT_CONFIG_GLOBAL': os.devnull, 'GIT_CONFIG_SYSTEM': os.devnull,
                 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_TERMINAL_PROMPT': '0',
                 'GIT_OPTIONAL_LOCKS': '0'}
        for who in ('AUTHOR', 'COMMITTER'):
            for k, v in ident.items():
                s.env['GIT_%s_%s' % (who, k)] = v
        s.git('init', '-q', '--bare', '-b', 'main', s.origin, cwd=base)
        s.git('init', '-q', '-b', 'main', s.work, cwd=base)
        shutil.copy2(J(ROOT, 'publish.sh'), J(s.work, 'publish.sh'))
        s.w('test.sh', '#!/bin/bash' + NL + 'exit 0' + NL)
        os.chmod(J(s.work, 'test.sh'), 0o755)
        s.w('UsageBar.swift', 'let usage = 1' + NL)
        s.w('README.md', '# UsageBar' + NL)
        s.w('.gitignore', '.env' + NL)
        for k, v in (('user.name', 'Fixture User'), ('user.email', 'fixture@example.invalid'),
                     ('core.hooksPath', J(base, 'nohooks')), ('commit.gpgsign', 'false'),
                     ('tag.gpgsign', 'false'), ('usagebar.autopush', 'true'),
                     ('usagebar.publishRemote', s.origin), ('usagebar.publishBranch', 'main')):
            s.git('config', k, v)
        s.git('remote', 'add', 'origin', s.origin)
        s.git('add', '-A')
        s.git('commit', '-q', '-m', 'baseline')
        s.git('push', '-q', '-u', 'origin', 'main')
        s.base_sha = s.sha()

    def git(s, *a, cwd=None):
        r = subprocess.run(['git', *a], cwd=cwd or s.work, env=s.env, capture_output=True,
                           text=True, stdin=subprocess.DEVNULL)
        if r.returncode:
            raise RuntimeError(redact('git %s failed: %s' % (' '.join(a), r.stderr)))
        return r.stdout.strip()

    def sha(s, ref='HEAD'):
        return s.git('rev-parse', ref)

    def rsha(s, origin=None):
        return s.git('rev-parse', 'refs/heads/main', cwd=origin or s.origin)

    def w(s, path, data, mode='w'):
        with open(J(s.work, path), mode) as fh:
            fh.write(data)

    def commit(s, path, data, msg):
        if data is None:
            s.git('rm', '-q', path)
        else:
            s.w(path, data)
            s.git('add', path)
        s.git('commit', '-q', '-m', msg)

    def run(s, msg=None, extra=None):
        try:
            r = subprocess.run(['bash', 'publish.sh'] + ([msg] if msg else []), cwd=s.work,
                               env=dict(s.env, **(extra or {})), capture_output=True, text=True, errors='replace',
                               stdin=subprocess.DEVNULL, timeout=120)
            s.last = r.stdout + r.stderr
            return r.returncode
        except subprocess.TimeoutExpired:
            s.last = 'timeout'
            return 124

def snap(f):
    tree = {}
    for d, ds, fs in os.walk(f.work):
        if '.git' in ds:
            ds.remove('.git')
        for n in fs + [x for x in ds if os.path.islink(J(d, x))]:
            p = J(d, n)
            tree[p] = (os.lstat(p).st_mode, os.readlink(p) if os.path.islink(p) else open(p, 'rb').read())
    gd = J(f.work, '.git')
    head = open(J(gd, 'HEAD')).read()
    # raw bytes of the real index, any shared index and any lock, so a silent rewrite or refresh is visible
    files = {}
    for n in sorted(os.listdir(gd)):
        if n == 'index' or n == 'index.lock' or n.startswith('sharedindex.'):
            files[n] = open(J(gd, n), 'rb').read()
    return (tree, f.git('ls-files', '-s'), f.git('ls-files', '-v'),
            f.git('for-each-ref', 'refs/heads', 'refs/tags'),
            head, os.path.exists(J(gd, 'MERGE_HEAD')), files)

def chk(f, cond, msg):
    if not cond:
        raise AssertionError(msg + NL + redact(f.last[-1200:]))

def lock_bytes(f):
    p = J(f.work, '.git', 'index.lock')
    return open(p, 'rb').read() if os.path.exists(p) else None

def tmp_left(f):
    return sorted(os.listdir(f.env['TMPDIR']))

def clean_after(f):
    chk(f, f.git('status', '--porcelain') == '', 'worktree not clean after publish')
    chk(f, f.git('diff', '--cached') == '', 'index differs from HEAD after publish')
    chk(f, lock_bytes(f) is None, 'index.lock left behind')
    chk(f, tmp_left(f) == [], 'fixture TMPDIR not empty after publish')

def stop(f, msg=None, why=None, extra=None):
    pre, r0, lock0 = snap(f), f.rsha(), lock_bytes(f)
    rc = f.run(msg, extra)
    chk(f, rc not in (0, 124), 'expected nonzero exit, got %d' % rc)
    chk(f, 'Publish: stopped:' in f.last, 'no stopped line in output')
    if why is not None:
        chk(f, why in f.last, 'missing stop reason: ' + why)
    chk(f, snap(f) == pre, 'source/index/refs changed')
    chk(f, f.rsha() == r0, 'remote changed')
    chk(f, lock_bytes(f) == lock0, 'index.lock was removed or changed')
    chk(f, tmp_left(f) == [], 'temporary directory left behind')

def pushed(f, msg=None):
    chk(f, f.run(msg) == 0, 'expected exit 0')
    chk(f, f.rsha() == f.sha(), 'remote tip is not local HEAD')
    clean_after(f)

def edit(f, p='UsageBar.swift'):
    f.w(p, '// edit' + NL, 'a')

CASES = []
def case(fn):
    CASES.append(fn)
    return fn

@case
def opted_out_no_commit(f):
    f.git('config', 'usagebar.autopush', 'false')
    edit(f)
    pre, r0 = snap(f), f.rsha()
    chk(f, f.run() == 0, 'disabled should exit 0')
    chk(f, snap(f) == pre and f.rsha() == r0, 'disabled run changed state')

@case
def normal_edit_explicit_message(f):
    edit(f)
    pushed(f, 'fixture: explicit message')
    chk(f, f.git('log', '-1', '--format=%s') == 'fixture: explicit message', 'subject mismatch')
    chk(f, f.sha('HEAD^') == f.base_sha, 'expected exactly one new commit')

@case
def default_message(f):
    edit(f)
    pushed(f)
    chk(f, f.sha() != f.base_sha, 'no commit created')
    chk(f, f.git('log', '-1', '--format=%s') == 'Update UsageBar', 'default subject mismatch')

@case
def clean_up_to_date(f):
    pre, r0 = snap(f), f.rsha()
    chk(f, f.run() == 0, 'up-to-date should exit 0')
    chk(f, snap(f) == pre and f.rsha() == r0, 'up-to-date run changed state')
    clean_after(f)

@case
def deleted_readme_committed(f):
    os.remove(J(f.work, 'README.md'))
    pushed(f)
    chk(f, f.git('ls-tree', 'main', '--', 'README.md', cwd=f.origin) == '', 'README still at remote')

@case
def failing_test_stops_before_commit(f):
    f.w('test.sh', '#!/bin/bash' + NL + 'exit 1' + NL)
    edit(f)
    stop(f)

@case
def partial_staged_preserved(f):
    edit(f, 'README.md')
    f.git('add', 'README.md')
    edit(f, 'README.md')
    stop(f)

@case
def unexpected_untracked_stops(f):
    edit(f)
    f.w('extra.txt', 'x' + NL)
    stop(f)

@case
def ignored_env_untouched_edit_publishes(f):
    f.w('.env', 'TOKEN=1' + NL)
    edit(f)
    pushed(f)
    chk(f, f.sha() != f.base_sha, 'no commit created')
    chk(f, '.env' not in f.git('ls-tree', '-r', '--name-only', 'main', cwd=f.origin), '.env published')
    chk(f, open(J(f.work, '.env')).read() == 'TOKEN=1' + NL, '.env modified')

@case
def symlink_allowed_name_stops(f):
    os.remove(J(f.work, 'README.md'))
    os.symlink('UsageBar.swift', J(f.work, 'README.md'))
    stop(f)

@case
def pending_clean_commit_pushes(f):
    f.commit('UsageBar.swift', 'let usage = 2' + NL, 'pending')
    pushed(f)

@case
def pending_secret_file_removed_later(f):
    f.commit('secrets.txt', KEY + NL, 'add')
    f.commit('secrets.txt', None, 'remove')
    stop(f)
    chk(f, KEY not in f.last, 'marker leaked in output')

@case
def pending_secret_in_allowed_file_removed_later(f):
    f.commit('README.md', '# x' + NL + KEY + NL, 'add')
    f.commit('README.md', '# UsageBar' + NL, 'clean')
    stop(f)
    chk(f, KEY not in f.last, 'marker leaked in output')

@case
def detached_head_stops(f):
    f.git('checkout', '-q', '--detach')
    edit(f)
    stop(f)

@case
def wrong_branch_stops(f):
    f.git('checkout', '-q', '-b', 'other')
    edit(f)
    stop(f)

@case
def merge_head_stops(f):
    f.w(J('.git', 'MERGE_HEAD'), f.sha() + NL)
    edit(f)
    stop(f)

@case
def wrong_expected_url_stops(f):
    f.git('config', 'usagebar.publishRemote', J(f.base, 'other.git'))
    edit(f)
    stop(f)

@case
def multiple_pushurls_stop(f):
    for u in (f.origin, J(f.base, 'second.git')):
        f.git('config', '--add', 'remote.origin.pushurl', u)
    edit(f)
    stop(f)

@case
def configured_fork_destination_works(f):
    fork = J(f.base, 'fork.git')
    f.git('init', '-q', '--bare', '-b', 'main', fork, cwd=f.base)
    f.git('push', '-q', fork, 'main')
    f.git('remote', 'set-url', 'origin', fork)
    f.git('config', 'usagebar.publishRemote', fork)
    edit(f)
    chk(f, f.run() == 0, 'expected exit 0')
    chk(f, f.rsha(fork) == f.sha(), 'fork tip is not local HEAD')
    chk(f, f.rsha() == f.base_sha, 'original origin changed')
    clean_after(f)

@case
def remote_advanced_stops(f):
    other = J(f.base, 'other')
    f.git('clone', '-q', f.origin, other, cwd=f.base)
    with open(J(other, 'README.md'), 'a') as fh:
        fh.write('advance' + NL)
    f.git('commit', '-q', '-am', 'advance', cwd=other)
    f.git('push', '-q', 'origin', 'main', cwd=other)
    edit(f)
    stop(f)

@case
def receive_hook_rejects_push(f):
    hook = J(f.origin, 'hooks', 'pre-receive')
    with open(hook, 'w') as fh:
        fh.write('#!/bin/sh' + NL + 'echo rejected >&2' + NL + 'exit 1' + NL)
    os.chmod(hook, 0o755)
    edit(f)
    chk(f, f.run() not in (0, 124), 'expected nonzero exit')
    chk(f, f.rsha() == f.base_sha, 'remote changed despite rejection')
    chk(f, f.sha() != f.base_sha, 'local commit was not kept')
    chk(f, f.sha('HEAD^') == f.base_sha, 'expected exactly one kept local commit')
    chk(f, 'Publish: local commit kept, push failed' in f.last, 'wrong final line')
    clean_after(f)

@case
def followtags_annotated_tag_not_pushed(f):
    f.git('config', 'push.followTags', 'true')
    f.commit('UsageBar.swift', 'let usage = 3' + NL, 'tagged')
    f.git('tag', '-a', 'v-fixture', '-m', 'fixture tag')
    pushed(f)
    chk(f, f.git('tag', '-l', cwd=f.origin) == '', 'tag reached the remote')

@case
def failure_log_redacts_token(f):
    f.env['SYNTHETIC_MARKER'] = TOKEN
    f.w('test.sh', '#!/bin/bash' + NL + 'echo "$SYNTHETIC_MARKER" >&2' + NL + 'exit 1' + NL)
    edit(f)
    stop(f)
    chk(f, TOKEN not in f.last, 'token leaked in output')

@case
def missing_explicit_identity_stops(f):
    f.git('config', '--unset', 'user.email')
    edit(f)
    stop(f)

@case
def successful_test_changes_source_stops(f):
    f.w('test.sh', '#!/bin/bash' + NL + 'echo changed-during-test >> UsageBar.swift' + NL)
    edit(f)
    before, index = f.sha(), f.git('ls-files', '-s')
    chk(f, f.run() not in (0, 124), 'source race must stop')
    chk(f, f.sha() == before and f.rsha() == before, 'source race committed or pushed')
    chk(f, f.git('ls-files', '-s') == index, 'source race changed the index')
    chk(f, 'changed-during-test' in open(J(f.work, 'UsageBar.swift')).read(), 'test edit was discarded')

@case
def successful_test_changes_mode_stops(f):
    f.w('test.sh', '#!/bin/bash' + NL + 'chmod +x UsageBar.swift' + NL)
    edit(f)
    before, index = f.sha(), f.git('ls-files', '-s')
    chk(f, f.run() not in (0, 124), 'mode race must stop')
    chk(f, f.sha() == before and f.rsha() == before, 'mode race committed or pushed')
    chk(f, f.git('ls-files', '-s') == index, 'mode race changed index')
    chk(f, os.stat(J(f.work, 'UsageBar.swift')).st_mode & 0o111, 'test chmod discarded')

@case
def clean_filter_changed_bytes_stops(f):
    f.w(J('.git', 'info', 'attributes'), 'UsageBar.swift filter=fixture' + NL)
    f.git('config', 'filter.fixture.clean', "sed 's/let /var /g'")
    edit(f)
    stop(f)

@case
def secret_commit_message_stops(f):
    edit(f)
    stop(f, TOKEN)
    chk(f, TOKEN not in f.last, 'commit message leaked')

@case
def pending_secret_commit_message_stops(f):
    f.commit('UsageBar.swift', 'let usage = 5' + NL, TOKEN)
    stop(f)
    chk(f, TOKEN not in f.last, 'pending commit message leaked')

@case
def existing_index_lock_preserved(f):
    f.w(J('.git', 'index.lock'), 'owned-by-another-process' + NL)
    edit(f)
    stop(f, why='the git index is locked by another process')
    chk(f, open(J(f.work, '.git', 'index.lock')).read() == 'owned-by-another-process' + NL,
        'another process lock was removed or changed')

@case
def client_hooks_are_skipped(f):
    for hook in ('pre-commit', 'pre-push'):
        path = J(f.base, 'nohooks', hook)
        with open(path, 'w') as out:
            out.write('#!/bin/sh' + NL + 'touch "' + J(f.base, hook + '-ran') + '"' + NL)
        os.chmod(path, 0o755)
    edit(f)
    pushed(f)
    for hook in ('pre-commit', 'pre-push'):
        chk(f, not os.path.exists(J(f.base, hook + '-ran')), hook + ' ran')

@case
def concurrent_staging_preserved(f):
    f.w('test.sh', '#!/bin/bash' + NL + 'echo staged-during-test >> README.md' + NL + 'git add README.md' + NL)
    edit(f)
    before = f.sha()
    chk(f, f.run() not in (0, 124), 'staging race must stop')
    chk(f, f.sha() == before and f.rsha() == before, 'staging race committed or pushed')
    chk(f, 'staged-during-test' in f.git('diff', '--cached'), 'concurrent staging discarded')

@case
def concurrent_head_change_preserved(f):
    f.w('test.sh', '#!/bin/bash' + NL + 'echo other-commit >> README.md' + NL +
        'git add README.md' + NL + 'git commit -q -m concurrent' + NL)
    edit(f)
    before = f.sha()
    chk(f, f.run() not in (0, 124), 'HEAD race must stop')
    chk(f, f.sha() != before and f.rsha() == before, 'concurrent commit discarded or pushed')
    chk(f, f.git('log', '-1', '--format=%s') == 'concurrent', 'concurrent commit changed')

SPECIAL_TYPE_WHY = 'unpublished history contains a symlink, submodule or other unusual file type'
ENV_WHY = 'is set in the environment; unset it'

@case
def skip_worktree_stops(f):
    f.git('update-index', '--skip-worktree', 'README.md')
    chk(f, 'S README.md' in f.git('ls-files', '-v'), 'skip-worktree fixture not set')
    edit(f)
    stop(f, why='the index has skip-worktree, assume-unchanged')

@case
def assume_unchanged_stops(f):
    f.git('update-index', '--assume-unchanged', 'README.md')
    chk(f, 'h README.md' in f.git('ls-files', '-v'), 'assume-unchanged fixture not set')
    edit(f)
    stop(f, why='the index has skip-worktree, assume-unchanged')

@case
def configured_sparse_checkout_stops(f):
    f.git('config', 'core.sparseCheckout', 'true')
    os.makedirs(J(f.work, '.git', 'info'), exist_ok=True)
    f.w(J('.git', 'info', 'sparse-checkout'), '/*' + NL)
    chk(f, f.git('config', '--bool', 'core.sparseCheckout') == 'true', 'sparse fixture not set')
    edit(f)
    stop(f, why='a split or sparse index setup is not supported')

@case
def index_sparse_stops(f):
    f.git('config', 'index.sparse', 'true')
    chk(f, f.git('config', '--bool', 'index.sparse') == 'true', 'index.sparse fixture not set')
    edit(f)
    stop(f, why='a split or sparse index setup is not supported')

@case
def configured_split_index_stops(f):
    f.git('config', 'core.splitIndex', 'true')
    chk(f, f.git('config', '--bool', 'core.splitIndex') == 'true', 'splitIndex fixture not set')
    edit(f)
    stop(f, why='a split or sparse index setup is not supported')

@case
def shared_index_with_split_config_false_stops(f):
    f.git('update-index', '--split-index')
    f.git('config', 'core.splitIndex', 'false')
    shared = f.git('-c', 'core.splitIndex=true', 'rev-parse', '--shared-index-path')
    chk(f, shared != '', 'no shared index path: index is not split')
    chk(f, os.path.isfile(shared if os.path.isabs(shared) else J(f.work, shared)), 'shared index file missing')
    chk(f, f.git('config', '--bool', 'core.splitIndex') == 'false', 'splitIndex should be false')
    edit(f)
    stop(f, why='the index is a split index')

@case
def pending_symlink_stops(f):
    os.symlink('UsageBar.swift', J(f.work, 'build.sh'))
    f.git('add', 'build.sh')
    f.git('commit', '-q', '-m', 'pending symlink')
    chk(f, f.git('ls-files', '-s', 'build.sh').startswith('120000'), 'symlink fixture not committed')
    edit(f)
    stop(f, why=SPECIAL_TYPE_WHY)
    chk(f, 'build.sh' in f.last, 'offending path not reported')

@case
def pending_gitlink_stops(f):
    f.git('update-index', '--add', '--cacheinfo', '160000,%s,build.sh' % f.sha())
    f.git('commit', '-q', '-m', 'pending gitlink')
    os.makedirs(J(f.work, 'build.sh'))
    chk(f, f.git('ls-files', '-s', 'build.sh').startswith('160000'), 'gitlink fixture not committed')
    edit(f)
    stop(f, why=SPECIAL_TYPE_WHY)
    chk(f, 'build.sh' in f.last, 'offending path not reported')

@case
def pending_merge_commit_stops(f):
    f.git('checkout', '-q', '-b', 'side')
    f.commit('README.md', '# side' + NL, 'side')
    f.git('checkout', '-q', 'main')
    f.commit('UsageBar.swift', 'let usage = 6' + NL, 'main side')
    f.git('merge', '-q', '--no-ff', '-m', 'pending merge', 'side')
    chk(f, len(f.git('rev-list', '--parents', '-1', 'HEAD').split()) == 3, 'fixture is not a merge')
    edit(f)
    stop(f, why='an unpublished commit is a merge')

@case
def secret_author_metadata_stops(f):
    f.env['GIT_AUTHOR_NAME'] = TOKEN
    try:
        f.commit('UsageBar.swift', 'let usage = 7' + NL, 'pending author')
    finally:
        f.env['GIT_AUTHOR_NAME'] = 'Fixture User'
    chk(f, TOKEN in f.git('log', '-1', '--format=%an'), 'author fixture not set')
    edit(f)
    stop(f, why='commit message/author/committer')
    chk(f, 'possible secrets found by the heuristic scan' in f.last, 'scan did not stop the run')
    chk(f, TOKEN not in f.last, 'author marker leaked in output')

@case
def missing_remote_branch_stops(f):
    f.git('update-ref', '-d', 'refs/heads/main', cwd=f.origin)
    chk(f, f.git('for-each-ref', 'refs/heads', cwd=f.origin) == '', 'remote branch still exists')
    edit(f)
    # inline: stop() would look up the remote branch that is deliberately gone
    pre, lock0 = snap(f), lock_bytes(f)
    rc = f.run()
    chk(f, rc not in (0, 124), 'expected nonzero exit, got %d' % rc)
    chk(f, 'Publish: stopped:' in f.last, 'no stopped line in output')
    chk(f, 'the remote has no main branch' in f.last, 'missing-branch reason not reported')
    chk(f, snap(f) == pre, 'source/index/refs changed')
    chk(f, f.git('for-each-ref', 'refs/heads', cwd=f.origin) == '', 'publish created a remote branch')
    chk(f, lock_bytes(f) == lock0, 'index.lock was removed or changed')
    chk(f, tmp_left(f) == [], 'temporary directory left behind')

@case
def inherited_git_dir_stops(f):
    edit(f)
    stop(f, why=ENV_WHY, extra={'GIT_DIR': J(f.work, '.git')})

@case
def inherited_git_index_file_stops(f):
    alt = J(f.base, 'alt-index')
    edit(f)
    stop(f, why=ENV_WHY, extra={'GIT_INDEX_FILE': alt})
    chk(f, not os.path.exists(alt), 'inherited index file was created')

@case
def remote_moves_during_tests_keeps_local_commit(f):
    upstream = f.git('commit-tree', f.git('rev-parse', 'main^{tree}', cwd=f.origin),
                     '-p', f.base_sha, '-m', 'concurrent remote change', cwd=f.origin)
    f.env['FIXTURE_ORIGIN'] = f.origin
    f.env['FIXTURE_UPSTREAM'] = upstream
    f.w('test.sh', '#!/bin/bash' + NL +
        'git --git-dir="$FIXTURE_ORIGIN" update-ref refs/heads/main "$FIXTURE_UPSTREAM"' + NL)
    edit(f)
    chk(f, f.run() not in (0, 124), 'remote race must stop')
    chk(f, 'moved after it was checked' in f.last, 'did not reach remote recheck')
    chk(f, f.rsha() == upstream, 'concurrent remote change was overwritten')
    chk(f, f.sha() != f.base_sha and f.sha('HEAD^') == f.base_sha, 'reviewed local commit was not kept')
    clean_after(f)

@case
def final_compare_and_swap_failure_preserves_concurrent_head(f):
    racing = f.git('commit-tree', f.sha('HEAD^{tree}'), '-p', f.base_sha,
                   '-m', 'other concurrent commit')
    shimdir = J(f.base, 'shim')
    os.makedirs(shimdir)
    realgit = shutil.which('git', path=f.env['PATH'])
    marker = J(f.base, 'cas-race-injected')
    f.env.update({'FIXTURE_REAL_GIT': realgit, 'FIXTURE_RACING_COMMIT': racing,
                  'FIXTURE_RACE_MARKER': marker})
    shim = J(shimdir, 'git')
    with open(shim, 'w') as out:
        out.write('#!/bin/bash' + NL +
                  'if [ "$1" = update-ref ] && [ "$2" = -m ] && [ "$3" = "publish.sh: commit" ] && [ ! -e "$FIXTURE_RACE_MARKER" ]; then' + NL +
                  '  "$FIXTURE_REAL_GIT" update-ref "$4" "$FIXTURE_RACING_COMMIT" "$6" || exit 99' + NL +
                  '  : > "$FIXTURE_RACE_MARKER"' + NL + 'fi' + NL +
                  'exec "$FIXTURE_REAL_GIT" "$@"' + NL)
    os.chmod(shim, 0o755)
    f.env['PATH'] = shimdir + os.pathsep + f.env['PATH']
    edit(f)
    index = open(J(f.work, '.git', 'index'), 'rb').read()
    chk(f, f.run() not in (0, 124), 'compare-and-swap race must stop')
    chk(f, os.path.exists(marker), 'CAS race was never injected')
    chk(f, 'branch moved or could not be updated' in f.last, 'did not reach compare-and-swap refusal')
    chk(f, f.sha() == racing and f.rsha() == f.base_sha, 'concurrent head was replaced or pushed')
    chk(f, open(J(f.work, '.git', 'index'), 'rb').read() == index, 'failed CAS changed real index bytes')
    chk(f, not os.path.exists(J(f.work, '.git', 'index.lock')), 'failed CAS left index.lock')
    chk(f, not os.listdir(J(f.base, 'tmp')), 'failed CAS left scratch files')

@case
def signal_after_ref_update_finishes_owned_index(f):
    pidfile, marker = J(f.base, 'publisher-pid'), J(f.base, 'signal-hook-ran')
    f.env.update({'FIXTURE_PID_FILE': pidfile, 'FIXTURE_HOOK_MARKER': marker})
    f.w('test.sh', '#!/bin/bash' + NL + 'printf "%s\\n" "$PPID" > "$FIXTURE_PID_FILE"' + NL)
    hook = J(f.base, 'nohooks', 'reference-transaction')
    with open(hook, 'w') as out:
        out.write('#!/bin/sh' + NL +
                  'if [ "$1" = committed ] && [ -f "$FIXTURE_PID_FILE" ]; then' + NL +
                  '  : > "$FIXTURE_HOOK_MARKER"' + NL +
                  '  kill -TERM "$(cat "$FIXTURE_PID_FILE")"' + NL + 'fi' + NL + 'exit 0' + NL)
    os.chmod(hook, 0o755)
    edit(f)
    chk(f, f.run() == 143, 'expected caught termination after reference update')
    chk(f, os.path.exists(marker), 'reference hook did not inject signal')
    chk(f, f.sha() != f.base_sha and f.sha('HEAD^') == f.base_sha, 'reviewed local commit missing')
    chk(f, f.rsha() == f.base_sha, 'interrupted run pushed to remote')
    clean_after(f)

def main():
    bad = []
    for fn in CASES:
        base = os.path.realpath(tempfile.mkdtemp(prefix='ub-publish-'))
        try:
            fn(F(base))
            print('PASS ' + fn.__name__)
        except Exception as e:
            bad.append(fn.__name__)
            print('FAIL ' + fn.__name__ + ': ' + redact(str(e)))
        finally:
            shutil.rmtree(base, ignore_errors=True)
    print('%d passed, %d failed' % (len(CASES) - len(bad), len(bad)))
    if bad:
        print('failed: ' + ', '.join(bad))
    sys.exit(1 if bad else 0)

main()
PY
