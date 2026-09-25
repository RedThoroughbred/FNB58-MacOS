"""
Bluetooth LE Reader for FNIRSI FNB58
Protocol per parkerlreed's gist (reverse engineered).

The FNB58 exposes a UART-style GATT service:
    write  ffe9  - two init commands enable streaming
    notify ffe4  - measurement frames; V, I, W as 3 x int32 LE at offset 21,
                   scaled by 1/10000.

All bleak calls run on ONE private asyncio loop owned by a dedicated thread.
The public API is synchronous and safe to call from Flask request handlers.
"""

import asyncio
import logging
import struct
import threading
from collections import deque
from datetime import datetime

from bleak import BleakClient, BleakScanner

log = logging.getLogger(__name__)

WRITE_UUID = "0000ffe9-0000-1000-8000-00805f9b34fb"
NOTIFY_UUID = "0000ffe4-0000-1000-8000-00805f9b34fb"
INIT_COMMANDS = [bytes([0xaa, 0x81, 0x00, 0xf4]), bytes([0xaa, 0x82, 0x00, 0xa7])]

FRAME_OFFSET = 21
FRAME_SCALE = 10000.0
MIN_VOLTAGE, MAX_VOLTAGE = 0.0, 150.0


def parse_frame(data, now=None):
    """Parse one BLE notification into a reading dict, or None if unusable."""
    if len(data) < FRAME_OFFSET + 12:
        return None
    voltage, current, power = (v / FRAME_SCALE for v in struct.unpack_from('<iii', data, FRAME_OFFSET))
    if not (MIN_VOLTAGE <= voltage <= MAX_VOLTAGE):
        return None
    return {
        'timestamp': (now or datetime.now()).isoformat(),
        'voltage': round(voltage, 5),
        'current': round(current, 5),
        'power': round(power, 5),
        'dp': 0.0,           # not available over BLE
        'dn': 0.0,
        'temperature': 0.0,  # not available over BLE
        'sample': 0,
    }


async def scan_for_devices(timeout=8.0, name_filter="FNB58"):
    """Scan for BLE devices whose advertised name contains `name_filter`."""
    found = await BleakScanner.discover(timeout=timeout, return_adv=True)
    devices = []
    for device, adv in found.values():
        name = device.name or adv.local_name
        if name and name_filter.lower() in name.lower():
            devices.append({'address': device.address, 'name': name, 'rssi': adv.rssi})
    devices.sort(key=lambda d: d['rssi'] if d['rssi'] is not None else -999, reverse=True)
    return devices


class _LoopThread:
    """A background thread running an asyncio loop forever."""

    def __init__(self):
        self.loop = asyncio.new_event_loop()
        self.thread = threading.Thread(target=self._run, name='ble-loop', daemon=True)
        self.thread.start()

    def _run(self):
        asyncio.set_event_loop(self.loop)
        self.loop.run_forever()
        self.loop.close()

    def call(self, coro, timeout=30):
        return asyncio.run_coroutine_threadsafe(coro, self.loop).result(timeout)

    def stop(self):
        self.loop.call_soon_threadsafe(self.loop.stop)
        self.thread.join(timeout=5)


class BluetoothReader:
    """Bluetooth LE communication with a FNIRSI FNB58."""

    def __init__(self, device_address=None, device_name="FNB58", scan_timeout=8.0):
        self.device_address = device_address
        self.device_name = device_name
        self.scan_timeout = scan_timeout
        self.client = None
        self.is_connected = False
        self.is_reading = False
        self.data_callback = None
        self.data_buffer = deque(maxlen=1000)
        self._loop = None

    # -------------------------------------------------------------- connect

    def connect(self):
        self._loop = _LoopThread()
        try:
            return self._loop.call(self._connect_async(), timeout=self.scan_timeout + 30)
        except Exception:
            self._loop.stop()
            self._loop = None
            raise

    async def _connect_async(self):
        if not self.device_address:
            devices = await scan_for_devices(self.scan_timeout, self.device_name)
            if not devices:
                raise ConnectionError(f"No {self.device_name} devices found over Bluetooth")
            self.device_address = devices[0]['address']
            log.info("Found %s at %s", devices[0]['name'], self.device_address)

        self.client = BleakClient(self.device_address, disconnected_callback=self._on_disconnected)
        await self.client.connect()
        if not self.client.is_connected:
            raise ConnectionError("Failed to connect to Bluetooth device")

        for cmd in INIT_COMMANDS:
            await self.client.write_gatt_char(WRITE_UUID, cmd, response=False)
            await asyncio.sleep(0.1)

        self.is_connected = True
        log.info("Connected to %s via Bluetooth", self.device_address)
        return True

    def _on_disconnected(self, _client):
        log.warning("Bluetooth device disconnected")
        self.is_connected = False
        self.is_reading = False

    # -------------------------------------------------------------- reading

    def start_reading(self, callback=None):
        if not self.is_connected:
            raise ConnectionError("Device not connected")
        if self.is_reading:
            return
        self.data_callback = callback
        self.is_reading = True
        self._loop.call(self.client.start_notify(NOTIFY_UUID, self._on_notify))

    def _on_notify(self, _sender, data):
        reading = parse_frame(bytes(data))
        if reading is None:
            return
        self.data_buffer.append(reading)
        if self.data_callback:
            try:
                self.data_callback(reading)
            except Exception:
                log.exception("Error in Bluetooth data callback")

    def stop_reading(self):
        if not self.is_reading:
            return
        self.is_reading = False
        if self._loop and self.client and self.client.is_connected:
            try:
                self._loop.call(self.client.stop_notify(NOTIFY_UUID), timeout=5)
            except Exception as e:
                log.debug("stop_notify failed: %s", e)

    # ------------------------------------------------------------ lifecycle

    def disconnect(self):
        self.stop_reading()
        if self._loop:
            if self.client:
                try:
                    self._loop.call(self.client.disconnect(), timeout=10)
                except Exception as e:
                    log.debug("disconnect failed: %s", e)
            self._loop.stop()
            self._loop = None
        self.client = None
        self.is_connected = False

    def get_device_info(self):
        if not self.client:
            return None
        return {
            'address': self.device_address,
            'name': self.device_name,
            'connection_type': 'bluetooth',
        }
