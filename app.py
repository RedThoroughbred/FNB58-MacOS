"""
FNIRSI FNB58 Web Monitor - Main Flask Application
Real-time USB power monitoring with WebSocket support
"""

from flask import Flask, render_template, jsonify, request, send_file, redirect, url_for
from flask_socketio import SocketIO, emit
from flask_cors import CORS
from device import DeviceManager, DataProcessor
from device.bluetooth_reader import scan_for_devices
from config import config
import asyncio
import logging
import os
import json
from datetime import datetime
from pathlib import Path

logging.basicConfig(level=os.environ.get('LOG_LEVEL', 'INFO'),
                    format='%(asctime)s %(levelname)s %(name)s: %(message)s')
log = logging.getLogger('fnb58')

# Initialize Flask app
app = Flask(__name__)
config_name = os.environ.get('FLASK_CONFIG', 'development')
app.config.from_object(config[config_name])
config[config_name].init_app(app)

# Enable CORS
CORS(app)

# Threading mode: plain OS threads, so the USB reader thread (blocking libusb
# calls) and the Bluetooth asyncio loop coexist without eventlet monkey-patching.
socketio = SocketIO(
    app,
    cors_allowed_origins="*",
    async_mode='threading',
    ping_timeout=60,
    ping_interval=25,
    logger=False,
    engineio_logger=False
)

# Global device manager
device_manager = DeviceManager()
data_processor = DataProcessor()


# ==================== Web Routes ====================

@app.route('/')
def index():
    """Redirect to professional dashboard"""
    return redirect(url_for('dashboard_pro'))


@app.route('/dashboard')
def dashboard_pro():
    """Professional dashboard with oscilloscope and advanced features"""
    return render_template('dashboard_pro.html')


@app.route('/settings')
def settings():
    """Professional settings page"""
    return render_template('settings_pro.html')


@app.route('/history')
def history():
    """Professional history page"""
    return render_template('history_pro.html')


@app.route('/classic')
def classic_dashboard():
    """Original classic dashboard"""
    return render_template('dashboard.html')


# ==================== API Routes ====================

@app.route('/api/status')
def api_status():
    """Get connection status"""
    return jsonify(device_manager.get_connection_info())


@app.route('/api/connect', methods=['POST'])
def api_connect():
    """Connect to device"""
    try:
        data = request.json or {}
        mode = data.get('mode', 'auto')  # 'auto', 'usb', or 'bluetooth'
        device_address = data.get('device_address')  # For Bluetooth

        log.info("Connect request: mode=%s address=%s", mode, device_address)

        result = device_manager.connect(mode=mode, device_address=device_address)
        device_manager.register_callback(broadcast_data)
        device_manager.start_monitoring()

        log.info("Connected via %s", result.get('connection_type'))
        return jsonify(result)
    except Exception as e:
        log.exception("Connection failed")
        return jsonify({'success': False, 'error': str(e)}), 400


@app.route('/api/disconnect', methods=['POST'])
def api_disconnect():
    """Disconnect from device"""
    try:
        device_manager.disconnect()
        return jsonify({'success': True})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 400


@app.route('/api/scan-bluetooth', methods=['GET'])
def api_scan_bluetooth():
    """Scan for Bluetooth devices"""
    try:
        timeout = request.args.get('timeout', default=8.0, type=float)
        devices = asyncio.run(scan_for_devices(timeout=min(max(timeout, 1.0), 30.0)))
        return jsonify({'success': True, 'devices': devices})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 400


@app.route('/api/reading/latest')
def api_latest_reading():
    """Get latest reading"""
    reading = device_manager.get_latest_reading()
    if reading:
        return jsonify(reading)
    return jsonify({'error': 'No data available'}), 404


@app.route('/api/reading/recent')
def api_recent_data():
    """Get recent data points"""
    num_points = request.args.get('points', default=100, type=int)
    data = device_manager.get_recent_data(num_points)
    return jsonify(data)


@app.route('/api/stats')
def api_stats():
    """Get current statistics"""
    stats = device_manager.get_stats()
    return jsonify(stats)


@app.route('/api/recording/start', methods=['POST'])
def api_start_recording():
    """Start recording session"""
    try:
        data = request.json or {}
        session_name = data.get('name')

        if not device_manager.is_connected:
            return jsonify({'success': False, 'error': 'Not connected to a device'}), 400

        device_manager.start_recording(name=session_name)
        return jsonify({'success': True, 'start_time': datetime.now().isoformat(), 'name': session_name})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 400


@app.route('/api/recording/stop', methods=['POST'])
def api_stop_recording():
    """Stop recording session"""
    try:
        if not device_manager.is_recording:
            return jsonify({'success': False, 'error': 'Not recording'}), 400

        session = device_manager.stop_recording()
        session_name = session.get('name')

        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        safe_name = "".join(c for c in (session_name or '') if c.isalnum() or c in (' ', '-', '_')).strip()
        safe_name = safe_name.replace(' ', '_')
        filename = f'{safe_name}_{timestamp}.json' if safe_name else f'session_{timestamp}.json'
        session_file = os.path.join(app.config['SESSION_DIR'], filename)

        with open(session_file, 'w') as f:
            json.dump(session, f, indent=2)

        return jsonify({
            'success': True,
            'session': session,
            'filename': os.path.basename(session_file),
            'name': session_name
        })
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 400


@app.route('/api/export/csv', methods=['POST'])
def api_export_csv():
    """Export current session to CSV"""
    try:
        data = request.json or {}
        session_data = data.get('data', [])

        if not session_data:
            return jsonify({'success': False, 'error': 'No data to export'}), 400

        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        filename = os.path.join(app.config['EXPORT_DIR'], f'export_{timestamp}.csv')

        data_processor.export_to_csv(session_data, filename)

        return send_file(filename, as_attachment=True, download_name=f'fnirsi_data_{timestamp}.csv')
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 400


@app.route('/api/export/html', methods=['POST'])
def api_export_html():
    """Export session as comprehensive HTML report"""
    try:
        data = request.json or {}

        # Build session object
        session = {
            'start_time': data.get('start_time', datetime.now().strftime('%Y-%m-%d %H:%M:%S')),
            'end_time': data.get('end_time', datetime.now().strftime('%Y-%m-%d %H:%M:%S')),
            'connection_type': data.get('connection_type', 'unknown'),
            'data': data.get('data', [])
        }

        if not session['data']:
            return jsonify({'success': False, 'error': 'No data to export'}), 400

        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        filename = os.path.join(app.config['EXPORT_DIR'], f'report_{timestamp}.html')

        data_processor.generate_html_report(session, filename)

        return send_file(filename, as_attachment=True, download_name=f'fnirsi_report_{timestamp}.html')
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 400


def _session_path(filename):
    """Resolve a session filename inside SESSION_DIR, or None if it escapes it."""
    session_dir = Path(app.config['SESSION_DIR']).resolve()
    candidate = (session_dir / filename).resolve()
    if candidate.parent != session_dir or candidate.suffix != '.json':
        return None
    return str(candidate)


@app.route('/api/sessions')
def api_list_sessions():
    """List saved sessions"""
    try:
        sessions = []
        session_dir = Path(app.config['SESSION_DIR'])

        for session_file in sorted(session_dir.glob('*.json'), reverse=True):
            try:
                with open(session_file, 'r') as f:
                    session_info = json.load(f)
            except (OSError, json.JSONDecodeError) as e:
                log.warning("Skipping unreadable session %s: %s", session_file.name, e)
                continue
            sessions.append({
                'filename': session_file.name,
                'name': session_info.get('name') or 'Untitled',
                'start_time': session_info.get('start_time'),
                'end_time': session_info.get('end_time'),
                'connection_type': session_info.get('connection_type'),
                'samples': len(session_info.get('data', []))
            })

        return jsonify({'success': True, 'sessions': sessions})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 400


@app.route('/api/sessions/<filename>')
def api_get_session(filename):
    """Get a specific session"""
    try:
        session_file = _session_path(filename)
        if session_file is None:
            return jsonify({'success': False, 'error': 'Invalid filename'}), 400

        if not os.path.exists(session_file):
            return jsonify({'success': False, 'error': 'Session not found'}), 404

        with open(session_file, 'r') as f:
            session = json.load(f)

        return jsonify({'success': True, 'session': session})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 400


@app.route('/api/sessions/<filename>', methods=['DELETE'])
def api_delete_session(filename):
    """Delete a specific session"""
    try:
        session_file = _session_path(filename)
        if session_file is None:
            return jsonify({'success': False, 'error': 'Invalid filename'}), 400

        if not os.path.exists(session_file):
            return jsonify({'success': False, 'error': 'Session not found'}), 404

        # Delete the file
        os.remove(session_file)

        return jsonify({'success': True, 'message': f'Session {filename} deleted'})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 400


@app.route('/api/protocol')
def api_get_protocol():
    """Get current detected protocol"""
    try:
        protocol = device_manager.current_protocol
        if protocol:
            return jsonify({'success': True, 'protocol': protocol})
        return jsonify({'success': False, 'protocol': None})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 400


@app.route('/api/trigger/voltage', methods=['POST'])
def api_trigger_voltage():
    """Trigger fast charging protocol voltage"""
    try:
        data = request.json or {}
        protocol = data.get('protocol')
        voltage = data.get('voltage')

        if not protocol or voltage is None:
            return jsonify({'success': False, 'error': 'Missing protocol or voltage'}), 400

        voltage = int(voltage)
        log.info("Trigger request: %s %sV", protocol.upper(), voltage)

        device_manager.trigger_voltage(protocol, voltage)

        return jsonify({
            'success': True,
            'protocol': protocol,
            'voltage': voltage,
            'experimental': True,
            'message': f'{protocol.upper()} {voltage}V command sent (experimental - confirm on the meter display)'
        })
    except (ValueError, ConnectionError) as e:
        return jsonify({'success': False, 'error': str(e)}), 400
    except Exception as e:
        log.exception("Trigger failed")
        return jsonify({'success': False, 'error': str(e)}), 500


@app.route('/api/trigger/qc3-adjust', methods=['POST'])
def api_qc3_adjust():
    """Adjust QC 3.0 voltage in fine steps"""
    try:
        data = request.json or {}
        voltage = data.get('voltage')

        if voltage is None:
            return jsonify({'success': False, 'error': 'Missing voltage'}), 400

        voltage = float(voltage)
        log.info("QC 3.0 adjust request: %.2fV", voltage)

        device_manager.adjust_qc3_voltage(voltage)

        return jsonify({
            'success': True,
            'voltage': voltage,
            'experimental': True,
            'message': f'QC 3.0 {voltage:.2f}V command sent (experimental - confirm on the meter display)'
        })
    except (ValueError, ConnectionError) as e:
        return jsonify({'success': False, 'error': str(e)}), 400
    except Exception as e:
        log.exception("QC 3.0 adjustment failed")
        return jsonify({'success': False, 'error': str(e)}), 500


@app.route('/api/alerts')
def api_get_alerts():
    """Get active alerts"""
    try:
        alerts = device_manager.alert_manager.get_active_alerts()
        return jsonify({'success': True, 'alerts': alerts})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 400


@app.route('/api/alerts/history')
def api_get_alert_history():
    """Get alert history"""
    try:
        limit = request.args.get('limit', default=50, type=int)
        history = device_manager.alert_manager.get_alert_history(limit)
        return jsonify({'success': True, 'history': history})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 400


@app.route('/api/alerts/acknowledge/<alert_id>', methods=['POST'])
def api_acknowledge_alert(alert_id):
    """Acknowledge an alert"""
    try:
        success = device_manager.alert_manager.acknowledge_alert(alert_id)
        return jsonify({'success': success})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 400


@app.route('/api/alerts/clear', methods=['POST'])
def api_clear_alerts():
    """Clear all acknowledged alerts"""
    try:
        device_manager.alert_manager.clear_acknowledged_alerts()
        return jsonify({'success': True})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 400


@app.route('/api/thresholds', methods=['GET'])
def api_get_thresholds():
    """Get current alert thresholds"""
    try:
        thresholds = device_manager.alert_manager.get_thresholds()
        return jsonify({'success': True, 'thresholds': thresholds})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 400


@app.route('/api/thresholds', methods=['POST'])
def api_set_threshold():
    """Set an alert threshold"""
    try:
        data = request.json or {}
        threshold_name = data.get('name')
        value = data.get('value')

        if not threshold_name or value is None:
            return jsonify({'success': False, 'error': 'Missing name or value'}), 400

        success = device_manager.alert_manager.set_threshold(threshold_name, float(value))
        return jsonify({'success': success})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 400


@app.route('/api/system-stats')
def api_system_stats():
    """Get system resource usage"""
    try:
        import psutil

        cpu_percent = psutil.cpu_percent(interval=0.1)
        memory = psutil.virtual_memory()
        memory_mb = memory.used / (1024 * 1024)

        return jsonify({
            'success': True,
            'cpu_percent': round(cpu_percent, 1),
            'memory_mb': round(memory_mb, 0),
            'memory_percent': memory.percent
        })
    except ImportError:
        return jsonify({'success': False, 'error': 'psutil not installed'}), 501
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)}), 400


# ==================== WebSocket Events ====================

def broadcast_data(reading):
    """Broadcast new reading to all connected clients (called from the reader thread)."""
    socketio.emit('new_reading', reading, namespace='/')


@socketio.on('connect')
def handle_connect():
    """Handle WebSocket connection"""
    log.debug('WebSocket client connected')
    emit('connection_response', {'status': 'connected'})


@socketio.on('disconnect')
def handle_disconnect():
    """Handle WebSocket disconnection"""
    log.debug('WebSocket client disconnected')


@socketio.on('request_data')
def handle_request_data(data):
    """Handle request for historical data"""
    num_points = data.get('points', 100)
    recent_data = device_manager.get_recent_data(num_points)
    emit('historical_data', recent_data)


@socketio.on('ping')
def handle_ping():
    """Handle client ping to keep connection alive"""
    emit('pong')


# ==================== Error Handlers ====================

@app.errorhandler(404)
def not_found(error):
    return jsonify({'error': 'Not found'}), 404


@app.errorhandler(500)
def internal_error(error):
    return jsonify({'error': 'Internal server error'}), 500


# ==================== Main ====================

if __name__ == '__main__':
    port = app.config['PORT']
    print("=" * 60)
    print("FNIRSI FNB58 Web Monitor")
    print(f"Dashboard: http://localhost:{port}")
    print("=" * 60)
    socketio.run(app, host=app.config['HOST'], port=port, debug=app.config['DEBUG'],
                 allow_unsafe_werkzeug=True)
