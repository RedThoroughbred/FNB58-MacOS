#!/usr/bin/env python3
"""
FNIRSI FNB58 Web Monitor - Startup Script
Quick launcher with system checks
"""

import sys


def check_python_version():
    if sys.version_info < (3, 9):
        print("❌ Python 3.9 or higher is required")
        print(f"   Current version: {sys.version}")
        return False
    print(f"✓ Python {sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")
    return True


def check_dependencies():
    required = ['flask', 'flask_socketio', 'simple_websocket', 'usb', 'bleak']
    missing = []
    for package in required:
        try:
            __import__(package)
            print(f"✓ {package}")
        except ImportError:
            missing.append(package)
            print(f"❌ {package} not found")
    if missing:
        print("\n❌ Missing dependencies. Install with:")
        print("   pip install -r requirements.txt")
        return False
    return True


def check_device():
    print("\n🔍 Checking for FNIRSI device...")
    try:
        import usb.core
        from device.usb_reader import KNOWN_DEVICES
        for vid, pid, model, _ in KNOWN_DEVICES:
            if usb.core.find(idVendor=vid, idProduct=pid) is not None:
                print(f"✓ {model} detected on USB")
                return
        print("⚠️  No USB device detected (Bluetooth may still work)")
    except Exception as e:  # noqa: BLE001
        print(f"⚠️  Could not check USB: {e}")


def main():
    print("=" * 60)
    print("FNIRSI FNB58 Web Monitor - Startup")
    print("=" * 60)
    print("\nSystem Checks:")
    print("-" * 60)

    if not check_python_version() or not check_dependencies():
        sys.exit(1)
    check_device()

    from app import app, socketio
    port = app.config['PORT']

    print()
    print("=" * 60)
    print(f"Dashboard: http://localhost:{port}")
    print("Press Ctrl+C to stop")
    print("=" * 60)
    print()

    try:
        socketio.run(app, host=app.config['HOST'], port=port, debug=app.config['DEBUG'],
                     use_reloader=False, allow_unsafe_werkzeug=True)
    except KeyboardInterrupt:
        print("\n\n👋 Shutting down gracefully...")


if __name__ == '__main__':
    main()
