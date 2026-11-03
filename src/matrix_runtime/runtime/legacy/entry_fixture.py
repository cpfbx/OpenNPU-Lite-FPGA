"""Actual helper/observer code over fake OS/fcntl. NEVER a real FD/flock probe."""
from contextlib import contextmanager,ExitStack
import errno
import os
from pathlib import Path
import stat
import sys
from types import ModuleType,SimpleNamespace
from unittest.mock import patch

import numpy as np
import batch_owner
import os_evidence
import kws_threeway_entry_support_draft as helper
import lease_entry_candidate
import pynq_gemm as driver
from batch_policy import BatchPolicy
from flat_driver_candidate import flat_runner_type
import offline_fixture
from test_driver_integration import bank


class FakeCanonicalEnvironment:
    """Integer 99 is a synthetic token, never passed to the real OS."""
    def __init__(self,*,busy=False,drift=False,close_error=False,precheck=False,ambiguous=False):
        self.busy,self.drift,self.close_error=busy,drift,close_error
        self.precheck,self.ambiguous=precheck,ambiguous
        self.fd_live=self.exclusive_held=False
        self.open_calls=self.flock_calls=self.close_calls=self.factory_calls=0
        self.contexts=[]
        self.events=[]
        self.fake_os=SimpleNamespace(name='posix',getpid=os.getpid,
            O_NOFOLLOW=0x100,O_RDONLY=0,O_NONBLOCK=0x200,
            lstat=self.lstat,open=self.open,fstat=self.fstat,close=self.close,
            get_inheritable=lambda fd:False,major=lambda device:8,minor=lambda device:0)
        self.fake_fcntl=ModuleType('fcntl')
        self.fake_fcntl.LOCK_EX=2
        self.fake_fcntl.LOCK_NB=4
        self.fake_fcntl.flock=self.flock
        env=self
        class FakePath:
            def __init__(self,path):self.path=str(path)
            @property
            def name(self):return self.path.rsplit('/',1)[-1]
            def is_dir(self):return True
            def iterdir(self):
                return iter([FakePath('/proc/self/fd/99')]+([FakePath('/proc/self/fd/98')] if env.ambiguous else []))
        self.fake_path=FakePath

    def lstat(self,path):
        if self.precheck:raise FileNotFoundError('synthetic canonical path missing')
        inode=12 if self.drift and self.exclusive_held else 11
        return SimpleNamespace(st_mode=stat.S_IFREG|0o644,st_nlink=1,st_dev=2048,st_ino=inode)

    def open(self,*args):
        self.open_calls+=1
        self.fd_live=True
        return 99

    def fstat(self,fd):
        if not self.fd_live:raise OSError(errno.EBADF,'synthetic descriptor closed')
        return SimpleNamespace(st_mode=stat.S_IFREG|0o644,st_dev=2048,st_ino=11)

    def flock(self,fd,flags):
        self.flock_calls+=1
        if self.busy:raise BlockingIOError(errno.EAGAIN,'synthetic canonical lock busy')
        self.exclusive_held=True

    def close(self,fd):
        self.close_calls+=1
        if self.close_error:raise OSError('synthetic descriptor close failure')
        self.fd_live=self.exclusive_held=False

    def read_text(self,path,limit=65536):
        if path.endswith('/fdinfo/99'):
            return f'flags:\t02000000\nino:\t11\nlock:\t1: FLOCK ADVISORY WRITE {os.getpid()} 08:00:11 0 EOF\n'
        if path=='/proc/self/stat':return f'{os.getpid()} (synthetic) S '+('0 '*18)+'123'
        raise AssertionError('unmodeled fake proc path: '+path)

    def factory(self):
        self.factory_calls+=1
        context=helper.existing_shared_lock_draft()
        self.contexts.append(context)
        return context

    @contextmanager
    def install(self):
        with ExitStack() as stack:
            stack.enter_context(patch.object(helper,'os',self.fake_os))
            stack.enter_context(patch.object(os_evidence,'os',self.fake_os))
            stack.enter_context(patch.object(os_evidence,'Path',self.fake_path))
            stack.enter_context(patch.object(os_evidence,'read_text',side_effect=self.read_text))
            stack.enter_context(patch.object(lease_entry_candidate,'os',self.fake_os))
            stack.enter_context(patch.object(lease_entry_candidate,'Path',self.fake_path))
            stack.enter_context(patch.dict(sys.modules,{'fcntl':self.fake_fcntl}))
            try:
                yield self
            finally:
                # Test teardown ONLY: close synthetic suspended generators while
                # fake os is still installed. Never touch a real descriptor 99.
                for context in self.contexts:
                    generator=getattr(context,'gen',None)
                    if generator is not None:generator.close()


class PynqHarness:
    """Original owner/constructor + actual helper/observer + fake PYNQ hardware."""
    def __init__(self,owner_type,*,allocation_failure=None,recovery_factory_error=False,
                 recovery_confirmation_failure=False,pynq_version='3.1.1',clock=100.,stop_after_allocation=False):
        self.a,self.b,self.jobs,self.payload,self.expected=bank()
        r,_,_,self.events=offline_fixture.fixture(self.jobs,self.payload)
        self.engine=r.mmio
        self.stop=False
        self.owner=owner_type(BatchPolicy('smoke8',enabled=True),lambda:self.stop,enabled=True)
        self.fake=ModuleType('pynq')
        self.fake.__version__=pynq_version
        self.fake.Clocks=SimpleNamespace(fclk0_mhz=clock)
        overlay=SimpleNamespace(ip_dict={'axi_dma':{'type':'xilinx.com:ip:axi_dma:7.1'},
            'accel':{'phys_addr':0x40000000,'addr_range':4096}},axi_dma=r.dma)
        self.fake.Overlay=lambda path,download:overlay
        self.fake.MMIO=lambda address,extent:self.engine
        self.buffers=[]
        def allocate(shape,dtype):
            if allocation_failure==len(self.buffers):raise RuntimeError('synthetic allocation failure')
            buf=offline_fixture.Buffer(shape[0],0x10000000+len(self.buffers)*0x10000000,
                self.events,'tx' if not self.buffers else 'rx')
            self.buffers.append(buf)
            if stop_after_allocation and len(self.buffers)==2:self.stop=True
            return buf
        self.fake.allocate=allocate
        harness=self
        class Recovery:
            last_diagnostics={'source':'synthetic recovery, no device evidence'}
            def recover_and_confirm(self,runner):
                harness.engine.values[0x12c]=1
                harness.engine.values[driver.REG_STATUS]=1
                return not recovery_confirmation_failure
        def recovery(*args,**kwargs):
            if recovery_factory_error:raise RuntimeError('synthetic recovery factory failure')
            return Recovery()
        self.recovery_factory=recovery

    def start(self,environment,runner_type=None):
        cls=runner_type or flat_runner_type(enabled=True)
        with patch.dict(sys.modules,{'pynq':self.fake}):
            self.owner.start(cls,Path('synthetic_only.bit'),environment.factory,self.recovery_factory)
        return self.owner

    def discard_synthetic_retention(self):
        # Does not call close/free or release an OS resource. Test-process only.
        if self.owner in batch_owner._RETAINED:batch_owner._RETAINED.remove(self.owner)
