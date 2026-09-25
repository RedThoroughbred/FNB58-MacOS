import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


@pytest.fixture()
def app_client(tmp_path, monkeypatch):
    """Flask test client with a fresh DeviceManager and temp session/export dirs."""
    monkeypatch.setenv('FLASK_CONFIG', 'testing')
    monkeypatch.setenv('SESSION_DIR', str(tmp_path / 'sessions'))
    monkeypatch.setenv('EXPORT_DIR', str(tmp_path / 'exports'))
    for mod in ('app', 'config'):
        sys.modules.pop(mod, None)
    import app as app_module
    from device.device_manager import DeviceManager
    from tests.fakes import FakeReader

    app_module.device_manager = DeviceManager(reader_factories={
        'usb': lambda **kw: FakeReader('usb'),
        'bluetooth': lambda **kw: FakeReader('bluetooth'),
    })
    app_module.app.config['TESTING'] = True
    yield app_module.app.test_client(), app_module
    app_module.device_manager.disconnect()
