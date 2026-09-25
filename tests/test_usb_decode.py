from datetime import datetime

import pytest

from device.usb_reader import (
    CMD_INIT_1, CMD_INIT_2, CMD_POLL_FAST, CMD_POLL_SLOW,
    crc8, decode_packet, KNOWN_DEVICES,
)


def build_packet(samples, packet_type=0x04, corrupt_crc=False):
    """Build a 64-byte FNIRSI HID packet from up to 4 (V, I, D+, D-, T) tuples."""
    body = bytearray([0xAA, packet_type])
    for v, i, dp, dn, t in samples:
        body += int(round(v * 100000)).to_bytes(4, 'little')
        body += int(round(i * 100000)).to_bytes(4, 'little')
        body += int(round(dp * 1000)).to_bytes(2, 'little')
        body += int(round(dn * 1000)).to_bytes(2, 'little')
        body += b'\x01'
        body += int(round(t * 10)).to_bytes(2, 'little')
    body += b'\x00' * (63 - len(body))  # pad remaining samples + unknown byte 62
    crc = crc8(body[1:63])
    body.append(crc ^ 0xFF if corrupt_crc else crc)
    assert len(body) == 64
    return bytes(body)


SAMPLES = [
    (5.01234, 1.5, 0.6, 0.3, 27.5),
    (9.0, 2.25, 2.7, 2.7, 30.0),
    (20.0, 4.99999, 0.0, 0.0, 45.1),
    (0.0, 0.0, 0.0, 0.0, 0.0),
]


def test_crc8_matches_reference_vectors():
    # The reference CRC (poly 0x39, init 0x42) check value for "123456789" is 0x4B
    # per the reveng line in baryluk's logger.
    assert crc8(b"123456789") == 0x4B
    # Command frames from the reference implementation carry their own CRC.
    for cmd in (CMD_INIT_1, CMD_INIT_2, CMD_POLL_FAST, CMD_POLL_SLOW):
        assert crc8(cmd[1:63]) == cmd[63], cmd.hex()


def test_decode_all_four_samples_with_correct_stride():
    now = datetime(2026, 1, 1, 12, 0, 0, 40000)
    readings = decode_packet(build_packet(SAMPLES), now=now)
    assert len(readings) == 4
    for r, (v, i, dp, dn, t) in zip(readings, SAMPLES):
        assert r['voltage'] == pytest.approx(v, abs=1e-5)
        assert r['current'] == pytest.approx(i, abs=1e-5)
        assert r['dp'] == pytest.approx(dp, abs=1e-3)
        assert r['dn'] == pytest.approx(dn, abs=1e-3)
        assert r['temperature'] == pytest.approx(t, abs=0.1)
        assert r['power'] == pytest.approx(v * i, abs=1e-4)
    assert [r['sample'] for r in readings] == [0, 1, 2, 3]


def test_sample_timestamps_are_10ms_apart_ending_at_now():
    now = datetime(2026, 1, 1, 12, 0, 0, 40000)
    ts = [datetime.fromisoformat(r['timestamp']) for r in decode_packet(build_packet(SAMPLES), now=now)]
    assert ts[-1] == now
    deltas = [(b - a).total_seconds() for a, b in zip(ts, ts[1:])]
    assert deltas == pytest.approx([0.01, 0.01, 0.01])


def test_non_data_packets_are_ignored():
    assert decode_packet(build_packet(SAMPLES, packet_type=0x03)) == []


def test_bad_crc_is_dropped():
    assert decode_packet(build_packet(SAMPLES, corrupt_crc=True)) == []


def test_short_or_malformed_packets_are_ignored():
    assert decode_packet(b"") == []
    assert decode_packet(b"\xaa\x04" + b"\x00" * 10) == []
    assert decode_packet(b"\x00" * 64) == []


def test_known_device_ids_match_fnirsi_hardware():
    ids = {(vid, pid): model for vid, pid, model, _ in KNOWN_DEVICES}
    assert ids[(0x2E3C, 0x5558)] == 'FNB58'
    assert ids[(0x2E3C, 0x0049)] == 'FNB48S'
    assert ids[(0x0483, 0x003A)] == 'FNB48'
    assert ids[(0x0483, 0x003B)] == 'C1'
    # FNB58 / FNB48S use the slow keep-alive
    assert {m: slow for _, _, m, slow in KNOWN_DEVICES} == {
        'FNB58': True, 'FNB48S': True, 'FNB48': False, 'C1': False}
