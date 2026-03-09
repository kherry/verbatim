"""
run.py — Development entry point.

Usage:
    python run.py

This starts Flask's built-in dev server with reloading enabled.
For production, use gunicorn directly (see README).
"""

from app import create_app
import config

if __name__ == "__main__":
    app = create_app()
    app.run(
        host="0.0.0.0",
        port=config.GUNICORN_PORT,
        debug=config.DEBUG,
        use_reloader=config.DEBUG,
    )
