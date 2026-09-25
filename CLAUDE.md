# FNIRSI FNB58 Web Monitor - Claude Code Guide

## Project Overview

A real-time web application for monitoring FNIRSI FNB58 USB Power Meter via USB and Bluetooth. Built with Flask, WebSocket, and modern JavaScript.

**Key Technologies**: Flask 3.0, Flask-SocketIO, PyUSB, Bleak, Chart.js, TailwindCSS

## Project Structure

```
fnirsi-web-monitor/
├── app.py                      # Main Flask application with REST API and WebSocket
├── config.py                   # Configuration management
├── device/                     # Device communication layer
│   ├── usb_reader.py          # USB HID communication (PyUSB)
│   ├── bluetooth_reader.py    # Bluetooth LE communication (Bleak)
│   ├── device_manager.py      # Unified device interface, auto-switching
│   └── data_processor.py      # Statistics calculation and export
├── static/
│   ├── css/style.css          # Custom CSS (Tailwind via CDN)
│   ├── js/
│   │   ├── common.js          # Shared utilities and API helpers
│   │   └── dashboard.js       # Real-time chart updates via WebSocket
│   └── manifest.json          # PWA manifest
├── templates/
│   ├── base.html              # Base template with navigation
│   ├── dashboard.html         # Main monitoring interface
│   ├── settings.html          # Bluetooth scanner and configuration
│   └── history.html           # Session viewer and comparison
├── tests/                      # pytest suite (hardware-free)
└── ios/                        # SwiftUI + CoreBluetooth iPhone app
```

## Architecture

### Data Flow
1. **Device → Reader** (USB/Bluetooth) - Raw packets at 100Hz (USB) or 10Hz (BT)
2. **Reader → DeviceManager** - Parsed readings with callbacks
3. **DeviceManager → Flask** - Thread-safe data buffer
4. **Flask → WebSocket** - Broadcast to all connected clients
5. **WebSocket → Browser** - Real-time chart updates

### Threading Model
- **Main Thread**: Flask app and HTTP requests
- **SocketIO Thread**: WebSocket event handling
- **USB Reader Thread**: Continuous USB polling (device/usb_reader.py)
- **Bluetooth Thread**: Async event loop for BLE (device/bluetooth_reader.py)

### Key Design Patterns
- **Singleton**: DeviceManager (global instance in app.py)
- **Observer**: Callback pattern for data streaming
- **Strategy**: USB vs Bluetooth readers with unified interface
- **Factory**: Auto-detection and connection in DeviceManager

## Coding Conventions

### Python
- **Style**: PEP 8 with 4-space indentation
- **Docstrings**: Google style for all public functions
- **Type Hints**: Preferred but not required
- **Imports**: Standard library → Third party → Local
- **Error Handling**: Specific exceptions, never bare `except:`

### JavaScript
- **Style**: ES6+, 2-space indentation
- **Naming**: camelCase for functions/variables, PascalCase for classes
- **Async**: Prefer async/await over callbacks
- **DOM**: Vanilla JS, no jQuery
- **Chart.js**: Use `update('none')` for performance

### File Organization
- **One class per file** (device layer)
- **Separate concerns** (UI logic vs data processing)
- **Keep functions under 50 lines** when possible
- **Group related functions** with clear comments

## Key Components

### 1. USB Reader (`device/usb_reader.py`)

**Purpose**: Communicate with FNIRSI via USB HID protocol

**Key Methods**:
- `connect()` - Find and configure USB device (table `KNOWN_DEVICES`)
- `start_reading(callback)` - Send init handshake, begin background thread
- `decode_packet(data)` - Module-level pure function; parse 64-byte packet into readings

**Device IDs** (from baryluk's logger, verified against hardware):
- FNB58 `0x2E3C:0x5558`, FNB48S `0x2E3C:0x0049` (slow 1 s keep-alive, `0xAA 0x82`)
- FNB48 `0x0483:0x003A`, C1 `0x0483:0x003B` (3 ms keep-alive, `0xAA 0x83`)

**Packet Format** (64 bytes):
- `[0]` = 0xAA, `[1]` = packet type (only `0x04` carries data)
- 4 samples at offsets `2 + 15*i` (2, 17, 32, 47), **15-byte stride**
- Each sample: V u32 /100000, I u32 /100000, D+ u16 /1000, D- u16 /1000, 1 unknown byte, Temp u16 /10
- `[63]` = CRC-8 (poly 0x39, init 0x42) over `[1..62]`; bad-CRC packets are dropped

**Important Notes**:
- Init sequence `0xAA81`, `0xAA82`, then the per-model poll command, must be sent before data flows
- `trigger_voltage()` / `adjust_qc3_voltage()` are EXPERIMENTAL and unverified - the API reports "command sent", never "voltage changed"
- Device may require udev rules on Linux; macOS needs no kernel-driver detach
- Always call `disconnect()` to release device

### 2. Bluetooth Reader (`device/bluetooth_reader.py`)

**Purpose**: Communicate with FNIRSI FNB58 via Bluetooth LE

**Key Methods**:
- `scan_for_devices(timeout, name_filter)` - Module-level coroutine; returns address/name/rssi
- `parse_frame(data)` - Module-level pure function
- `connect()` / `start_reading(callback)` / `disconnect()` - Synchronous wrappers

**UUIDs**:
- Write: `0000ffe9-0000-1000-8000-00805f9b34fb`
- Notify: `0000ffe4-0000-1000-8000-00805f9b34fb`

**Data Format**:
- Offset 21, 3x signed 32-bit integers (V, I, W)
- Scale by 10000

**Important Notes**:
- Requires `bleak` library
- One private asyncio loop on a dedicated thread (`_LoopThread`); every bleak call goes through
  `run_coroutine_threadsafe`. Never drive the loop from a Flask thread.
- Limited data compared to USB (no D+/D-/Temp)
- The same protocol is implemented natively in `ios/WattBench/Bluetooth/` (CoreBluetooth)

### 3. Device Manager (`device/device_manager.py`)

**Purpose**: Unified interface for both connection types

**Key Methods**:
- `connect(mode='auto', **kwargs)` - Auto-detect or manual connection
- `start_monitoring()` - Begin data collection
- `start_recording()` / `stop_recording()` - Session management
- `register_callback(fn)` - Add data listeners

**Global Instance** in `app.py`:
```python
device_manager = DeviceManager()
```

**Thread Safety**: Uses `threading.RLock()` for all shared state; data callbacks are invoked
outside the lock. `DeviceManager(reader_factories=...)` accepts injectable reader factories
(see `tests/fakes.py`). Auto mode tries USB first (fails fast), then Bluetooth.

**Statistics**: Energy/capacity are integrated from reading timestamps, not an assumed sample
rate. `min_voltage`/`min_current` are `None` (not `inf`) before the first sample so `/api/stats`
is always valid JSON.

### 4. Flask App (`app.py`)

**REST API Endpoints**:
```python
GET  /api/status              # Connection status
POST /api/connect             # Connect to device
POST /api/disconnect          # Disconnect
GET  /api/reading/latest      # Latest reading
GET  /api/reading/recent      # Recent N readings
GET  /api/stats               # Current statistics
POST /api/recording/start     # Start session recording
POST /api/recording/stop      # Stop and save session
GET  /api/sessions            # List saved sessions
GET  /api/sessions/<filename> # Get specific session
GET  /api/scan-bluetooth      # Scan for BT devices
POST /api/export/csv          # Export to CSV
```

**WebSocket Events**:
```python
connect              # Client connected
disconnect           # Client disconnected
new_reading          # Server → Client: New data point
request_data         # Client → Server: Request historical data
historical_data      # Server → Client: Historical data response
```

**Important Notes**:
- Uses Flask-SocketIO in `threading` async mode (no eventlet; needs `simple-websocket`)
- CORS enabled for development
- Sessions saved as JSON in `sessions/` directory

### 5. Dashboard JavaScript (`static/js/dashboard.js`)

**Key Functions**:
```javascript
initCharts()                    // Initialize Chart.js instances
connectWebSocket()              // Connect to SocketIO
handleNewReading(reading)       // Process incoming data
updateChartsWithReading(reading) // Update all charts
connectDevice(mode)             // API call to connect
startRecording() / stopRecording() // Session management
```

**Chart Configuration**:
- 4 charts: voltage, current, power, combined
- Max 500 points displayed for performance
- Update mode: `'none'` for no animation
- All charts use dark theme

**Performance Notes**:
- Throttle chart updates to ~60fps
- Use `pointRadius: 0` for line charts
- Keep data buffer at 1000 max points

## Common Tasks

### Adding a New Metric

1. **Modify USB/BT Reader** to extract the metric:
```python
# device/usb_reader.py or bluetooth_reader.py
reading = {
    'voltage': ...,
    'current': ...,
    'new_metric': value  # Add here
}
```

2. **Update Dashboard HTML** (`templates/dashboard.html`):
```html
<div id="new-metric-value">0.00</div>
```

3. **Update Dashboard JS** (`static/js/dashboard.js`):
```javascript
function handleNewReading(reading) {
    document.getElementById('new-metric-value').textContent = 
        formatNumber(reading.new_metric, 3);
}
```

### Adding a New API Endpoint

1. **Add route** in `app.py`:
```python
@app.route('/api/new-endpoint', methods=['GET'])
def api_new_endpoint():
    try:
        result = device_manager.some_method()
        return jsonify({'success': True, 'data': result})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 400
```

2. **Add frontend call** in JavaScript:
```javascript
async function callNewEndpoint() {
    const result = await apiRequest('/api/new-endpoint');
    // Process result
}
```

### Adding a New Chart

1. **Add canvas** in `templates/dashboard.html`:
```html
<canvas id="new-chart" height="250"></canvas>
```

2. **Initialize chart** in `dashboard.js`:
```javascript
charts.newChart = new Chart(ctx, {
    type: 'line',
    data: { datasets: [{ label: 'New Metric', data: [] }] },
    options: chartConfig.options
});
```

3. **Update in data handler**:
```javascript
function updateChartsWithReading(reading) {
    charts.newChart.data.datasets[0].data.push({
        x: timestamp,
        y: reading.new_metric
    });
    charts.newChart.update('none');
}
```

### Modifying the Device Protocol

**USB Protocol Changes**:
- Modify `_decode_packet()` in `device/usb_reader.py`
- Adjust offsets/parsing based on packet structure
- Update data format in docstring

**Bluetooth Protocol Changes**:
- Modify `_parse_data()` in `device/bluetooth_reader.py`
- Adjust offset/scale based on packet structure
- Test with actual device using Bluetooth sniffer

### Adding Session Analysis

1. **Add analysis function** in `device/data_processor.py`:
```python
@staticmethod
def analyze_charging_curve(data):
    # Analysis logic
    return results
```

2. **Add API endpoint** in `app.py`:
```python
@app.route('/api/analyze/<filename>')
def api_analyze_session(filename):
    session = load_session(filename)
    results = DataProcessor.analyze_charging_curve(session['data'])
    return jsonify(results)
```

3. **Display in history page** (`templates/history.html`)

## Configuration

### Environment Variables (`.env`)
```bash
SECRET_KEY=your-secret-key-here
FLASK_ENV=development
HOST=0.0.0.0
PORT=5001
BT_DEVICE_ADDRESS=98:DA:B0:08:A1:82  # Optional
```

### Config Class (`config.py`)
```python
HOST = '0.0.0.0'; PORT = 5001   # 5000 is AirPlay Receiver on macOS
BT_DEVICE_NAME = 'FNB58'
SESSION_DIR / EXPORT_DIR         # overridable via env; tests point them at tmp dirs
```
`FLASK_CONFIG=development|production|testing` selects the config class. USB IDs live in
`device/usb_reader.py::KNOWN_DEVICES`, not in config.

## Dependencies

### Python Core
- **Flask 3.0**: Web framework
- **Flask-SocketIO 5.3**: WebSocket support
- **PyUSB 1.2**: USB communication
- **Bleak 0.21**: Bluetooth LE
- **NumPy 1.26**: Numerical operations
- **Pandas 2.1**: Data processing

### Frontend (CDN)
- **Tailwind CSS**: Utility-first styling
- **Chart.js 4**: Interactive charts
- **Socket.IO Client 4**: WebSocket client

## Development Workflow

### Setup
```bash
pip install -r requirements.txt
python test_setup.py  # Verify installation
python start.py       # Run development server
```

### Testing Changes

**Backend**:
```python
# Test USB connection
python -c "from device.usb_reader import USBReader; r = USBReader(); r.connect()"

# Test Bluetooth scanning
python -c "from device.bluetooth_reader import BluetoothReader; import asyncio; r = BluetoothReader(); print(asyncio.run(r.scan_devices()))"
```

**Frontend**:
- Open browser DevTools → Console
- Check for JavaScript errors
- Monitor WebSocket connection in Network tab
- Test on mobile device for responsive design

### Debugging

**Enable Flask Debug Mode**:
```python
# app.py
socketio.run(app, debug=True)
```

**USB Issues**:
- Check `lsusb` (Linux) or System Information (macOS)
- Verify udev rules (Linux)
- Try with `sudo` to test permissions

**Bluetooth Issues**:
- Check system Bluetooth status
- Verify device is in range
- Use `bleak` scanner CLI: `python -m bleak.scanner`

**WebSocket Issues**:
- Check browser console for connection errors
- Verify CORS settings if accessing from different origin
- Check Flask-SocketIO async mode (threading/eventlet/gevent)

## Performance Optimization

### Backend
- **Data Buffer**: Limited to 10,000 points (configurable)
- **Threading**: USB reader in separate thread
- **Callbacks**: Async to avoid blocking

### Frontend
- **Chart Updates**: Throttled with `update('none')`
- **Data Points**: Max 500 visible points per chart
- **WebSocket**: Binary protocol for large datasets (future)

### Memory Management
```python
# Device manager uses deque with maxlen
self.data_buffer = deque(maxlen=10000)
```

## Security Considerations

### Current State (Development)
- CORS enabled for all origins
- No authentication required
- Local-only access recommended

### Production Recommendations
- **Disable CORS** or restrict origins
- **Add authentication** (Flask-Login)
- **Use HTTPS** with proper certificates
- **Rate limiting** on API endpoints
- **Input validation** on all endpoints

## Troubleshooting

### Device Not Detected (USB)
```python
# Check if device visible
import usb.core
device = usb.core.find(idVendor=0x0716)
print(device)
```

**Solutions**:
- Linux: Add udev rules
- macOS: No special setup needed
- Windows: Install libusb driver

### Bluetooth Connection Fails
```python
# Test scanning
from device.bluetooth_reader import BluetoothReader
import asyncio
reader = BluetoothReader()
devices = asyncio.run(reader.scan_devices(timeout=10))
print(devices)
```

**Solutions**:
- Ensure Bluetooth is enabled
- Device must be in pairing mode
- Try increasing scan timeout
- Check system Bluetooth permissions

### Charts Not Updating
1. Check WebSocket connection in browser console
2. Verify device is connected: `/api/status`
3. Check for JavaScript errors
4. Clear browser cache

### High CPU Usage
- Reduce chart update frequency
- Decrease `MAX_DATA_POINTS` in config
- Use `update('none')` for all charts

## Future Enhancements

### Planned Features
- [ ] Multi-device support (multiple FNB58s)
- [ ] Alert thresholds with notifications
- [ ] Database storage (SQLite/PostgreSQL)
- [ ] Protocol triggering (QC/PD modes)
- [ ] Advanced statistics (FFT, harmonics)
- [ ] Comparison mode (overlay sessions)
- [x] Mobile native app (SwiftUI, `ios/`)
- [ ] Desktop app (Electron)
- [ ] Cloud sync and sharing

### Code Quality
- [x] Unit tests (pytest)
- [ ] Integration tests
- [ ] Type hints throughout
- [ ] Code coverage (>80%)
- [ ] CI/CD pipeline
- [ ] Docker container
- [ ] Automated releases

## Resources

### Project Documentation
- `README.md` - Comprehensive user guide
- `GETTING_STARTED.md` - Quick start tutorial
- `PROJECT_SUMMARY.md` - Technical overview

### External References
- [FNIRSI USB Protocol](https://github.com/baryluk/fnirsi-usb-power-data-logger) - Original reverse engineering
- [Bluetooth Protocol](https://gist.github.com/parkerlreed/0ce45e907ce536a0541afb90b5b49350) - BLE protocol discovery
- [Flask-SocketIO Docs](https://flask-socketio.readthedocs.io/)
- [Chart.js Docs](https://www.chartjs.org/docs/)
- [PyUSB Tutorial](https://github.com/pyusb/pyusb/blob/master/docs/tutorial.rst)
- [Bleak Docs](https://bleak.readthedocs.io/)

## Quick Reference

### Start Server
```bash
python start.py
```

### Run Tests
```bash
python -m pytest                      # backend: decoders, DeviceManager, Flask API (no hardware needed)
python test_setup.py                  # dependency sanity check
cd ios && xcodegen generate && \
  xcodebuild test -project WattBench.xcodeproj -scheme WattBench \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'   # iOS unit tests
```

### iOS App (`ios/`)
Native SwiftUI + CoreBluetooth app (iOS 17+), generated from `ios/project.yml` with
[xcodegen](https://github.com/yonaskolb/XcodeGen). It talks to the meter directly over BLE
(no Flask server involved), so it only gets V/I/W. `FNB58Protocol.swift` mirrors
`device/bluetooth_reader.py`; keep them in sync. Sessions are JSON in the app's Documents
directory (visible in Files); CSV export goes through the share sheet. In the Simulator use
"Use demo data" - it has no Bluetooth radio.

### Connect to Device
```bash
# Auto-detect
curl -X POST http://localhost:5001/api/connect -H "Content-Type: application/json" -d '{"mode":"auto"}'

# USB only
curl -X POST http://localhost:5001/api/connect -H "Content-Type: application/json" -d '{"mode":"usb"}'

# Bluetooth only
curl -X POST http://localhost:5001/api/connect -H "Content-Type: application/json" -d '{"mode":"bluetooth"}'
```

### Get Latest Reading
```bash
curl http://localhost:5001/api/reading/latest
```

### Get Stats
```bash
curl http://localhost:5001/api/stats
```

---

**Last Updated**: 2025-01-08  
**Project Version**: 1.0.0  
**Claude Code**: Use this as context for all development tasks
