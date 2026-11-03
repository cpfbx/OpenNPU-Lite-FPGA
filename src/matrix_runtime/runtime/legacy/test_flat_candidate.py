import dataclasses
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'frozen_source'))
sys.path.insert(1, str(ROOT))
import numpy as np
import chain_protocol as chain
import tiled_gemm as tiled
from matrix_panel_builder_candidate import build_panel_layout_cached_transactions
from pack_chain_flat_candidate import pack_chain_flat


def arrays(m=65, n=67, k=69, seed=20261020):
    rng = np.random.default_rng(seed)
    return rng.integers(-128, 128, (m, k), dtype=np.int8), rng.integers(-128, 128, (k, n), dtype=np.int8)


def jobs_for(m=65, n=67, k=69, layout=tiled.Layout.K_MAJOR, config=None):
    a, b = arrays(m, n, k)
    config = config or tiled.TileConfig(layout=layout)
    return list(tiled.iter_transactions(a, b, config))


class FlatCandidateTests(unittest.TestCase):
    def equivalent(self, jobs, first=1):
        old = chain.pack_chain(jobs, first)
        new = pack_chain_flat(jobs, first, enabled=True)
        self.assertEqual(old, new)
        self.assertIs(type(new[0]), bytes)
        self.assertIs(type(new[1]), list)
        self.assertTrue(all(type(r) is chain.ChainRecord for r in new[1]))
        return new

    def same_exception(self, jobs, first=1):
        errors = []
        for function in (lambda: chain.pack_chain(jobs, first),
                         lambda: pack_chain_flat(jobs, first, enabled=True)):
            try:
                function()
            except Exception as exc:
                errors.append((type(exc), str(exc)))
        self.assertEqual(len(errors), 2)
        self.assertEqual(errors[0], errors[1])

    def test_default_off(self):
        with self.assertRaisesRegex(ValueError, 'default-off'):
            pack_chain_flat([])

    def test_only_literal_enable(self):
        for enabled in (False, None, 1, 'true'):
            with self.subTest(enabled=enabled), self.assertRaises(ValueError):
                pack_chain_flat([], enabled=enabled)

    def test_empty_error(self):
        self.same_exception([])

    def test_row_major_shapes(self):
        for shape in [(1, 1, 1), (3, 5, 7), (64, 64, 64), (65, 67, 69), (128, 130, 129)]:
            with self.subTest(shape=shape):
                self.equivalent(jobs_for(*shape, layout=tiled.Layout.ROW_MAJOR))

    def test_k_major_shapes(self):
        for shape in [(1, 1, 1), (3, 5, 7), (63, 64, 65), (64, 64, 64), (65, 67, 69), (128, 130, 129)]:
            with self.subTest(shape=shape):
                self.equivalent(jobs_for(*shape))

    def test_row_major_nondefault_blocks(self):
        config = tiled.TileConfig(bm=17, bn=31, bk=7)
        self.equivalent(jobs_for(config=config))

    def test_k_major_nondefault_mn_blocks(self):
        config = tiled.TileConfig(bm=17, bn=31, bk=64, layout=tiled.Layout.K_MAJOR)
        self.equivalent(jobs_for(config=config))

    def test_full_256(self):
        wire, records = self.equivalent(jobs_for(256, 256, 256))
        self.assertEqual(len(records), 16)
        self.assertEqual(len(wire), sum(64 + len(r.payload) for r in records))

    def test_two_real_512_banks(self):
        for input_id in (42, 43):
            with self.subTest(input_id=input_id):
                a = np.frombuffer((ROOT / 'bank' / f'input_{input_id}_a.bin').read_bytes(), dtype=np.int8).reshape(512, 512).copy()
                b = np.frombuffer((ROOT / 'bank' / f'input_{input_id}_b.bin').read_bytes(), dtype=np.int8).reshape(512, 512).copy()
                jobs = build_panel_layout_cached_transactions(a, b, tiled.TileConfig(layout=tiled.Layout.K_MAJOR), enabled=True).transactions
                wire, records = self.equivalent(jobs)
                self.assertEqual(len(wire), 4198400)
                self.assertEqual(len(records), 64)

    def test_fused_bias_variants_both_layouts(self):
        for layout in tiled.Layout:
            for use_bias in (False, True):
                for relu in (False, True):
                    for rounded in (False, True):
                        with self.subTest(layout=layout, bias=use_bias, relu=relu, rounded=rounded):
                            jobs = jobs_for(9, 11, 65, layout=layout)
                            quant = tiled.RequantizeConfig(-1234567, 31, rounded, relu, -128)
                            fused = [tiled.make_fused_transaction(j, quant,
                                      np.arange(j.actual_bn, dtype=np.int32) - 5 if use_bias else None) for j in jobs]
                            self.equivalent(fused)

    def test_generator_once(self):
        jobs = jobs_for()
        seen = []
        def once():
            for i, job in enumerate(jobs):
                seen.append(i)
                yield job
        result = pack_chain_flat(once(), enabled=True)
        self.assertEqual(result, chain.pack_chain(jobs))
        self.assertEqual(seen, list(range(len(jobs))))

    def test_job_id_wrap(self):
        jobs = jobs_for()
        _, records = self.equivalent(jobs, 0xFFFF_FFFE)
        self.assertEqual([r.header.job_id for r in records[:4]], [0xFFFF_FFFE, 0xFFFF_FFFF, 0, 1])

    def test_invalid_first_job_type(self):
        self.same_exception(jobs_for(), 'not an integer')

    def test_payload_extent_corruption(self):
        jobs = jobs_for()
        jobs[0] = dataclasses.replace(jobs[0], payload=jobs[0].payload[:-9])
        self.same_exception(jobs)

    def test_k_major_wrong_bk(self):
        jobs = jobs_for()
        jobs[0] = dataclasses.replace(jobs[0], config=tiled.TileConfig(bk=32, layout=tiled.Layout.K_MAJOR))
        self.same_exception(jobs)

    def test_geometry_corruption(self):
        jobs = jobs_for()
        jobs[0] = dataclasses.replace(jobs[0], m_offset=512)
        self.same_exception(jobs)

    def test_matrix_dimension_corruption(self):
        jobs = jobs_for()
        jobs[0] = dataclasses.replace(jobs[0], matrix_m=513)
        self.same_exception(jobs)

    def test_all_original_header_validation_calls_retained(self):
        jobs = jobs_for()
        parser = chain.parse_chain_header
        for operation in (lambda: chain.pack_chain(jobs), lambda: pack_chain_flat(jobs, enabled=True)):
            with patch.object(chain, 'parse_chain_header', wraps=parser) as observed:
                operation()
                self.assertEqual(observed.call_count, len(jobs))

    def test_zero_intermediate_record_bytes_materializations(self):
        jobs = jobs_for()
        getter = chain.ChainRecord.bytes.fget
        sizes = []
        def observed(record):
            raw = getter(record)
            sizes.append(len(raw))
            return raw
        with patch.object(chain.ChainRecord, 'bytes', property(observed)):
            old = chain.pack_chain(jobs)
            self.assertEqual(len(sizes), len(jobs))
            self.assertEqual(sum(sizes), len(old[0]))
            sizes.clear()
            new = pack_chain_flat(jobs, enabled=True)
            self.assertEqual(sizes, [])
            self.assertEqual(new, old)

    def test_no_stale_cross_request_cache(self):
        a, b = arrays(64, 64, 64)
        config = tiled.TileConfig(layout=tiled.Layout.K_MAJOR)
        before = pack_chain_flat(tiled.iter_transactions(a, b, config), enabled=True)[0]
        a.fill(-128)
        b.fill(127)
        jobs = list(tiled.iter_transactions(a, b, config))
        after, _ = self.equivalent(jobs)
        self.assertNotEqual(before, after)


if __name__ == '__main__':
    unittest.main(verbosity=2)
