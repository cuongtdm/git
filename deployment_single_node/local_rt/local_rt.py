#!/usr/bin/env python3
"""Small, dependency-free RT replacement for the one-node CRBT pilot."""

import html
import os
import random
import re
import subprocess
import time
from threading import RLock
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from socketserver import ThreadingMixIn
from urllib.parse import parse_qs, urlparse


HOST = os.environ.get("LOCAL_RT_BIND", "127.0.0.1")
PORT = int(os.environ.get("LOCAL_RT_PORT", "8081"))
MEDIA_DIR = Path(os.environ.get("LOCAL_RT_MEDIA_DIR", "/opt/vrbt/bin/mediaserver_pcm/media/local")).resolve()
FALLBACK_SONG = os.environ.get("LOCAL_RT_FALLBACK_SONG", "song-1.wav").strip()
DB_HOST = os.environ.get("LOCAL_RT_DB_HOST", "127.0.0.1")
DB_PORT = os.environ.get("LOCAL_RT_DB_PORT", "3306")
DB_NAME = os.environ.get("LOCAL_RT_DB_NAME", "")
DB_USER = os.environ.get("LOCAL_RT_DB_USER", "")
DB_PASSWORD = os.environ.get("LOCAL_RT_DB_PASSWORD", "")
MSISDN_PREFIX = os.environ.get("LOCAL_RT_MSISDN_PREFIX", "509")
CALLED_ROUTING_PREFIX = os.environ.get("LOCAL_RT_CALLED_ROUTING_PREFIX", "1221")
PROFILE_CACHE_SECONDS = max(0, int(os.environ.get("LOCAL_RT_PROFILE_CACHE_SECONDS", "900")))
PROFILE_CACHE_MAX_ENTRIES = max(1, int(os.environ.get("LOCAL_RT_PROFILE_CACHE_MAX_ENTRIES", "1000")))
PROFILE_CACHE = {}
PROFILE_CACHE_LOCK = RLock()


def vxml(song: str, item_id: str) -> bytes:
    # These element names and attributes match mediactrl_rt SELECT_AUDIO/SELECT_ITEMID.
    # mediactrl prepends RT_FILE_DIR to this URL path before swapfile copies it.
    audio_url = f"http://{HOST}:{PORT}/media/local/{song}"
    body = f'''<?xml version="1.0" encoding="UTF-8"?>
<vxml version="2.1">
  <var name="ITEMID" expr="'{html.escape(item_id, quote=True)}'" />
  <form id="playMultiTime"><field name="fieldvar"><prompt playfromoffsetexpr="offset">
    <audio src="{html.escape(audio_url, quote=True)}" />
  </prompt></field></form>
</vxml>'''
    return body.encode("utf-8")


def normalise_msisdn(called: str) -> str:
    digits = "".join(char for char in called if char.isdigit())
    if not digits:
        return ""
    # NATCOM sends the called party as 1221 + subscriber in the SIP R-URI.
    if CALLED_ROUTING_PREFIX and digits.startswith(CALLED_ROUTING_PREFIX):
        digits = digits[len(CALLED_ROUTING_PREFIX):]
    return digits if digits.startswith(MSISDN_PREFIX) else MSISDN_PREFIX + digits


def cached_profile(msisdn: str):
    """Return a non-expired subscriber profile without touching MariaDB."""
    now = time.monotonic()
    with PROFILE_CACHE_LOCK:
        cached = PROFILE_CACHE.get(msisdn)
        if cached and cached[0] > now:
            return True, cached[1]
        if cached:
            del PROFILE_CACHE[msisdn]
    return False, None


def cache_profile(msisdn: str, profile) -> None:
    """Bound cache growth while retaining inactive subscribers as negative cache entries."""
    if not PROFILE_CACHE_SECONDS:
        return
    now = time.monotonic()
    with PROFILE_CACHE_LOCK:
        if len(PROFILE_CACHE) >= PROFILE_CACHE_MAX_ENTRIES:
            expired = [key for key, value in PROFILE_CACHE.items() if value[0] <= now]
            for key in expired:
                del PROFILE_CACHE[key]
        # Drop an arbitrary oldest-inserted entry only when the active cache is full.
        if len(PROFILE_CACHE) >= PROFILE_CACHE_MAX_ENTRIES:
            del PROFILE_CACHE[next(iter(PROFILE_CACHE))]
        PROFILE_CACHE[msisdn] = (now + PROFILE_CACHE_SECONDS, profile)


def subscriber_songs(msisdn: str):
    """Return ordered active album-item buckets, or None on a database failure."""
    hit, profile = cached_profile(msisdn)
    if hit:
        return profile

    # Album-item status is the only eligibility gate. Cache buckets rather than
    # the final choice, so random playback
    # remains random for every call while avoiding repeated database queries.
    query = (
        "SELECT s.code, COALESCE(ai.is_priority, 0), COALESCE(ai.is_signature, 0) "
        "FROM album_item ai "
        "JOIN song s ON s.id = ai.song_id "
        "WHERE ai.msisdn = '%s' AND ai.status = 'ACTIVE' "
        "ORDER BY COALESCE(ai.is_priority, 0) DESC, "
        "COALESCE(ai.is_signature, 0) DESC, s.code" % msisdn
    )
    environment = os.environ.copy()
    environment["MYSQL_PWD"] = DB_PASSWORD
    command = [
        "mysql", "--batch", "--skip-column-names", "--raw",
        "--connect-timeout=2", "-h", DB_HOST, "-P", DB_PORT,
        "-u", DB_USER, DB_NAME, "-e", query,
    ]
    try:
        result = subprocess.run(
            command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=environment, timeout=3, universal_newlines=True, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        print("DB song lookup unavailable for %s: %s" % (msisdn, error), flush=True)
        return None
    if result.returncode:
        print("DB song lookup failed for %s: %s" % (msisdn, result.stderr.strip()), flush=True)
        return None

    priority_songs = []
    signature_songs = []
    random_songs = []
    for row in result.stdout.splitlines():
        values = row.split("\t")
        code = values[0].strip() if values else ""
        if not re.match(r"^[A-Za-z0-9_-]+$", code):
            continue
        song = code + ".wav"
        if (MEDIA_DIR / song).is_file():
            if len(values) > 1 and values[1].strip() == "1":
                priority_songs.append(song)
            elif len(values) > 2 and values[2].strip() == "1":
                signature_songs.append(song)
            else:
                random_songs.append(song)

    # No active album item is a valid profile and falls back to song-1.wav.
    profile = (priority_songs, signature_songs, random_songs)
    cache_profile(msisdn, profile)
    return profile


def active_song_codes(called: str):
    """Return active album-item songs for the normalized called subscriber."""
    msisdn = normalise_msisdn(called)
    if not (DB_NAME and DB_USER and msisdn):
        return None
    return subscriber_songs(msisdn)


def select_song(called: str):
    profile = active_song_codes(called)
    if profile is not None:
        priority_songs, signature_songs, random_songs = profile
    else:
        # DB errors and missing DB configuration deliberately use the fallback.
        priority_songs, signature_songs, random_songs = [], [], []
    if priority_songs:
        # Data should contain one priority song. SQL ordering gives a stable
        # result if provisioning accidentally marks more than one.
        song = priority_songs[0]
    elif signature_songs:
        # Signature songs are the second deterministic choice after priority.
        song = signature_songs[0]
    elif random_songs:
        song = random.choice(random_songs)
    else:
        song = None
    if song:
        # ITEMID is consumed by mediactrl_rt. Keep it equal to the content code
        # regardless of selection mode so priority and random paths are identical.
        return song, song[:-4]
    if not FALLBACK_SONG or not (MEDIA_DIR / FALLBACK_SONG).is_file():
        return None, None
    return FALLBACK_SONG, FALLBACK_SONG[:-4]


class Handler(BaseHTTPRequestHandler):
    server_version = "crbt-local-rt/1.0"
    protocol_version = "HTTP/1.1"

    def handle_expect_100(self):
        # The legacy Java RT client sends Expect: 100-continue even for GET.
        self.send_response_only(100)
        self.end_headers()
        return True

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def do_GET(self):
        self.respond()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
        self.respond(body)

    def respond(self, body=""):
        parsed = urlparse(self.path)
        if parsed.path == "/healthz":
            return self.send_bytes(200, b"ok\n", "text/plain")
        if parsed.path == "/rt/playtrack":
            params = parse_qs(parsed.query)
            if body:
                params.update(parse_qs(body))
            called = params.get("called", [""])[0]
            song, item_id = select_song(called)
            if not song:
                return self.send_bytes(503, b"No configured local fallback song is available.\n", "text/plain")
            print("Selected %s for called=%s" % (song, normalise_msisdn(called) or "unknown"), flush=True)
            return self.send_bytes(200, vxml(song, item_id), "application/xml; charset=utf-8")
        if parsed.path.startswith("/media/"):
            song = Path(parsed.path[len("/media/"):]).name
            if not song.endswith(".wav"):
                return self.send_error(404)
            path = (MEDIA_DIR / song).resolve()
            if path.parent != MEDIA_DIR or not path.is_file():
                return self.send_error(404)
            return self.send_bytes(200, path.read_bytes(), "audio/wav")
        return self.send_error(404)

    def send_bytes(self, status, body, content_type):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


if __name__ == "__main__":
    print(f"Serving local RT on {HOST}:{PORT}; media directory: {MEDIA_DIR}", flush=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
