import os
import json
import sqlite3
import logging
from functools import wraps
from datetime import datetime, timezone

from flask import Flask, request, jsonify, g

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

CONFIG_PATH = os.environ.get("CONFIG_PATH", os.path.join(os.path.dirname(__file__), "config.json"))
with open(CONFIG_PATH) as _f:
    _CONFIG = json.load(_f)

TOKEN = _CONFIG["token"]
DB_PATH = _CONFIG.get("db_path", "/data/address_book.sqlite")
HOST = _CONFIG.get("host", "0.0.0.0")
PORT = int(_CONFIG.get("port", 8443))

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)

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

def require_auth(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        auth = request.headers.get("Authorization", "")
        if not auth.startswith("Bearer ") or auth[7:] != TOKEN:
            return jsonify({"error": "Unauthorized"}), 401
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


# ---------------------------------------------------------------------------
# Group endpoints
# ---------------------------------------------------------------------------

@app.route("/api/groups", methods=["GET"])
@require_auth
def get_groups():
    db = get_db()
    rows = db.execute("SELECT id, name, parent_id, icon, sort_order FROM groups").fetchall()
    return jsonify(_build_tree([dict(r) for r in rows]))


@app.route("/api/groups", methods=["POST"])
@require_auth
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
@require_auth
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
@require_auth
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
@require_auth
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
@require_auth
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
@require_auth
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
@require_auth
def delete_client(client_id):
    db = get_db()
    if not db.execute("SELECT 1 FROM clients WHERE id = ?", (client_id,)).fetchone():
        return jsonify({"error": "Not found"}), 404
    db.execute("DELETE FROM clients WHERE id = ?", (client_id,))
    db.commit()
    return jsonify({"deleted": client_id})


@app.route("/api/clients/<int:client_id>/move", methods=["POST"])
@require_auth
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
