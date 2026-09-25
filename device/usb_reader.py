"""
USB HID Reader for FNIRSI USB power meters (FNB48, FNB48S, FNB58, C1)
Protocol per baryluk/fnirsi-usb-power-data-logger (reverse engineered).

Packet layout (64 bytes, HID IN endpoint):
    [0]      0xAA  vendor constant
    [1]      packet type (0x04 = measurement data; everything else ignored)
    [2..61]  4 samples x 15 bytes:
                 +0  u32 LE voltage  (/100000 -> V)
                 +4  u32 LE current  (/100000 -> A)
                 +8  u16 LE D+       (/1000   -> V)
                 +10 u16 LE D-       (/1000   -> V)
                 +12 u8  unknown (constant 1)
                 +13 u16 LE temp     (/10     -> degC)
    [62]     unknown
    [63]     CRC-8 (poly 0x39, init 0x42) over bytes [1..62]
"""

import logging
import threading
import time
from collections import deque
from datetime import datetime, timedelta

import usb.core
import usb.util

log = logging.getLogger(__name__)

# (vendor_id, product_id, model, slow_refresh)
# FNB58 / FNB48S need a 1 s keep-alive; FNB48 / C1 need ~3 ms.
KNOWN_DEVICES = [
    (0x2E3C, 0x5558, 'FNB58', True),
    (0x2E3C, 0x0049, 'FNB48S', True),
    (0x0483, 0x003A, 'FNB48', False),
    (0x0483, 0x003B, 'C1', False),
]

SAMPLE_INTERVAL_S = 0.01   # device samples at 100 Hz
SAMPLES_PER_PACKET = 4
SAMPLE_STRIDE = 15
DATA_PACKET_TYPE = 0x04

CMD_INIT_1 = b"\xaa\x81" + b"\x00" * 61 + b"\x8e"
CMD_INIT_2 = b"\xaa\x82" + b"\x00" * 61 + b"\x96"
CMD_POLL_FAST = b"\xaa\x83" + b"\x00" * 61 + b"\x9e"   # FNB48 / C1
CMD_POLL_SLOW = CMD_INIT_2                              # FNB58 / FNB48S


def _build_crc8_table(poly=0x39):
    table = []
    for byte in range(256):
        crc = byte
        for _ in range(8):
            crc = ((crc << 1) ^ poly) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
        table.append(crc)
    return table


_CRC_TABLE = _build_crc8_table()


def crc8(data, init=0x42):
    """CRC-8 used by FNIRSI packets (width 8, poly 0x39, init 0x42, no reflection)."""
    crc = init
    for b in data:
        crc = _CRC_TABLE[crc ^ b]
    return crc


def decode_packet(data, now=None):
    """Decode one 64-byte HID packet into a list of reading dicts.

    Returns [] for non-data packets or packets that fail the CRC check.
    Sample timestamps are back-dated so the 4 samples are 10 ms apart and
    the last one lands on `now`.
    """
    if len(data) < 64 or data[0] != 0xAA or data[1] != DATA_PACKET_TYPE:
        return []
    if crc8(data[1:63]) != data[63]:
        log.debug("Dropping packet with bad CRC (got %02x)", data[63])
        return []

    now = now or datetime.now()
    t0 = now - timedelta(seconds=SAMPLE_INTERVAL_S * (SAMPLES_PER_PACKET - 1))
    readings = []
    for i in range(SAMPLES_PER_PACKET):
        o = 2 + SAMPLE_STRIDE * i
        voltage = int.from_bytes(data[o:o + 4], 'little') / 100000.0
        current = int.from_bytes(data[o + 4:o + 8], 'little') / 100000.0
        dp = int.from_bytes(data[o + 8:o + 10], 'little') / 1000.0
        dn = int.from_bytes(data[o + 10:o + 12], 'little') / 1000.0
        temp = int.from_bytes(data[o + 13:o + 15], 'little') / 10.0
        ts = t0 + timedelta(seconds=SAMPLE_INTERVAL_S * i)
        readings.append({
            'timestamp': ts.isoformat(),
            'voltage': round(voltage, 5),
            'current': round(current, 5),
            'power': round(voltage * current, 5),
            'dp': round(dp, 3),
            'dn': round(dn, 3),
            'temperature': round(temp, 1),
            'sample': i,
        })
    return readings


class USBReader:
    """USB HID communication with FNIRSI power meters."""

    def __init__(self):
        self.device = None
        self.model = None
        self.slow_refresh = False
        self.ep_in = None
        self.ep_out = None
        self.is_connected = False
        self.is_reading = False
        self.read_thread = None
        self.data_callback = None
        self.data_buffer = deque(maxlen=1000)
        self.bad_packets = 0

    # ------------------------------------------------------------------ setup

    def connect(self):
        """Find, claim and configure the first known FNIRSI device."""
        for vid, pid, model, slow in KNOWN_DEVICES:
            dev = usb.core.find(idVendor=vid, idProduct=pid)
            if dev is not None:
                self.device, self.model, self.slow_refresh = dev, model, slow
                break
        if self.device is None:
            raise ConnectionError("No FNIRSI device found on USB (FNB58/FNB48S/FNB48/C1).")

        self._detach_kernel_drivers()

        try:
            self.device.set_configuration()
        except usb.core.USBError as e:
            # Already configured is fine; anything else is a real problem.
            if 'busy' not in str(e).lower() and e.errno not in (16,):
                raise ConnectionError(f"Could not configure USB device: {e}") from e

        cfg = self.device.get_active_configuration()
        intf = self._find_hid_interface(cfg)

        self.ep_out = usb.util.find_descriptor(
            intf, custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_OUT)
        self.ep_in = usb.util.find_descriptor(
            intf, custom_match=lambda e: usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_IN)
        if self.ep_in is None or self.ep_out is None:
            raise ConnectionError("Could not find USB HID endpoints")

        self.is_connected = True
        log.info("Connected to %s via USB", self.model)
        return True

    def _detach_kernel_drivers(self):
        """Detach kernel HID driver on Linux; a no-op on macOS (not implemented there)."""
        try:
            for cfg in self.device:
                for intf in cfg:
                    if self.device.is_kernel_driver_active(intf.bInterfaceNumber):
                        try:
                            self.device.detach_kernel_driver(intf.bInterfaceNumber)
                        except usb.core.USBError as e:
                            log.warning("Could not detach kernel driver: %s", e)
        except (NotImplementedError, usb.core.USBError):
            pass

    @staticmethod
    def _find_hid_interface(cfg):
        for intf in cfg:
            if intf.bInterfaceClass == 3:  # HID
                return intf
        return cfg[(0, 0)]

    # ---------------------------------------------------------------- reading

    def start_reading(self, callback=None):
        """Start the background read loop; `callback(reading)` per sample."""
        if not self.is_connected:
            raise ConnectionError("Device not connected")
        if self.is_reading:
            return
        self.data_callback = callback
        self.is_reading = True
        self.read_thread = threading.Thread(target=self._read_loop, name='usb-reader', daemon=True)
        self.read_thread.start()

    def stop_reading(self):
        self.is_reading = False
        if self.read_thread and self.read_thread is not threading.current_thread():
            self.read_thread.join(timeout=6)
        self.read_thread = None

    def _send(self, cmd):
        self.ep_out.write(cmd)

    def _read_loop(self):
        poll_cmd = CMD_POLL_SLOW if self.slow_refresh else CMD_POLL_FAST
        refresh = 1.0 if self.slow_refresh else 0.003

        try:
            self._send(CMD_INIT_1)
            self._send(CMD_INIT_2)
            self._send(poll_cmd)
        except usb.core.USBError as e:
            log.error("USB handshake failed: %s", e)
            self.is_reading = False
            return

        next_poll = time.monotonic() + refresh
        while self.is_reading:
            try:
                data = self.ep_in.read(64, timeout=5000)
                for reading in decode_packet(bytes(data)):
                    self.data_buffer.append(reading)
                    if self.data_callback:
                        self.data_callback(reading)
                if time.monotonic() >= next_poll:
                    next_poll = time.monotonic() + refresh
                    self._send(poll_cmd)
            except usb.core.USBTimeoutError:
                # Device went quiet; re-issue the poll command and keep going.
                try:
                    self._send(poll_cmd)
                except usb.core.USBError:
                    pass
            except usb.core.USBError as e:
                if self.is_reading:
                    log.error("USB error in read loop: %s", e)
                    time.sleep(0.1)
            except Exception:
                log.exception("Unexpected error in USB read loop")
                time.sleep(0.1)

    # ------------------------------------------------------------- lifecycle

    def disconnect(self):
        self.stop_reading()
        if self.device is not None:
            try:
                usb.util.dispose_resources(self.device)
            except usb.core.USBError:
                pass
        self.device = None
        self.is_connected = False

    def get_device_info(self):
        if not self.device:
            return None

        def _str(idx):
            try:
                return usb.util.get_string(self.device, idx) if idx else "Unknown"
            except usb.core.USBError:
                return "Unknown"

        return {
            'model': self.model,
            'vendor_id': f"0x{self.device.idVendor:04x}",
            'product_id': f"0x{self.device.idProduct:04x}",
            'manufacturer': _str(self.device.iManufacturer),
            'product': _str(self.device.iProduct),
            'serial': _str(self.device.iSerialNumber),
        }

    # ------------------------------------------------- protocol triggering
    #
    # EXPERIMENTAL. These command bytes are NOT part of any published
    # reverse-engineering of the FNIRSI protocol; they were inherited from the
    # original code base and have not been verified against hardware. The
    # methods only report that the bytes were written, never that the meter
    # actually changed its output. Confirm on the device display.

    TRIGGER_COMMANDS = {
        'pd':   {5: 0x05, 9: 0x09, 12: 0x0c, 15: 0x0f, 20: 0x14},
        'qc':   {5: 0x05, 9: 0x09, 12: 0x0c},
        'afc':  {5: 0x05, 9: 0x09, 12: 0x0c},
        'fcp':  {5: 0x05, 9: 0x09, 12: 0x0c},
        'scp':  {5: 0x05, 9: 0x09, 12: 0x0c},
        'vooc': {5: 0x05, 10: 0x0a},
    }
    TRIGGER_PROTOCOL_IDS = {'pd': 1, 'qc': 2, 'afc': 3, 'fcp': 4, 'scp': 5, 'vooc': 6}

    def trigger_voltage(self, protocol, voltage):
        """Send an (experimental, unverified) protocol trigger command."""
        if not self.is_connected or not self.ep_out:
            raise ConnectionError("Device not connected")
        protocol = str(protocol).lower()
        if protocol not in self.TRIGGER_COMMANDS:
            raise ValueError(f"Unknown protocol: {protocol}")
        if voltage not in self.TRIGGER_COMMANDS[protocol]:
            raise ValueError(f"Unsupported voltage {voltage}V for {protocol.upper()}")
        cmd = bytes([0x5a, self.TRIGGER_PROTOCOL_IDS[protocol], self.TRIGGER_COMMANDS[protocol][voltage]])
        self._send(cmd + b"\x00" * (64 - len(cmd)))
        log.warning("Sent experimental %s %sV trigger command", protocol.upper(), voltage)
        return True

    def adjust_qc3_voltage(self, target_voltage):
        """Send an (experimental, unverified) QC 3.0 fine-adjust command (3.6-12.0 V)."""
        if not self.is_connected or not self.ep_out:
            raise ConnectionError("Device not connected")
        if not 3.6 <= target_voltage <= 12.0:
            raise ValueError("QC 3.0 voltage must be between 3.6V and 12.0V")
        cmd = b"\x5a\x02" + int(round(target_voltage * 1000)).to_bytes(2, 'little')
        self._send(cmd + b"\x00" * (64 - len(cmd)))
        log.warning("Sent experimental QC3 adjust command for %.2fV", target_voltage)
        return True
