import pytest

from device.data_processor import DataProcessor
from tests.fakes import reading_series


def test_advanced_statistics_use_timestamps_not_assumed_rate():
    # 11 samples at 10 Hz (Bluetooth) -> 1.0 s, 5 V @ 2 A = 10 W
    data = reading_series(11, dt_s=0.1, voltage=5.0, current=2.0)
    stats = DataProcessor.calculate_advanced_statistics(data)
    assert stats['sample_count'] == 11
    assert stats['duration_seconds'] == pytest.approx(1.0)
    assert stats['sample_rate_hz'] == pytest.approx(10.0)
    assert stats['energy_wh'] == pytest.approx(10.0 / 3600)
    assert stats['capacity_ah'] == pytest.approx(2.0 / 3600)
    assert stats['capacity_mah'] == pytest.approx(2000.0 / 3600)


def test_advanced_statistics_fallback_without_timestamps():
    data = [{'voltage': 5.0, 'current': 1.0, 'power': 5.0} for _ in range(101)]
    stats = DataProcessor.calculate_advanced_statistics(data)
    assert stats['duration_seconds'] == pytest.approx(1.0)  # assumes 100 Hz
    assert stats['energy_wh'] == pytest.approx(5.0 / 3600)


def test_advanced_statistics_empty():
    assert DataProcessor.calculate_advanced_statistics([]) == {}


def test_html_report_handles_null_connection_type(tmp_path):
    session = {
        'start_time': '2026-01-01T12:00:00',
        'end_time': '2026-01-01T12:00:01',
        'connection_type': None,
        'data': reading_series(20, dt_s=0.1),
    }
    out = tmp_path / 'report.html'
    DataProcessor.generate_html_report(session, str(out))
    html = out.read_text()
    assert '<html' in html.lower()
    assert '10.0 Hz' in html or '10 Hz' in html


def test_text_report_handles_null_connection_type():
    session = {'connection_type': None, 'data': reading_series(5), 'stats': {}}
    text = DataProcessor.generate_report(session)
    assert 'Connection: N/A' in text
