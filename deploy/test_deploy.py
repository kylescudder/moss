"""Security gates, queue handling and rollback without production changes."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('deployer', Path(__file__).with_name('herman-deploy.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
D = 'sha256:' + 'a' * 64
R = 'b' * 40


class Deploy(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.app = Path(self.temp.name)
        self.patches = [patch.object(module, k, self.app / v) for k,v in
                        [('APP','.'),('STATE','state'),('BACKUPS','backups'),('REQUESTS','requests')]]
        for p in self.patches:p.start()
        for d in (module.STATE,module.BACKUPS,module.REQUESTS):d.mkdir()
        for f in ('.env',):
            p=self.app/f;p.write_text('MOSS_IMAGE=fixture\n');p.chmod(0o600)
        self.calls=[]
        self.verifier = patch.object(module, 'verify')
        self.verifier.start()
        self.patches.append(self.verifier)

    def tearDown(self):
        for p in reversed(self.patches):p.stop()
        self.temp.cleanup()

    def queue(self, name, timestamp, digest=D):
        (module.REQUESTS/name).write_text(json.dumps({'digest':digest,'revision':R,'timestamp':timestamp}))

    def test_newest_valid_request_wins_and_malformed_is_consumed(self):
        self.queue('old.json',10)
        self.queue('new.json',20,'sha256:'+'c'*64)
        (module.REQUESTS/'broken.json').write_text('{')
        self.assertEqual(module.take_request()['timestamp'],20)
        self.assertEqual(list(module.REQUESTS.iterdir()),[])
        self.assertIsNone(module.take_request())

    def test_symlink_cannot_read_outside_queue(self):
        private=self.app/'private';private.write_text('keep')
        (module.REQUESTS/'link.json').symlink_to(private)
        self.assertIsNone(module.take_request())
        self.assertEqual(private.read_text(),'keep')

    def test_replaced_queue_directory_is_rejected_without_touching_target(self):
        module.REQUESTS.rmdir()
        target=self.app/'other';target.mkdir()
        (target/'private.json').write_text('keep')
        module.REQUESTS.symlink_to(target)
        with self.assertRaises(module.Error):module.take_request()
        self.assertEqual((target/'private.json').read_text(),'keep')

    def test_malformed_directory_is_quarantined_without_a_launch_loop(self):
        (module.REQUESTS/'bad.json').mkdir()
        self.assertIsNone(module.take_request())
        self.assertEqual(list(module.REQUESTS.iterdir()),[])
        self.assertEqual(len(list(module.STATE.glob('rejected-directory-*'))),1)

    def test_stale_partial_is_removed_and_fresh_partial_is_left_alone(self):
        stale=module.REQUESTS/'.old.json.tmp';stale.write_text('partial');os.utime(stale,(0,0))
        fresh=module.REQUESTS/'.new.json.tmp';fresh.write_text('partial')
        self.assertIsNone(module.take_request())
        self.assertFalse(stale.exists())
        self.assertTrue(fresh.exists())

    def test_healthy_same_digest_requires_the_requested_revision(self):
        current={'Config':{'Image':module.IMAGE+'@'+D,'Labels':{'org.opencontainers.image.revision':R}},
                 'State':{'Running':True,'Health':{'Status':'healthy'}}}
        with patch.object(module,'inspect_current',return_value=current),patch.object(module,'compose',self.fake_compose),patch.object(module,'start') as start:
            with self.assertRaises(module.Error):module.deploy(D,'c'*40)
            module.deploy(D,R)
            start.assert_not_called()

    def fake_run(self, args, **kwargs):
        self.calls.append(args)
        if args[:2]==['docker','inspect']:
            return b'"previous"|{"Running":true,"Health":{"Status":"healthy"}}|{}'
        if args[:3]==['docker','image','inspect']:
            return json.dumps({'org.opencontainers.image.revision':R}).encode()
        return b''

    def fake_compose(self,*args,**kwargs):
        if args[0]=='ps':return b'container\n'
        if args[0]=='exec':kwargs['output'].write(b'{"films":[]}')
        return b''

    def test_failed_verification_never_migrates_or_starts(self):
        def run(args,**kwargs):
            if args[0]=='gh':raise module.Error('verification rejected')
            return self.fake_run(args,**kwargs)
        with patch.object(module,'run',run),patch.object(module,'compose',self.fake_compose),patch.object(module,'start') as start:
            with self.assertRaises(module.Error):module.deploy(D,R)
            start.assert_not_called()
        self.assertFalse(any(c[:2]==['docker','run'] for c in self.calls))

    def test_revision_mismatch_never_migrates_or_starts(self):
        with patch.object(module,'run',self.fake_run),patch.object(module,'compose',self.fake_compose),patch.object(module,'start') as start:
            with self.assertRaises(module.Error):module.deploy(D,'c'*40)
            start.assert_not_called()
        self.assertFalse(any(c[:2]==['docker','run'] for c in self.calls))

    def test_failed_health_restores_previous_and_does_not_record_success(self):
        with patch.object(module,'run',self.fake_run),patch.object(module,'compose',self.fake_compose),patch.object(module,'start',side_effect=[module.Error('unhealthy'),None]) as start:
            with self.assertRaises(module.Error):module.deploy(D,R)
            self.assertEqual([c.args[0] for c in start.call_args_list],[module.IMAGE+'@'+D,'previous'])
        self.assertFalse((module.STATE/'history.log').exists())
        self.assertIn('MOSS_IMAGE=previous',(self.app/'.env').read_text())

    def test_failed_acceptance_never_publishes_status(self):
        with patch.object(module,'run',self.fake_run),patch.object(module,'compose',self.fake_compose),patch.object(module,'start'),patch.object(module,'verify',side_effect=[module.Error('assets missing'),None]):
            with self.assertRaises(module.Error):module.deploy(D,R)
        self.assertFalse((module.STATE/'public/deployment.json').exists())
        self.assertIn('MOSS_IMAGE=previous',(self.app/'.env').read_text())

    def test_success_is_pinned_and_new_arrival_remains_queued(self):
        def start(image):self.queue('arriving.json',30)
        with patch.object(module,'run',self.fake_run),patch.object(module,'compose',self.fake_compose),patch.object(module,'start',start):module.deploy(D,R)
        self.assertIn(module.IMAGE+'@'+D,(self.app/'.env').read_text())
        self.assertTrue((module.STATE/'history.log').exists())
        self.assertTrue((module.REQUESTS/'arriving.json').exists())
        self.assertEqual(json.loads((module.STATE/'public/deployment.json').read_text()), {'image':module.IMAGE+'@'+D,'revision':R})


    def test_registry_token_is_consumed_without_recording_it(self):
        value = {'digest':D, 'revision':R, 'timestamp':10, 'registryToken':'fixture-job-token-' + 'a'*32}
        (module.REQUESTS/'request.json').write_text(json.dumps(value))
        self.assertEqual(module.take_request()['registryToken'], value['registryToken'])
        self.assertNotIn('registryToken', (module.STATE/'last-request.json').read_text())
        self.assertEqual(list(module.REQUESTS.iterdir()), [])

    def test_registry_config_is_temporary_even_on_error(self):
        with patch.dict(os.environ, {'DOCKER_HOST':'unix:///fixture.sock'}):
            with self.assertRaises(RuntimeError):
                with module.registry_credentials('fixture-job-token-' + 'a'*32) as env:
                    folder = Path(env['DOCKER_CONFIG'])
                    self.assertTrue((folder/'config.json').is_file())
                    self.assertEqual((folder/'config.json').stat().st_mode & 0o777, 0o600)
                    self.assertEqual(env['GH_TOKEN'], 'fixture-job-token-' + 'a'*32)
                    raise RuntimeError('fixture failure')
            self.assertFalse(folder.exists())

    def test_provenance_is_restricted_to_main_and_this_workflow(self):
        with patch.object(module,'run',self.fake_run), patch.object(module,'compose',self.fake_compose), patch.object(module,'start'):
            module.deploy(D,R)
        args = next(call for call in self.calls if call[0]=='gh')
        self.assertEqual(args[args.index('--source-ref')+1], 'refs/heads/main')
        self.assertEqual(args[args.index('--signer-workflow')+1], module.REPO+'/.github/workflows/release-site.yml')
        self.assertIn('--deny-self-hosted-runners', args)


if __name__=='__main__':unittest.main()
