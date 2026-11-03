"""Cold pinned binding and immutable contract for KWS full hybrid offline candidate.

No board activation entry, no real lock access, no automatic dependency install.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import stat
import sys
import tarfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parent

PREREQ_ZIP_SHA = 'fae95a89a7bbefc4a26f281e05997b1ff7df8e9b68d44735a954e61c6ac49bd4'
PREREQ_MANIFEST_SHA = '524927755ea6e403c834fee7a518a0c9d2816b499a305a2c9d2816b499a305a'  # checked dynamically via PINS
SELECTION12_SHA = 'e96413b815827dcb82b5e51fa40144f3a6021fae15ca74973a6a2b2c97a3037a'
CPU_MANIFEST_SHA = '19aa43c2d0964cd77de13c1964c251ae66176c3f644238a21beaf377479bf4ba'
SHARED_KIT_MANIFEST_SHA = '26747c4a3f4b31321708a0508c4a6d3111c5cb9e29faed997bba84f1b8bf5e03'
SHARED_CANDIDATE_MANIFEST_SHA = 'a9b97371db2cae602f1b500384c2f4063436e08772960f05d532dbc62686b403'
QUALITY_MANIFEST_SHA = '263debd95a6872ddc3a31867819997a17b6bf6b647cebd21a0da1664c3d2fdcc'
SHARED_BOARD_TAR_SHA = '7786d5eee69b1cd17c1296beee522d324ca5d7fff9cc3e6e1a3aea39010651b7'
CPU420_BOARD_TAR_SHA = '5939c7c0ae2e565bc7e67cbd5e1b815e207db40961ed1a6972396fd05b64ccba'
MODEL_SHA = 'aeea436800704fce17b17292e4412630ad856e9d777c044c64ef748a880bd0ae'
DESCRIPTOR_SHA = '8bd3019d159ea3264164f09e90622423c29650647e8b340fe933b70a9030be08'
FROZEN_POLICY_SHA = 'f8025ffee689b99f94ec98cc884a4c404be38c18cdf4e5c7099af552e3bfaf2d'
HISTORICAL_VAD_RAW_SHA = 'f0c5b77175e82163c9ef93ee944626c14130ce1c7084ac96acfba1ca08cfc45a'
QUALITY_INFERENCE02_RAW_SHA = '001de0ff636bb36c23917ff75b395adf3aa5af80eccddc7dd101559f0639341c'
VOICE_GATE_SOURCE_SHA = '582ba98f89fceaf7046a24be5a40759ed2b40d600688b331920883db5a74437c'
NATIVE_VAD_SHA = '409b96d051bbb51a750a088177fd1694f79eb9ba317334e8f5ede75c3d288476'

INDICES = (0, 30, 60, 90, 120, 150, 180, 210, 240, 270, 300, 400)
LABELS = ('down', 'go', 'left', 'no', 'off', 'on', 'right', 'stop', 'up', 'yes', '_silence_', '_unknown_')
LOGITS_SCALE = 0.14469251036643982
LOGITS_ZERO_POINT = 14

SOURCE_ANCHORS = {
    'selection12.json': dict(bytes=36335, sha256=SELECTION12_SHA),
    'cpu/review_manifest.json': dict(bytes=119944, sha256=CPU_MANIFEST_SHA),
    'shared/kit_manifest.json': dict(bytes=56272, sha256=SHARED_KIT_MANIFEST_SHA),
    'shared/core/candidate_manifest.json': dict(bytes=53494, sha256=SHARED_CANDIDATE_MANIFEST_SHA),
    'quality/MANIFEST.json': dict(bytes=18770, sha256=QUALITY_MANIFEST_SHA),
    'board_records/shared_board.tar.gz': dict(bytes=1956826, sha256=SHARED_BOARD_TAR_SHA),
    'board_records/cpu420_board.tar.gz': dict(bytes=196310, sha256=CPU420_BOARD_TAR_SHA),
    'cpu/candidate_05/component/model/kws_ref_model.tflite': dict(bytes=53936, sha256=MODEL_SHA),
    'cpu/candidate_05/component/model/descriptor.json': dict(bytes=78208, sha256=DESCRIPTOR_SHA),
    'quality/project/.offline-results/WP4-voice-gate-20261015_01/experiment_02/frozen_policy.json': dict(bytes=1092, sha256=FROZEN_POLICY_SHA),
    'quality/project/.offline-results/WP4-voice-gate-20261015_01/experiment_02/evaluation/raw.jsonl': dict(bytes=1066087, sha256=HISTORICAL_VAD_RAW_SHA),
    'quality/project/.offline-results/KWS-dscnn-quality-20261022_01/inference_02/raw.jsonl': dict(bytes=1557072, sha256=QUALITY_INFERENCE02_RAW_SHA),
    'quality/project/.board-work/FPGA-20-zip-test-20261013/apps/kws/experiments/voice_gate_candidate.py': dict(bytes=3313, sha256=VOICE_GATE_SOURCE_SHA),
}


def need(ok: bool, message: str) -> None:
    if not ok:
        raise ValueError(message)


def sha(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def pin(path: Path) -> dict:
    raw = Path(path).read_bytes()
    return dict(bytes=len(raw), sha256=sha(raw))


def strict_json(raw: bytes | str):
    if isinstance(raw, bytes):
        raw = raw.decode('utf-8')
    def pairs(items):
        out = {}
        for k, v in items:
            need(k not in out, 'duplicate JSON key: ' + str(k))
            out[k] = v
        return out
    def invalid(_):
        raise ValueError('nonfinite JSON constant')
    return json.loads(raw, object_pairs_hook=pairs, parse_constant=invalid)


def encode_json(value) -> bytes:
    return (json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + '\n').encode('utf-8')


def write_exclusive(path: Path, raw: bytes) -> dict:
    path = Path(path)
    with path.open('xb') as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    return dict(bytes=len(raw), sha256=sha(raw))


def write_json_exclusive(path: Path, value) -> dict:
    return write_exclusive(path, encode_json(value))


def inventory(root: Path, exclude: set[str] | None = None) -> dict:
    root = Path(root).resolve()
    exclude = exclude or set()
    result = {}
    for p in sorted(root.rglob('*')):
        need(not p.is_symlink() and not getattr(p, 'is_junction', lambda: False)(), 'symlink/junction forbidden in tree')
        if '__pycache__' in p.parts or p.suffix == '.pyc':
            raise ValueError('pycache/pyc forbidden in pinned tree: ' + str(p))
        if p.is_file():
            rel = p.relative_to(root).as_posix()
            if rel not in exclude:
                result[rel] = pin(p)
    return result


def verify_candidate_tree(expected_manifest_sha: str | None = None) -> dict:
    manifest_path = ROOT / 'manifest.json'
    need(manifest_path.is_file(), 'candidate manifest.json required')
    raw = manifest_path.read_bytes()
    actual_sha = sha(raw)
    if expected_manifest_sha is not None:
        need(type(expected_manifest_sha) is str and actual_sha == expected_manifest_sha,
             'external candidate manifest pin mismatch')
    doc = strict_json(raw)
    need(type(doc) is dict and doc.get('schema') == 'kws-full-hybrid-candidate-v1' and 'files' in doc,
         'candidate manifest schema')
    actual = inventory(ROOT, exclude={'manifest.json'})
    need(actual == doc['files'], 'candidate file set, size or SHA drift')
    return dict(manifest_sha256=actual_sha, files=actual)


def verify_sources_tree(sources_root: Path) -> Path:
    sources_root = Path(sources_root).resolve()
    need(sources_root.is_dir(), 'unpacked sources root directory required')
    for rel, expected in SOURCE_ANCHORS.items():
        target = sources_root / rel
        need(target.is_file() and not target.is_symlink(), 'missing unpacked source anchor: ' + rel)
        need(pin(target) == expected, 'unpacked source anchor drift: ' + rel)
    # Verify each unpacked bundle against its own internal manifest
    for bundle_dir, manifest_name in (
        (sources_root / 'cpu', 'review_manifest.json'),
        (sources_root / 'shared', 'kit_manifest.json'),
        (sources_root / 'quality', 'MANIFEST.json'),
    ):
        manifest_file = bundle_dir / manifest_name
        expected_files = strict_json(manifest_file.read_bytes())['files']
        actual_files = inventory(bundle_dir, exclude={manifest_name})
        need(actual_files == expected_files, 'frozen source bundle modified: ' + bundle_dir.name)
    return sources_root


def validate_output_dir(output: Path, sources_root: Path) -> Path:
    output = Path(output).resolve()
    sources_root = Path(sources_root).resolve()
    need(not output.exists(), 'fresh output directory required (already exists)')
    need(output.parent.is_dir(), 'output parent directory must exist')
    need(not output.is_relative_to(ROOT) and not ROOT.is_relative_to(output),
         'output directory must be outside candidate directory')
    need(not output.is_relative_to(sources_root) and not sources_root.is_relative_to(output),
         'output directory must be outside unpacked sources directory')
    return output


def load_module_isolated(name: str, path: Path):
    path = Path(path).resolve()
    if name in sys.modules:
        existing = Path(getattr(sys.modules[name], '__file__', '')).resolve()
        need(existing == path, 'foreign module already loaded for ' + name)
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    need(spec is not None and spec.loader is not None, 'module spec required for ' + str(path))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


@dataclass(frozen=True)
class HybridBundle:
    sources_root: Path
    shared_components: object
    shared_binding: object
    shared_contract: object
    wire_environment_type: object
    shared_session_type: object
    frontend: object
    portable_integer_module: object
    cpu_oracle_model: object
    quality_core: object
    voice_gate: object
    frozen_policy: object
    cohort: list
    selection12: dict
    historical_vad_by_index: dict
    quality_oracle_by_index: dict
    cpu420_board_features: bytes
    cpu420_board_logits: bytes
    shared_board_summary: dict
    shared_board_artifacts: dict


_BUNDLE_CACHE: dict[Path, HybridBundle] = {}


def load_hybrid_bundle(sources_root: Path, *, enabled: bool = False) -> HybridBundle:
    need(enabled is True, 'hybrid bundle loading default-off')
    sources_root = verify_sources_tree(sources_root)
    if sources_root in _BUNDLE_CACHE:
        _BUNDLE_CACHE[sources_root].shared_components.reference.sources2()
        return _BUNDLE_CACHE[sources_root]

    need(not any(n == r or n.startswith(r + '.') for n in sys.modules for r in ('pynq', 'tensorflow', 'tflite_runtime')),
         'cold binding required before loading hybrid bundle')

    shared_core = sources_root / 'shared/core'
    if str(shared_core) not in sys.path:
        sys.path.insert(0, str(shared_core))

    import device_binding as b
    import device_contract as ct
    from device_fixture import WireEnvironment
    from device_session import SharedDeviceSession

    b.verify(SHARED_CANDIDATE_MANIFEST_SHA)
    shared_components = b.configure(enabled=True)

    cpu_src = sources_root / 'cpu/candidate_05/src'
    if str(cpu_src) not in sys.path:
        sys.path.insert(0, str(cpu_src))
    frontend_mod = load_module_isolated('frontend', cpu_src / 'frontend.py')
    frontend = frontend_mod.Frontend(sources_root / 'cpu/candidate_05')

    pi_path = sources_root / 'cpu/candidate_05/component/portable_integer.py'
    pi_mod = load_module_isolated('_hybrid_portable_integer', pi_path)
    cpu_oracle_model = pi_mod.IntegerReference(sources_root / 'cpu/candidate_05/component/model', enabled=True)

    # Cross-check model & 21 constants equality between CPU and shared bundles
    shared_model_dir = sources_root / 'shared/core/frozen_process/frozen_shared/frozen_combo/frozen_kit/core/driver/frozen_op4/frozen_op2/frozen/model'
    cpu_model_dir = sources_root / 'cpu/candidate_05/component/model'
    for item_path in sorted(cpu_model_dir.iterdir()):
        if item_path.is_file():
            need(pin(item_path) == pin(shared_model_dir / item_path.name),
                 'CPU and shared model/constant mismatch: ' + item_path.name)

    qc_path = sources_root / 'quality/project/.offline-results/KWS-dscnn-quality-20261022_01/quality_core.py'
    quality_core = load_module_isolated('_hybrid_quality_core', qc_path)
    vg_path = sources_root / 'quality/project/.board-work/FPGA-20-zip-test-20261013/apps/kws/experiments/voice_gate_candidate.py'
    voice_gate = quality_core.load_gate(vg_path)

    policy_doc = strict_json((sources_root / 'quality/project/.offline-results/WP4-voice-gate-20261015_01/experiment_02/frozen_policy.json').read_bytes())
    need(policy_doc['native_sha256'] == NATIVE_VAD_SHA, 'native VAD SHA drift')
    frozen_policy = voice_gate.Policy(**policy_doc['policy'])
    need(frozen_policy.mode == 0 and frozen_policy.min_voiced_frames == 3 and frozen_policy.min_voiced_run == 3
         and frozen_policy.min_score == 0.95 and frozen_policy.min_score_gap == 0.0, 'frozen gate policy drift')

    cohort = strict_json((sources_root / 'cpu/candidate_05/data/cohort.json').read_bytes())
    need(type(cohort) is list and len(cohort) == 420, 'cohort 420 required')
    selection12 = strict_json((sources_root / 'selection12.json').read_bytes())
    need(tuple(selection12['indices']) == INDICES and len(selection12['windows']) == 12, 'selection12 indices')

    vad_lines = (sources_root / 'quality/project/.offline-results/WP4-voice-gate-20261015_01/experiment_02/evaluation/raw.jsonl').read_bytes().splitlines()
    need(len(vad_lines) == 420, '420 historical VAD records required')
    historical_vad_by_index = {}
    for idx, line in enumerate(vad_lines):
        row = strict_json(line)
        need(row['source_id'] == cohort[idx]['source_id'] and row['source_sha256'] == cohort[idx]['source_sha256']
             and row['pcm_sha256'] == cohort[idx]['pcm_sha256'], 'historical VAD cohort alignment')
        vad_entry = quality_core.checked_vad(dict(row['vad']['0']), frozen_policy)
        need(vad_entry.get('native_sha256') == NATIVE_VAD_SHA, 'historical VAD native_sha256')
        historical_vad_by_index[idx] = dict(
            source_id=row['source_id'],
            source_sha256=row['source_sha256'],
            pcm_sha256=row['pcm_sha256'],
            vad=vad_entry,
        )

    qual_lines = (sources_root / 'quality/project/.offline-results/KWS-dscnn-quality-20261022_01/inference_02/raw.jsonl').read_bytes().splitlines()
    need(len(qual_lines) == 420, '420 quality oracle records required')
    quality_oracle_by_index = {idx: strict_json(line) for idx, line in enumerate(qual_lines)}

    with tarfile.open(sources_root / 'board_records/cpu420_board.tar.gz', 'r:gz') as tf:
        cpu420_board_features = tf.extractfile('metrics_kws_prepare_0ROstCki/work/evidence/worker/numerical/features.i8').read()
        cpu420_board_logits = tf.extractfile('metrics_kws_prepare_0ROstCki/work/evidence/worker/numerical/logits.i8').read()
    need(len(cpu420_board_features) == 205800 and len(cpu420_board_logits) == 5040, 'cpu420 board extents')

    shared_board_artifacts = {}
    with tarfile.open(sources_root / 'board_records/shared_board.tar.gz', 'r:gz') as tf:
        shared_board_summary = strict_json(tf.extractfile('work/evidence/worker/data/summary.json').read())
        for w_idx in INDICES:
            w_prefix = f'work/evidence/worker/data/window_{w_idx:03d}/'
            w_files = {}
            for member in tf.getmembers():
                if member.isfile() and member.name.startswith(w_prefix):
                    short = member.name[len(w_prefix):]
                    if short != 'result.json':
                        raw = tf.extractfile(member).read()
                        w_files[short] = dict(bytes=len(raw), sha256=sha(raw))
            need(len(w_files) == 22, f'shared_board window_{w_idx:03d} 22 artifacts')
            shared_board_artifacts[w_idx] = w_files

    bundle = HybridBundle(
        sources_root=sources_root,
        shared_components=shared_components,
        shared_binding=b,
        shared_contract=ct,
        wire_environment_type=WireEnvironment,
        shared_session_type=SharedDeviceSession,
        frontend=frontend,
        portable_integer_module=pi_mod,
        cpu_oracle_model=cpu_oracle_model,
        quality_core=quality_core,
        voice_gate=voice_gate,
        frozen_policy=frozen_policy,
        cohort=cohort,
        selection12=selection12,
        historical_vad_by_index=historical_vad_by_index,
        quality_oracle_by_index=quality_oracle_by_index,
        cpu420_board_features=cpu420_board_features,
        cpu420_board_logits=cpu420_board_logits,
        shared_board_summary=shared_board_summary,
        shared_board_artifacts=shared_board_artifacts,
    )
    _BUNDLE_CACHE[sources_root] = bundle
    return bundle


if __name__ == '__main__':
    raise SystemExit('Library only. No board activation entry.')
