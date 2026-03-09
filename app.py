"""
app.py — Flask application factory.

Import and call create_app() to get the configured Flask instance.
Both run.py (dev) and gunicorn (prod) use this.
"""

from flask import Flask

import config


def create_app() -> Flask:
    app = Flask(__name__)

    # ── Core config ───────────────────────────────────────────────────────────
    app.secret_key = config.SECRET_KEY
    app.debug = config.DEBUG
    app.config["MAX_CONTENT_LENGTH"] = config.MAX_UPLOAD_BYTES

    # ── Register blueprints ───────────────────────────────────────────────────
    # Blueprints are registered here as they are built in later steps.
    # Each import is guarded so the scaffold boots even before those files exist.

    try:
        from routes.upload import upload_bp
        app.register_blueprint(upload_bp)
    except ImportError:
        pass

    try:
        from routes.job import job_bp
        app.register_blueprint(job_bp)
    except ImportError:
        pass

    try:
        from routes.processing import processing_bp
        app.register_blueprint(processing_bp)
    except ImportError:
        pass

    try:
        from routes.download import download_bp
        app.register_blueprint(download_bp)
    except ImportError:
        pass

    # ── Health check ──────────────────────────────────────────────────────────
    @app.get("/health")
    def health():
        return {"status": "ok"}, 200

    return app
