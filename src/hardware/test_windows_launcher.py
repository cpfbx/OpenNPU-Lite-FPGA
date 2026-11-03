"""Fixed command/exit/profile tests. Actual Windows processes run ONLY generated stub BAT."""
import copy
import hashlib
import inspect
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from test_rebuild import build
launcher=build.launcher

STUB_BAT=b'''@echo off\r
if not "%USERPROFILE%"=="fixture_profile" exit /b 81\r
if not "%APPDATA%"=="fixture_appdata" exit /b 82\r
if not "%LM_LICENSE_FILE%"=="fixture_license_no_secret" exit /b 83\r
if "%~1"=="-version" goto version\r
if not "%~1"=="-mode" exit /b 84\r
if not "%~2"=="batch" exit /b 85\r
if not "%~3"=="-source" exit /b 86\r
if not exist "%~4" exit /b 87\r
if not "%OPENNPU_ACCELERATOR%"=="gemm" exit /b 88\r
if not "%OPENNPU_ARRAY_SIZE%"=="8" exit /b 89\r
if not "%OPENNPU_MODE11_EXPERIMENT%"=="1" exit /b 90\r
if defined TCLLIBPATH exit /b 91\r
echo STUB_BUILD_ONLY_NO_VIVADO\r
if "%OPENNPU_STUB_CASE%"=="build_fail" exit /b 42\r
exit /b 0\r
:version\r
if "%OPENNPU_STUB_CASE%"=="wrong_version" goto wrong_version\r
echo Vivado v2026.1 ^(64-bit^) STUB_ONLY\r
if "%OPENNPU_STUB_CASE%"=="version_fail" exit /b 42\r
exit /b 0\r
:wrong_version\r
echo Vivado v2026.10 ^(64-bit^) STUB_ONLY\r
exit /b 0\r
'''


class EnvironmentTests(unittest.TestCase):
    def env(self,action='Build'):
        original=dict(USERPROFILE='fixture_profile',APPDATA='fixture_appdata',
            LM_LICENSE_FILE='fake_private_license',XILINXD_LICENSE_FILE='fake_xilinx',
            PATH='original_path',TCLLIBPATH='untrusted_tcl',opennpu_array_size='999',
            _opennpu_internal_vivado_bat='stale')
        return original,launcher.environment(original,'C:/Tool/bin/vivado.bat','C:/Source/build.tcl','C:/Out',action)

    def test_profiles_and_license_variables_preserved(self):
        old,new=self.env()
        for name in ('USERPROFILE','APPDATA','LM_LICENSE_FILE','XILINXD_LICENSE_FILE','PATH'):
            self.assertEqual(new[name],old[name])

    def test_original_environment_not_mutated(self):
        old,_=self.env();self.assertEqual(old['TCLLIBPATH'],'untrusted_tcl');self.assertEqual(old['opennpu_array_size'],'999')

    def test_case_insensitive_controlled_aliases_removed(self):
        _,new=self.env();self.assertNotIn('opennpu_array_size',new)
        self.assertNotIn('_opennpu_internal_vivado_bat',new)
        self.assertEqual(new['OPENNPU_ARRAY_SIZE'],'8')

    def test_fixed_build_parameters_and_no_tcl_search_injection(self):
        _,new=self.env();self.assertNotIn('TCLLIBPATH',new)
        self.assertTrue(all(new[k]==v for k,v in launcher.FIXED_ENV.items()))

    def test_version_preserves_build_environment(self):
        old,new=self.env('Version');self.assertEqual(old['opennpu_array_size'],new['opennpu_array_size'])
        self.assertEqual(new['TCLLIBPATH'],old['TCLLIBPATH'])

    def test_action_has_no_arbitrary_command_option(self):
        with self.assertRaises(ValueError):self.env('Delete')

    def test_command_line_fixed_switches_no_powershell(self):
        line=launcher.command_line('C:/Windows/System32/cmd.exe','Build')
        self.assertIn('/d /v:off /s /c call',line);self.assertIn(' -mode batch -source ',line)
        self.assertNotIn('powershell',line.lower());self.assertNotIn('-File',line)

    def test_version_command_not_build(self):
        line=launcher.command_line('C:/Windows/System32/cmd.exe','Version')
        self.assertTrue(line.endswith('-version'));self.assertNotIn('-source',line)

    def test_metacharacters_rejected_before_interpolation(self):
        for char in ('%','!','&','|','<','>','^','"','\n','\r','\0','?','*','\t','\x01'):
            with self.subTest(char=repr(char)),self.assertRaises(ValueError):launcher.safe_text('C:/name'+char+'/vivado.bat')

    def test_spaces_parentheses_and_unicode_supported(self):
        value='C:/文件夹 with spaces (x86)/vivado.bat';self.assertEqual(launcher.safe_text(value),value)

    def test_no_profile_redirection_or_policy_mutation_in_launcher(self):
        source=inspect.getsource(launcher.run)
        for forbidden in ('Set-ExecutionPolicy','Unblock-File','-ExecutionPolicy','Bypass'):
            self.assertNotIn(forbidden,source)
        self.assertNotIn("env['USERPROFILE']",source);self.assertNotIn("env['APPDATA']",source)


class BuildClassificationTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.work=Path(self.temp.name).resolve()/'work';self.work.mkdir()
        self.tool=self.work.parent/'Tool';(self.tool/'bin').mkdir(parents=True)
        (self.tool/'bin/vivado.bat').write_bytes(b'not executed')

    def run_build(self,codes,version=b'Vivado v2026.1 (64-bit)\n'):
        calls=[]
        def fake(root,source,output,cwd,stem,action):
            calls.append(action)
            if action=='Version':(self.work/'version.stdout').write_bytes(version)
            return codes[len(calls)-1]
        with patch.object(build,'os',SimpleNamespace(name='nt')),patch.object(build,'prepared'),\
             patch.object(build.launcher,'run',side_effect=fake),patch.object(build,'collect',return_value={'fixture':True}) as collect:
            try:value=build.build(self.work,self.tool,'OFFLINE_BUILD_ONLY')
            except BaseException as error:return error,calls,collect.call_count
        return value,calls,collect.call_count

    def test_nonzero_version_not_mislabeled_version_mismatch(self):
        error,calls,collect=self.run_build([42]);self.assertIn('version_query_failed',str(error))
        self.assertNotIn('version_mismatch',str(error));self.assertEqual(calls,['Version']);self.assertEqual(collect,0)

    def test_wrong_version_exit_zero_separately_rejected(self):
        error,calls,_=self.run_build([0],b'Vivado v2026.10 (64-bit)\n')
        self.assertIn('version_mismatch',str(error));self.assertEqual(calls,['Version'])

    def test_nonzero_build_does_not_collect(self):
        error,calls,collect=self.run_build([0,42]);self.assertIn('build_failed',str(error))
        self.assertEqual(calls,['Version','Build']);self.assertEqual(collect,0)

    def test_bool_exit_is_not_success(self):
        for code in (False,True):
            with self.subTest(code=code):
                # Fresh work per attempt; do not overwrite the real claim guard.
                self.work=self.work.parent/('bool_'+str(code));self.work.mkdir()
                error,calls,_=self.run_build([code]);self.assertIn('version_query_failed',str(error))
                self.assertEqual(calls,['Version'])

    def test_normal_build_collect_once_after_two_steps(self):
        value,calls,collect=self.run_build([0,0]);self.assertEqual(value,{'fixture':True})
        self.assertEqual(calls,['Version','Build']);self.assertEqual(collect,1)

    def test_missing_confirmation_no_launcher(self):
        with patch.object(build.launcher,'run') as launch,self.assertRaises(ValueError):build.build(self.work,self.tool,None)
        launch.assert_not_called();self.assertFalse((self.work/'build_claim.json').exists())

    def test_claim_prevents_retry(self):
        self.run_build([42])
        with patch.object(build,'os',SimpleNamespace(name='nt')),patch.object(build,'prepared'),\
             patch.object(build.launcher,'run') as launch,self.assertRaises(FileExistsError):
            build.build(self.work,self.tool,'OFFLINE_BUILD_ONLY')
        launch.assert_not_called()

    def test_launcher_error_separate_from_tool_exit_and_version_mismatch(self):
        with patch.object(build,'os',SimpleNamespace(name='nt')),patch.object(build,'prepared'),\
             patch.object(build.launcher,'run',side_effect=OSError('synthetic CreateProcess failure')):
            with self.assertRaisesRegex(ValueError,'version_launcher_failed') as got:
                build.build(self.work,self.tool,'OFFLINE_BUILD_ONLY')
        self.assertIsInstance(got.exception.__cause__,OSError)


@unittest.skipUnless(os.name=='nt','actual Windows CMD stub execution unavailable')
class ActualWindowsStubTests(unittest.TestCase):
    def stub(self,folder):
        tool=folder/'假工具 with spaces (x86)';(tool/'bin').mkdir(parents=True)
        (tool/'bin/vivado.bat').write_bytes(STUB_BAT)
        source=folder/'source with spaces';(source/'synth').mkdir(parents=True)
        (source/'synth/build_dma_loopback.tcl').write_bytes(b'# STUB fixture; never run as Tcl\n')
        return tool,source

    def invoke(self,folder,case,action):
        tool,source=self.stub(folder)
        original=launcher.environment
        def inherited(inherited_env,*args):
            inherited_env.update(USERPROFILE='fixture_profile',APPDATA='fixture_appdata',
                LM_LICENSE_FILE='fixture_license_no_secret',OPENNPU_STUB_CASE=case,TCLLIBPATH='bad')
            return original(inherited_env,*args)
        with patch.object(launcher,'environment',side_effect=inherited):
            result=launcher.run(tool,source,source/'not_existing_output',folder,folder/'tool',action)
        receipt=json.loads((folder/'tool.receipt.json').read_bytes())
        self.assertTrue(receipt['exit_observed']);self.assertFalse(receipt['profile_redirected'])
        self.assertFalse(receipt['execution_policy_changed']);self.assertFalse(receipt['powershell_used'])
        self.assertEqual(receipt['actual_exit_code'],result)
        for kind in ('stdout','stderr'):
            raw=(folder/('tool.'+kind)).read_bytes();self.assertEqual(hashlib.sha256(raw).hexdigest(),receipt[kind+'_sha256'])
        return result,(folder/'tool.stdout').read_bytes()

    def test_real_cmd_stub_version_success(self):
        if os.name!='nt':
            with self.assertRaisesRegex(ValueError,'Windows-only'):launcher.run(None,None,None,None,None,'Version')
            return
        with tempfile.TemporaryDirectory() as tmp:
            result,raw=self.invoke(Path(tmp).resolve(),'normal','Version')
            self.assertEqual(result,0);self.assertTrue(build.exact_vivado_version(raw))

    def test_real_cmd_stub_nonzero_version_preserved(self):
        if os.name!='nt':return  # Windows execution is separately declared, never claimed on Linux.
        with tempfile.TemporaryDirectory() as tmp:
            result,raw=self.invoke(Path(tmp).resolve(),'version_fail','Version')
            self.assertEqual(result,42);self.assertTrue(build.exact_vivado_version(raw))

    def test_real_cmd_stub_wrong_version_preserved(self):
        if os.name!='nt':return
        with tempfile.TemporaryDirectory() as tmp:
            result,raw=self.invoke(Path(tmp).resolve(),'wrong_version','Version')
            self.assertEqual(result,0);self.assertFalse(build.exact_vivado_version(raw))

    def test_real_cmd_stub_build_environment_and_quote_success(self):
        if os.name!='nt':return
        with tempfile.TemporaryDirectory() as tmp:
            result,raw=self.invoke(Path(tmp).resolve(),'normal','Build')
            self.assertEqual(result,0);self.assertIn(b'STUB_BUILD_ONLY_NO_VIVADO',raw)

    def test_real_cmd_stub_build_failure_preserved(self):
        if os.name!='nt':return
        with tempfile.TemporaryDirectory() as tmp:
            result,_=self.invoke(Path(tmp).resolve(),'build_fail','Build');self.assertEqual(result,42)

    def test_log_set_cannot_be_overwritten(self):
        if os.name!='nt':return
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp).resolve();tool,source=self.stub(folder)
            (folder/'tool.stdout').write_bytes(b'original evidence')
            with self.assertRaisesRegex(ValueError,'fresh launcher log'):
                launcher.run(tool,source,source/'out',folder,folder/'tool','Version')
            self.assertEqual((folder/'tool.stdout').read_bytes(),b'original evidence')

    def test_actual_rebuild_bridge_two_cmds_no_vivado(self):
        if os.name!='nt':return
        with tempfile.TemporaryDirectory() as tmp:
            work=Path(tmp).resolve();tool,_=self.stub(work)
            source=work/'source';(source/'synth').mkdir(parents=True)
            (source/'synth/build_dma_loopback.tcl').write_bytes(b'# fixture only\n')
            original=launcher.environment
            def inherited(inherited_env,*args):
                inherited_env.update(USERPROFILE='fixture_profile',APPDATA='fixture_appdata',
                    LM_LICENSE_FILE='fixture_license_no_secret',OPENNPU_STUB_CASE='normal')
                return original(inherited_env,*args)
            with patch.object(build,'prepared'),patch.object(build,'collect',return_value={'fixture':True}) as collect,\
                 patch.object(launcher,'environment',side_effect=inherited):
                self.assertEqual(build.build(work,tool,'OFFLINE_BUILD_ONLY'),{'fixture':True})
                collect.assert_called_once_with(work)
            for name in ('version','build'):
                row=json.loads((work/(name+'.receipt.json')).read_bytes())
                self.assertTrue(row['exit_observed']);self.assertEqual(row['actual_exit_code'],0)


if __name__=='__main__':unittest.main(verbosity=2)
