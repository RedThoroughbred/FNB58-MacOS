"""Test doubles for the device layer."""

from datetime import datetime, timedelta


def make_reading(voltage=5.0, current=1.0, dp=0.0, dn=0.0, temperature=25.0, ts=None, sample=0):
    ts = ts or datetime.now()
    return {
        'timestamp': ts.isoformat(),
        'voltage': voltage,
        'current': current,
        'power': round(voltage * current, 5),
        'dp': dp,
        'dn': dn,
        'temperature': temperature,
        'sample': sample,
    }


def reading_series(n, dt_s=0.01, start=None, **kw):
    start = start or datetime(2026, 1, 1, 12, 0, 0)
    return [make_reading(ts=start + timedelta(seconds=i * dt_s), sample=i % 4, **kw) for i in range(n)]


class FakeReader:
    """Stands in for USBReader / BluetoothReader. Readings are pushed manually."""

    def __init__(self, kind='usb', fail_connect=False):
        self.kind = kind
        self.fail_connect = fail_connect
        self.is_connected = False
        self.is_reading = False
        self.callback = None
        self.disconnect_calls = 0
        self.sent = []

    def connect(self):
        if self.fail_connect:
            raise ConnectionError(f"fake {self.kind} unavailable")
        self.is_connected = True
        return True

    def start_reading(self, callback=None):
        if not self.is_connected:
            raise ConnectionError("not connected")
        self.callback = callback
        self.is_reading = True

    def stop_reading(self):
        self.is_reading = False

    def disconnect(self):
        self.disconnect_calls += 1
        self.is_connected = False
        self.is_reading = False

    def get_device_info(self):
        return {'model': f'fake-{self.kind}'}

    def push(self, reading):
        if self.callback:
            self.callback(reading)

    # USB-only extras
    def trigger_voltage(self, protocol, voltage):
        self.sent.append(('trigger', protocol, voltage))
        return True

    def adjust_qc3_voltage(self, v):
        self.sent.append(('qc3', v))
        return True
