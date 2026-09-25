import json

import pytest

from device.device_manager import DeviceManager
from tests.fakes import FakeReader, make_reading, reading_series


def manager(usb_fail=False, bt_fail=False):
    readers = {}

    def factory(kind, fail):
        def make(**kw):
            readers[kind] = FakeReader(kind, fail_connect=fail)
            return readers[kind]
        return make

    dm = DeviceManager(reader_factories={'usb': factory('usb', usb_fail), 'bluetooth': factory('bluetooth', bt_fail)})
    return dm, readers


def test_auto_prefers_usb():
    dm, readers = manager()
    result = dm.connect('auto')
    assert result['connection_type'] == 'usb'
    assert 'bluetooth' not in readers


def test_auto_falls_back_to_bluetooth():
    dm, readers = manager(usb_fail=True)
    assert dm.connect('auto')['connection_type'] == 'bluetooth'
    assert readers['usb'].disconnect_calls == 1  # failed reader is cleaned up


def test_all_backends_failing_raises_with_both_errors():
    dm, _ = manager(usb_fail=True, bt_fail=True)
    with pytest.raises(ConnectionError) as ei:
        dm.connect('auto')
    assert 'usb' in str(ei.value) and 'bluetooth' in str(ei.value)
    assert not dm.is_connected


def test_explicit_mode_does_not_fall_back():
    dm, readers = manager(usb_fail=True)
    with pytest.raises(ConnectionError):
        dm.connect('usb')
    assert 'bluetooth' not in readers


def test_unknown_mode_rejected():
    dm, _ = manager()
    with pytest.raises(ValueError):
        dm.connect('serial')


def test_double_connect_rejected():
    dm, _ = manager()
    dm.connect('usb')
    with pytest.raises(ConnectionError):
        dm.connect('usb')


def test_callbacks_are_deduplicated_and_receive_enhanced_reading():
    dm, readers = manager()
    dm.connect('usb')
    dm.start_monitoring()
    got = []
    dm.register_callback(got.append)
    dm.register_callback(got.append)  # simulate a second /api/connect
    readers['usb'].push(make_reading(voltage=5.0, current=1.0))
    assert len(got) == 1
    assert got[0]['protocol']['protocol'] == 'Standard USB'
    assert got[0]['has_alerts'] is False


def test_recording_stats_integrate_from_timestamps():
    dm, readers = manager()
    dm.connect('usb')
    dm.start_monitoring()
    dm.start_recording(name='bench')
    # 101 samples at 10 ms = exactly 1.0 s recorded, 5 V @ 2 A = 10 W
    for r in reading_series(101, dt_s=0.01, voltage=5.0, current=2.0):
        readers['usb'].push(r)
    session = dm.stop_recording()

    s = session['stats']
    assert session['name'] == 'bench'
    assert s['samples_collected'] == 101
    assert s['duration_s'] == pytest.approx(1.0)
    assert s['total_energy_wh'] == pytest.approx(10.0 / 3600)
    assert s['total_capacity_ah'] == pytest.approx(2.0 / 3600)
    assert s['avg_voltage'] == pytest.approx(5.0)
    assert s['min_voltage'] == 5.0 and s['max_voltage'] == 5.0
    assert len(session['data']) == 101


def test_stats_are_json_serialisable_before_any_sample():
    dm, _ = manager()
    dm.start_recording()
    text = json.dumps(dm.get_stats())
    assert 'Infinity' not in text
    assert dm.get_stats()['min_voltage'] is None


def test_large_time_gap_uses_fallback_dt():
    dm, readers = manager()
    dm.connect('bluetooth')
    dm.start_monitoring()
    dm.start_recording()
    series = reading_series(2, dt_s=60.0, voltage=5.0, current=1.0)  # 60 s gap (reconnect)
    for r in series:
        readers['bluetooth'].push(r)
    assert dm.get_stats()['duration_s'] == pytest.approx(0.1)  # bluetooth fallback


def test_get_recent_data_bounds():
    dm, readers = manager()
    dm.connect('usb')
    dm.start_monitoring()
    for r in reading_series(10):
        readers['usb'].push(r)
    assert len(dm.get_recent_data(3)) == 3
    assert len(dm.get_recent_data(100)) == 10
    assert dm.get_recent_data(0) == []


def test_disconnect_resets_state():
    dm, readers = manager()
    dm.connect('usb')
    dm.disconnect()
    assert not dm.is_connected
    assert dm.reader is None
    assert dm.get_connection_info() == {'connected': False}
    assert readers['usb'].disconnect_calls == 1


def test_usb_only_features_gated():
    dm, _ = manager(usb_fail=True)
    dm.connect('auto')
    with pytest.raises(ValueError):
        dm.trigger_voltage('pd', 9)
    with pytest.raises(ValueError):
        dm.adjust_qc3_voltage(9.0)
