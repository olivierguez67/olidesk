"""Telegram alerting for olidesk-api.

Config lives in alerts.json (gitignored, never in the repo) next to
config.json -- see alerts.json.example for the format. A missing or
malformed config disables alerting entirely (logged once at import time);
it must never crash the app, since alerting is a nice-to-have on top of an
API that has to keep serving requests regardless.

Rate-limiting: every alert goes through _should_send(db, kind, key), which
persists the last-sent timestamp per (kind, key) pair in the same SQLite
database the rest of the app uses. That's a deliberate choice, not an
oversight -- gunicorn runs multiple worker processes that don't share
memory (the same reason registration_events exists instead of an in-memory
counter for the registration rate limit), so an in-memory cooldown would
let each worker send its own copy of the same alert. No more than one
alert per (kind, key) within ALERT_COOLDOWN, regardless of how many times
the underlying condition re-fires.
"""

import os
import json
import logging
import urllib.parse
import urllib.request
from datetime import datetime, timezone, timedelta

log = logging.getLogger("alerts")

ALERTS_CONFIG_PATH = os.environ.get(
    "ALERTS_CONFIG_PATH", os.path.join(os.path.dirname(__file__), "alerts.json")
)

# Never send more than one alert per (kind, key) within this window, no
# matter how many times the condition re-triggers -- the safety net so one
# ongoing incident can't send fifty messages.
ALERT_COOLDOWN = timedelta(minutes=15)

ADMIN_AUTH_FAILURE_THRESHOLD = 5
ADMIN_AUTH_FAILURE_WINDOW = timedelta(minutes=10)
ENROLL_FAILURE_THRESHOLD = 5
ENROLL_FAILURE_WINDOW = timedelta(minutes=10)

_bot_token = None
_chat_id = None


def _load_config():
    global _bot_token, _chat_id
    try:
        with open(ALERTS_CONFIG_PATH) as f:
            cfg = json.load(f)
    except FileNotFoundError:
        log.info("alerts.json not found at %s -- Telegram alerting disabled", ALERTS_CONFIG_PATH)
        return
    except Exception as e:
        log.warning("Failed to read alerts.json (%s) -- Telegram alerting disabled", e)
        return
    _bot_token = (cfg.get("bot_token") or "").strip() or None
    _chat_id = (cfg.get("chat_id") or "").strip() or None
    if _bot_token and _chat_id:
        log.info("Telegram alerting enabled")
    else:
        log.warning("alerts.json is missing bot_token/chat_id -- Telegram alerting disabled")


_load_config()


def alerts_enabled() -> bool:
    return bool(_bot_token and _chat_id)


def send_telegram_message(text: str) -> bool:
    """Best-effort send -- never raises. Callers don't (and shouldn't) need
    to handle a Telegram outage as anything other than "the alert didn't
    go out this time"."""
    if not alerts_enabled():
        return False
    try:
        url = f"https://api.telegram.org/bot{_bot_token}/sendMessage"
        data = urllib.parse.urlencode(
            {"chat_id": _chat_id, "text": text, "disable_web_page_preview": "true"}
        ).encode("utf-8")
        req = urllib.request.Request(url, data=data, method="POST")
        with urllib.request.urlopen(req, timeout=10) as resp:
            if resp.status != 200:
                log.warning("Telegram send failed: HTTP %s", resp.status)
                return False
            return True
    except Exception as e:
        log.warning("Telegram send failed: %s", e)
        return False


def _ensure_tables(db):
    """Idempotent; called once per connection right before these tables are
    first used, so a fresh alerts.py doesn't require an app.py schema
    migration to already have run."""
    db.executescript(
        """
        CREATE TABLE IF NOT EXISTS alert_failure_events (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            kind       TEXT    NOT NULL,
            ip         TEXT    NOT NULL,
            created_at TEXT    NOT NULL
        );
        CREATE TABLE IF NOT EXISTS alert_sent_log (
            kind    TEXT NOT NULL,
            key     TEXT NOT NULL,
            sent_at TEXT NOT NULL,
            PRIMARY KEY (kind, key)
        );
        """
    )


def _record_failure(db, kind: str, ip: str):
    _ensure_tables(db)
    db.execute(
        "INSERT INTO alert_failure_events (kind, ip, created_at) VALUES (?, ?, ?)",
        (kind, ip, datetime.now(timezone.utc).isoformat()),
    )
    db.commit()


def _recent_failure_count(db, kind: str, ip: str, window: timedelta) -> int:
    window_start = (datetime.now(timezone.utc) - window).isoformat()
    return db.execute(
        "SELECT COUNT(*) AS n FROM alert_failure_events "
        "WHERE kind = ? AND ip = ? AND created_at > ?",
        (kind, ip, window_start),
    ).fetchone()["n"]


def _should_send(db, kind: str, key: str) -> bool:
    _ensure_tables(db)
    now = datetime.now(timezone.utc)
    row = db.execute(
        "SELECT sent_at FROM alert_sent_log WHERE kind = ? AND key = ?", (kind, key)
    ).fetchone()
    if row is not None:
        last_sent = datetime.fromisoformat(row["sent_at"])
        if now - last_sent < ALERT_COOLDOWN:
            return False
    db.execute(
        "INSERT INTO alert_sent_log (kind, key, sent_at) VALUES (?, ?, ?) "
        "ON CONFLICT(kind, key) DO UPDATE SET sent_at = excluded.sent_at",
        (kind, key, now.isoformat()),
    )
    db.commit()
    return True


def check_admin_auth_failure(db, ip: str):
    """Call this for every failed admin-auth attempt (address-book or
    admin-devices endpoints alike) -- see _log_admin_auth in app.py."""
    if not alerts_enabled() or not ip:
        return
    _record_failure(db, "admin_auth", ip)
    count = _recent_failure_count(db, "admin_auth", ip, ADMIN_AUTH_FAILURE_WINDOW)
    if count >= ADMIN_AUTH_FAILURE_THRESHOLD and _should_send(db, "admin_auth", ip):
        minutes = int(ADMIN_AUTH_FAILURE_WINDOW.total_seconds() // 60)
        send_telegram_message(
            f"⚠️ Olidesk: {count} failed admin-auth attempts from "
            f"{ip} in the last {minutes} minutes."
        )


def check_enrollment_failure(db, ip: str):
    """Call this for every rejected enrollment code -- see
    require_enroll_auth in app.py."""
    if not alerts_enabled() or not ip:
        return
    _record_failure(db, "enrollment", ip)
    count = _recent_failure_count(db, "enrollment", ip, ENROLL_FAILURE_WINDOW)
    if count >= ENROLL_FAILURE_THRESHOLD and _should_send(db, "enrollment", ip):
        minutes = int(ENROLL_FAILURE_WINDOW.total_seconds() // 60)
        send_telegram_message(
            f"⚠️ Olidesk: {count} invalid enrollment-code attempts "
            f"from {ip} in the last {minutes} minutes."
        )


def alert_new_device(db, olidesk_id: str, hostname, group_name, ip: str):
    """Call this only for a genuinely new registration (HTTP 201, not a
    re-registration of an existing client) -- see register_client in
    app.py. Cooldown is keyed by olidesk_id rather than suppressed
    globally: a single device retry-looping its own registration can't
    spam this, but two different new devices each still get their own
    notification."""
    if not alerts_enabled():
        return
    if not _should_send(db, "new_device", olidesk_id or ip):
        return
    send_telegram_message(
        f"\U0001f195 Olidesk: new device registered — "
        f"host={hostname or '(unknown)'} group={group_name or '(none)'} ip={ip}"
    )
