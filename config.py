import os


class Config:
    """Base configuration"""
    SECRET_KEY = os.environ.get('SECRET_KEY') or 'dev-secret-key-change-in-production'

    # Server. Port 5000 is taken by AirPlay Receiver on recent macOS, so default to 5001.
    HOST = os.environ.get('HOST', '0.0.0.0')
    PORT = int(os.environ.get('PORT', 5001))

    # Bluetooth Configuration
    BT_DEVICE_NAME = os.environ.get('BT_DEVICE_NAME', 'FNB58')  # Partial name to search for

    # Data Collection
    MAX_DATA_POINTS = 10000  # Maximum points to keep in memory

    # Storage
    BASE_DIR = os.path.dirname(os.path.abspath(__file__))
    EXPORT_DIR = os.environ.get('EXPORT_DIR', os.path.join(BASE_DIR, 'exports'))
    SESSION_DIR = os.environ.get('SESSION_DIR', os.path.join(BASE_DIR, 'sessions'))

    @classmethod
    def init_app(cls, app):
        """Initialize application directories"""
        os.makedirs(cls.EXPORT_DIR, exist_ok=True)
        os.makedirs(cls.SESSION_DIR, exist_ok=True)


class DevelopmentConfig(Config):
    DEBUG = True
    TESTING = False


class ProductionConfig(Config):
    DEBUG = False
    TESTING = False


class TestingConfig(Config):
    DEBUG = False
    TESTING = True


config = {
    'development': DevelopmentConfig,
    'production': ProductionConfig,
    'testing': TestingConfig,
    'default': DevelopmentConfig,
}
