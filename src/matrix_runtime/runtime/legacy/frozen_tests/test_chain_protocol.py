import unittest

import numpy as np

from chain_protocol import (
    CHAIN_HEADER_BYTES,
    CHAIN_MAGIC,
    FLAG_BIAS,
    FLAG_CHAIN_LAST,
    FLAG_FUSED,
    FLAG_RELU,
    FLAG_ROUND,
    FLAG_SATURATE,
    build_chain_record,
    pack_chain,
    parse_chain_header,
    split_chain_output,
)
from tiled_gemm import RequantizeConfig, TileConfig, iter_transactions, make_fused_transaction


class ChainProtocolTests(unittest.TestCase):
    def setUp(self) -> None:
        self.a = np.arange(9 * 11, dtype=np.int8).reshape(9, 11)
        self.b = (np.arange(11 * 7, dtype=np.int8) - 30).reshape(11, 7)
        self.jobs = list(iter_transactions(self.a, self.b, TileConfig(4, 5, 6)))

    def test_dense_chain_headers_lengths_and_last_flag(self) -> None:
        payload, records = pack_chain(self.jobs, first_job_id=0xFFFF_FFFE)
        self.assertEqual(len(records), len(self.jobs))
        self.assertEqual(records[0].header.job_id, 0xFFFF_FFFE)
        self.assertEqual(records[2].header.job_id, 0)
        self.assertTrue(records[-1].header.chain_last)
        self.assertTrue(all(not record.header.chain_last for record in records[:-1]))
        self.assertEqual(len(payload), sum(len(record.bytes) for record in records))
        for record in records:
            self.assertEqual(len(record.header_bytes), CHAIN_HEADER_BYTES)
            self.assertEqual(len(record.payload) % 8, 0)
            self.assertEqual(record.header.output_transport_bytes % 8, 0)
            self.assertFalse(record.header.fused)

    def test_fused_header_freezes_flags_bias_and_signed_fields(self) -> None:
        base = self.jobs[-1]
        fused = make_fused_transaction(
            base,
            RequantizeConfig(-12345, 7, round_enable=True, relu=True, output_zero_point=-5),
            np.arange(base.actual_bn, dtype=np.int32),
        )
        record = build_chain_record(fused, 9, chain_last=True)
        expected_flags = (
            FLAG_FUSED | FLAG_BIAS | FLAG_RELU | FLAG_ROUND | FLAG_SATURATE | FLAG_CHAIN_LAST
        )
        self.assertEqual(record.header.flags, expected_flags)
        self.assertEqual(record.header.scale_mult, -12345)
        self.assertEqual(record.header.scale_shift, 7)
        self.assertEqual(record.header.output_zero_point, -5)
        self.assertEqual(record.header.output_valid_bytes, base.actual_bm * base.actual_bn)

    def test_corrupted_header_is_rejected(self) -> None:
        record = build_chain_record(self.jobs[0], 1, chain_last=True)
        bad_magic = bytearray(record.header_bytes)
        bad_magic[0:4] = (CHAIN_MAGIC ^ 1).to_bytes(4, "little")
        with self.assertRaisesRegex(ValueError, "magic"):
            parse_chain_header(bytes(bad_magic))
        bad_length = bytearray(record.header_bytes)
        bad_length[48:52] = (record.header.output_transport_bytes + 8).to_bytes(4, "little")
        with self.assertRaisesRegex(ValueError, "output transport"):
            parse_chain_header(bytes(bad_length))

    def test_512_chain_fits_simple_dma_limit_and_matches_frozen_size(self) -> None:
        a = np.zeros((512, 512), dtype=np.int8)
        b = np.zeros((512, 512), dtype=np.int8)
        payload, records = pack_chain(iter_transactions(a, b, TileConfig(64, 64, 64)))
        self.assertEqual(len(records), 64)
        self.assertEqual(len(payload), 4_198_400)
        self.assertLess(len(payload), (1 << 23) - 1)

    def test_empty_chain_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "at least one"):
            pack_chain([])

    def test_split_output_removes_and_checks_transport_padding(self) -> None:
        _, records = pack_chain(self.jobs)
        chunks = []
        expected = []
        for index, record in enumerate(records):
            valid = bytes([index + 1]) * record.header.output_valid_bytes
            expected.append(valid)
            chunks.append(
                valid
                + bytes(
                    record.header.output_transport_bytes
                    - record.header.output_valid_bytes
                )
            )
        self.assertEqual(split_chain_output(b"".join(chunks), records), expected)

        malformed = bytearray(b"".join(chunks))
        first_valid = records[0].header.output_valid_bytes
        first_transport = records[0].header.output_transport_bytes
        if first_transport > first_valid:
            malformed[first_valid] = 1
            with self.assertRaisesRegex(ValueError, "nonzero padding"):
                split_chain_output(bytes(malformed), records)
        with self.assertRaisesRegex(ValueError, "output length"):
            split_chain_output(b"".join(chunks)[:-1], records)


if __name__ == "__main__":
    unittest.main()
