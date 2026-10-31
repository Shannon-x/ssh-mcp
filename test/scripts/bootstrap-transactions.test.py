"""Isolated bootstrap transaction tests; never invokes SSH or real account tools.

All target paths are rewritten into TemporaryDirectory; account, systemd, sudo,
sshd and ownership commands are executable fixture stubs. Run with python3.
This does not replace real distro/sshd integration testing.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
SOURCE = (REPO / 'deploy/claudeops/bootstrap-hosts.sh').read_text()
BODY = SOURCE.split("cat <<'REMOTE'\n", 1)[1].split('\nREMOTE\n}', 1)[0]
STUB = r'''#!/usr/bin/env python3
import sys, os, json, pathlib, shutil
r=pathlib.Path(os.environ['FIXTURE_ROOT']); name=pathlib.Path(sys.argv[0]).name; a=sys.argv[1:]
f=r/'account.json'; d=json.loads(f.read_text()) if f.exists() else None
with (r/'calls').open('a') as out: out.write(name+' '+repr(a)+'\n')
def save():
 if d is None:
  if f.exists(): f.unlink()
 else: f.write_text(json.dumps(d))
if name=='id':
 if a==['-u']: print(0); sys.exit()
 if a==['-u','admin']: print(1000); sys.exit()
 if d is None: sys.exit(1)
 if a[0]=='-u': print(1001)
 elif a[0]=='-g': print(1001)
 elif a[0]=='-G': print('1001'+(' 190' if 'systemd-journal' in d['groups'] else ''))
 elif a[0]=='-nG': print(' '.join(['claudeops']+d['groups']))
 sys.exit()
if name=='stat':
 if a[1]=='%u': print(1001 if os.environ.get('UNSAFE_OWNER')==a[-1] else 0)
 elif a[1]=='%a': print(oct(pathlib.Path(a[-1]).stat().st_mode & 0o7777)[2:])
 else: raise RuntimeError('unexpected stat format')
 sys.exit()
if name=='getent':
 if a[0]=='group':
  if a[1]=='systemd-journal': print('systemd-journal:x:190:'); sys.exit()
  if a[1]=='claudeops' and d is not None: print('claudeops:x:1001:'); sys.exit()
  sys.exit(2)
 if d is None: sys.exit(2)
 if a[0]=='shadow': print('claudeops:'+d.get('password','*')+':1:0:99999:7::'+d['expiry']+':')
 else: print('claudeops:x:1001:1001::'+str(r/'home/claudeops')+':/bin/bash')
 sys.exit()
if name=='usermod':
 if '--expiredate' in a: d['expiry']=a[a.index('--expiredate')+1]
 if '-aG' in a: d['groups']+=a[a.index('-aG')+1].split(',')
 if '-G' in a: d['groups']=['systemd-journal'] if a[a.index('-G')+1]=='190' else []
 save(); sys.exit()
if name=='useradd':
 d={'groups':[], 'expiry':'', 'password':'*'}; save(); (r/'home/claudeops').mkdir(parents=True); sys.exit()
if name=='userdel':
 d=None; save(); shutil.rmtree(r/'home/claudeops', ignore_errors=True); sys.exit()
if name=='pkill':
 key=r/'etc/ssh/authorized_keys/claudeops'
 (r/'key-at-kill').write_text(key.read_text() if key.exists() else '<absent>')
 sys.exit()
if name in ('groupdel','logger','chown'): sys.exit()
if name=='sudo': sys.exit(0 if os.environ.get('HAS_SUDO')=='1' else 1)
if name=='install':
 mode=int(a[a.index('-m')+1],8) if '-m' in a else 0o755
 i=0
 while i<len(a):
  if a[i] in ('-o','-g','-m'): i+=2
  elif a[i]=='-d': i+=1
  else: pathlib.Path(a[i]).mkdir(parents=True,exist_ok=True); os.chmod(a[i],mode); i+=1
 if os.environ.get('ACCOUNT_APPEARS')=='1':
  d={'groups':[], 'expiry':'', 'password':'*'}; save()
 sys.exit()
if name=='systemctl':
 if a[0]=='is-active': sys.exit(0 if a[-1]=='ssh' else 1)
 sys.exit()
if name=='systemd-run':
 if os.environ.get('TIMER_FAIL')=='1': sys.exit(1)
 (r/'timer.json').write_text(json.dumps(a)); sys.exit()
if name=='sshd':
 if a[0]=='-t':
  n=int((r/'sshd-count').read_text())+1 if (r/'sshd-count').exists() else 1
  (r/'sshd-count').write_text(str(n))
  sys.exit(1 if n>1 and os.environ.get('SSHD_FAIL')=='1' else 0)
 if a[0]=='-T':
  if 'addr=192.0.2.254' in a[-1]: print('pubkeyauthentication no')
  else: print('authorizedkeysfile /etc/ssh/authorized_keys/%u\nauthenticationmethods publickey\npasswordauthentication no')
 sys.exit()
if name=='visudo':
 if '/dev/stdin' in a: sys.stdin.read()
 n=int((r/'visudo-count').read_text())+1 if (r/'visudo-count').exists() else 1
 (r/'visudo-count').write_text(str(n))
 sys.exit(1 if n>2 and os.environ.get('SUDO_FAIL')=='1' else 0)
raise RuntimeError('unexpected fixture command '+name)
'''

class Bootstrap(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='bootstrap-fixture-')
        self.root = Path(self.tmp.name)
        for path in ('etc/ssh/sshd_config.d','etc/ssh/authorized_keys','etc/sudoers.d','run/systemd/system','bin','home'):
            (self.root/path).mkdir(parents=True)
        (self.root/'etc/ssh/sshd_config').write_text('Include /etc/ssh/sshd_config.d/*.conf\n')
        for command in ('id','stat','getent','usermod','useradd','userdel','groupdel','pkill','logger','chown','sudo','install','systemctl','systemd-run','sshd','visudo'):
            p=self.root/'bin'/command; p.write_text(STUB); p.chmod(0o755)
        self.env={**os.environ,'PATH':str(self.root/'bin')+':'+os.environ['PATH'],'FIXTURE_ROOT':str(self.root),
                  'U':'claudeops','ROLE':'prod','MODE':'apply','APPLY':'1','HARDEN':'0','UNLOCK':'0','TIMEOUT':'30',
                  'CONTROL_PROBE':'203.0.113.10','CONTROL_IP':'203.0.113.10','EXTRA_GROUPS':'',
                  'KEYS_B64':'bmV3LWtleQ==','SSHD_B64':'bmV3LXNzaGQ=','SUDO_B64':'bmV3LXN1ZG8=','SUDO_USER':'admin'}
        body=BODY
        # Rewrite paths in target code AND generated controller, but preserve the
        # expected sshd output and Include regex through fixture content matching.
        for p in ('/etc/','/run/','/home/'):
            body=body.replace(p,str(self.root)+p)
        # Fixture sshd must emit the rewritten expected authorizedkeysfile path.
        for p in (self.root/'bin').iterdir():
            p.write_text(p.read_text().replace("print('authorizedkeysfile /etc/", "print('authorizedkeysfile "+str(self.root)+"/etc/"))
        (self.root/'etc/ssh/sshd_config').write_text('Include '+str(self.root)+'/etc/ssh/sshd_config.d/*.conf\n')
        self.script=self.root/'remote.sh';self.script.write_text(body)
    def tearDown(self): self.tmp.cleanup()
    def run_remote(self,**kwargs):
        return subprocess.run(['bash',str(self.script)],env={**self.env,**kwargs},text=True,capture_output=True,timeout=20)
    def existing(self, groups=None, expiry=''):
        (self.root/'account.json').write_text(json.dumps({'groups':groups or [],'expiry':expiry,'password':'*'}))
        (self.root/'home/claudeops').mkdir()
    def controller(self): return next((self.root/'run/claudeops-bootstrap').glob('txn.*/control.sh'))
    def control(self,action):
        return subprocess.run(['bash',str(self.controller()),action],env=self.env,text=True,capture_output=True,timeout=20)
    def test_dangerous_existing_group_stops_before_writes(self):
        self.existing(['docker']); r=self.run_remote(); self.assertEqual(r.returncode,3,r.stderr)
        self.assertNotIn('usermod ',(self.root/'calls').read_text());self.assertFalse((self.root/'run/claudeops-bootstrap').exists())
    def test_extra_groups_rejected_before_writes(self):
        r=self.run_remote(EXTRA_GROUPS='docker');self.assertEqual(r.returncode,3);self.assertFalse((self.root/'account.json').exists())
    def test_existing_sudo_stops_before_new_authorization(self):
        self.existing(); r=self.run_remote(HAS_SUDO='1');self.assertEqual(r.returncode,3)
        self.assertFalse((self.root/'etc/ssh/authorized_keys/claudeops').exists())
    def test_managed_directories_reject_unsafe_owner_or_permissions(self):
        for rel in ('etc/ssh/authorized_keys','etc/ssh/sshd_config.d','etc/sudoers.d'):
            p=self.root/rel
            for mode in (0o775,0o757):
                with self.subTest(path=rel,mode=mode):
                    p.chmod(mode); r=self.run_remote()
                    self.assertEqual(r.returncode,3,r.stdout+r.stderr)
                    self.assertFalse((self.root/'account.json').exists())
                    self.assertFalse((self.root/'run/claudeops-bootstrap').exists())
                p.chmod(0o755)
            with self.subTest(path=rel,owner=1001):
                r=self.run_remote(UNSAFE_OWNER=str(p))
                self.assertEqual(r.returncode,3,r.stdout+r.stderr)
                self.assertFalse((self.root/'account.json').exists())
                self.assertFalse((self.root/'run/claudeops-bootstrap').exists())
    def test_dry_run_is_no_mutation(self):
        r=self.run_remote(APPLY='0',MODE='plan');self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertFalse((self.root/'account.json').exists());self.assertFalse((self.root/'run/claudeops-bootstrap').exists())
    def test_timer_failure_precedes_mutations(self):
        r=self.run_remote(TIMER_FAIL='1');self.assertEqual(r.returncode,3,r.stdout+r.stderr)
        self.assertFalse((self.root/'account.json').exists());self.assertNotIn('useradd ',(self.root/'calls').read_text())
    def test_sshd_failure_removes_new_account_and_keys(self):
        r=self.run_remote(SSHD_FAIL='1');self.assertNotEqual(r.returncode,0)
        self.assertFalse((self.root/'account.json').exists(),r.stdout+r.stderr)
        self.assertFalse((self.root/'etc/ssh/authorized_keys/claudeops').exists())
        self.assertTrue((self.controller().parent/'rolled-back').exists())
    def test_rollback_restores_existing_files_groups_and_expiry(self):
        self.existing(expiry='1')
        files=['etc/ssh/authorized_keys/claudeops','etc/sudoers.d/claudeops','etc/ssh/sshd_config.d/10-claudeops.conf']
        for f in files: (self.root/f).write_text('original '+f)
        r=self.run_remote(UNLOCK='1',EXTRA_GROUPS='systemd-journal');self.assertEqual(r.returncode,10,r.stdout+r.stderr)
        rb=self.control('rollback');self.assertEqual(rb.returncode,0,rb.stdout+rb.stderr)
        for f in files:self.assertEqual((self.root/f).read_text(),'original '+f)
        self.assertEqual(json.loads((self.root/'account.json').read_text())['groups'],[])
        self.assertEqual(json.loads((self.root/'account.json').read_text())['expiry'],'1')
    def test_existing_rollback_kills_sessions_before_restoring_authorization(self):
        self.existing()
        key=self.root/'etc/ssh/authorized_keys/claudeops';key.write_text('original-key')
        r=self.run_remote();self.assertEqual(r.returncode,10,r.stdout+r.stderr)
        (self.root/'calls').write_text('')
        rb=self.control('rollback');self.assertEqual(rb.returncode,0,rb.stdout+rb.stderr)
        self.assertEqual((self.root/'key-at-kill').read_text().strip(),'new-key')
        self.assertEqual(key.read_text(),'original-key')
        calls=(self.root/'calls').read_text()
        self.assertEqual(calls.count('pkill '),1)
        self.assertIn("pkill ['-KILL', '-u', '1001']",calls)
        self.assertLess(calls.index("usermod ['--expiredate', '1'"),calls.index('pkill '))
        self.assertLess(calls.index('pkill '),calls.index("usermod ['--expiredate', ''"))
    def test_account_appearing_before_lock_is_not_rolled_back(self):
        r=self.run_remote(ACCOUNT_APPEARS='1');self.assertEqual(r.returncode,3,r.stdout+r.stderr)
        self.assertTrue((self.root/'account.json').exists())
        calls=(self.root/'calls').read_text()
        self.assertNotIn('userdel ',calls);self.assertNotIn('usermod ',calls)
        self.assertNotIn('systemd-run ',calls)
        self.assertFalse((self.root/'etc/ssh/authorized_keys/claudeops').exists())
        self.assertEqual(list((self.root/'run/claudeops-bootstrap').glob('txn.*')),[])
    def test_pending_reentry_refused_and_committed_timer_cannot_rollback(self):
        r=self.run_remote();self.assertEqual(r.returncode,10,r.stdout+r.stderr)
        first=self.controller(); r2=self.run_remote();self.assertEqual(r2.returncode,3,r2.stdout+r2.stderr)
        self.assertEqual(len(list(first.parent.parent.glob('txn.*'))),1)
        c=self.control('commit');self.assertEqual(c.returncode,0,c.stdout+c.stderr)
        old=self.control('rollback');self.assertNotEqual(old.returncode,0)
        self.assertTrue((self.root/'account.json').exists())
    def test_post_install_sudo_validation_failure_rolls_back(self):
        r=self.run_remote(ROLE='test',SUDO_FAIL='1');self.assertNotEqual(r.returncode,0)
        self.assertFalse((self.root/'account.json').exists(),r.stdout+r.stderr)
        self.assertFalse((self.root/'etc/sudoers.d/claudeops').exists())
        self.assertFalse((self.root/'etc/ssh/authorized_keys/claudeops').exists())
    def test_old_timer_does_not_touch_new_pending_transaction(self):
        first_result=self.run_remote();self.assertEqual(first_result.returncode,10,first_result.stdout+first_result.stderr)
        first=self.controller(); self.assertEqual(self.control('commit').returncode,0)
        second_result=self.run_remote();self.assertEqual(second_result.returncode,10,second_result.stdout+second_result.stderr)
        pending=list((self.root/'run/claudeops-bootstrap').glob('txn.*/pending'))
        self.assertEqual(len(pending),1)
        old=subprocess.run(['bash',str(first),'rollback'],env=self.env,capture_output=True,timeout=20)
        self.assertNotEqual(old.returncode,0);self.assertTrue(pending[0].exists())
    def test_lock_contention_refused(self):
        import fcntl
        base=self.root/'run/claudeops-bootstrap';base.mkdir()
        with (base/'lock').open('w') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            r=self.run_remote();self.assertEqual(r.returncode,3,r.stdout+r.stderr)
        self.assertFalse((self.root/'account.json').exists())

if __name__=='__main__':unittest.main()
