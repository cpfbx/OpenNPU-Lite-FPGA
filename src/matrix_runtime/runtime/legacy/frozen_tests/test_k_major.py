"""Golden-model tests for the D006-2 K-major layout and protocol V2.

These tests are white-box: they exercise the pack/unpack byte order and the
bank/address mapping directly, plus the v1-vs-v2 output byte-exactness gate and
the chain-header V2 round-trip.  They run with NumPy only and never touch the
board, matching the frozen execution order (06_复核修正记录.md §6 step 3).

Address-mapping contract under test (06 §3):
    write address: addr = group*64 + k      bank: lane in [0,7]
    read address : (row//8)*64 + bank_k     bank: row%8   (unchanged RTL)
"""

import unittest

import numpy as np

from chain_protocol import (
    CHAIN_VERSION_V2,
    FLAG_K_MAJOR,
    build_chain_record,
    pack_chain,
    parse_chain_header,
)
from tiled_gemm import (
    K_MAJOR_BK,
    K_MAJOR_SEGMENT,
    Layout,
    RequantizeConfig,
    TileConfig,
    _k_major_a_bytes,
    _k_major_b_bytes,
    _unpack_k_major_a,
    _unpack_k_major_b,
    emulate_fused_transaction,
    input_transport_bytes,
    iter_transactions,
    k_major_a_bank_address,
    k_major_groups,
    make_fused_transaction,
    tiled_gemm,
)

V1 = TileConfig(64, 64, 64)
V2 = TileConfig(64, 64, 64, Layout.K_MAJOR)


class KMajorPackTests(unittest.TestCase):
    def test_a_and_b_pack_unpack_roundtrip(self) -> None:
        rng = np.random.default_rng(1)
        for dim in (1, 3, 7, 8, 9, 15, 16, 31, 64):
            for actual_bk in (1, 5, 8, 31, 63, 64):
                a = rng.integers(-128, 128, (dim, actual_bk), dtype=np.int8)
                a_packed = _k_major_a_bytes(a, dim, actual_bk)
                self.assertEqual(len(a_packed), k_major_groups(dim) * K_MAJOR_SEGMENT)
                np.testing.assert_array_equal(_unpack_k_major_a(a_packed, dim, actual_bk), a)

                b = rng.integers(-128, 128, (actual_bk, dim), dtype=np.int8)
                b_packed = _k_major_b_bytes(b, dim, actual_bk)
                self.assertEqual(len(b_packed), k_major_groups(dim) * K_MAJOR_SEGMENT)
                np.testing.assert_array_equal(_unpack_k_major_b(b_packed, dim, actual_bk), b)

    def test_a_beat_spreads_across_eight_banks(self) -> None:
        # One AXI beat = 8 lanes = 8 rows (fixed g, k).  Each lane must map to a
        # distinct bank (no single-write-port conflict) and the byte order must
        # equal bytes[g*512 + k*8 + r] == A[g*8 + r][k].
        rng = np.random.default_rng(2)
        block = rng.integers(-128, 128, (64, 64), dtype=np.int8)
        packed = _k_major_a_bytes(block, 64, 64)
        for g in range(8):
            for k in range(64):
                banks = set()
                for r in range(8):
                    bank, addr = k_major_a_bank_address(g * 8 + r, k)
                    self.assertEqual(bank, r)
                    self.assertEqual(addr, g * 64 + k)
                    self.assertEqual(
                        packed[g * K_MAJOR_SEGMENT + k * 8 + r],
                        int(block[g * 8 + r, k]) & 0xFF,
                    )
                    banks.add(bank)
                self.assertEqual(len(banks), 8)

    def test_b_beat_spreads_across_eight_banks(self) -> None:
        rng = np.random.default_rng(3)
        block = rng.integers(-128, 128, (64, 64), dtype=np.int8)
        packed = _k_major_b_bytes(block, 64, 64)
        for g in range(8):
            for k in range(64):
                for c in range(8):
                    # byte (g, k, c) -> bank c, address g*64 + k == B[k][g*8 + c]
                    self.assertEqual(
                        packed[g * K_MAJOR_SEGMENT + k * 8 + c],
                        int(block[k, g * 8 + c]) & 0xFF,
                    )

    def test_read_path_address_recovers_k_major_value(self) -> None:
        # The unchanged read path (rtl:268) fetches bank[row%8] at
        # (row//8)*64 + bank_k.  Assert it recovers A[row][bank_k] exactly,
        # which is the mathematical reason the read path needs zero changes.
        rng = np.random.default_rng(4)
        block = rng.integers(-128, 128, (64, 64), dtype=np.int8)
        packed = _k_major_a_bytes(block, 64, 64)
        for row in range(64):
            for bank_k in range(64):
                idx = (row // 8) * K_MAJOR_SEGMENT + bank_k * 8 + (row % 8)
                self.assertEqual(packed[idx], int(block[row, bank_k]) & 0xFF)


class KMajorGoldenModelTests(unittest.TestCase):
    def test_k_major_matches_numpy_and_v1_output(self) -> None:
        rng = np.random.default_rng(20260908)
        dimensions = (1, 3, 4, 7, 8, 15, 16, 31, 50)
        checked = 0
        for m in dimensions:
            for n in dimensions:
                for k in dimensions:
                    a = rng.integers(-128, 128, (m, k), dtype=np.int8)
                    b = rng.integers(-128, 128, (k, n), dtype=np.int8)
                    expected = a.astype(np.int32) @ b.astype(np.int32)
                    out_v1, _ = tiled_gemm(a, b, V1)
                    out_v2, _ = tiled_gemm(a, b, V2)
                    np.testing.assert_array_equal(out_v2, expected)
                    # v1/v2 对拍: outputs must be byte-identical (the payloads
                    # intentionally differ; only the INT32 result must not).
                    np.testing.assert_array_equal(out_v1, out_v2)
                    checked += 1
        self.assertEqual(checked, len(dimensions) ** 3)

    def test_full_512_transport_is_layout_invariant(self) -> None:
        # Full 64x64 tiles have no padding in either layout, so the 512^3 chain
        # payload must stay exactly 4,198,400 bytes (matches the frozen v1 test).
        a = np.zeros((512, 512), dtype=np.int8)
        b = np.zeros((512, 512), dtype=np.int8)
        v1_payload, _ = pack_chain(iter_transactions(a, b, V1))
        v2_payload, records = pack_chain(iter_transactions(a, b, V2))
        self.assertEqual(len(records), 64)
        self.assertEqual(len(v2_payload), 4_198_400)
        self.assertEqual(len(v2_payload), len(v1_payload))
        self.assertLess(len(v2_payload), (1 << 23) - 1)

    def test_tail_and_group_padding_overhead_matches_length_function(self) -> None:
        # Tail K block (matrix_k=100) is padded to BK=64 in v2.
        a = np.zeros((64, 100), dtype=np.int8)
        b = np.zeros((100, 64), dtype=np.int8)
        v1 = next(iter_transactions(a, b, V1))
        v2 = next(iter_transactions(a, b, V2))
        self.assertEqual(v1.expected_input_bytes, 12800)  # 64*64*2 + (64*36 + 36*64)
        self.assertEqual(v2.expected_input_bytes, 16384)  # 2 blocks x (4096 + 4096)
        self.assertEqual(
            v2.expected_input_bytes,
            input_transport_bytes(64, 64, 64, 100, Layout.K_MAJOR),
        )

        # BM=50 is not a multiple of 8 -> rounded up to 7 groups.
        c = np.zeros((50, 64), dtype=np.int8)
        d = np.zeros((64, 64), dtype=np.int8)
        v2b = next(iter_transactions(c, d, TileConfig(50, 64, 64, Layout.K_MAJOR)))
        self.assertEqual(v2b.expected_input_bytes, 7 * 512 + 8 * 512)  # 7680
        self.assertEqual(v2b.effective_input_bytes, 50 * 64 + 64 * 64)  # logical, unpadded

    def test_bk_must_be_64_for_k_major(self) -> None:
        with self.assertRaises(ValueError):
            TileConfig(64, 64, 32, Layout.K_MAJOR).validate()

    def test_k_major_fused_output_matches_legacy(self) -> None:
        a = np.array([[1, -2, 3], [-4, 5, -6]], dtype=np.int8)
        b = np.array([[7, -8, 9], [10, 11, -12], [-13, 14, 15]], dtype=np.int8)
        config = RequantizeConfig(3, 2, round_enable=True, output_zero_point=1)
        bias = np.array([4, -5, 6], dtype=np.int32)
        fused_v1 = make_fused_transaction(next(iter_transactions(a, b, TileConfig(2, 3, 64))), config, bias)
        fused_v2 = make_fused_transaction(next(iter_transactions(a, b, V2)), config, bias)
        self.assertEqual(emulate_fused_transaction(fused_v1), emulate_fused_transaction(fused_v2))


class KMajorProtocolTests(unittest.TestCase):
    def test_v2_chain_header_round_trips(self) -> None:
        a = np.arange(9 * 11, dtype=np.int8).reshape(9, 11)
        b = (np.arange(11 * 7, dtype=np.int8) - 30).reshape(11, 7)
        jobs = list(iter_transactions(a, b, TileConfig(8, 8, 64, Layout.K_MAJOR)))
        payload, records = pack_chain(jobs)
        self.assertGreater(len(records), 1)
        for record in records:
            self.assertEqual(record.header.version, CHAIN_VERSION_V2)
            self.assertTrue(record.header.k_major)
            self.assertTrue(record.header.flags & FLAG_K_MAJOR)
            self.assertEqual(record.header.block_k, 64)
            self.assertEqual(record.header.input_transport_bytes % 8, 0)
            parsed = parse_chain_header(record.header_bytes)
            self.assertEqual(parsed.version, CHAIN_VERSION_V2)
            self.assertEqual(parsed.input_transport_bytes, record.header.input_transport_bytes)
            # Single length function must agree with the parsed header.
            self.assertEqual(
                parsed.input_transport_bytes,
                input_transport_bytes(
                    parsed.block_m,
                    parsed.block_n,
                    parsed.block_k,
                    parsed.matrix_k,
                    Layout.K_MAJOR,
                    bias_transport_bytes=parsed.bias_transport_bytes,
                ),
            )
        self.assertEqual(len(payload), sum(len(r.bytes) for r in records))

    def test_v1_header_rejects_stray_k_major_flag(self) -> None:
        a = np.arange(16, dtype=np.int8).reshape(4, 4)
        b = np.arange(16, dtype=np.int8).reshape(4, 4)
        record = build_chain_record(next(iter_transactions(a, b, TileConfig(4, 4, 64))), 1, chain_last=True)
        mutated = bytearray(record.header_bytes)
        flags = int.from_bytes(mutated[0x0C:0x10], "little")
        mutated[0x0C:0x10] = (flags | FLAG_K_MAJOR).to_bytes(4, "little")
        with self.assertRaisesRegex(ValueError, "must not set"):
            parse_chain_header(bytes(mutated))

    def test_v2_header_requires_k_major_flag(self) -> None:
        a = np.arange(16, dtype=np.int8).reshape(4, 4)
        b = np.arange(16, dtype=np.int8).reshape(4, 4)
        record = build_chain_record(
            next(iter_transactions(a, b, TileConfig(4, 4, 64, Layout.K_MAJOR))),
            1,
            chain_last=True,
        )
        mutated = bytearray(record.header_bytes)
        flags = int.from_bytes(mutated[0x0C:0x10], "little")
        mutated[0x0C:0x10] = (flags & ~FLAG_K_MAJOR).to_bytes(4, "little")
        with self.assertRaisesRegex(ValueError, "requires the K_MAJOR flag"):
            parse_chain_header(bytes(mutated))

    def test_v2_header_rejects_non_64_block_k(self) -> None:
        a = np.arange(16, dtype=np.int8).reshape(4, 4)
        b = np.arange(16, dtype=np.int8).reshape(4, 4)
        record = build_chain_record(
            next(iter_transactions(a, b, TileConfig(4, 4, 64, Layout.K_MAJOR))),
            1,
            chain_last=True,
        )
        mutated = bytearray(record.header_bytes)
        # block_mnk is word 9 at offset 0x24; block_k lives in bits [23:16].
        block_mnk = int.from_bytes(mutated[0x24:0x28], "little")
        block_mnk = (block_mnk & 0xFF00FFFF) | (32 << 16)  # block_k = 32
        mutated[0x24:0x28] = block_mnk.to_bytes(4, "little")
        with self.assertRaisesRegex(ValueError, "block_k == 64"):
            parse_chain_header(bytes(mutated))


if __name__ == "__main__":
    unittest.main()
