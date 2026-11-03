"""Default-off full hybrid graph executor and offline fixed-12 window runner.

Executes:
  public WAV -> Frontend.process -> CPU prefix (op0, op1) -> SharedCall Op2 ->
  CPU DW3 (op3) -> SharedCall Op4 -> CPU suffix (op5..op11) -> INT8 logits (tensor33)
  -> classification & frozen voice gate (with historical PCM-bound VAD flags).

Never uses IntegerReference.infer(compare=...) as a backend replacement, never
substitutes golden features/tensors/logits into the candidate dataflow, and
never accesses real board/lock/DMA hardware.
"""
from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path
import numpy as np

import hybrid_contract as hc
from hybrid_contract import need, sha, write_exclusive, write_json_exclusive, INDICES, LABELS, LOGITS_SCALE, LOGITS_ZERO_POINT


@dataclass(frozen=True)
class TensorNodeRecord:
    operator_index: int
    operator_name: str
    backend: str
    input_tensor: int
    output_tensor: int
    cohort_index: int
    source_id: str
    feature_sha256: str
    input_object_id: int
    output_object_id: int
    input_sha256: str
    output_sha256: str
    accumulator_sha256: str | None
    shape: list[int]
    values_count: int


def checked_owning_125x64(arr: np.ndarray, label: str = 'owning 125x64 INT8') -> np.ndarray:
    need(type(arr) is np.ndarray and arr.dtype == np.int8 and arr.shape == (125, 64)
         and arr.flags.c_contiguous and arr.flags.owndata and arr.base is None,
         label)
    return arr


def checked_owning_nhwc(arr: np.ndarray, expected_shape: tuple[int, ...], label: str = 'owning NHWC INT8') -> np.ndarray:
    need(type(arr) is np.ndarray and arr.dtype == np.int8 and arr.shape == expected_shape
         and arr.flags.c_contiguous and arr.flags.owndata and arr.base is None,
         label)
    return arr


class HybridGraphExecutor:
    """Independent graph executor that dispatches Op2 & Op4 to SharedCall and other ops to CPU."""

    def __init__(self, bundle: hc.HybridBundle, *, enabled: bool = False):
        need(enabled is True, 'HybridGraphExecutor default-off')
        need(type(bundle) is hc.HybridBundle, 'exact HybridBundle required')
        self.bundle = bundle
        self.pi = bundle.portable_integer_module
        self.model = bundle.cpu_oracle_model
        self.info = self.model.info
        self.options = self.model.options
        self.constants = self.model.constants
        self.dw3_params = bundle.shared_components.combination.depthwise_parameters()

        # Verify model operator topology up front
        ops = self.info['operators']
        need(len(ops) == 13 and [op['index'] for op in ops] == list(range(13)), '13 operators 0..12 expected')
        need(ops[0]['name'] == 'CONV_2D' and ops[0]['inputs'][0] == 0 and ops[0]['outputs'] == [22], 'op0 topology')
        need(ops[1]['name'] == 'DEPTHWISE_CONV_2D' and ops[1]['inputs'][0] == 22 and ops[1]['outputs'] == [23], 'op1 topology')
        need(ops[2]['name'] == 'CONV_2D' and ops[2]['inputs'][0] == 23 and ops[2]['outputs'] == [24], 'op2 topology')
        need(ops[3]['name'] == 'DEPTHWISE_CONV_2D' and ops[3]['inputs'][0] == 24 and ops[3]['outputs'] == [25], 'op3 topology')
        need(ops[4]['name'] == 'CONV_2D' and ops[4]['inputs'][0] == 25 and ops[4]['outputs'] == [26], 'op4 topology')
        need(ops[11]['name'] == 'FULLY_CONNECTED' and ops[11]['inputs'][0] == 32 and ops[11]['outputs'] == [33], 'op11 topology')
        need(ops[12]['name'] == 'SOFTMAX' and ops[12]['inputs'] == [33] and ops[12]['outputs'] == [34], 'op12 topology')

    def run_cpu_operator(self, op_index: int, a: np.ndarray) -> tuple[np.ndarray, np.ndarray | None]:
        need(type(op_index) is int and op_index in (0, 1, 5, 6, 7, 8, 9, 10, 11),
             f'CPU operator dispatch forbidden for op {op_index}')
        op = self.info['operators'][op_index]
        name = op['name']
        src = op['inputs'][0]
        output = op['outputs'][0]
        it = self.info['tensors'][src]
        ot = self.info['tensors'][output]
        expected_in_shape = tuple(it['shape'])
        expected_out_shape = tuple(ot['shape'])
        checked_owning_nhwc(a, expected_in_shape, f'op{op_index} input tensor{src} owning shape')

        if name in ('CONV_2D', 'DEPTHWISE_CONV_2D', 'FULLY_CONNECTED'):
            wi, bi = op['inputs'][1:]
            b = self.constants[wi]
            bias = self.constants[bi]
            wt = self.info['tensors'][wi]
            need(all(z == 0 for z in wt['zero_points']), 'symmetric weights required')
            zp = int(it['zero_points'][0])
            if name == 'CONV_2D':
                patches = self.pi.conv_patches(a, b.shape, ot['shape'], op['stride'], op['padding'], op['dilation'], zp)
                weight = b.reshape(b.shape[0], -1)
                acc = (patches.astype(np.int32) @ weight.astype(np.int32).T).astype(np.int64)
                acc += bias.astype(np.int64) - zp * weight.astype(np.int64).sum(axis=1)
            elif name == 'DEPTHWISE_CONV_2D':
                need(b.shape[-1] == a.shape[-1], 'depth multiplier 1 required')
                _, kh, kw, c = b.shape
                patches = self.pi.conv_patches(a, (c, kh, kw, c), ot['shape'], op['stride'], op['padding'], op['dilation'], zp)
                centered = patches.reshape(-1, kh * kw, c).astype(np.int64) - zp
                acc = (centered * b.reshape(kh * kw, c).astype(np.int64)).sum(axis=1) + bias.astype(np.int64)
            else:
                acc = (a.reshape(-1, b.shape[1]).astype(np.int32) @ b.astype(np.int32).T).astype(np.int64)
                acc += bias.astype(np.int64) - zp * b.astype(np.int64).sum(axis=1)
            acc_i32 = self.pi.checked_i32(acc).copy(order='C')
            scale = np.array(wt['scales'], np.float64) * float(it['scales'][0]) / float(ot['scales'][0])
            activation = op.get('activation', self.options.get(op_index, {}).get('activation', 0))
            out = self.pi.requantize(acc, scale, int(ot['zero_points'][0]), activation).reshape(expected_out_shape).copy(order='C')
            checked_owning_nhwc(out, expected_out_shape, f'op{op_index} output tensor{output}')
            return out, acc_i32

        if name == 'AVERAGE_POOL_2D':
            opts = self.options[op_index]
            need(opts['padding'] == 1 and opts['activation'] == 0 and ot['shape'] == [1, 1, 1, 64], 'pool options')
            need(it['scales'] == ot['scales'] and it['zero_points'] == ot['zero_points'], 'pool quantization')
            h, w = opts['filter']
            count = h * w
            need(h <= a.shape[1] and w <= a.shape[2], 'pool window bounds')
            total = a[0, :h, :w, :].astype(np.int64).sum(axis=(0, 1))
            acc_i32 = self.pi.checked_i32(total).copy(order='C')
            out = (np.sign(total) * ((np.abs(total) + count // 2) // count)).astype(np.int8).reshape(expected_out_shape).copy(order='C')
            checked_owning_nhwc(out, expected_out_shape, f'op{op_index} output tensor{output}')
            return out, acc_i32

        if name == 'RESHAPE':
            out = a.reshape(expected_out_shape).copy(order='C')
            checked_owning_nhwc(out, expected_out_shape, f'op{op_index} output tensor{output}')
            return out, None

        raise ValueError('Unsupported operator: ' + name)

    def run_prefix(self, feature_2d: np.ndarray, cohort_index: int, source_id: str, feature_sha256: str) -> tuple[np.ndarray, dict[int, np.ndarray], dict[int, np.ndarray | None], list[TensorNodeRecord]]:
        need(type(feature_2d) is np.ndarray and feature_2d.dtype == np.int8 and feature_2d.shape == (49, 10),
             'feature_2d must be (49, 10) int8')
        need(sha(feature_2d.tobytes(order='C')) == feature_sha256, 'feature_2d digest mismatch')
        t0 = feature_2d.reshape(1, 49, 10, 1).copy(order='C')
        checked_owning_nhwc(t0, (1, 49, 10, 1), 'tensor0 owning input')

        tensors: dict[int, np.ndarray] = {0: t0}
        accumulators: dict[int, np.ndarray | None] = {}
        trace: list[TensorNodeRecord] = []

        for op_idx in (0, 1):
            op = self.info['operators'][op_idx]
            in_idx = op['inputs'][0]
            out_idx = op['outputs'][0]
            in_arr = tensors[in_idx]
            out_arr, acc_arr = self.run_cpu_operator(op_idx, in_arr)
            tensors[out_idx] = out_arr
            accumulators[op_idx] = acc_arr
            trace.append(TensorNodeRecord(
                operator_index=op_idx,
                operator_name=op['name'],
                backend='cpu_integer',
                input_tensor=in_idx,
                output_tensor=out_idx,
                cohort_index=cohort_index,
                source_id=source_id,
                feature_sha256=feature_sha256,
                input_object_id=id(in_arr),
                output_object_id=id(out_arr),
                input_sha256=sha(in_arr.tobytes(order='C')),
                output_sha256=sha(out_arr.tobytes(order='C')),
                accumulator_sha256=None if acc_arr is None else sha(acc_arr.tobytes(order='C')),
                shape=list(out_arr.shape),
                values_count=int(out_arr.size),
            ))

        t23_2d = tensors[23].reshape(125, 64).copy(order='C')
        checked_owning_125x64(t23_2d, 'prefix produced tensor23 (125, 64)')
        return t23_2d, tensors, accumulators, trace

    def run_suffix(self, op4_out_2d: np.ndarray, cohort_index: int, source_id: str, feature_sha256: str) -> tuple[np.ndarray, dict[int, np.ndarray], dict[int, np.ndarray | None], list[TensorNodeRecord]]:
        checked_owning_125x64(op4_out_2d, 'op4_out_2d owning (125, 64) INT8')
        t26 = op4_out_2d.reshape(1, 25, 5, 64).copy(order='C')
        checked_owning_nhwc(t26, (1, 25, 5, 64), 'tensor26 (1, 25, 5, 64) owning INT8')

        tensors: dict[int, np.ndarray] = {26: t26}
        accumulators: dict[int, np.ndarray | None] = {}
        trace: list[TensorNodeRecord] = []

        for op_idx in (5, 6, 7, 8, 9, 10, 11):
            op = self.info['operators'][op_idx]
            in_idx = op['inputs'][0]
            out_idx = op['outputs'][0]
            in_arr = tensors[in_idx]
            out_arr, acc_arr = self.run_cpu_operator(op_idx, in_arr)
            tensors[out_idx] = out_arr
            accumulators[op_idx] = acc_arr
            trace.append(TensorNodeRecord(
                operator_index=op_idx,
                operator_name=op['name'],
                backend='cpu_integer',
                input_tensor=in_idx,
                output_tensor=out_idx,
                cohort_index=cohort_index,
                source_id=source_id,
                feature_sha256=feature_sha256,
                input_object_id=id(in_arr),
                output_object_id=id(out_arr),
                input_sha256=sha(in_arr.tobytes(order='C')),
                output_sha256=sha(out_arr.tobytes(order='C')),
                accumulator_sha256=None if acc_arr is None else sha(acc_arr.tobytes(order='C')),
                shape=list(out_arr.shape),
                values_count=int(out_arr.size),
            ))

        logits = tensors[33].copy(order='C')
        checked_owning_nhwc(logits, (1, 12), 'tensor33 pre-softmax INT8 logits')
        return logits, tensors, accumulators, trace

    def compute_full_cpu_oracle(self, feature_2d: np.ndarray) -> dict:
        """Independent full CPU oracle execution for verification only; never feeds candidate."""
        x = feature_2d.reshape(1, 49, 10, 1).copy(order='C')
        oracle_tensors: dict[int, np.ndarray] = {0: x}
        oracle_accs: dict[int, np.ndarray | None] = {}
        for op_idx in range(12):
            op = self.info['operators'][op_idx]
            in_idx = op['inputs'][0]
            out_idx = op['outputs'][0]
            if op_idx in (0, 1, 5, 6, 7, 8, 9, 10, 11):
                out_arr, acc_arr = self.run_cpu_operator(op_idx, oracle_tensors[in_idx])
            else:
                a = oracle_tensors[in_idx]
                wi, bi = op['inputs'][1:]
                b = self.constants[wi]
                bias = self.constants[bi]
                it = self.info['tensors'][in_idx]
                ot = self.info['tensors'][out_idx]
                wt = self.info['tensors'][wi]
                zp = int(it['zero_points'][0])
                if op['name'] == 'CONV_2D':
                    patches = self.pi.conv_patches(a, b.shape, ot['shape'], op['stride'], op['padding'], op['dilation'], zp)
                    weight = b.reshape(b.shape[0], -1)
                    acc = (patches.astype(np.int32) @ weight.astype(np.int32).T).astype(np.int64)
                    acc += bias.astype(np.int64) - zp * weight.astype(np.int64).sum(axis=1)
                else:
                    _, kh, kw, c = b.shape
                    patches = self.pi.conv_patches(a, (c, kh, kw, c), ot['shape'], op['stride'], op['padding'], op['dilation'], zp)
                    centered = patches.reshape(-1, kh * kw, c).astype(np.int64) - zp
                    acc = (centered * b.reshape(kh * kw, c).astype(np.int64)).sum(axis=1) + bias.astype(np.int64)
                acc_arr = self.pi.checked_i32(acc).copy(order='C')
                scale = np.array(wt['scales'], np.float64) * float(it['scales'][0]) / float(ot['scales'][0])
                activation = op.get('activation', self.options.get(op_idx, {}).get('activation', 0))
                out_arr = self.pi.requantize(acc, scale, int(ot['zero_points'][0]), activation).reshape(tuple(ot['shape'])).copy(order='C')
            oracle_tensors[out_idx] = out_arr
            oracle_accs[op_idx] = acc_arr

        ref_logits, _ = self.model.infer(x)
        need(np.array_equal(oracle_tensors[33], ref_logits), 'oracle tensor33 vs IntegerReference.infer mismatch')
        return dict(tensors=oracle_tensors, accumulators=oracle_accs, logits=ref_logits)


def evaluate_gate_with_historical_vad(
    bundle: hc.HybridBundle,
    cohort_index: int,
    source_id: str,
    source_sha256: str,
    pcm_sha256: str,
    quantized_logits_1d: list[int],
    *,
    scale: float = LOGITS_SCALE,
    zero_point: int = LOGITS_ZERO_POINT,
    vad_override: dict | None = None,
    claim_vad_recomputed: bool = False,
) -> dict:
    need(claim_vad_recomputed is False, 'historical VAD flags must never be marked as recomputed')
    need(type(cohort_index) is int and cohort_index in bundle.historical_vad_by_index, 'valid cohort index for VAD')
    need(math.isclose(float(scale), LOGITS_SCALE, rel_tol=0.0, abs_tol=1e-18) and type(zero_point) is int and zero_point == LOGITS_ZERO_POINT,
         'gate logits quantization scale/zero_point mismatch')

    hist_record = bundle.historical_vad_by_index[cohort_index]
    if vad_override is not None:
        need(type(vad_override) is dict, 'vad_override dictionary')
        need(vad_override.get('source_id') == source_id and vad_override.get('source_sha256') == source_sha256
             and vad_override.get('pcm_sha256') == pcm_sha256,
             'VAD record source_id/PCM SHA mismatch (cross-window VAD rejected)')
        vad_dict = vad_override['vad']
    else:
        need(hist_record['source_id'] == source_id and hist_record['source_sha256'] == source_sha256
             and hist_record['pcm_sha256'] == pcm_sha256,
             'historical VAD record PCM binding mismatch')
        vad_dict = hist_record['vad']

    need(vad_dict.get('native_sha256') == hc.NATIVE_VAD_SHA, 'historical VAD native_sha256 mismatch')
    gate_decision = bundle.quality_core.gate_candidate(
        bundle.voice_gate,
        quantized_logits_1d,
        scale,
        zero_point,
        vad_dict,
        bundle.frozen_policy,
        True,
    )
    pred_index = int(np.argmax(np.asarray(quantized_logits_1d, dtype=np.int8)))
    raw_pred = LABELS[pred_index]
    need(gate_decision['raw_prediction'] == raw_pred, 'dequantized-logit argmax vs INT8 argmax drift')
    return dict(
        prediction=raw_pred,
        action_allowed=gate_decision['action_allowed'],
        suggested_command=gate_decision['suggested_command'],
        rejection_reasons=list(gate_decision['rejection_reasons']),
        score=gate_decision['score'],
        score_gap=gate_decision['score_gap'],
        gate_decision=gate_decision,
        vad_reused=vad_dict,
        vad_recomputed=False,
        vad_source='historical_fixed_pcm',
        physical_action=False,
        virtual_action=False,
        deployable=False,
    )


def run_hybrid_session(
    bundle: hc.HybridBundle,
    output: Path,
    *,
    enabled: bool = False,
    mode: str = 'fixed12',
    profile: str = 'normal',
    mutate_hook=None,
    raise_on_error: bool = False,
) -> dict:
    """Execute 1-window smoke ('smoke1') or full 12-window ('fixed12') hybrid inference."""
    need(enabled is True, 'run_hybrid_session default-off')
    need(type(mode) is str and mode in ('smoke1', 'fixed12'), 'mode must be smoke1 or fixed12')
    c = bundle.shared_components
    b = bundle.shared_binding
    ct = bundle.shared_contract
    need(type(profile) is str and profile in ct.PROFILES, 'valid fixture profile required')

    output = hc.validate_output_dir(output, bundle.sources_root)
    output.mkdir(parents=False, exist_ok=False)

    executor = HybridGraphExecutor(bundle, enabled=True)
    cases2 = {i: c.reference.derive(2, i) for i in INDICES}
    cases4 = {i: c.reference.derive(4, i) for i in INDICES}
    dw_params = c.combination.depthwise_parameters()
    win_meta_by_index = {w['index']: w for w in bundle.selection12['windows']}
    target_indices = (0,) if mode == 'smoke1' else INDICES

    req = ct.fixture_request(hc.SHARED_CANDIDATE_MANIFEST_SHA, profile)
    env = bundle.wire_environment_type(c, profile)
    finite_sup = (
        b.previous().load('shared_process_fixture', b.FROZEN / 'shared_process_fixture.py').finite_supervised
        if profile in ct.FINITE_PROFILES else None
    )

    holder = {'stop': lambda: env.stop}
    session = bundle.shared_session_type(
        req,
        lambda: holder['stop'](),
        enabled=True,
        fixture=True,
        components=c,
        evidence=env.evidence,
        overrides=env.overrides,
    )

    rows = []
    calls = []
    features_concat = bytearray()
    logits_concat = bytearray()
    accepted2 = accepted4 = dw_calls = 0
    frontend_executed = prefix_executed = suffix_executed = gate_executed = 0
    active_call = None
    current_index = None
    stage = 'before_owner_start'
    primary_error = None
    failure_record = None
    secondary_errors = []
    ticket = None

    def check_stop(where: str):
        nonlocal stage
        stage = where
        env.boundary(where, current_index)
        if holder['stop']() is not False:
            raise __import__('batch_policy').BatchStop(f'hybrid stop at {where}')

    def publish_attention(value: dict):
        write_json_exclusive(
            output / 'attention_retained.json',
            dict(value, run_id=req['run_id'], fixture=True, real_infinite_hold_executed=False),
        )

    def operation(stopped):
        nonlocal ticket, stage, current_index, active_call, primary_error, failure_record
        nonlocal accepted2, accepted4, dw_calls, frontend_executed, prefix_executed, suffix_executed, gate_executed
        holder['stop'] = lambda: (env.stop or (stopped() is not False))
        try:
            stage = 'owner_start'
            if holder['stop']() is not False:
                raise __import__('batch_policy').BatchStop('stop before owner start')
            ticket = session.start()

            for index in target_indices:
                current_index = index
                w_meta = win_meta_by_index[index]
                cohort_item = bundle.cohort[index]
                need(cohort_item['source_id'] == w_meta['source_id']
                     and cohort_item['source_sha256'] == w_meta['source_sha256']
                     and cohort_item['pcm_sha256'] == w_meta['pcm_sha256'],
                     'cohort/selection12 window identity mismatch')

                # 1. Public WAV -> Frontend.process
                check_stop('before_frontend')
                feat_2d, fe_meta = bundle.frontend.process(cohort_item)
                frontend_executed += 1
                if mutate_hook is not None:
                    feat_2d = mutate_hook('after_frontend', index, feat_2d)
                need(type(feat_2d) is np.ndarray and feat_2d.dtype == np.int8 and feat_2d.shape == (49, 10),
                     'frontend output shape/dtype')
                feat_bytes = feat_2d.tobytes(order='C')
                feat_sha = sha(feat_bytes)
                need(feat_sha == w_meta['expected_feature']['sha256']
                     and feat_bytes == bundle.cpu420_board_features[index * 490:(index + 1) * 490],
                     'recomputed WAV feature mismatch against frozen oracle')

                # 2. CPU prefix (op0 -> tensor22, op1 -> tensor23)
                check_stop('before_prefix')
                t23_2d, prefix_tensors, prefix_accs, prefix_trace = executor.run_prefix(
                    feat_2d, index, cohort_item['source_id'], feat_sha
                )
                prefix_executed += 1
                if mutate_hook is not None:
                    t23_2d = mutate_hook('after_prefix', index, t23_2d)
                checked_owning_125x64(t23_2d, 'candidate prefix tensor23')

                # Independent CPU oracle for cross-checking intermediate tensors
                oracle = executor.compute_full_cpu_oracle(feat_2d)
                need(np.array_equal(prefix_tensors[22], oracle['tensors'][22])
                     and np.array_equal(prefix_accs[0], oracle['accumulators'][0]),
                     'prefix op0 tensor22/accumulator mismatch')
                need(np.array_equal(t23_2d, oracle['tensors'][23].reshape(125, 64))
                     and np.array_equal(prefix_accs[1], oracle['accumulators'][1]),
                     'prefix op1 tensor23/accumulator mismatch')

                # 3. SharedCall Op2 (tensor23 -> tensor24)
                check_stop('op2_before_submit')
                case2 = cases2[index]
                session.check_reuse()
                active_call = c.call_type(session.owner, case2, enabled=True)
                spec2 = active_call.spec
                stage = 'op2_call'
                need(t23_2d is not case2['a'], 'candidate t23_2d must be distinct object from case2["a"]')
                env2 = c.envelope_type(2, 23, index, cohort_item['source_id'], feat_sha, t23_2d)
                if mutate_hook is not None:
                    env2 = mutate_hook('before_op2_call', index, env2)
                out2, d2 = active_call(env2)
                accepted2 += 1
                session.check_reuse()
                need(np.array_equal(c.combination.wire_input(d2['input_chain'], spec2.first_job_id), t23_2d),
                     'submitted Op2 wire must equal dynamic prefix tensor23')
                calls.append(dict(
                    request_index=spec2.index,
                    cohort_index=index,
                    operator_index=2,
                    first_job_id=spec2.first_job_id,
                    accepted=True,
                ))

                # 4. CPU DW3 (tensor24 -> tensor25)
                upstream = c.combination.make_upstream(out2.tobytes(), case2, 'fixture')
                a_dw3 = c.combination.validate_upstream(upstream, case2, 'fixture')
                check_stop('before_depthwise')
                dynamic_t25, dw3_acc = c.depthwise(a_dw3, dw_params)
                dw_calls += 1
                if mutate_hook is not None:
                    dynamic_t25 = mutate_hook('after_dw3', index, dynamic_t25)
                env4 = c.combination.dynamic_envelope(upstream, dynamic_t25, cases4[index])
                need(env4.values is dynamic_t25, 'Op4 envelope must wrap actual dynamic DW3 output object')

                # 5. SharedCall Op4 (tensor25 -> tensor26)
                check_stop('op4_before_submit')
                session.check_reuse()
                active_call = c.call_type(session.owner, cases4[index], enabled=True)
                spec4 = active_call.spec
                stage = 'op4_call'
                if mutate_hook is not None:
                    env4 = mutate_hook('before_op4_call', index, env4)
                out4, d4 = active_call(env4)
                accepted4 += 1
                session.check_reuse()
                need(np.array_equal(c.combination.wire_input(d4['input_chain'], spec4.first_job_id), dynamic_t25),
                     'submitted Op4 wire must equal dynamic DW3 tensor25')
                calls.append(dict(
                    request_index=spec4.index,
                    cohort_index=index,
                    operator_index=4,
                    first_job_id=spec4.first_job_id,
                    accepted=True,
                ))
                check_stop('after_op4')

                # 6. CPU suffix (tensor26 -> op5..op11 -> tensor33 pre-softmax INT8 logits)
                op4_out_owning = out4.copy(order='C')
                if mutate_hook is not None:
                    op4_out_owning = mutate_hook('before_suffix', index, op4_out_owning)
                checked_owning_125x64(op4_out_owning, 'Op4 output owning (125, 64) INT8')
                logits_2d, suffix_tensors, suffix_accs, suffix_trace = executor.run_suffix(
                    op4_out_owning, index, cohort_item['source_id'], feat_sha
                )
                suffix_executed += 1
                if mutate_hook is not None:
                    logits_2d = mutate_hook('after_suffix', index, logits_2d)

                # Verify every suffix intermediate accumulator & output tensor against independent CPU oracle
                for op_idx in (5, 6, 7, 8, 9, 10, 11):
                    out_t = executor.info['operators'][op_idx]['outputs'][0]
                    if oracle['accumulators'][op_idx] is not None:
                        need(np.array_equal(suffix_accs[op_idx], oracle['accumulators'][op_idx]),
                             f'suffix op{op_idx} accumulator mismatch against independent oracle')
                    need(np.array_equal(suffix_tensors[out_t], oracle['tensors'][out_t]),
                         f'suffix op{op_idx} tensor{out_t} mismatch against independent oracle')

                logits_bytes = logits_2d.tobytes(order='C')
                logits_sha = sha(logits_bytes)
                need(len(logits_bytes) == 12
                     and logits_sha == w_meta['expected_logits']['sha256']
                     and logits_bytes == bundle.cpu420_board_logits[index * 12:(index + 1) * 12],
                     'candidate pre-softmax INT8 logits mismatch against CPU420/selection12 oracle')

                # 7. Classification & frozen voice gate with historical PCM-bound VAD
                logits_list = [int(x) for x in logits_2d.reshape(-1)]
                gate_info = evaluate_gate_with_historical_vad(
                    bundle,
                    index,
                    cohort_item['source_id'],
                    cohort_item['source_sha256'],
                    cohort_item['pcm_sha256'],
                    logits_list,
                )
                gate_executed += 1
                qual_oracle = bundle.quality_oracle_by_index[index]
                need(gate_info['prediction'] == w_meta['reference_prediction'] == qual_oracle['prediction'],
                     'classification label mismatch against oracle')
                need(gate_info['action_allowed'] is w_meta['reference_gate']['action_allowed']
                     and gate_info['suggested_command'] == w_meta['reference_gate']['suggested_command']
                     and gate_info['rejection_reasons'] == w_meta['reference_gate']['rejection_reasons'],
                     'frozen gate discrete decision/rejection_reasons mismatch against oracle')

                # 8. Save all per-window artifacts (22 shared artifacts + full hybrid prefix/suffix/logits/gate)
                w_folder = output / f'window_{index:03d}'
                w_folder.mkdir()
                shared_22 = {
                    'op2_input.i8': t23_2d.tobytes(),
                    'op2_weights.i8': case2['weights'].tobytes(),
                    'op2_bias.i32': case2['bias'].astype('<i4').tobytes(),
                    'op2_scales.f64': case2['scales'].astype('<f8').tobytes(),
                    'op2_output.i8': out2.tobytes(),
                    'op2_wire.bin': d2['input_chain'],
                    'op2_raw.i32': d2['raw'].astype('<i4').tobytes(),
                    'op2_corrected.i32': d2['corrected'].astype('<i4').tobytes(),
                    'dw3_input.i8': a_dw3.tobytes(),
                    'dw3_weights.i8': dw_params['weights'].tobytes(),
                    'dw3_bias.i32': dw_params['bias'].astype('<i4').tobytes(),
                    'dw3_scales.f64': dw_params['scales'].astype('<f8').tobytes(),
                    'dw3_acc.i32': dw3_acc.tobytes(),
                    'dw3_output.i8': dynamic_t25.tobytes(),
                    'op4_input.i8': dynamic_t25.tobytes(),
                    'op4_weights.i8': cases4[index]['weights'].tobytes(),
                    'op4_bias.i32': cases4[index]['bias'].astype('<i4').tobytes(),
                    'op4_scales.f64': cases4[index]['scales'].astype('<f8').tobytes(),
                    'op4_wire.bin': d4['input_chain'],
                    'op4_raw.i32': d4['raw'].astype('<i4').tobytes(),
                    'op4_corrected.i32': d4['corrected'].astype('<i4').tobytes(),
                    'op4_output.i8': out4.tobytes(),
                }
                saved_shared_22 = {name: write_exclusive(w_folder / name, raw) for name, raw in shared_22.items()}
                need(saved_shared_22 == bundle.shared_board_artifacts[index],
                     f'window_{index:03d} 22 shared artifacts differ from sealed shared12 board archive')

                hybrid_extra = {
                    'feature_00.i8': feat_bytes,
                    'prefix_op0_out_t22.i8': prefix_tensors[22].tobytes(order='C'),
                    'prefix_op1_out_t23.i8': t23_2d.tobytes(order='C'),
                    'suffix_op5_acc.i32': suffix_accs[5].astype('<i4').tobytes(order='C'),
                    'suffix_op5_out_t27.i8': suffix_tensors[27].tobytes(order='C'),
                    'suffix_op6_out_t28.i8': suffix_tensors[28].tobytes(order='C'),
                    'suffix_op7_out_t29.i8': suffix_tensors[29].tobytes(order='C'),
                    'suffix_op8_out_t30.i8': suffix_tensors[30].tobytes(order='C'),
                    'suffix_op9_out_t31.i8': suffix_tensors[31].tobytes(order='C'),
                    'suffix_op10_out_t32.i8': suffix_tensors[32].tobytes(order='C'),
                    'logits_t33.i8': logits_bytes,
                }
                saved_hybrid_extra = {name: write_exclusive(w_folder / name, raw) for name, raw in hybrid_extra.items()}

                full_trace = [
                    *(t.__dict__ for t in prefix_trace),
                    dict(
                        operator_index=2,
                        operator_name='CONV_2D',
                        backend='shared_driver_wire_fixture',
                        input_tensor=23,
                        output_tensor=24,
                        cohort_index=index,
                        source_id=cohort_item['source_id'],
                        feature_sha256=feat_sha,
                        input_object_id=id(t23_2d),
                        output_object_id=id(out2),
                        input_sha256=sha(t23_2d.tobytes(order='C')),
                        output_sha256=sha(out2.tobytes(order='C')),
                        raw_sha256=sha(d2['raw'].astype('<i4').tobytes()),
                        corrected_sha256=sha(d2['corrected'].astype('<i4').tobytes()),
                        wire_sha256=sha(d2['input_chain']),
                        shape=[1, 25, 5, 64],
                        values_count=8000,
                    ),
                    dict(
                        operator_index=3,
                        operator_name='DEPTHWISE_CONV_2D',
                        backend='cpu_shared_depthwise3',
                        input_tensor=24,
                        output_tensor=25,
                        cohort_index=index,
                        source_id=cohort_item['source_id'],
                        feature_sha256=feat_sha,
                        input_object_id=id(a_dw3),
                        output_object_id=id(dynamic_t25),
                        input_sha256=sha(a_dw3.tobytes(order='C')),
                        output_sha256=sha(dynamic_t25.tobytes(order='C')),
                        accumulator_sha256=sha(dw3_acc.tobytes()),
                        shape=[1, 25, 5, 64],
                        values_count=8000,
                    ),
                    dict(
                        operator_index=4,
                        operator_name='CONV_2D',
                        backend='shared_driver_wire_fixture',
                        input_tensor=25,
                        output_tensor=26,
                        cohort_index=index,
                        source_id=cohort_item['source_id'],
                        feature_sha256=feat_sha,
                        input_object_id=id(dynamic_t25),
                        output_object_id=id(out4),
                        input_sha256=sha(dynamic_t25.tobytes(order='C')),
                        output_sha256=sha(out4.tobytes(order='C')),
                        raw_sha256=sha(d4['raw'].astype('<i4').tobytes()),
                        corrected_sha256=sha(d4['corrected'].astype('<i4').tobytes()),
                        wire_sha256=sha(d4['input_chain']),
                        shape=[1, 25, 5, 64],
                        values_count=8000,
                    ),
                    *(t.__dict__ for t in suffix_trace),
                ]

                row = dict(
                    cohort_index=index,
                    source_id=cohort_item['source_id'],
                    label=cohort_item['label'],
                    wav=cohort_item['wav'],
                    offset=cohort_item['offset'],
                    source_sha256=cohort_item['source_sha256'],
                    pcm_sha256=cohort_item['pcm_sha256'],
                    feature_sha256=feat_sha,
                    logits_sha256=logits_sha,
                    candidate_pre_softmax_int8=logits_list,
                    prediction=gate_info['prediction'],
                    action_allowed=gate_info['action_allowed'],
                    suggested_command=gate_info['suggested_command'],
                    rejection_reasons=gate_info['rejection_reasons'],
                    gate_decision=gate_info['gate_decision'],
                    vad_recomputed=False,
                    vad_source='historical_fixed_pcm',
                    WAV_frontend_reexecuted=True,
                    prefix_dynamically_computed=True,
                    suffix_dynamically_computed=True,
                    op2_request_index=spec2.index,
                    op4_request_index=spec4.index,
                    op2_first_job_id=spec2.first_job_id,
                    op4_first_job_id=spec4.first_job_id,
                    op2_driver_metrics=d2['driver_metrics'],
                    op4_driver_metrics=d4['driver_metrics'],
                    actual_dynamic_payload_identity=True,
                    same_resource_pair=True,
                    shared_artifacts=saved_shared_22,
                    hybrid_artifacts=saved_hybrid_extra,
                    operator_trace=full_trace,
                    frontend_meta=fe_meta,
                )
                write_json_exclusive(w_folder / 'result.json', row)
                features_concat.extend(feat_bytes)
                logits_concat.extend(logits_bytes)
                rows.append(row)

        except BaseException as error:
            primary_error = error
            failure_record = dict(
                cohort_index=current_index,
                stage=stage,
                error_type=type(error).__name__,
                error_message=str(error),
                automatic_retry=False,
            )
            try:
                first = None if active_call is None else active_call.first_failure
                if type(first) is dict:
                    raw_payload = first.get('payload')
                    if type(raw_payload) is bytes and len(raw_payload) <= 32000:
                        failure_record['payload'] = write_exclusive(output / 'first_failure.bin', raw_payload)
                    diag = first.get('return_diagnostic')
                    if diag is not None:
                        from return_diagnostic import valid
                        need(valid(diag), 'bounded return diagnostic')
                        write_exclusive(
                            output / 'return_diagnostic.json',
                            (json.dumps(diag, sort_keys=True, ensure_ascii=True) + '\n').encode('ascii'),
                        )
            except BaseException as diag_err:
                secondary_errors.append(type(diag_err).__name__)
        finally:
            if not session.owner._held and not session.owner._unsafe:
                try:
                    session.close()
                except BaseException as close_err:
                    if primary_error is None:
                        primary_error = close_err
                    session.owner._hold(close_err)
        if primary_error is not None:
            raise primary_error
        return True

    supervise = finite_sup or c.supervisor
    signals = None
    with env.install():
        try:
            sup_res = supervise(session.owner, operation, publish_attention, lambda: env.stop, enabled=True)
            signals = sup_res['signals']
        except BaseException as err:
            if primary_error is None:
                primary_error = err
            signals = getattr(err, 'supervision_bridge_observation', None)
        state = session.observation()
        unresolved = any(
            state['resources'][k]
            for k in ('held', 'safety_unresolved', 'lease_retained', 'runner_retained', 'root_buffers_retained')
        )
        need(not unresolved or finite_sup is not None, 'supervisor cannot exit unresolved resources without finite fixture')
        env.capture(session, {})

    expected_count = len(target_indices)
    ok = primary_error is None and len(rows) == expected_count and not unresolved

    features_pin = write_exclusive(output / 'features.i8', bytes(features_concat)) if features_concat else None
    logits_pin = write_exclusive(output / 'logits.i8', bytes(logits_concat)) if logits_concat else None
    boundary_pin = write_json_exclusive(output / 'fixture_boundary.json', env.before_teardown)

    flags_dict = ct.flags(
        True,
        lock_access=session.lock_observation_attempted,
        board_access=session.hardware_constructor_attempted,
        driver_returns=session.owner._index,
    )
    summary = dict(
        **flags_dict,
        schema='kws-full-hybrid-offline-summary-v1',
        mode=mode,
        fixture_profile=profile,
        operation_success=ok,
        target_indices=list(target_indices),
        completed_indices=[r['cohort_index'] for r in rows],
        not_completed_indices=list(target_indices[len(rows):]),
        windows_completed=len(rows),
        frontend_executed_windows=frontend_executed,
        prefix_executed_windows=prefix_executed,
        accepted_op2_calls=accepted2,
        depthwise_executed_calls=dw_calls,
        accepted_op4_calls=accepted4,
        suffix_executed_windows=suffix_executed,
        gate_evaluated_windows=gate_executed,
        driver_returns=session.owner._index,
        returned_jobs=2 * session.owner._index,
        returned_pointwise_MACs=512000 * session.owner._index,
        depthwise_executed_logical_MACs=72000 * dw_calls,
        completed_chain_depthwise_logical_MACs=72000 * len(rows),
        recomputed_feature_scalars=490 * len(rows),
        verified_op2_scalars=dict(raw=8000 * accepted2, corrected=8000 * accepted2, int8=8000 * accepted2),
        verified_dw3_scalars=dict(acc=8000 * dw_calls, int8=8000 * dw_calls),
        verified_op4_scalars=dict(raw=8000 * accepted4, corrected=8000 * accepted4, int8=8000 * accepted4),
        verified_logits_scalars=12 * len(rows),
        features_artifact=features_pin,
        logits_artifact=logits_pin,
        fixture_boundary_artifact=boundary_pin,
        calls=calls,
        windows=rows,
        failure=failure_record,
        secondary_diagnostic_error_types=secondary_errors,
        session=state,
        signals=signals,
        safety_unresolved=unresolved,
        finite_supervisor_fixture=finite_sup is not None,
        vad_recomputed=False,
        vad_source='historical_fixed_pcm',
        quantized_softmax_op12_executed=False,
        physical_action=False,
        virtual_action=False,
        deployable=False,
    )
    write_json_exclusive(output / 'summary.json', summary)
    if raise_on_error and primary_error is not None:
        primary_error.hybrid_summary = summary
        raise primary_error
    return summary


if __name__ == '__main__':
    raise SystemExit('Library only. Use run_hybrid_candidate.py for offline execution.')
