"""
Device Manager - Unified interface for USB and Bluetooth connections
"""

import logging
import threading
from collections import deque
from datetime import datetime

from .usb_reader import USBReader
from .bluetooth_reader import BluetoothReader
from .protocol_detector import ProtocolDetector
from .alert_manager import AlertManager

log = logging.getLogger(__name__)


def _empty_stats():
    return {
        'samples_collected': 0,
        'max_voltage': 0.0,
        'min_voltage': None,
        'max_current': 0.0,
        'min_current': None,
        'max_power': 0.0,
        'total_energy_wh': 0.0,
        'total_capacity_ah': 0.0,
        'avg_voltage': 0.0,
        'avg_current': 0.0,
        'avg_power': 0.0,
        'duration_s': 0.0,
    }


class DeviceManager:
    """Manages device connection, data collection and session recording."""

    # Fallback sample spacing when a timestamp can't be parsed
    DEFAULT_DT = {'usb': 0.01, 'bluetooth': 0.1}

    def __init__(self, reader_factories=None):
        self.connection_type = None  # 'usb' or 'bluetooth'
        self.reader = None
        self.is_connected = False
        self.is_recording = False
        self.session_name = None
        self.data_callbacks = []
        self.data_buffer = deque(maxlen=10000)
        self.session_data = []
        self.session_start_time = None
        self.lock = threading.RLock()

        self.protocol_detector = ProtocolDetector()
        self.alert_manager = AlertManager()
        self.current_protocol = None

        self.stats = _empty_stats()
        self._last_sample_time = None

        # Injectable for tests: {'usb': callable(**kw) -> reader, 'bluetooth': ...}
        self._factories = reader_factories or {
            'usb': lambda **kw: USBReader(),
            'bluetooth': lambda **kw: BluetoothReader(
                device_address=kw.get('device_address'),
                device_name=kw.get('device_name', 'FNB58')),
        }

    # ------------------------------------------------------------ connect

    def connect(self, mode='auto', **kwargs):
        """Connect to a device.

        mode: 'auto' (USB first, then Bluetooth), 'usb' or 'bluetooth'.
        kwargs: device_address / device_name for Bluetooth.
        """
        if self.is_connected:
            raise ConnectionError("Already connected to a device")
        if mode not in ('auto', 'usb', 'bluetooth'):
            raise ValueError(f"Unknown connection mode: {mode}")

        # USB fails fast when absent, so try it first in auto mode; a BLE scan
        # costs several seconds.
        order = ['usb', 'bluetooth'] if mode == 'auto' else [mode]
        errors = []
        for kind in order:
            reader = self._factories[kind](**kwargs)
            try:
                log.info("Attempting %s connection...", kind)
                reader.connect()
            except Exception as e:  # noqa: BLE001 - surface any backend failure
                log.warning("%s connection failed: %s", kind, e)
                errors.append(f"{kind}: {e}")
                try:
                    reader.disconnect()
                except Exception:  # noqa: BLE001
                    pass
                continue
            self.reader = reader
            self.connection_type = kind
            self.is_connected = True
            log.info("Connected via %s", kind)
            return {
                'success': True,
                'connection_type': kind,
                'device_info': reader.get_device_info(),
            }

        raise ConnectionError("Failed to connect. " + "; ".join(errors))

    def start_monitoring(self):
        if not self.is_connected:
            raise ConnectionError("Device not connected")
        self.reader.start_reading(callback=self._on_data_received)
        return True

    def stop_monitoring(self):
        if self.reader:
            self.reader.stop_reading()

    def disconnect(self):
        self.stop_monitoring()
        if self.reader:
            try:
                self.reader.disconnect()
            except Exception:  # noqa: BLE001
                log.exception("Error while disconnecting reader")
        with self.lock:
            self.is_connected = False
            self.connection_type = None
            self.reader = None

    # ---------------------------------------------------------- recording

    def start_recording(self, name=None):
        with self.lock:
            self.is_recording = True
            self.session_name = name
            self.session_data = []
            self.session_start_time = datetime.now()
            self.stats = _empty_stats()
            self._last_sample_time = None
        return True

    def stop_recording(self):
        with self.lock:
            self.is_recording = False
            return {
                'name': self.session_name,
                'start_time': self.session_start_time.isoformat() if self.session_start_time else None,
                'end_time': datetime.now().isoformat(),
                'data': list(self.session_data),
                'stats': dict(self.stats),
                'connection_type': self.connection_type,
            }

    # --------------------------------------------------------- data path

    def _on_data_received(self, reading):
        """Reader callback. Runs on the reader's thread."""
        with self.lock:
            protocol_info = self.protocol_detector.detect_protocol(reading)
            self.current_protocol = protocol_info
            alerts = self.alert_manager.check_reading(reading)

            enhanced = {**reading, 'protocol': protocol_info, 'has_alerts': bool(alerts)}
            self.data_buffer.append(enhanced)

            if self.is_recording:
                self.session_data.append(enhanced)
                self._update_stats(reading)

            callbacks = list(self.data_callbacks)

        # Fan out outside the lock so a slow consumer can't stall the reader.
        for callback in callbacks:
            try:
                callback(enhanced)
            except Exception:  # noqa: BLE001
                log.exception("Error in data callback")

    def _sample_dt(self, reading):
        """Seconds since the previous recorded sample, from timestamps when possible."""
        fallback = self.DEFAULT_DT.get(self.connection_type, 0.01)
        try:
            t = datetime.fromisoformat(reading['timestamp'])
        except (KeyError, TypeError, ValueError):
            return fallback
        prev, self._last_sample_time = self._last_sample_time, t
        if prev is None:
            return 0.0
        dt = (t - prev).total_seconds()
        # Guard against clock jumps / reconnect gaps polluting the integral.
        return dt if 0.0 <= dt <= 5.0 else fallback

    def _update_stats(self, reading):
        v, c, p = reading['voltage'], reading['current'], reading['power']
        s = self.stats
        s['samples_collected'] += 1
        n = s['samples_collected']

        s['max_voltage'] = max(s['max_voltage'], v)
        s['min_voltage'] = v if s['min_voltage'] is None else min(s['min_voltage'], v)
        s['max_current'] = max(s['max_current'], c)
        s['min_current'] = c if s['min_current'] is None else min(s['min_current'], c)
        s['max_power'] = max(s['max_power'], p)

        s['avg_voltage'] += (v - s['avg_voltage']) / n
        s['avg_current'] += (c - s['avg_current']) / n
        s['avg_power'] += (p - s['avg_power']) / n

        dt = self._sample_dt(reading)
        s['duration_s'] += dt
        s['total_energy_wh'] += p * dt / 3600.0
        s['total_capacity_ah'] += c * dt / 3600.0

    # ---------------------------------------------------------- accessors

    def register_callback(self, callback):
        with self.lock:
            if callback not in self.data_callbacks:
                self.data_callbacks.append(callback)

    def unregister_callback(self, callback):
        with self.lock:
            if callback in self.data_callbacks:
                self.data_callbacks.remove(callback)

    def get_latest_reading(self):
        with self.lock:
            return self.data_buffer[-1] if self.data_buffer else None

    def get_recent_data(self, num_points=100):
        with self.lock:
            if num_points <= 0:
                return []
            data = list(self.data_buffer)
            return data[-num_points:]

    def get_stats(self):
        with self.lock:
            return dict(self.stats)

    def get_connection_info(self):
        with self.lock:
            if not self.is_connected:
                return {'connected': False}
            return {
                'connected': True,
                'connection_type': self.connection_type,
                'device_info': self.reader.get_device_info() if self.reader else None,
                'is_recording': self.is_recording,
                'session_name': self.session_name,
            }

    # ---------------------------------------------------- USB-only extras

    def _require_usb(self, what):
        if not self.is_connected:
            raise ConnectionError("Device not connected")
        if self.connection_type != 'usb':
            raise ValueError(f"{what} is only supported over USB")

    def trigger_voltage(self, protocol, voltage):
        """Experimental - see USBReader.trigger_voltage."""
        self._require_usb("Voltage triggering")
        return self.reader.trigger_voltage(protocol, voltage)

    def adjust_qc3_voltage(self, target_voltage):
        """Experimental - see USBReader.adjust_qc3_voltage."""
        self._require_usb("QC 3.0 adjustment")
        return self.reader.adjust_qc3_voltage(target_voltage)
