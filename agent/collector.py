#!/usr/bin/env python3

import base64
import hashlib
import json
import socket
import sqlite3
import subprocess
import urllib.parse
import urllib.request
from datetime import datetime, timezone


CONFIG_FILE = "/opt/mvt-dns-agent/config.env"
DB_FILE = "/opt/mvt-dns-agent/queue.db"

AGENT_VERSION = "0.2.1"

ADGUARD_PAGE_SIZE = 500
UPLOAD_BATCH_SIZE = 500
MAX_PAGES_PER_RUN = 1000


# =========================================================
# CONFIGURATION
# =========================================================

def load_config():
    config = {}

    with open(CONFIG_FILE, "r") as f:
        for line in f:
            line = line.strip()

            if not line or line.startswith("#") or "=" not in line:
                continue

            key, value = line.split("=", 1)
            config[key.strip()] = value.strip().strip('"').strip("'")

    required = [
        "MVT_API_BASE",
        "MVT_API_KEY",
        "ADGUARD_URL",
        "ADGUARD_USERNAME",
        "ADGUARD_PASSWORD",
    ]

    for key in required:
        if not config.get(key):
            raise RuntimeError(
                f"Missing configuration value: {key}"
            )

    return config


# =========================================================
# SQLITE
# =========================================================

def open_database():
    db = sqlite3.connect(DB_FILE)

    db.execute("""
        CREATE TABLE IF NOT EXISTS queue (
            event_uid TEXT PRIMARY KEY,
            event_timestamp TEXT NOT NULL,
            payload TEXT NOT NULL,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        )
    """)

    db.execute("""
        CREATE TABLE IF NOT EXISTS state (
            key TEXT PRIMARY KEY,
            value TEXT
        )
    """)

    db.commit()

    return db


def get_state(db, key):
    row = db.execute(
        "SELECT value FROM state WHERE key = ?",
        (key,)
    ).fetchone()

    return row[0] if row else None


def set_state(db, key, value):
    db.execute("""
        INSERT INTO state (
            key,
            value
        )
        VALUES (?, ?)
        ON CONFLICT(key)
        DO UPDATE SET value = excluded.value
    """, (
        key,
        str(value)
    ))

    db.commit()


def queue_event(db, event):
    db.execute("""
        INSERT OR IGNORE INTO queue (
            event_uid,
            event_timestamp,
            payload
        )
        VALUES (?, ?, ?)
    """, (
        event["event_uid"],
        event["timestamp"],
        json.dumps(event),
    ))


def queue_count(db):
    row = db.execute(
        "SELECT COUNT(*) FROM queue"
    ).fetchone()

    return row[0]


# =========================================================
# ADGUARD HELPERS
# =========================================================

def adguard_auth_header(config):
    credentials = (
        f'{config["ADGUARD_USERNAME"]}:'
        f'{config["ADGUARD_PASSWORD"]}'
    ).encode()

    encoded = base64.b64encode(
        credentials
    ).decode()

    return "Basic " + encoded


def get_adguard_status(config):
    url = (
        config["ADGUARD_URL"].rstrip("/")
        + "/control/status"
    )

    request = urllib.request.Request(
        url,
        headers={
            "Authorization": adguard_auth_header(config),
            "Accept": "application/json",
        },
    )

    try:
        with urllib.request.urlopen(
            request,
            timeout=15
        ) as response:

            data = json.loads(
                response.read().decode()
            )

            return {
                "healthy": True,
                "version": data.get("version"),
                "running": data.get(
                    "running",
                    True
                ),
                "protection_enabled": data.get(
                    "protection_enabled"
                ),
            }

    except Exception as error:
        print(
            f"Unable to read AdGuard status: {error}"
        )

        return {
            "healthy": False,
            "version": None,
            "running": False,
            "protection_enabled": None,
        }


# =========================================================
# ADGUARD QUERY LOG
# =========================================================

def adguard_query_log(
    config,
    older_than=None
):
    params = {
        "limit": ADGUARD_PAGE_SIZE
    }

    if older_than:
        params["older_than"] = older_than

    query = urllib.parse.urlencode(
        params
    )

    url = (
        config["ADGUARD_URL"].rstrip("/")
        + "/control/querylog?"
        + query
    )

    request = urllib.request.Request(
        url,
        headers={
            "Authorization": adguard_auth_header(config),
            "Accept": "application/json",
        },
    )

    with urllib.request.urlopen(
        request,
        timeout=30
    ) as response:

        return json.loads(
            response.read().decode()
        )


# =========================================================
# DNS EVENT CONVERSION
# =========================================================

def parse_time(value):
    if not value:
        return None

    return datetime.fromisoformat(
        value.replace(
            "Z",
            "+00:00"
        )
    )


def make_event_uid(entry):
    question = (
        entry.get("question")
        or {}
    )

    raw = "|".join([
        entry.get("time", ""),
        entry.get("client", ""),
        question.get("name", ""),
        question.get("type", ""),
    ])

    return hashlib.sha256(
        raw.encode()
    ).hexdigest()


def convert_event(entry):
    question = (
        entry.get("question")
        or {}
    )

    client_info = (
        entry.get("client_info")
        or {}
    )

    reason = entry.get(
        "reason",
        ""
    )

    blocked = (
        reason != "NotFilteredNotFound"
    )

    return {
        "event_uid": make_event_uid(
            entry
        ),
        "timestamp": entry.get(
            "time"
        ),
        "client_ip": entry.get(
            "client"
        ),
        "client_name": (
            client_info.get("name")
            or None
        ),
        "mac_address": None,
        "domain": question.get(
            "name"
        ),
        "query_type": question.get(
            "type"
        ),
        "blocked": blocked,
        "block_reason": (
            reason
            if blocked
            else None
        ),
    }


# =========================================================
# HARVEST ADGUARD
# =========================================================

def harvest_adguard(
    config,
    db
):
    last_harvested = get_state(
        db,
        "last_harvested_at"
    )

    last_harvested_dt = (
        parse_time(
            last_harvested
        )
        if last_harvested
        else None
    )

    older_than = None
    newest_seen = None

    pages = 0
    added = 0
    reached_cursor = False

    while pages < MAX_PAGES_PER_RUN:

        result = adguard_query_log(
            config,
            older_than
        )

        data = result.get(
            "data",
            []
        )

        if not data:
            break

        pages += 1

        for entry in data:

            event = convert_event(
                entry
            )

            if not (
                event["timestamp"]
                and event["client_ip"]
                and event["domain"]
            ):
                continue

            event_dt = parse_time(
                event["timestamp"]
            )

            if (
                newest_seen is None
                or event_dt > parse_time(
                    newest_seen
                )
            ):
                newest_seen = (
                    event["timestamp"]
                )

            if (
                last_harvested_dt
                and
                event_dt
                <= last_harvested_dt
            ):
                reached_cursor = True
                continue

            before = (
                db.total_changes
            )

            queue_event(
                db,
                event
            )

            if (
                db.total_changes
                > before
            ):
                added += 1

        db.commit()

        if reached_cursor:
            break

        next_oldest = result.get(
            "oldest"
        )

        if not next_oldest:
            break

        if (
            next_oldest
            == older_than
        ):
            break

        older_than = next_oldest

    if newest_seen:

        if (
            not last_harvested_dt
            or
            parse_time(
                newest_seen
            )
            > last_harvested_dt
        ):

            set_state(
                db,
                "last_harvested_at",
                newest_seen
            )

    print(
        f"Harvested {added} new DNS events "
        f"from {pages} AdGuard page(s)"
    )


# =========================================================
# DNS CLOUD UPLOAD
# =========================================================

def get_upload_batch(db):
    rows = db.execute("""
        SELECT
            event_uid,
            payload
        FROM queue
        ORDER BY event_timestamp ASC
        LIMIT ?
    """, (
        UPLOAD_BATCH_SIZE,
    )).fetchall()

    events = []
    ids = []

    for event_uid, payload in rows:

        ids.append(
            event_uid
        )

        events.append(
            json.loads(
                payload
            )
        )

    return ids, events


def send_batch(
    config,
    events
):
    url = (
        config["MVT_API_BASE"].rstrip("/")
        + "/api/public/dns-events"
    )

    payload = json.dumps({
        "events": events
    })

    result = subprocess.run(
        [
            "curl",
            "-sS",
            "--fail-with-body",

            "-X",
            "POST",

            url,

            "-H",
            "Content-Type: application/json",

            "-H",
            f'X-MVT-API-Key: '
            f'{config["MVT_API_KEY"]}',

            "--data-binary",
            payload,
        ],

        capture_output=True,
        text=True,
        timeout=60,
    )

    if result.returncode != 0:

        print(
            "DNS upload failed"
        )

        print(
            result.stdout
            or result.stderr
        )

        return False

    try:

        response = json.loads(
            result.stdout
        )

    except Exception:

        print(
            "Invalid MVT DNS response:",
            result.stdout
        )

        return False

    if not response.get(
        "success"
    ):

        print(
            "MVT API rejected DNS batch:",
            response
        )

        return False

    if response.get(
        "rejected",
        0
    ):

        print(
            "DNS batch contained "
            "rejected events:",
            response
        )

        return False

    print(
        "Uploaded:",
        f'received='
        f'{response.get("received", 0)}',

        f'inserted='
        f'{response.get("inserted", 0)}',

        f'duplicates='
        f'{response.get("duplicates", 0)}'
    )

    return True


def delete_uploaded(
    db,
    ids
):
    if not ids:
        return

    placeholders = ",".join(
        "?"
        for _ in ids
    )

    db.execute(
        f"""
        DELETE FROM queue
        WHERE event_uid
        IN ({placeholders})
        """,
        ids
    )

    db.commit()


def drain_queue(
    config,
    db
):
    while True:

        ids, events = (
            get_upload_batch(
                db
            )
        )

        if not events:
            break

        if not send_batch(
            config,
            events
        ):

            print(
                "Stopping upload; "
                "events remain safely "
                "queued locally."
            )

            break

        delete_uploaded(
            db,
            ids
        )

    print(
        f"Local queue remaining: "
        f"{queue_count(db)}"
    )


# =========================================================
# CENTRAL FILTER CONFIG
# =========================================================

def get_mvt_config(config):
    url = (
        config["MVT_API_BASE"].rstrip("/")
        + "/api/public/config"
    )

    result = subprocess.run(
        [
            "curl",
            "-sS",
            "--fail-with-body",

            url,

            "-H",
            f'X-MVT-API-Key: '
            f'{config["MVT_API_KEY"]}',
        ],

        capture_output=True,
        text=True,
        timeout=30,
    )

    if result.returncode != 0:

        print(
            "Config fetch failed"
        )

        print(
            result.stdout
            or result.stderr
        )

        return None

    try:

        response = json.loads(
            result.stdout
        )

    except Exception:

        print(
            "Invalid config response:",
            result.stdout
        )

        return None

    if not response.get(
        "success"
    ):

        print(
            "Config API rejected request:",
            response
        )

        return None

    return response


# =========================================================
# APPLY DOMAIN RULES
# =========================================================

def apply_adguard_user_rules(
    config,
    blocked_domains,
    allowed_domains
):
    rules = []

    for domain in sorted(
        set(blocked_domains)
    ):

        domain = (
            domain
            .strip()
            .lower()
        )

        if domain:

            rules.append(
                f"||{domain}^"
            )

    for domain in sorted(
        set(allowed_domains)
    ):

        domain = (
            domain
            .strip()
            .lower()
        )

        if domain:

            rules.append(
                f"@@||{domain}^"
            )

    payload = json.dumps({
        "rules": rules
    })

    url = (
        config["ADGUARD_URL"].rstrip("/")
        + "/control/filtering/set_rules"
    )

    result = subprocess.run(
        [
            "curl",
            "-sS",
            "--fail-with-body",

            "-u",
            f'{config["ADGUARD_USERNAME"]}:'
            f'{config["ADGUARD_PASSWORD"]}',

            "-X",
            "POST",

            url,

            "-H",
            "Content-Type: application/json",

            "--data-binary",
            payload,
        ],

        capture_output=True,
        text=True,
        timeout=30,
    )

    if result.returncode != 0:

        print(
            "Failed to apply "
            "AdGuard domain rules"
        )

        print(
            result.stdout
            or result.stderr
        )

        return False

    print(
        f"Applied "
        f"{len(blocked_domains)} "
        f"blocked domain(s) and "
        f"{len(allowed_domains)} "
        f"allowed domain(s)"
    )

    return True


# =========================================================
# APPLY BLOCKED SERVICES
# =========================================================

def apply_adguard_blocked_services(
    config,
    blocked_services
):
    payload = json.dumps({
        "schedule": {
            "time_zone": "Local"
        },

        "ids": sorted(
            set(blocked_services)
        ),
    })

    url = (
        config["ADGUARD_URL"].rstrip("/")
        + "/control/blocked_services/update"
    )

    result = subprocess.run(
        [
            "curl",
            "-sS",
            "--fail-with-body",

            "-u",
            f'{config["ADGUARD_USERNAME"]}:'
            f'{config["ADGUARD_PASSWORD"]}',

            "-X",
            "PUT",

            url,

            "-H",
            "Content-Type: application/json",

            "--data-binary",
            payload,
        ],

        capture_output=True,
        text=True,
        timeout=30,
    )

    if result.returncode != 0:

        print(
            "Failed to apply "
            "AdGuard blocked services"
        )

        print(
            result.stdout
            or result.stderr
        )

        return False

    print(
        f"Applied "
        f"{len(blocked_services)} "
        f"blocked service(s)"
    )

    return True


# =========================================================
# FILTER CONFIG SYNC
# =========================================================

def sync_filtering_config(
    config,
    db
):
    remote = get_mvt_config(
        config
    )

    if remote is None:

        set_state(
            db,
            "config_sync_status",
            "failed"
        )

        return False

    remote_version = int(
        remote.get(
            "config_version",
            0
        )
    )

    local_version = int(
        get_state(
            db,
            "applied_config_version"
        )
        or 0
    )

    if (
        remote_version
        == local_version
    ):

        print(
            "Filtering config "
            f"already current "
            f"(version "
            f"{remote_version})"
        )

        set_state(
            db,
            "config_sync_status",
            "synced"
        )

        # Upgrade path from agent 0.2.0.
        # Earlier versions stored the applied
        # version but not last_config_sync.

        if not get_state(
            db,
            "last_config_sync"
        ):

            set_state(
                db,
                "last_config_sync",
                datetime.now(
                    timezone.utc
                ).isoformat()
            )

        return True

    print(
        "Filtering config "
        f"change detected: "
        f"{local_version} -> "
        f"{remote_version}"
    )

    blocked_services = (
        remote.get(
            "blocked_services"
        )
        or []
    )

    blocked_domains = (
        remote.get(
            "blocked_domains"
        )
        or []
    )

    allowed_domains = (
        remote.get(
            "allowed_domains"
        )
        or []
    )

    services_ok = (
        apply_adguard_blocked_services(
            config,
            blocked_services
        )
    )

    if not services_ok:

        set_state(
            db,
            "config_sync_status",
            "failed"
        )

        print(
            "Filtering sync stopped. "
            "Config version "
            "not advanced."
        )

        return False

    rules_ok = (
        apply_adguard_user_rules(
            config,
            blocked_domains,
            allowed_domains
        )
    )

    if not rules_ok:

        set_state(
            db,
            "config_sync_status",
            "failed"
        )

        print(
            "Filtering sync stopped. "
            "Config version "
            "not advanced."
        )

        return False

    now = datetime.now(
        timezone.utc
    ).isoformat()

    set_state(
        db,
        "applied_config_version",
        remote_version
    )

    set_state(
        db,
        "last_config_sync",
        now
    )

    set_state(
        db,
        "config_sync_status",
        "synced"
    )

    print(
        "Filtering config version "
        f"{remote_version} "
        "applied successfully"
    )

    return True


# =========================================================
# HEARTBEAT
# =========================================================

def get_local_ip():
    try:

        result = subprocess.run(
            [
                "hostname",
                "-I"
            ],

            capture_output=True,
            text=True,
            timeout=5,
        )

        addresses = (
            result.stdout
            .strip()
            .split()
        )

        if addresses:
            return addresses[0]

    except Exception:
        pass

    return None


def send_heartbeat(
    config,
    db
):
    status = get_adguard_status(
        config
    )

    applied_version = get_state(
        db,
        "applied_config_version"
    )

    heartbeat = {
        "agent_version":
            AGENT_VERSION,

        "adguard_version":
            status.get(
                "version"
            ),

        "adguard_status":
            (
                "healthy"
                if status.get(
                    "healthy"
                )
                else "unhealthy"
            ),

        "protection_enabled":
            status.get(
                "protection_enabled"
            ),

        "hostname":
            socket.gethostname(),

        "local_ip":
            get_local_ip(),

        "last_event_timestamp":
            get_state(
                db,
                "last_harvested_at"
            ),

        "applied_config_version":
            (
                int(
                    applied_version
                )
                if applied_version
                is not None
                else None
            ),

        "last_config_sync":
            get_state(
                db,
                "last_config_sync"
            ),

        "config_sync_status":
            (
                get_state(
                    db,
                    "config_sync_status"
                )
                or "unknown"
            ),
    }

    url = (
        config["MVT_API_BASE"].rstrip("/")
        + "/api/public/heartbeat"
    )

    result = subprocess.run(
        [
            "curl",
            "-sS",
            "--fail-with-body",

            "-X",
            "POST",

            url,

            "-H",
            "Content-Type: application/json",

            "-H",
            f'X-MVT-API-Key: '
            f'{config["MVT_API_KEY"]}',

            "--data-binary",
            json.dumps(
                heartbeat
            ),
        ],

        capture_output=True,
        text=True,
        timeout=30,
    )

    if result.returncode != 0:

        print(
            "Heartbeat failed"
        )

        print(
            result.stdout
            or result.stderr
        )

        return False

    try:

        response = json.loads(
            result.stdout
        )

    except Exception:

        print(
            "Invalid heartbeat response:",
            result.stdout
        )

        return False

    if response.get(
        "success"
    ):

        protection = (
            "Enabled"
            if status.get(
                "protection_enabled"
            )
            is True

            else "Disabled"
            if status.get(
                "protection_enabled"
            )
            is False

            else "Unknown"
        )

        print(
            f"Heartbeat OK - "
            f"AdGuard "
            f"{status.get('version') or 'unknown'} "
            f"- Protection {protection}"
        )

        return True

    print(
        "Heartbeat rejected:",
        response
    )

    return False


# =========================================================
# MAIN
# =========================================================

def main():
    config = load_config()
    db = open_database()

    try:

        print(
            "MVT DNS Agent"
        )

        print(
            "------------------------------"
        )

        print(
            f"Agent Version: "
            f"{AGENT_VERSION}"
        )

        print(
            f"Queue before harvest: "
            f"{queue_count(db)}"
        )

        harvest_adguard(
            config,
            db
        )

        print(
            f"Queue after harvest: "
            f"{queue_count(db)}"
        )

        drain_queue(
            config,
            db
        )

        sync_filtering_config(
            config,
            db
        )

        send_heartbeat(
            config,
            db
        )

    finally:

        db.close()


if __name__ == "__main__":

    try:

        main()

    except Exception as error:

        print(
            f"ERROR: {error}"
        )
