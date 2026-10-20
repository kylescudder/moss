#!/usr/bin/env python3
"""Moss settings and hooks for the shared host deployer (deploy_core.py)."""
import json
from pathlib import Path
import re

import deploy_core as core


def accept(image):
    assets = set()
    for path, expected in [('/', 'Travel, together'), ('/privacy/', 'Privacy'),
                           ('/terms/', 'Terms'), ('/support/', 'Support')]:
        html = core.compose('exec', '-T', 'moss', 'wget', '-qO-', 'http://127.0.0.1:8080' + path, image=image).decode()
        if expected not in html or 'mailto:support@getmoss.app' not in html:
            raise core.Error('Site content verification failed for ' + path)
        assets.update(re.findall(r'(?:src|href)="(/(?:_astro/|assets/)[^"]+)"', html))
    if not assets or not any('/_astro/' in asset for asset in assets):
        raise core.Error('Expected built site assets were missing.')
    for asset in sorted(assets):
        core.compose('exec', '-T', 'moss', 'wget', '-qO', '/dev/null',
                     'http://127.0.0.1:8080' + asset, image=image)
    association = json.loads(core.compose('exec', '-T', 'moss', 'wget', '-qO-',
                             'http://127.0.0.1:8080/.well-known/apple-app-site-association', image=image))
    if association.get('applinks', {}).get('details', [{}])[0].get('appIDs') != ['6AAGJ9Y234.app.getmoss.moss']:
        raise core.Error('Apple app-site association verification failed.')


APP = core.App(
    name='moss', title='Moss',
    image='ghcr.io/kylescudder/moss-site', repo='kylescudder/moss',
    image_var='MOSS_IMAGE', service='moss', app_dir=Path(__file__).resolve().parents[1],
    workflow='release-site.yml',
    accept=accept,
    public_status=True)

if __name__ == '__main__':
    core.cli(APP, __file__)
