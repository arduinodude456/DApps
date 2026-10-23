#!/usr/bin/env python3
"""Live acceptance test. Creates ONLY tagged test users; removes them and their media.

Needs the authenticated Supabase MCP CLI, Python requests and Pillow. No real email
is sent. Passwords/tokens remain in process memory and are never printed or saved
in the repository. Never run against an unintended project.
"""
import json
import secrets
import sys
import uuid
from io import BytesIO
from pathlib import Path

import requests
from PIL import Image

PROJECT = "qndwbriqomqqaqhkasbh"
BASE = f"https://{PROJECT}.supabase.co"
KEY = "sb_publishable_UAIcZameyUZHtEB-NY1ffQ_TfF67BjS"
RUN = "inkblog-test-" + secrets.token_hex(8)
USERS = [str(uuid.uuid4()), str(uuid.uuid4())]
EMAILS = [f"{RUN}-{index}@example.invalid" for index in (1, 2)]
PASSWORD = secrets.token_urlsafe(24)
TOKENS = {}
MEDIA = []
CHECKS = []
FIXTURE_PATH = Path("/tmp/inkblog-live-fixture.json")


def call(method, path, user=None, data=None, expected=(200, 201, 204), raw=None):
    headers = {"apikey": KEY, "Prefer": "return=representation"}
    if user is not None:
        headers["Authorization"] = "Bearer " + TOKENS[user]
    if raw is not None:
        headers["content-type"] = "image/png"
    response = requests.request(method, BASE + path, headers=headers, json=data, data=raw, timeout=40)
    if response.status_code not in expected:
        # No tokens or passwords are included in diagnostics.
        raise AssertionError(f"{method} {path.split('?')[0]}: HTTP {response.status_code}: {response.text[:400]}")
    if response.headers.get("content-type", "").startswith("image/"):
        return response.content
    return response.json() if response.content else None


def check(name, condition=True):
    assert condition, name
    CHECKS.append(name)
    print("PASS " + name, flush=True)


def fixture():
    rows = []
    for user, email in zip(USERS, EMAILS):
        rows.append(f"('{user}', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', '{email}', extensions.crypt('{PASSWORD}', extensions.gen_salt('bf')), now(), '{{\"provider\":\"email\",\"providers\":[\"email\"]}}'::jsonb, '{{\"inkblog_test_run\":\"{RUN}\"}}'::jsonb, '', '', '', '', now(), now())")
    query = "WITH new_users AS (INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, confirmation_token, recovery_token, email_change, email_change_token_new, created_at, updated_at) VALUES " + ",".join(rows) + " RETURNING id, email), new_identities AS (INSERT INTO auth.identities (user_id, provider_id, identity_data, provider, created_at, updated_at) SELECT id, id::text, jsonb_build_object('sub',id::text,'email',email,'email_verified',true), 'email', now(), now() FROM new_users RETURNING id) SELECT count(*) AS users_created FROM new_users LIMIT 1;"
    cleanup = f"WITH deleted AS (DELETE FROM auth.users WHERE id IN ('{USERS[0]}','{USERS[1]}') AND raw_user_meta_data->>'inkblog_test_run' = '{RUN}' RETURNING id) SELECT count(*) AS users_removed FROM deleted LIMIT 1;"
    for name, value in [("/tmp/inkblog-live-provision.json", {"project_id": PROJECT, "query": query}), ("/tmp/inkblog-live-cleanup.json", {"project_id": PROJECT, "query": cleanup}), (str(FIXTURE_PATH), {"users": USERS, "emails": EMAILS, "password": PASSWORD, "run": RUN})]:
        path = Path(name)
        path.touch(mode=0o600)
        path.write_text(json.dumps(value))
        path.chmod(0o600)
    print("Fixture-/Provisionierungs-/Bereinigungspayloads unter /tmp/inkblog-live-*.json vorbereitet. MCP separat aufrufen.")


def png():
    stream = BytesIO()
    Image.new("RGB", (160, 120), (220, 40, 30)).save(stream, "PNG")
    return stream.getvalue()


def media_upload(kind, post=None, dither=False):
    import base64
    result = call("POST", "/functions/v1/inkblog-media", 0, {"kind": kind, "post_id": post, "alt_text": "Ein monochromer Testdruck", "mime": "image/png", "image_base64": base64.b64encode(png()).decode(), "dither": dither})
    bucket = "inkblog-avatars" if kind == "avatar" else "inkblog-images"
    MEDIA.append((bucket, result["path"]))
    return result, "/functions/v1/inkblog-media?" + requests.compat.urlencode({"bucket": bucket, "path": result["path"]})


def run():
    global USERS, EMAILS, PASSWORD, RUN
    config = json.loads(FIXTURE_PATH.read_text())
    USERS, EMAILS, PASSWORD, RUN = config["users"], config["emails"], config["password"], config["run"]
    try:
        for index, email in enumerate(EMAILS):
            session = call("POST", "/auth/v1/token?grant_type=password", data={"email": email, "password": PASSWORD})
            TOKENS[index] = session["access_token"]
            call("POST", "/rest/v1/inkblog_profiles?on_conflict=id", index, {"id": USERS[index], "display_name": f"InkBlog Test {index + 1}", "bio": "Nur ein kurzlebiger Abnahmetest."}, expected=(200, 201), )
        check("Zwei Supabase-Auth-Sitzungen und Profile")
        avatar, avatar_url = media_upload("avatar")
        assert avatar["width"] == 128 and avatar["height"] == 128
        image = Image.open(BytesIO(call("GET", avatar_url)))
        check("Avatar anonym lesbar, serverseitig rund und grau", image.mode in ("L", "1") and image.getpixel((0, 0)) == 255)
        post = call("POST", "/rest/v1/inkblog_posts", 0, {"author_id": USERS[0], "title": "Testdruck", "markdown": "# Test\n\n**Tinte**", "status": "draft"})[0]
        pid = post["id"]
        params = {"p_mode": "discover", "p_limit": 6, "p_offset": 0}
        check("Entwurf nur für den Autor", not call("GET", f"/rest/v1/inkblog_posts?select=id&id=eq.{pid}&limit=1", 1) and not call("GET", f"/rest/v1/inkblog_posts?select=id&id=eq.{pid}&limit=1"))
        picture, picture_url = media_upload("post", pid, True)
        call("GET", picture_url, 1, expected=(404,))
        call("GET", picture_url, expected=(404,))
        check("Private Entwurfsbilder für Fremde und anonyme Leser gesperrt")
        call("POST", f"/storage/v1/object/inkblog-images/{USERS[0]}/{pid}/{uuid.uuid4()}.png", 0, raw=png(), expected=(400, 401, 403))
        check("Direkter unverarbeiteter Storage-Upload verweigert")
        call("PATCH", f"/rest/v1/inkblog_posts?id=eq.{pid}", 0, {"status": "published", "markdown": f"# Test\n\n![Druck](inkblog:{picture['path']})"})
        published_image = Image.open(BytesIO(call("GET", picture_url)))
        check("Veröffentlichter Eintrag mit echtem 1-Bit-Bild", published_image.mode == "1")
        foreign = call("PATCH", f"/rest/v1/inkblog_posts?id=eq.{pid}", 1, {"title": "Fremde Änderung"}, expected=(200, 204, 403))
        original = call("GET", f"/rest/v1/inkblog_posts?select=id,title&id=eq.{pid}&limit=1", 0)[0]
        check("RLS verhindert fremdes Bearbeiten", original["title"] == "Testdruck" and not foreign)
        call("DELETE", f"/rest/v1/inkblog_posts?id=eq.{pid}", 1, expected=(200, 204, 403))
        check("RLS verhindert fremdes Löschen", bool(call("GET", f"/rest/v1/inkblog_posts?select=id&id=eq.{pid}&limit=1", 0)))
        call("DELETE", picture_url, 1, expected=(403,))
        check("Fremde Bildlöschung verweigert")
        call("POST", "/rest/v1/inkblog_follows", 1, {"follower_id": USERS[1], "following_id": USERS[0]})
        feed = call("POST", "/rest/v1/rpc/inkblog_list_posts", 1, {**params, "p_mode": "feed"})
        check("Abonnieren und Feed", any(row["id"] == pid for row in feed))
        call("POST", "/rest/v1/inkblog_likes", 1, {"user_id": USERS[1], "target_type": "post", "target_id": pid})
        comment = call("POST", "/rest/v1/inkblog_comments", 1, {"post_id": pid, "author_id": USERS[1], "body": "Eine Randnotiz."})[0]
        cid = comment["id"]
        reply = call("POST", "/rest/v1/inkblog_comments", 0, {"post_id": pid, "author_id": USERS[0], "parent_id": cid, "body": "Eine Antwort."})[0]
        call("POST", "/rest/v1/inkblog_comments", 1, {"post_id": pid, "author_id": USERS[1], "parent_id": reply["id"], "body": "Verbotene zweite Ebene."}, expected=(400, 403, 409))
        call("POST", "/rest/v1/inkblog_likes", 0, {"user_id": USERS[0], "target_type": "comment", "target_id": cid})
        comments = call("POST", "/rest/v1/rpc/inkblog_list_comments", 0, {"p_post": pid, "p_limit": 6, "p_offset": 0})
        check("Eintrags-/Kommentar-Kleckse und genau eine Antwortebene", any(row["id"] == cid and row["like_count"] == 1 for row in comments))
        notes = call("GET", f"/rest/v1/inkblog_notifications?select=id,kind,recipient_id&recipient_id=eq.{USERS[0]}&limit=20", 0)
        check("Benachrichtigungen für Follow, Like und Kommentar", len(notes) >= 3)
        check("Fremde Benachrichtigungen nicht sichtbar", not call("GET", f"/rest/v1/inkblog_notifications?select=id&recipient_id=eq.{USERS[0]}&limit=20", 1))
        call("POST", "/rest/v1/inkblog_reports", 1, {"reporter_id": USERS[1], "target_type": "post", "target_id": pid, "reason": "Testmeldung, kein echter Verstoß."})
        call("POST", "/rest/v1/inkblog_reports", 0, {"reporter_id": USERS[0], "target_type": "comment", "target_id": cid, "reason": "Testmeldung."})
        check("Einträge und Kommentare melden")
        call("POST", "/rest/v1/inkblog_blocks", 0, {"blocker_id": USERS[0], "blocked_id": USERS[1]})
        check("Blockieren sperrt Feed und Inhalte", not call("GET", f"/rest/v1/inkblog_posts?select=id&id=eq.{pid}&limit=1", 1))
        call("GET", picture_url, 1, expected=(404,))
        call("POST", "/rest/v1/inkblog_comments", 1, {"post_id": pid, "author_id": USERS[1], "body": "Gesperrt."}, expected=(400, 403, 409))
        check("Blockieren sperrt Bilder und Interaktionen")
        call("DELETE", f"/rest/v1/inkblog_blocks?blocker_id=eq.{USERS[0]}&blocked_id=eq.{USERS[1]}", 0)
        check("Entblockieren hebt Inhaltssperre auf", bool(call("GET", f"/rest/v1/inkblog_posts?select=id&id=eq.{pid}&limit=1", 1)))
        call("DELETE", f"/rest/v1/inkblog_comments?id=eq.{cid}", 0)
        check("Blogbesitzer darf fremde Randnotiz am eigenen Eintrag löschen", not call("GET", f"/rest/v1/inkblog_comments?select=id&id=eq.{cid}&limit=1", 1))
        call("PATCH", f"/rest/v1/inkblog_posts?id=eq.{pid}", 0, {"status": "draft"})
        call("GET", picture_url, expected=(404,))
        check("Rücknahme eines Eintrags schützt zuvor öffentliche Bilder")
    finally:
        for bucket, path in reversed(MEDIA):
            if 0 in TOKENS:
                url = "/functions/v1/inkblog-media?" + requests.compat.urlencode({"bucket": bucket, "path": path})
                call("DELETE", url, 0, expected=(200, 204, 404))
        print("CLEANUP Eigene Bilddateien entfernt; jetzt den separaten MCP-Bereinigungspayload ausführen.", flush=True)
    print(f"OK {len(CHECKS)} Live-Prüfungen", flush=True)


if __name__ == "__main__":
    fixture() if "--prepare" in sys.argv else run()
