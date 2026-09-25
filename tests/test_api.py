import json
import os

from tests.fakes import reading_series


def connect(client, mode='usb'):
    r = client.post('/api/connect', json={'mode': mode})
    assert r.status_code == 200, r.get_json()
    return r.get_json()


def test_status_disconnected(app_client):
    client, _ = app_client
    assert client.get('/api/status').get_json() == {'connected': False}


def test_connect_status_disconnect_roundtrip(app_client):
    client, mod = app_client
    body = connect(client)
    assert body['success'] and body['connection_type'] == 'usb'
    assert client.get('/api/status').get_json()['connected'] is True
    assert client.post('/api/disconnect').get_json() == {'success': True}
    assert client.get('/api/status').get_json() == {'connected': False}


def test_connect_failure_is_400(app_client):
    client, mod = app_client
    from tests.fakes import FakeReader
    mod.device_manager._factories['usb'] = lambda **kw: FakeReader('usb', fail_connect=True)
    r = client.post('/api/connect', json={'mode': 'usb'})
    assert r.status_code == 400
    assert r.get_json()['success'] is False


def test_recording_flow_saves_named_session(app_client):
    client, mod = app_client
    connect(client)
    assert client.post('/api/recording/start', json={'name': 'My Bench Test'}).status_code == 200
    for r in reading_series(20, voltage=9.0, current=1.0):
        mod.device_manager.reader.push(r)
    stop = client.post('/api/recording/stop').get_json()
    assert stop['success']
    assert stop['filename'].startswith('My_Bench_Test_')
    assert stop['session']['stats']['samples_collected'] == 20

    listing = client.get('/api/sessions').get_json()
    assert listing['sessions'][0]['name'] == 'My Bench Test'
    assert listing['sessions'][0]['samples'] == 20

    fetched = client.get(f"/api/sessions/{stop['filename']}").get_json()
    assert fetched['session']['name'] == 'My Bench Test'

    assert client.delete(f"/api/sessions/{stop['filename']}").status_code == 200
    assert client.get(f"/api/sessions/{stop['filename']}").status_code == 404


def test_recording_requires_connection(app_client):
    client, _ = app_client
    assert client.post('/api/recording/start', json={}).status_code == 400
    assert client.post('/api/recording/stop').status_code == 400


def test_session_path_traversal_blocked(app_client):
    client, mod = app_client
    secret = os.path.join(os.path.dirname(mod.app.config['SESSION_DIR']), 'secret.json')
    with open(secret, 'w') as f:
        json.dump({'leak': True}, f)
    for name in ('../secret.json', '..%2Fsecret.json', 'secret.txt'):
        r = client.get(f'/api/sessions/{name}')
        assert r.status_code in (400, 404), name
        assert b'leak' not in r.data
        assert client.delete(f'/api/sessions/{name}').status_code in (400, 404)
    assert os.path.exists(secret)


def test_recent_and_latest_readings(app_client):
    client, mod = app_client
    assert client.get('/api/reading/latest').status_code == 404
    connect(client)
    for r in reading_series(5):
        mod.device_manager.reader.push(r)
    assert len(client.get('/api/reading/recent?points=3').get_json()) == 3
    assert client.get('/api/reading/latest').get_json()['sample'] == 0


def test_stats_json_has_no_infinity(app_client):
    client, _ = app_client
    r = client.get('/api/stats')
    assert r.status_code == 200
    json.loads(r.data)  # strict: raises on NaN/Infinity only if allow_nan False; also check text
    assert b'Infinity' not in r.data


def test_trigger_requires_usb_and_marks_experimental(app_client):
    client, mod = app_client
    assert client.post('/api/trigger/voltage', json={'protocol': 'pd', 'voltage': 9}).status_code == 400
    connect(client)
    r = client.post('/api/trigger/voltage', json={'protocol': 'pd', 'voltage': 9})
    assert r.status_code == 200
    assert r.get_json()['experimental'] is True
    assert mod.device_manager.reader.sent == [('trigger', 'pd', 9)]


def test_qc3_adjust_accepts_string_voltage(app_client):
    client, mod = app_client
    connect(client)
    r = client.post('/api/trigger/qc3-adjust', json={'voltage': '7.5'})
    assert r.status_code == 200, r.get_json()
    assert mod.device_manager.reader.sent == [('qc3', 7.5)]
    assert client.post('/api/trigger/qc3-adjust', json={'voltage': 'abc'}).status_code == 400


def test_thresholds_roundtrip(app_client):
    client, _ = app_client
    assert client.post('/api/thresholds', json={'name': 'max_voltage', 'value': 12}).get_json()['success']
    assert client.get('/api/thresholds').get_json()['thresholds']['max_voltage'] == 12
    assert client.post('/api/thresholds', json={'name': 'bogus', 'value': 1}).get_json()['success'] is False


def test_export_csv(app_client):
    client, _ = app_client
    r = client.post('/api/export/csv', json={'data': reading_series(3)})
    assert r.status_code == 200
    assert r.data.count(b'\n') >= 3
    assert client.post('/api/export/csv', json={'data': []}).status_code == 400


def test_pages_render(app_client):
    client, _ = app_client
    for path in ('/dashboard', '/settings', '/history', '/classic'):
        assert client.get(path).status_code == 200, path
    assert client.get('/').status_code == 302
