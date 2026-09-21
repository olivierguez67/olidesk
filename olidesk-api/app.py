import os
import re
import json
import sqlite3
import logging
import hashlib
import secrets
from functools import wraps
from datetime import datetime, timezone, timedelta

from flask import Flask, request, jsonify, g

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

CONFIG_PATH = os.environ.get("CONFIG_PATH", os.path.join(os.path.dirname(__file__), "config.json"))
with open(CONFIG_PATH) as _f:
    _CONFIG = json.load(_f)

# Break-glass recovery credential only — see require_admin_devices_auth.
# Address-book access (groups/clients) is per-device now; this token cannot
# reach it. Keep it secret and treat rotating it as a real incident response
# action, since anyone with it can mint new admin devices.
TOKEN = _CONFIG["token"]
DB_PATH = _CONFIG.get("db_path", "/data/address_book.sqlite")
HOST = _CONFIG.get("host", "0.0.0.0")
PORT = int(_CONFIG.get("port", 8443))

MAX_ADMIN_DEVICES = 4
REGISTER_RATE_LIMIT = 20
REGISTER_RATE_WINDOW = timedelta(hours=1)

# Enrollment codes (see require_enroll_auth and /api/admin/enrollment-codes)
# replace the old single shared DEPLOY_TOKEN that used to be baked into
# every client MSI -- no long-lived secret ships in a public installer
# anymore. Short, human-typeable, generated per deployment batch from the
# admin app, and time-limited.
ENROLL_CODE_LENGTH = 8
ENROLL_CODE_TTL = timedelta(hours=24)
# No 0/O/1/I/L: characters that are easy to misread or mistype when a code
# is read off a screen and typed into the client's registration dialog.
_ENROLL_CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

# Dedicated, append-only file for every admin auth attempt (success and
# failure) — separate from the app's own stdout logging so it's easy to
# find and tail on the server regardless of how gunicorn's logs are set up.
# Lives next to the database, i.e. under the same ./data bind mount.
_ADMIN_AUTH_LOG_PATH = os.path.join(
    os.path.dirname(os.path.abspath(DB_PATH)) or ".", "admin_auth.log"
)
os.makedirs(os.path.dirname(_ADMIN_AUTH_LOG_PATH), exist_ok=True)
admin_auth_log = logging.getLogger("admin_auth")
admin_auth_log.setLevel(logging.INFO)
admin_auth_log.propagate = False
if not admin_auth_log.handlers:
    _admin_auth_handler = logging.FileHandler(_ADMIN_AUTH_LOG_PATH)
    _admin_auth_handler.setFormatter(logging.Formatter("%(asctime)s %(message)s"))
    admin_auth_log.addHandler(_admin_auth_handler)

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

_SCHEMA = """
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

CREATE TABLE IF NOT EXISTS groups (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT    NOT NULL,
    parent_id  INTEGER REFERENCES groups(id) ON DELETE SET NULL,
    icon       TEXT,
    sort_order INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS clients (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    olidesk_id TEXT    NOT NULL,
    name       TEXT    NOT NULL,
    group_id   INTEGER REFERENCES groups(id) ON DELETE SET NULL,
    hostname   TEXT,
    platform   TEXT,
    notes      TEXT,
    last_seen  TEXT,
    sort_order INTEGER NOT NULL DEFAULT 0
);

-- Per-device admin credentials, replacing the single shared admin token.
-- Only a hash of each token is ever stored; the plaintext is returned once,
-- at creation time, and never again (see create_admin_device).
CREATE TABLE IF NOT EXISTS admin_devices (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT    NOT NULL,
    token_hash   TEXT    NOT NULL UNIQUE,
    olidesk_id   TEXT,
    created_at   TEXT    NOT NULL,
    last_seen_at TEXT,
    last_ip      TEXT
);

-- Audit trail for /api/clients/register, and the source of truth for its
-- rate limit (COUNT(*) over the trailing window beats an in-memory counter,
-- since gunicorn runs multiple worker processes that don't share memory).
-- token_hash holds a hash of whatever credential authenticated the
-- registration -- originally the single shared deploy token, now an
-- enrollment code's normalized value (see require_enroll_auth) -- so each
-- credential gets its own independent rate-limit bucket.
CREATE TABLE IF NOT EXISTS registration_events (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    token_hash TEXT NOT NULL,
    ip         TEXT,
    hostname   TEXT,
    olidesk_id TEXT,
    group_name TEXT,
    created_at TEXT NOT NULL
);

-- Short-lived codes minted from the admin app (see /api/admin/enrollment-
-- codes) that authenticate a fresh client's device-registration dialog
-- (flutter/lib/common/widgets/olidesk_register_device.dart) and silent
-- MSI installs (ENROLLCODE=... on the msiexec command line). Reusable
-- (not single-use) within their lifetime, same as the old deploy token,
-- since one code is meant to cover a whole deployment batch -- just
-- scoped to 24h and individually revocable instead of a single
-- long-lived secret baked into every installer.
CREATE TABLE IF NOT EXISTS enrollment_codes (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    code         TEXT    NOT NULL UNIQUE,
    created_at   TEXT    NOT NULL,
    expires_at   TEXT    NOT NULL,
    revoked_at   TEXT,
    created_by   TEXT,
    last_used_at TEXT,
    use_count    INTEGER NOT NULL DEFAULT 0
);
"""


def init_db():
    os.makedirs(os.path.dirname(os.path.abspath(DB_PATH)), exist_ok=True)
    db = sqlite3.connect(DB_PATH)
    db.executescript(_SCHEMA)
    db.commit()
    db.close()
    log.info("Database ready: %s", DB_PATH)


# Initialise at import time so gunicorn workers pick it up.
init_db()

app = Flask(__name__)


def get_db():
    if "db" not in g:
        g.db = sqlite3.connect(DB_PATH, detect_types=sqlite3.PARSE_DECLTYPES)
        g.db.row_factory = sqlite3.Row
        g.db.execute("PRAGMA foreign_keys = ON")
        g.db.execute("PRAGMA journal_mode = WAL")
    return g.db


@app.teardown_appcontext
def close_db(exc):
    db = g.pop("db", None)
    if db is not None:
        db.close()


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

def _hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def _client_ip() -> str:
    # The address book API sits behind nginx (see olidesk_address_book.dart's
    # default URL comment), so prefer the original client IP if forwarded.
    forwarded = request.headers.get("X-Forwarded-For", "")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.remote_addr or ""


def _log_admin_auth(success: bool, device_name, endpoint: str):
    admin_auth_log.info(
        "%s ip=%s device=%s endpoint=%s",
        "SUCCESS" if success else "FAILURE",
        _client_ip(),
        device_name or "-",
        endpoint,
    )


def _touch_device(db, device_row):
    db.execute(
        "UPDATE admin_devices SET last_seen_at = ?, last_ip = ? WHERE id = ?",
        (datetime.now(timezone.utc).isoformat(), _client_ip(), device_row["id"]),
    )
    db.commit()


def _bearer_token() -> str:
    auth = request.headers.get("Authorization", "")
    return auth[7:] if auth.startswith("Bearer ") else ""


def _current_actor_name() -> str:
    """Name of whoever require_admin_devices_auth authenticated this request
    as, for audit logging. None means it was the break-glass token."""
    device = getattr(g, "admin_device", None)
    return device["name"] if device is not None else "break-glass"


def require_ab_auth(f):
    """Address-book endpoints (groups/clients): a valid per-device token
    only. The break-glass TOKEN deliberately does not work here — see
    require_admin_devices_auth for where it does."""
    @wraps(f)
    def decorated(*args, **kwargs):
        token = _bearer_token()
        db = get_db()
        device = None
        if token:
            device = db.execute(
                "SELECT * FROM admin_devices WHERE token_hash = ?",
                (_hash_token(token),),
            ).fetchone()
        if not device:
            _log_admin_auth(False, None, request.path)
            return jsonify({"error": "Unauthorized"}), 401
        _touch_device(db, device)
        _log_admin_auth(True, device["name"], request.path)
        g.admin_device = device
        return f(*args, **kwargs)
    return decorated


def require_admin_devices_auth(f):
    """/api/admin/devices endpoints: a valid per-device token, OR the
    break-glass config token — needed to bootstrap the very first device on
    a fresh server, and to recover if every device token is lost."""
    @wraps(f)
    def decorated(*args, **kwargs):
        token = _bearer_token()
        if token and TOKEN and token == TOKEN:
            _log_admin_auth(True, "break-glass", request.path)
            g.admin_device = None
            return f(*args, **kwargs)
        db = get_db()
        device = None
        if token:
            device = db.execute(
                "SELECT * FROM admin_devices WHERE token_hash = ?",
                (_hash_token(token),),
            ).fetchone()
        if not device:
            _log_admin_auth(False, None, request.path)
            return jsonify({"error": "Unauthorized"}), 401
        _touch_device(db, device)
        _log_admin_auth(True, device["name"], request.path)
        g.admin_device = device
        return f(*args, **kwargs)
    return decorated


def _normalize_enroll_code(raw: str) -> str:
    """Upper-cases and strips everything but letters/digits, so "k7h2-9x4q",
    "K7H29X4Q", and "  K7H2-9X4Q  " (however the client or a human typed or
    pasted it) all resolve to the same stored code."""
    return re.sub(r"[^A-Z0-9]", "", (raw or "").upper())


def _format_enroll_code(code: str) -> str:
    """The human-facing "XXXX-XXXX" spelling of a stored (dash-free) code."""
    return f"{code[:4]}-{code[4:]}" if len(code) == ENROLL_CODE_LENGTH else code


def _generate_enroll_code() -> str:
    return "".join(secrets.choice(_ENROLL_CODE_ALPHABET) for _ in range(ENROLL_CODE_LENGTH))


def require_enroll_auth(f):
    """Accepts only a valid, unexpired, unrevoked enrollment code (see
    /api/admin/enrollment-codes) as the bearer token, never an admin
    credential. Deliberately not a fallback on top of the admin auth
    decorators: an enrollment code stays scoped to exactly the two
    endpoints a fresh client needs. Replaces the old single shared
    DEPLOY_TOKEN that used to be baked into every client MSI."""
    @wraps(f)
    def decorated(*args, **kwargs):
        code = _normalize_enroll_code(_bearer_token())
        if not code:
            return jsonify({"error": "Unauthorized"}), 401
        db = get_db()
        now = datetime.now(timezone.utc).isoformat()
        row = db.execute(
            "SELECT * FROM enrollment_codes WHERE code = ? AND revoked_at IS NULL AND expires_at > ?",
            (code, now),
        ).fetchone()
        if not row:
            return jsonify({"error": "Unauthorized"}), 401
        g.enrollment_code = row
        return f(*args, **kwargs)
    return decorated


# ---------------------------------------------------------------------------
# Group helpers
# ---------------------------------------------------------------------------

def _build_tree(groups, parent_id=None):
    children = [g for g in groups if g["parent_id"] == parent_id]
    children.sort(key=lambda x: (x["sort_order"], x["name"].lower()))
    result = []
    for grp in children:
        node = dict(grp)
        node["children"] = _build_tree(groups, grp["id"])
        result.append(node)
    return result


def _is_descendant(db, ancestor_id, candidate_id):
    """Return True if candidate_id is in the subtree rooted at ancestor_id."""
    visited = set()
    queue = [candidate_id]
    while queue:
        current = queue.pop()
        if current in visited:
            continue
        visited.add(current)
        if current == ancestor_id:
            return True
        rows = db.execute("SELECT id FROM groups WHERE parent_id = ?", (current,)).fetchall()
        queue.extend(r["id"] for r in rows)
    return False


def _get_or_create_top_level_group(db, name):
    """Look up a top-level group by name (case-insensitive), creating it if
    it doesn't exist yet. Used by /api/clients/register so a deployment
    package's group name ("ASPEN GROUP") just works without the admin having
    to pre-create it."""
    name = (name or "").strip()
    if not name:
        return None
    row = db.execute(
        "SELECT id FROM groups WHERE parent_id IS NULL AND lower(name) = lower(?)",
        (name,),
    ).fetchone()
    if row:
        return row["id"]
    cur = db.execute(
        "INSERT INTO groups (name, parent_id, icon, sort_order) VALUES (?, NULL, NULL, 0)",
        (name,),
    )
    return cur.lastrowid


# ---------------------------------------------------------------------------
# Group endpoints
# ---------------------------------------------------------------------------

@app.route("/api/groups", methods=["GET"])
@require_ab_auth
def get_groups():
    db = get_db()
    rows = db.execute("SELECT id, name, parent_id, icon, sort_order FROM groups").fetchall()
    return jsonify(_build_tree([dict(r) for r in rows]))


@app.route("/api/groups", methods=["POST"])
@require_ab_auth
def create_group():
    data = request.get_json(silent=True) or {}
    name = (data.get("name") or "").strip()
    if not name:
        return jsonify({"error": "name is required"}), 400

    parent_id = data.get("parent_id")
    icon = data.get("icon")
    sort_order = int(data.get("sort_order", 0))

    db = get_db()
    if parent_id is not None:
        if not db.execute("SELECT 1 FROM groups WHERE id = ?", (parent_id,)).fetchone():
            return jsonify({"error": "parent_id not found"}), 400

    cur = db.execute(
        "INSERT INTO groups (name, parent_id, icon, sort_order) VALUES (?, ?, ?, ?)",
        (name, parent_id, icon, sort_order),
    )
    db.commit()
    row = db.execute("SELECT * FROM groups WHERE id = ?", (cur.lastrowid,)).fetchone()
    return jsonify(dict(row)), 201


@app.route("/api/groups/<int:group_id>", methods=["PUT"])
@require_ab_auth
def update_group(group_id):
    db = get_db()
    if not db.execute("SELECT 1 FROM groups WHERE id = ?", (group_id,)).fetchone():
        return jsonify({"error": "Not found"}), 404

    data = request.get_json(silent=True) or {}
    fields = {}

    if "name" in data:
        name = (data["name"] or "").strip()
        if not name:
            return jsonify({"error": "name cannot be empty"}), 400
        fields["name"] = name

    if "parent_id" in data:
        parent_id = data["parent_id"]
        if parent_id is not None:
            if parent_id == group_id:
                return jsonify({"error": "Cannot set parent to self"}), 400
            if not db.execute("SELECT 1 FROM groups WHERE id = ?", (parent_id,)).fetchone():
                return jsonify({"error": "parent_id not found"}), 400
            if _is_descendant(db, group_id, parent_id):
                return jsonify({"error": "Circular reference detected"}), 400
        fields["parent_id"] = parent_id

    if "icon" in data:
        fields["icon"] = data["icon"]
    if "sort_order" in data:
        fields["sort_order"] = int(data["sort_order"])

    if not fields:
        return jsonify({"error": "No fields to update"}), 400

    set_clause = ", ".join(f"{k} = ?" for k in fields)
    db.execute(f"UPDATE groups SET {set_clause} WHERE id = ?", list(fields.values()) + [group_id])
    db.commit()
    row = db.execute("SELECT * FROM groups WHERE id = ?", (group_id,)).fetchone()
    return jsonify(dict(row))


@app.route("/api/groups/<int:group_id>", methods=["DELETE"])
@require_ab_auth
def delete_group(group_id):
    db = get_db()
    row = db.execute("SELECT * FROM groups WHERE id = ?", (group_id,)).fetchone()
    if not row:
        return jsonify({"error": "Not found"}), 404

    parent_id = row["parent_id"]
    # Reparent children and clients before deleting.
    db.execute("UPDATE groups  SET parent_id = ? WHERE parent_id = ?", (parent_id, group_id))
    db.execute("UPDATE clients SET group_id  = ? WHERE group_id  = ?", (parent_id, group_id))
    db.execute("DELETE FROM groups WHERE id = ?", (group_id,))
    db.commit()
    return jsonify({"deleted": group_id, "children_moved_to": parent_id})


# ---------------------------------------------------------------------------
# Client endpoints
# ---------------------------------------------------------------------------

_CLIENT_SELECT = """
    SELECT c.id, c.olidesk_id, c.name, c.group_id, g.name AS group_name,
           c.hostname, c.platform, c.notes, c.last_seen, c.sort_order
    FROM clients c
    LEFT JOIN groups g ON c.group_id = g.id
"""


@app.route("/api/clients", methods=["GET"])
@require_ab_auth
def get_clients():
    db = get_db()
    group_id = request.args.get("group_id")

    if group_id is not None:
        try:
            group_id = int(group_id)
        except ValueError:
            return jsonify({"error": "group_id must be an integer"}), 400
        rows = db.execute(
            _CLIENT_SELECT + " WHERE c.group_id = ? ORDER BY c.sort_order, c.name",
            (group_id,),
        ).fetchall()
    else:
        rows = db.execute(_CLIENT_SELECT + " ORDER BY c.sort_order, c.name").fetchall()

    return jsonify([dict(r) for r in rows])


@app.route("/api/clients", methods=["POST"])
@require_ab_auth
def create_client():
    data = request.get_json(silent=True) or {}
    olidesk_id = (data.get("olidesk_id") or "").strip()
    name = (data.get("name") or "").strip()

    if not olidesk_id:
        return jsonify({"error": "olidesk_id is required"}), 400
    if not name:
        return jsonify({"error": "name is required"}), 400

    group_id = data.get("group_id")
    db = get_db()
    if group_id is not None:
        if not db.execute("SELECT 1 FROM groups WHERE id = ?", (group_id,)).fetchone():
            return jsonify({"error": "group_id not found"}), 400

    last_seen = data.get("last_seen") or datetime.now(timezone.utc).isoformat()
    cur = db.execute(
        """INSERT INTO clients
               (olidesk_id, name, group_id, hostname, platform, notes, last_seen, sort_order)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            olidesk_id, name, group_id,
            data.get("hostname"), data.get("platform"), data.get("notes"),
            last_seen, int(data.get("sort_order", 0)),
        ),
    )
    db.commit()
    row = db.execute(_CLIENT_SELECT + " WHERE c.id = ?", (cur.lastrowid,)).fetchone()
    return jsonify(dict(row)), 201


@app.route("/api/clients/<int:client_id>", methods=["PUT"])
@require_ab_auth
def update_client(client_id):
    db = get_db()
    if not db.execute("SELECT 1 FROM clients WHERE id = ?", (client_id,)).fetchone():
        return jsonify({"error": "Not found"}), 404

    data = request.get_json(silent=True) or {}
    fields = {}

    for key in ("olidesk_id", "name", "hostname", "platform", "notes", "last_seen"):
        if key in data:
            fields[key] = data[key]

    if "group_id" in data:
        group_id = data["group_id"]
        if group_id is not None:
            if not db.execute("SELECT 1 FROM groups WHERE id = ?", (group_id,)).fetchone():
                return jsonify({"error": "group_id not found"}), 400
        fields["group_id"] = group_id

    if "sort_order" in data:
        fields["sort_order"] = int(data["sort_order"])

    if not fields:
        return jsonify({"error": "No fields to update"}), 400

    set_clause = ", ".join(f"{k} = ?" for k in fields)
    db.execute(
        f"UPDATE clients SET {set_clause} WHERE id = ?",
        list(fields.values()) + [client_id],
    )
    db.commit()
    row = db.execute(_CLIENT_SELECT + " WHERE c.id = ?", (client_id,)).fetchone()
    return jsonify(dict(row))


@app.route("/api/clients/<int:client_id>", methods=["DELETE"])
@require_ab_auth
def delete_client(client_id):
    db = get_db()
    if not db.execute("SELECT 1 FROM clients WHERE id = ?", (client_id,)).fetchone():
        return jsonify({"error": "Not found"}), 404
    db.execute("DELETE FROM clients WHERE id = ?", (client_id,))
    db.commit()
    return jsonify({"deleted": client_id})


@app.route("/api/clients/<int:client_id>/move", methods=["POST"])
@require_ab_auth
def move_client(client_id):
    db = get_db()
    if not db.execute("SELECT 1 FROM clients WHERE id = ?", (client_id,)).fetchone():
        return jsonify({"error": "Not found"}), 404

    data = request.get_json(silent=True) or {}
    group_id = data.get("group_id")
    if group_id is not None:
        if not db.execute("SELECT 1 FROM groups WHERE id = ?", (group_id,)).fetchone():
            return jsonify({"error": "group_id not found"}), 400

    db.execute("UPDATE clients SET group_id = ? WHERE id = ?", (group_id, client_id))
    db.commit()
    row = db.execute(_CLIENT_SELECT + " WHERE c.id = ?", (client_id,)).fetchone()
    return jsonify(dict(row))


@app.route("/api/clients/register", methods=["POST"])
@require_enroll_auth
def register_client():
    """Self-service registration used by freshly deployed clients -- both
    the silent path (olidesk-deploy.json, written by the MSI from
    ENROLLCODE=...; see flutter/lib/common/olidesk_deploy.dart) and the
    app's own "Register this device" dialog (olidesk_register_device.dart).
    Deliberately narrower than POST /api/clients: no notes/sort_order, and
    re-registering an existing olidesk_id updates it in place instead of
    creating a duplicate entry.

    Rate limited to REGISTER_RATE_LIMIT calls per REGISTER_RATE_WINDOW per
    enrollment code, counted from registration_events (not an in-memory
    counter, since it has to hold across gunicorn's worker processes) --
    each code gets its own independent bucket."""
    db = get_db()
    code_row = g.enrollment_code
    token_hash = _hash_token(code_row["code"])
    window_start = (datetime.now(timezone.utc) - REGISTER_RATE_WINDOW).isoformat()
    recent = db.execute(
        "SELECT COUNT(*) AS n FROM registration_events WHERE token_hash = ? AND created_at > ?",
        (token_hash, window_start),
    ).fetchone()["n"]
    if recent >= REGISTER_RATE_LIMIT:
        log.warning("registration rate limit hit, ip=%s", _client_ip())
        return jsonify({"error": "Too many registrations, try again later"}), 429

    data = request.get_json(silent=True) or {}
    olidesk_id = (data.get("olidesk_id") or "").strip()
    if not olidesk_id:
        return jsonify({"error": "olidesk_id is required"}), 400

    hostname = (data.get("hostname") or "").strip() or None
    platform = (data.get("os") or "").strip() or None
    group_name = data.get("group")

    group_id = _get_or_create_top_level_group(db, group_name)
    now = datetime.now(timezone.utc).isoformat()

    existing = db.execute(
        "SELECT id FROM clients WHERE olidesk_id = ?", (olidesk_id,)
    ).fetchone()

    if existing:
        client_id = existing["id"]
        fields = {"last_seen": now}
        if hostname:
            fields["hostname"] = hostname
            fields["name"] = hostname
        if platform:
            fields["platform"] = platform
        if group_id is not None:
            fields["group_id"] = group_id
        set_clause = ", ".join(f"{k} = ?" for k in fields)
        db.execute(
            f"UPDATE clients SET {set_clause} WHERE id = ?",
            list(fields.values()) + [client_id],
        )
        db.commit()
        status = 200
    else:
        cur = db.execute(
            """INSERT INTO clients
                   (olidesk_id, name, group_id, hostname, platform, notes, last_seen, sort_order)
               VALUES (?, ?, ?, ?, ?, NULL, ?, 0)""",
            (olidesk_id, hostname or olidesk_id, group_id, hostname, platform, now),
        )
        db.commit()
        client_id = cur.lastrowid
        status = 201

    db.execute(
        """INSERT INTO registration_events
               (token_hash, ip, hostname, olidesk_id, group_name, created_at)
           VALUES (?, ?, ?, ?, ?, ?)""",
        (token_hash, _client_ip(), hostname, olidesk_id, group_name, now),
    )
    db.execute(
        "UPDATE enrollment_codes SET last_used_at = ?, use_count = use_count + 1 WHERE id = ?",
        (now, code_row["id"]),
    )
    db.commit()
    log.info(
        "client registered: ip=%s hostname=%s group=%s olidesk_id=%s",
        _client_ip(), hostname, group_name, olidesk_id,
    )

    row = db.execute(_CLIENT_SELECT + " WHERE c.id = ?", (client_id,)).fetchone()
    return jsonify(dict(row)), status


@app.route("/api/deploy/groups", methods=["GET"])
@require_enroll_auth
def list_deploy_groups():
    """Read-only group name list for the client's "Register this device"
    dialog (flutter/lib/common/widgets/olidesk_register_device.dart), shown
    once a typed enrollment code validates. Deliberately minimal -- just
    top-level group names, nothing a leaked/guessed code could use to
    enumerate clients, IDs, or the group tree.

    /api/groups (the admin endpoint) 401s for an enrollment code now that
    address-book access is per-device (require_ab_auth); this is the
    enrollment-code-scoped equivalent for exactly the one thing a
    registering client needs."""
    db = get_db()
    rows = db.execute(
        "SELECT name FROM groups WHERE parent_id IS NULL ORDER BY lower(name)"
    ).fetchall()
    return jsonify([r["name"] for r in rows])


# ---------------------------------------------------------------------------
# Enrollment code endpoints (admin-only)
# ---------------------------------------------------------------------------

_ENROLLMENT_CODE_SELECT = (
    "SELECT id, code, created_at, expires_at, revoked_at, created_by, "
    "last_used_at, use_count FROM enrollment_codes"
)


def _enrollment_code_public(row) -> dict:
    d = dict(row)
    d["code"] = _format_enroll_code(d["code"])
    return d


@app.route("/api/admin/enrollment-codes", methods=["GET"])
@require_admin_devices_auth
def list_enrollment_codes():
    db = get_db()
    rows = db.execute(_ENROLLMENT_CODE_SELECT + " ORDER BY created_at DESC").fetchall()
    return jsonify([_enrollment_code_public(r) for r in rows])


@app.route("/api/admin/enrollment-codes", methods=["POST"])
@require_admin_devices_auth
def create_enrollment_code():
    db = get_db()
    now = datetime.now(timezone.utc)

    code = _generate_enroll_code()
    # 32^8 possible codes makes a collision astronomically unlikely, but the
    # UNIQUE constraint means one would 500 the request instead of silently
    # minting a duplicate -- retry a handful of times rather than trust luck.
    for _ in range(5):
        if not db.execute("SELECT 1 FROM enrollment_codes WHERE code = ?", (code,)).fetchone():
            break
        code = _generate_enroll_code()

    cur = db.execute(
        """INSERT INTO enrollment_codes (code, created_at, expires_at, created_by)
           VALUES (?, ?, ?, ?)""",
        (code, now.isoformat(), (now + ENROLL_CODE_TTL).isoformat(), _current_actor_name()),
    )
    db.commit()
    row = db.execute(_ENROLLMENT_CODE_SELECT + " WHERE id = ?", (cur.lastrowid,)).fetchone()
    admin_auth_log.info("ENROLL_CODE_CREATED ip=%s by=%s", _client_ip(), _current_actor_name())
    return jsonify(_enrollment_code_public(row)), 201


@app.route("/api/admin/enrollment-codes/<int:code_id>", methods=["DELETE"])
@require_admin_devices_auth
def revoke_enrollment_code(code_id):
    db = get_db()
    row = db.execute("SELECT * FROM enrollment_codes WHERE id = ?", (code_id,)).fetchone()
    if not row:
        return jsonify({"error": "Not found"}), 404
    db.execute(
        "UPDATE enrollment_codes SET revoked_at = ? WHERE id = ?",
        (datetime.now(timezone.utc).isoformat(), code_id),
    )
    db.commit()
    admin_auth_log.info("ENROLL_CODE_REVOKED ip=%s by=%s", _client_ip(), _current_actor_name())
    return jsonify({"revoked": code_id})


# ---------------------------------------------------------------------------
# Admin device endpoints
# ---------------------------------------------------------------------------

_ADMIN_DEVICE_SELECT = (
    "SELECT id, name, olidesk_id, created_at, last_seen_at, last_ip FROM admin_devices"
)


@app.route("/api/admin/devices", methods=["GET"])
@require_admin_devices_auth
def list_admin_devices():
    db = get_db()
    rows = db.execute(_ADMIN_DEVICE_SELECT + " ORDER BY created_at").fetchall()
    return jsonify([dict(r) for r in rows])


@app.route("/api/admin/devices", methods=["POST"])
@require_admin_devices_auth
def create_admin_device():
    data = request.get_json(silent=True) or {}
    name = (data.get("name") or "").strip()
    if not name:
        return jsonify({"error": "name is required"}), 400
    olidesk_id = (data.get("olidesk_id") or "").strip() or None

    db = get_db()
    count = db.execute("SELECT COUNT(*) AS n FROM admin_devices").fetchone()["n"]
    if count >= MAX_ADMIN_DEVICES:
        return jsonify({
            "error": f"Device limit reached ({MAX_ADMIN_DEVICES}). Revoke one first."
        }), 403

    token = secrets.token_urlsafe(32)
    now = datetime.now(timezone.utc).isoformat()
    cur = db.execute(
        """INSERT INTO admin_devices
               (name, token_hash, olidesk_id, created_at, last_seen_at, last_ip)
           VALUES (?, ?, ?, ?, NULL, NULL)""",
        (name, _hash_token(token), olidesk_id, now),
    )
    db.commit()
    row = db.execute(_ADMIN_DEVICE_SELECT + " WHERE id = ?", (cur.lastrowid,)).fetchone()
    result = dict(row)
    # Returned once, here, and never again — only the hash is persisted.
    result["token"] = token
    admin_auth_log.info(
        "DEVICE_CREATED ip=%s name=%s by=%s",
        _client_ip(), name, _current_actor_name(),
    )
    return jsonify(result), 201


@app.route("/api/admin/devices/<int:device_id>", methods=["DELETE"])
@require_admin_devices_auth
def delete_admin_device(device_id):
    db = get_db()
    row = db.execute("SELECT * FROM admin_devices WHERE id = ?", (device_id,)).fetchone()
    if not row:
        return jsonify({"error": "Not found"}), 404
    db.execute("DELETE FROM admin_devices WHERE id = ?", (device_id,))
    db.commit()
    admin_auth_log.info(
        "DEVICE_REVOKED ip=%s name=%s by=%s",
        _client_ip(), row["name"], _current_actor_name(),
    )
    return jsonify({"deleted": device_id})


# ---------------------------------------------------------------------------
# Health (no auth — used by Docker healthcheck)
# ---------------------------------------------------------------------------

@app.route("/health")
def health():
    return jsonify({"status": "ok"})


# ---------------------------------------------------------------------------
# Dev entrypoint
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    app.run(host=HOST, port=PORT, debug=False)
