"""Offline naming/source adapters: no Vivado, board, real lock or network."""
from pathlib import Path
import copy,hashlib,importlib.util,json,re,sys,tempfile,unittest,zipfile
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,ROOT/path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module
build=load('naming_build','src/hardware/rebuild.py')
binding=load('naming_cpu','src/matrix_runtime/runtime/comparison_binding.py')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

class NamingAdapters(unittest.TestCase):
    def test_only_standard_uppercase_entries(self):
        names=[]
        for p in ROOT.rglob('*'):
            if p.name!=p.name.lower():
                self.assertTrue(p.is_file())
                self.assertIn(p.name,('README.md','SKILL.md'))
                names.append(p.relative_to(ROOT).as_posix())
            self.assertTrue(p.name.isascii())
        self.assertEqual(len(names),7)

    def test_simulation_paths_exact_case(self):
        base=ROOT/'sim/d075'
        real={p.relative_to(base).as_posix() for p in base.rglob('*') if p.is_file()}
        matched=0
        for p in (base/'sim').rglob('*'):
            if p.suffix not in ('.tcl','.ps1'):continue
            for name in re.findall(r'rtl[/\\]([A-Za-z0-9_]+\.(?:v|sv))',p.read_text(encoding='utf8')):
                self.assertIn('rtl/'+name,real)
                self.assertEqual(name,name.lower());matched+=1
        self.assertGreater(matched,30)

    def test_all_47_original_inputs_restored_for_build(self):
        config=build.identity()
        with tempfile.TemporaryDirectory(prefix='opennpu_naming_') as tmp:
            root=Path(tmp);board=root/'board.zip';work=root/'work'
            with zipfile.ZipFile(board,'w') as z:
                for n in ('pynq-z2/','pynq-z2/A.0/'):z.writestr(n,b'')
                for n in ('board.xml','part0_pins.xml','preset.xml','pynq_z2.jpg'):
                    z.writestr('pynq-z2/A.0/'+n,b'explicit offline board-definition fixture')
            config['board_definition'].update(bytes=board.stat().st_size,sha256=sha(board))
            with patch.object(build,'identity',return_value=config):
                self.assertFalse(build.prepare(work,board)['vivado_started'])
                self.assertEqual(build.prepared(work),config)
            real={p.relative_to(work/'source').as_posix() for p in (work/'source').rglob('*') if p.is_file()}
            self.assertEqual(len(config['original_build_input_sha256']),47)
            for name,h in config['original_build_input_sha256'].items():
                self.assertIn(name,real)
                self.assertEqual(sha(work/'source'/name),h)

    def test_wrong_build_alias_rejected(self):
        bad=copy.deepcopy(build.identity())
        bad['distribution_to_build_path']['rtl/pe_array.v']='rtl/another.v'
        with patch.object(build,'document',return_value=bad):
            with self.assertRaisesRegex(ValueError,'path aliases'):build.identity()

    def test_cpu_license_current_path_and_original_member(self):
        self.assertTrue(binding.verify_cpu_sources())
        rows=json.loads((binding.ROOT/'cpu_sources.json').read_bytes())['files']
        row=next(x for x in rows if x['path']=='runtime_cpu/license')
        self.assertEqual(row['member'],'candidate/core/frozen/cpu/LICENSE')

    def test_cpu_uppercase_distribution_alias_rejected(self):
        bad=json.loads((binding.ROOT/'cpu_sources.json').read_bytes())
        next(x for x in bad['files'] if x['path']=='runtime_cpu/license')['path']='runtime_cpu/LICENSE'
        with patch.object(binding.verifier,'read_json',return_value=bad):
            with self.assertRaisesRegex(ValueError,'member set'):binding.verify_cpu_sources()

    def test_cpu_original_archive_member_still_exact(self):
        bad=json.loads((binding.ROOT/'cpu_sources.json').read_bytes())
        next(x for x in bad['files'] if x['path']=='runtime_cpu/license')['member']='candidate/core/frozen/cpu/license'
        with patch.object(binding.verifier,'read_json',return_value=bad):
            with self.assertRaisesRegex(ValueError,'original mapping drift'):binding.verify_cpu_sources()

    def test_cpu_license_byte_tamper_rejected(self):
        read=Path.read_bytes
        def corrupt(path):
            raw=read(path)
            return bytes([raw[0]^1])+raw[1:] if path==binding.ROOT/'runtime_cpu/license' else raw
        with patch.object(Path,'read_bytes',new=corrupt):
            with self.assertRaisesRegex(ValueError,'byte drift'):binding.verify_cpu_sources()

    def test_current_manifest_and_request_names(self):
        base=ROOT/'src/skill_validation'
        self.assertIn('manifest.json',{p.name for p in base.iterdir()})
        self.assertNotIn('MANIFEST.json',{p.name for p in base.iterdir()})
        self.assertTrue((ROOT/'src/matrix_runtime/request.template.json').is_file())

if __name__=='__main__':unittest.main(verbosity=2)
