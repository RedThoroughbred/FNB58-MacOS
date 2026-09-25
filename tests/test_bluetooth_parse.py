import struct
from datetime import datetime

import pytest

from device.bluetooth_reader import FRAME_OFFSET, INIT_COMMANDS, NOTIFY_UUID, WRITE_UUID, parse_frame


def build_frame(voltage, current, power, prefix_len=FRAME_OFFSET, trailer=b""):
    return (b"\x00" * prefix_len
            + struct.pack('<iii', int(round(voltage * 10000)), int(round(current * 10000)), int(round(power * 10000)))
            + trailer)


def test_parse_frame_extracts_v_i_w():
    now = datetime(2026, 1, 1)
    r = parse_frame(build_frame(9.0123, 1.2345, 11.1234), now=now)
    assert r['voltage'] == pytest.approx(9.0123)
    assert r['current'] == pytest.approx(1.2345)
    assert r['power'] == pytest.approx(11.1234)
    assert r['timestamp'] == now.isoformat()
    assert r['dp'] == 0.0 and r['dn'] == 0.0 and r['temperature'] == 0.0


def test_parse_frame_rejects_short_frames():
    assert parse_frame(b"\x00" * (FRAME_OFFSET + 11)) is None


def test_parse_frame_filters_out_of_range_voltage():
    assert parse_frame(build_frame(-1.0, 0, 0)) is None
    assert parse_frame(build_frame(200.0, 0, 0)) is None


def test_parse_frame_accepts_negative_current():
    # Current direction can be negative (reverse power flow); only voltage is range-checked.
    r = parse_frame(build_frame(5.0, -0.5, -2.5))
    assert r['current'] == pytest.approx(-0.5)


def test_protocol_constants():
    assert WRITE_UUID == "0000ffe9-0000-1000-8000-00805f9b34fb"
    assert NOTIFY_UUID == "0000ffe4-0000-1000-8000-00805f9b34fb"
    assert INIT_COMMANDS == [bytes.fromhex("aa8100f4"), bytes.fromhex("aa8200a7")]
