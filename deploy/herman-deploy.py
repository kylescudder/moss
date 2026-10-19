#!/usr/bin/env python3
"""Deploy independently verified main images, consuming the newest queued request."""
from datetime import datetime, timezone
from contextlib import contextmanager
import base64
import tempfile
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid

IMAGE = 'ghcr.io/kylescudder/moss-site'
REPO = 'kylescudder/moss'
DIGEST = re.compile(r'sha256:[0-9a-f]{64}\Z')
REVISION = re.compile(r'[0-9a-f]{40}\Z')
REGISTRY_TOKEN = re.compile(r'[-A-Za-z0-9._~+/]{20,4096}={0,2}\Z')
APP = Path(os.environ.get('APP_DIR', Path(__file__).resolve().parents[1]))
STATE = APP / 'state'
BACKUPS = APP / 'backups'
REQUESTS = APP / 'deploy-spool/requests'


class Error(RuntimeError):
    pass


def log(message):
    print(f'[moss-deploy] {datetime.now(timezone.utc).isoformat()} {message}', flush=True)


def run(args, *, output=None, input_data=None, env=None, timeout=300):
    try:
        result = subprocess.run(args, cwd=APP, input=input_data, env=env,
                                stdout=output if output is not None else subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise Error(f'{args[0]} operation timed out.') from None
    if result.returncode:
        # Command stderr and resolved environment can contain production credentials.
        raise Error(f'{args[0]} {args[1]} operation failed (exit {result.returncode}).')
    return result.stdout or b''


def compose(*args, image=None, output=None):
    env = os.environ.copy()
    if image:
        env['MOSS_IMAGE'] = image
    return run(['docker', 'compose', '--project-directory', str(APP), '-f', str(APP / 'compose.yaml'),
                '--env-file', str(APP / '.env'), *args], env=env, output=output, timeout=180)


def private_env(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_mode & 0o077:
        raise Error(f'{path.name} must be a protected regular file (0600).')
    values = {}
    for line in path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        key, sep, value = line.partition('=')
        if not sep or not re.fullmatch(r'[A-Z][A-Z0-9_]*', key):
            raise Error(f'{path.name} contains an invalid environment entry.')
        values[key] = value.strip().strip('"\'')
    return values


def save_json(path, value):
    temp = path.with_name(path.name + '.next')
    with temp.open('w') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    temp.chmod(0o600)
    temp.replace(path)


def take_request():
    # Consume this snapshot only. Arrivals during deployment start the next run.
    if REQUESTS.is_symlink() or REQUESTS.parent.is_symlink():
        raise Error('Queue directories must not be symlinks.')
    # A receiver crash can leave a partial file. Remove old partials so launchd
    # does not keep restarting on a nonempty directory with no ready requests.
    for partial in REQUESTS.glob('.*.json.tmp'):
        if not partial.is_symlink() and partial.is_file() and time.time() - partial.stat().st_mtime > 30:
            partial.unlink()
    paths = sorted(REQUESTS.glob('*.json'))
    if not paths:
        return None
    valid = []
    for path in paths:
        try:
            if path.is_symlink() or path.stat().st_size > 8192:
                raise ValueError()
            value = json.loads(path.read_text())
            if not DIGEST.fullmatch(value.get('digest', '')) or not REVISION.fullmatch(value.get('revision', '')):
                raise ValueError()
            if type(value.get('timestamp')) is not int:
                raise ValueError()
            if value.get('registryToken') is not None and (not isinstance(value['registryToken'], str) or not REGISTRY_TOKEN.fullmatch(value['registryToken'])):
                raise ValueError()
            valid.append((value['timestamp'], path.name, value))
        except (ValueError, TypeError, OSError, AttributeError):
            log('discarded malformed queue entry')
    selected = max(valid, key=lambda entry:entry[:2])[2] if valid else None
    if selected:
        save_json(STATE / 'last-request.json', {k:v for k,v in selected.items() if k != 'registryToken'})
    for path in paths:
        if path.is_dir() and not path.is_symlink():
            path.rename(STATE / ('rejected-directory-' + uuid.uuid4().hex))
        else:
            path.unlink(missing_ok=True)
    return selected


def pin(image):
    path = APP / '.env'
    lines = [line for line in path.read_text().splitlines() if not line.startswith('MOSS_IMAGE=')]
    temp = path.with_name('.env.next')
    temp.write_text('\n'.join(lines) + f'\nMOSS_IMAGE={image}\n')
    temp.chmod(0o600)
    temp.replace(path)


def start(image):
    compose('up', '-d', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '120', 'moss', image=image)


def verify(image):
    assets = set()
    for path, expected in [('/', 'Travel, together'), ('/privacy/', 'Privacy'),
                           ('/terms/', 'Terms'), ('/support/', 'Support')]:
        html = compose('exec', '-T', 'moss', 'wget', '-qO-', 'http://127.0.0.1:8080' + path, image=image).decode()
        if expected not in html or 'mailto:support@getmoss.app' not in html:
            raise Error('Site content verification failed for ' + path)
        assets.update(re.findall(r'(?:src|href)="(/(?:_astro/|assets/)[^"]+)"', html))
    if not assets or not any('/_astro/' in asset for asset in assets):
        raise Error('Expected built site assets were missing.')
    for asset in sorted(assets):
        compose('exec', '-T', 'moss', 'wget', '-qO', '/dev/null',
                'http://127.0.0.1:8080' + asset, image=image)
    association = json.loads(compose('exec', '-T', 'moss', 'wget', '-qO-',
                       'http://127.0.0.1:8080/.well-known/apple-app-site-association', image=image))
    if association.get('applinks', {}).get('details', [{}])[0].get('appIDs') != ['6AAGJ9Y234.app.getmoss.moss']:
        raise Error('Apple app-site association verification failed.')


def publish_status(image, revision):
    directory = STATE / 'public'
    directory.mkdir(mode=0o700, exist_ok=True)
    save_json(directory / 'deployment.json', {'revision':revision, 'image':image})


def inspect_current(container):
    raw = run(['docker', 'inspect', '--format',
               '{{json .Config.Image}}|{{json .State}}|{{json .Config.Labels}}', container])
    image, state, labels = [json.loads(part) for part in raw.decode().strip().split('|', 2)]
    return {'Config': {'Image': image, 'Labels': labels}, 'State': state}


@contextmanager
def registry_credentials(token):
    if token is None:
        yield None
        return
    if not isinstance(token, str) or not REGISTRY_TOKEN.fullmatch(token):
        raise Error('Invalid temporary registry credential.')
    # The release job supplies a read-only, job-lifetime token. Its protected
    # queue file is consumed immediately; registry config is removed even on error.
    with tempfile.TemporaryDirectory(prefix='moss-registry-') as folder:
        config = Path(folder) / 'config.json'
        credential = base64.b64encode((REPO.split('/')[0] + ':' + token).encode()).decode()
        config.write_text(json.dumps({'auths':{'ghcr.io':{'auth':credential}}}))
        config.chmod(0o600)
        env = os.environ.copy()
        # A temporary DOCKER_CONFIG must retain Colima's active daemon endpoint.
        if not env.get('DOCKER_HOST'):
            endpoint = run(['docker', 'context', 'inspect', '--format', '{{.Endpoints.docker.Host}}']).decode().strip()
            if not endpoint.startswith('unix://'):
                raise Error('Expected Herman\'s local Docker socket.')
            env['DOCKER_HOST'] = endpoint
        env.pop('DOCKER_CONTEXT', None)
        env.update({'DOCKER_CONFIG':folder, 'GH_TOKEN':token})
        yield env


def deploy(digest, requested_revision=None, registry_token=None):
    if not DIGEST.fullmatch(digest):
        raise Error('Use an exact sha256 digest.')
    private_env(APP / '.env')
    candidate = f'{IMAGE}@{digest}'
    ids = compose('ps', '-a', '-q', 'moss').decode().strip().splitlines()
    if len(ids) > 1:
        raise Error('Expected a single Moss container.')
    current = inspect_current(ids[0]) if ids else None
    running = current['Config']['Image'] if current else None
    if running == candidate and current['State'].get('Health', {}).get('Status') == 'healthy':
        revision = (current['Config'].get('Labels') or {}).get('org.opencontainers.image.revision', '')
        if not REVISION.fullmatch(revision) or requested_revision and requested_revision != revision:
            raise Error('Running image revision does not match the request.')
        log('requested digest is already healthy')
        verify(candidate)
        pin(candidate)
        publish_status(candidate, revision)
        return
    log(f'verifying {candidate}')
    with registry_credentials(registry_token) as registry_env:
        run(['gh', 'attestation', 'verify', f'oci://{candidate}', '--bundle-from-oci', '--repo', REPO,
             '--signer-workflow', REPO + '/.github/workflows/release-site.yml', '--source-ref', 'refs/heads/main',
             '--deny-self-hosted-runners'], timeout=180, env=registry_env)
        run(['docker', 'pull', '--quiet', candidate], timeout=300, env=registry_env)
    labels = json.loads(run(['docker', 'image', 'inspect', '--format', '{{json .Config.Labels}}', candidate])) or {}
    revision = labels.get('org.opencontainers.image.revision', '')
    if not REVISION.fullmatch(revision) or requested_revision and requested_revision != revision:
        raise Error('Verified image revision does not match the request.')
    log(f'provenance verified for {revision}')
    try:
        start(candidate)
        verify(candidate)
    except Error:
        log('candidate failed health check')
        if running and running != candidate:
            try:
                start(running)
                verify(running)
                pin(running)
                log('previous image restored')
            except Error:
                raise Error('ROLLBACK FAILED; inspect the private deployment logs.') from None
        else:
            compose('stop', 'moss', image=candidate)
        raise Error('Candidate was not healthy; deploy failed.') from None
    pin(candidate)
    stamp = datetime.now(timezone.utc).isoformat()
    with (STATE / 'history.log').open('a') as stream:
        stream.write(f'{stamp} {candidate} {revision}\n')
    save_json(STATE / 'deployment.json', {'deployed_at':stamp, 'image':candidate, 'revision':revision, 'previous_image':running})
    publish_status(candidate, revision)
    log(f'healthy on {candidate}')


def main():
    os.umask(0o077)
    for folder in (STATE, BACKUPS, REQUESTS):
        folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (STATE / 'deploy.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if len(sys.argv) > 2:
            raise Error('Usage: herman-deploy.sh [sha256:<digest>]')
        request = {'digest':sys.argv[1]} if len(sys.argv) == 2 else take_request()
        if request is None:
            log('no queued requests')
            return
        try:
            deploy(request['digest'], request.get('revision'), request.get('registryToken'))
        except Error as error:
            save_json(STATE / 'last-failure.json', {'failed_at':datetime.now(timezone.utc).isoformat(),
                      'digest':request['digest'], 'error':str(error)})
            raise


if __name__ == '__main__':
    try:
        main()
    except (Error, OSError, ValueError, KeyError) as error:
        log(str(error) if isinstance(error, Error) else f'Deploy failed: {type(error).__name__}.')
        sys.exit(1)
