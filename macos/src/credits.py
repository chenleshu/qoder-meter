#!/usr/bin/python3
"""Qoder 每日 100 Credits 领取助手（macOS，仅标准库）。

只读取本机 Qoder 桌面端的设备身份（runtime-info），登录走 Qoder 官方设备授权流程。
用法：credits.py status|login|claim|logout
输出一行 JSON，令牌不会写进日志或输出。
"""

import base64
import hashlib
import json
import os
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone

VERSION = "1.0.0"
HOME = os.path.expanduser("~")
CONFIG_DIR = os.path.join(HOME, "Library", "Application Support", "QoderMeter")
CRED_PATH = os.path.join(CONFIG_DIR, "qoder-credits.json")
STATE_PATH = os.path.join(CONFIG_DIR, "qoder-credits-state.json")
LOGIN_PATH = os.path.join(CONFIG_DIR, "qoder-login.json")
LOCK_PATH = os.path.join(CONFIG_DIR, "qoder-credits.lock")
LOG_PATH = os.path.join(CONFIG_DIR, "qoder-credits.log")

WEB = "https://qoder.com"
OPENAPI = "https://openapi.qoder.sh"
CLIENT_ID = "e883ade2-e6e3-4d6d-adf7-f92ceff5fdcb"
CAMPAIGNS_PATH = "/sash/api/v1/me/campaigns"
RUNTIME_INFO = "/Applications/Qoder.app/Contents/Resources/umid/runtime-info"
UMID_CACHE = os.path.join(HOME, ".qoder", "umid-cache.json")
TZ_CN = timezone(timedelta(hours=8))
LOGIN_TIMEOUT = 15 * 60
HTTP_TIMEOUT = 20


def log(message):
    try:
        os.makedirs(CONFIG_DIR, exist_ok=True)
        if os.path.exists(LOG_PATH) and os.path.getsize(LOG_PATH) > 512 * 1024:
            os.replace(LOG_PATH, LOG_PATH + ".1")
        with open(LOG_PATH, "a", encoding="utf-8") as fh:
            fh.write("%s %s\n" % (datetime.now().astimezone().isoformat(timespec="seconds"), message))
    except Exception:
        pass


def read_json(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def write_json(path, obj):
    os.makedirs(CONFIG_DIR, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, ensure_ascii=False, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def http(method, url, token=None, body=None, headers=None, timeout=HTTP_TIMEOUT):
    hdrs = {"Accept": "application/json", "User-Agent": "Qoder/claim"}
    if headers:
        hdrs.update(headers)
    data = None
    if body is not None:
        data = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
        hdrs["Content-Type"] = "application/json"
    if token:
        hdrs["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            text = res.read().decode("utf-8", "replace")
            try:
                payload = json.loads(text)
            except Exception:
                payload = None
            return res.status, payload, text
    except urllib.error.HTTPError as exc:
        text = exc.read().decode("utf-8", "replace")
        try:
            payload = json.loads(text)
        except Exception:
            payload = None
        return exc.code, payload, text
    except Exception as exc:
        raise RuntimeError("network: %s" % type(exc).__name__)


def b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def parse_time(value):
    if value is None or value == "":
        return 0
    if isinstance(value, (int, float)):
        number = float(value)
        if number <= 0:
            return 0
        return int(number * 1000 if number < 1e12 else number)
    text = str(value).strip()
    if not text:
        return 0
    if text.isdigit():
        return parse_time(int(text))
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return int(parsed.timestamp() * 1000)
    except Exception:
        return 0


def iso_ms(ms):
    if not ms:
        return ""
    return datetime.fromtimestamp(ms / 1000.0, timezone.utc).astimezone().isoformat(timespec="seconds")


def window_start(now_ms=None):
    now = datetime.now(TZ_CN) if now_ms is None else datetime.fromtimestamp(now_ms / 1000.0, TZ_CN)
    start = now.replace(hour=10, minute=0, second=0, microsecond=0)
    if now < start:
        start -= timedelta(days=1)
    return start


def day_key(ms=None):
    return window_start(ms).strftime("%Y-%m-%d")


class Lock(object):
    def __init__(self, path, stale=300):
        self.path = path
        self.stale = stale
        self.token = None

    def __enter__(self):
        try:
            fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.write(fd, str(os.getpid()).encode())
            os.close(fd)
            self.token = True
            return self
        except FileExistsError:
            try:
                age = time.time() - os.path.getmtime(self.path)
            except OSError:
                age = self.stale + 1
            if age > self.stale:
                try:
                    os.remove(self.path)
                except OSError:
                    pass
                return self.__enter__()
            raise RuntimeError("busy")
        except Exception:
            raise

    def __exit__(self, *exc):
        if self.token:
            try:
                os.remove(self.path)
            except OSError:
                pass


def load_cred():
    data = read_json(CRED_PATH)
    if not data.get("deviceToken"):
        return None
    return data


def save_cred(cred):
    cred = dict(cred)
    cred["version"] = VERSION
    cred["savedAt"] = iso_ms(int(time.time() * 1000))
    write_json(CRED_PATH, cred)


def ensure_token(cred):
    raw_expiry = str(cred.get("expiresAt") or "").strip()
    expires = parse_time(raw_expiry)
    if raw_expiry and expires and expires - int(time.time() * 1000) > 10 * 60 * 1000:
        return cred
    refresh = str(cred.get("refreshToken") or "").strip()
    if not refresh:
        raise RuntimeError("sign_in_expired")
    status, payload, text = http("POST", OPENAPI + "/api/v1/deviceToken/refresh",
                                 body={"refresh_token": refresh})
    if status in (401, 403):
        raise RuntimeError("sign_in_expired")
    if status != 200:
        raise RuntimeError("refresh_http_%s" % status)
    payload = payload or {}
    token = str(payload.get("token") or payload.get("device_token") or "").strip()
    new_refresh = str(payload.get("refresh_token") or "").strip()
    if not token or not new_refresh:
        raise RuntimeError("refresh_incomplete")
    cred["deviceToken"] = token
    cred["refreshToken"] = new_refresh
    exp = parse_time(payload.get("expires_at"))
    if not exp and payload.get("expires_in"):
        exp = int(time.time() * 1000) + int(payload["expires_in"]) * 1000
    if exp:
        cred["expiresAt"] = iso_ms(exp)
    save_cred(cred)
    log("device token refreshed")
    return cred


def machine_headers(uid):
    if not uid:
        raise RuntimeError("missing_uid")
    if not os.path.isfile(RUNTIME_INFO):
        raise RuntimeError("runtime_info_missing")
    try:
        proc = subprocess.run([RUNTIME_INFO, "3", "--account-stdin"],
                              input=(json.dumps({"account": uid}) + "\n").encode("utf-8"),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
    except Exception as exc:
        raise RuntimeError("runtime_info_failed:%s" % type(exc).__name__)
    if proc.returncode != 0:
        raise RuntimeError("runtime_info_exit_%s" % proc.returncode)
    first = proc.stdout.decode("utf-8", "replace").strip().splitlines()
    if not first:
        raise RuntimeError("runtime_info_empty")
    try:
        identity = json.loads(first[0])
    except Exception:
        raise RuntimeError("runtime_info_bad_json")
    headers = {}
    for header, field in (("Cosy-MachineToken", "machineToken"), ("Cosy-MachineType", "machineType")):
        value = str(identity.get(field) or "").strip()
        if not value:
            raise RuntimeError("runtime_info_missing_%s" % field)
        headers[header] = value
    return headers


def campaign_headers(token, uid):
    headers = machine_headers(uid)
    headers["Cosy-ClientType"] = "10"
    return headers


def fetch_user(token):
    status, payload, text = http("GET", OPENAPI + "/api/v1/userinfo", token=token)
    if status != 200 or not isinstance(payload, dict):
        return {}
    user = payload.get("user") if isinstance(payload.get("user"), dict) else payload
    uid = str(user.get("id") or user.get("user_id") or user.get("uid") or "").strip()
    return {
        "uid": uid,
        "email": str(user.get("email") or "").strip(),
        "name": str(user.get("name") or user.get("user_name") or "").strip(),
    }


def login_machine_token():
    try:
        cached = read_json(UMID_CACHE)
        info = cached.get("info") if isinstance(cached.get("info"), dict) else {}
        token = str(info.get("machineToken") or "").strip()
        if token:
            return token
    except Exception:
        pass
    try:
        proc = subprocess.run([RUNTIME_INFO, "3"], stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=20)
        if proc.returncode == 0:
            first = proc.stdout.decode("utf-8", "replace").strip().splitlines()
            if first:
                return str(json.loads(first[0]).get("machineToken") or "").strip()
    except Exception:
        pass
    return ""


def pending_login():
    data = read_json(LOGIN_PATH)
    return data if data.get("status") == "pending" else None


def cmd_login():
    with Lock(LOCK_PATH, stale=LOGIN_TIMEOUT + 60):
        verifier = b64url(secrets.token_bytes(64))
        challenge = b64url(hashlib.sha256(verifier.encode("ascii")).digest())
        nonce = str(uuid.uuid4())
        machine_id = str(uuid.uuid4())
        params = {
            "challenge": challenge,
            "challenge_method": "S256",
            "nonce": nonce,
            "machine_id": machine_id,
            "client_id": CLIENT_ID,
        }
        machine_token = login_machine_token()
        if machine_token:
            params["machine_token"] = machine_token
        url = WEB + "/device/selectAccounts?" + urllib.parse.urlencode(params)
        started = int(time.time() * 1000)
        write_json(LOGIN_PATH, {
            "status": "pending",
            "startedAt": iso_ms(started),
            "url": url,
        })
        log("login started")
        try:
            subprocess.run(["/usr/bin/open", url], check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        except Exception:
            pass
        until = time.time() + LOGIN_TIMEOUT
        payload = None
        while time.time() < until:
            try:
                status, body, text = http("GET", OPENAPI + "/api/v1/deviceToken/poll?" +
                                          urllib.parse.urlencode({
                                              "nonce": nonce,
                                              "verifier": verifier,
                                              "challenge_method": "S256",
                                          }))
                if status == 200 and isinstance(body, dict) and str(body.get("token") or "").strip():
                    payload = body
                    break
            except Exception:
                pass
            time.sleep(2)
        if not payload:
            write_json(LOGIN_PATH, {
                "status": "error",
                "finishedAt": iso_ms(int(time.time() * 1000)),
                "message": "登录超时，请重新登录",
            })
            return {"ok": False, "error": "login_timeout"}
        token = str(payload.get("token") or "").strip()
        refresh = str(payload.get("refresh_token") or "").strip()
        user = fetch_user(token)
        if not user.get("uid"):
            user["uid"] = str(payload.get("user_id") or "").strip()
        if not user["uid"]:
            write_json(LOGIN_PATH, {
                "status": "error",
                "finishedAt": iso_ms(int(time.time() * 1000)),
                "message": "登录成功但读取账号信息失败",
            })
            return {"ok": False, "error": "userinfo_failed"}
        expires = parse_time(payload.get("expires_at"))
        if not expires and payload.get("expires_in"):
            expires = int(time.time() * 1000) + int(payload["expires_in"]) * 1000
        cred = {
            "uid": user["uid"],
            "email": user["email"],
            "name": user["name"],
            "deviceToken": token,
            "refreshToken": refresh,
            "expiresAt": iso_ms(expires),
            "machineId": machine_id,
            "loggedInAt": iso_ms(started),
        }
        save_cred(cred)
        state = load_state()
        state["signInExpired"] = False
        save_state(state)
        write_json(LOGIN_PATH, {
            "status": "success",
            "finishedAt": iso_ms(int(time.time() * 1000)),
            "email": user["email"],
            "name": user["name"],
        })
        log("login success user=%s" % (user["email"] or user["uid"]))
        return {"ok": True, "email": user["email"], "name": user["name"]}


def active(campaign, now_ms):
    start = parse_time(campaign.get("startAt")) or 0
    end = parse_time(campaign.get("endAt")) or 0
    return start <= now_ms and (not end or now_ms < end)


def next_open(campaign):
    start = parse_time(campaign.get("startAt"))
    end = parse_time(campaign.get("endAt"))
    if not end:
        return 0
    return max(end, start + 86400000) if start else end


def next_daily_open(now_ms):
    start = window_start(now_ms) + timedelta(days=1)
    return int(start.timestamp() * 1000) + 60000


def load_state():
    return read_json(STATE_PATH)


def save_state(state):
    write_json(STATE_PATH, state)


def result(ok, outcome, message="", credit=None, next_check=None, extra=None):
    state = load_state()
    now = int(time.time() * 1000)
    state.update({
        "version": VERSION,
        "outcome": outcome,
        "ok": bool(ok),
        "message": message,
        "lastAttemptAt": iso_ms(now),
        "nextCheckAt": iso_ms(next_check or 0),
    })
    if credit is not None:
        state["credit"] = credit
    if outcome in ("claimed", "already"):
        state["claimedDay"] = day_key(now)
        state["claimedAt"] = iso_ms(now)
        state["creditDay"] = day_key(now)
        state["signInExpired"] = False
    elif outcome == "sign_in_expired":
        state["signInExpired"] = True
    if extra:
        state.update(extra)
    save_state(state)
    out = {
        "ok": bool(ok),
        "outcome": outcome,
        "message": message,
        "credit": credit,
        "nextCheckAt": iso_ms(next_check or 0),
        "claimedToday": state.get("claimedDay") == day_key(now),
        "email": (load_cred() or {}).get("email", ""),
    }
    return out


def cmd_claim(_auto=False):
    cred = load_cred()
    if not cred:
        return result(False, "not_logged_in", "未登录 Qoder 账号", next_check=0)
    if _auto:
        now = int(time.time() * 1000)
        state = load_state()
        if state.get("claimedDay") == day_key(now):
            return {"ok": True, "outcome": "skipped", "message": "今日已领取",
                    "claimedToday": True}
        next_check = parse_time(state.get("nextCheckAt"))
        if next_check and now < next_check:
            return {"ok": True, "outcome": "skipped", "message": "未到下一次检查时间",
                    "nextCheckAt": iso_ms(next_check), "claimedToday": False}
    try:
        with Lock(LOCK_PATH, stale=180):
            cred = ensure_token(cred)
            now = int(time.time() * 1000)
            headers = campaign_headers(cred.get("deviceToken"), cred.get("uid"))
            url = OPENAPI + CAMPAIGNS_PATH + "?forceRefresh=true"
            status, payload, text = http("GET", url, token=cred["deviceToken"], headers=headers)
            if status in (401, 403):
                cred = ensure_token(dict(cred, expiresAt="1970-01-01T00:00:00+00:00"))
                status, payload, text = http("GET", url, token=cred["deviceToken"], headers=headers)
            if status != 200 or not isinstance(payload, dict):
                return result(False, "failed", "活动列表 HTTP %s" % status,
                              next_check=int(time.time() * 1000) + 15 * 60 * 1000)
            campaigns = []
            for row in (payload.get("campaigns") or []):
                if not isinstance(row, dict) or row.get("actionType") != "CLAIM_BENEFIT":
                    continue
                benefit = row.get("benefit") if isinstance(row.get("benefit"), dict) else {}
                if str(benefit.get("kind") or "").upper() != "CREDITS":
                    continue
                try:
                    amount = int(benefit.get("amount") or 0)
                except (TypeError, ValueError):
                    amount = 0
                if amount == 100:
                    campaigns.append(row)
            active_rows = [c for c in campaigns if active(c, now)]
            claimable = next((c for c in active_rows if c.get("claimStatus") == "CLAIMABLE"), None)
            if claimable is None:
                done = next((c for c in active_rows if c.get("claimStatus") == "CLAIMED"), None)
                if done:
                    amount = (done.get("benefit") or {}).get("amount")
                    return result(True, "already", "今日已领取", credit=amount,
                                  next_check=next_open(done) or next_daily_open(now))
                future = [t for t in ([parse_time(c.get("startAt")) for c in campaigns] +
                                      [next_open(c) for c in campaigns]) if t and t > now]
                upcoming = min(future) if future else next_daily_open(now)
                return result(False, "inactive", "当前没有可领取的活动", next_check=upcoming)
            campaign_id = claimable.get("campaignId") or claimable.get("id")
            if not campaign_id:
                return result(False, "failed", "活动缺少 campaignId",
                              next_check=int(time.time() * 1000) + 15 * 60 * 1000)
            claim_url = "%s%s/%s/claim" % (OPENAPI, CAMPAIGNS_PATH, urllib.parse.quote(str(campaign_id), safe=""))
            status, body, text = http("POST", claim_url, token=cred["deviceToken"], headers=headers, body={})
            body = body if isinstance(body, dict) else {}
            nested = body.get("data") if isinstance(body.get("data"), dict) else {}
            said = body.get("status") or nested.get("status")
            if status in (401, 403):
                return result(False, "sign_in_expired", "登录已失效，请重新登录",
                              next_check=int(time.time() * 1000) + 30 * 60 * 1000)
            if status != 200:
                return result(False, "failed", "领取 HTTP %s" % status,
                              next_check=int(time.time() * 1000) + 15 * 60 * 1000)
            if said == "CLAIMED":
                amount = ((body.get("benefit") or {}).get("amount") or
                          ((body.get("data") or {}).get("benefit") or {}).get("amount") or
                          (claimable.get("benefit") or {}).get("amount"))
                if body.get("replayed"):
                    log("claim replayed")
                return result(True, "claimed", "领取成功", credit=amount,
                              next_check=next_open(claimable) or next_daily_open(now),
                              extra={"campaignId": str(campaign_id),
                                     "campaignStart": iso_ms(parse_time(claimable.get("startAt")))})
            return result(False, "failed", "领取返回 %s" % (said or "unknown"),
                          next_check=int(time.time() * 1000) + 15 * 60 * 1000)
    except RuntimeError as exc:
        message = str(exc)
        if message == "busy":
            return {"ok": False, "outcome": "busy", "message": "领取进行中"}
        if message == "sign_in_expired":
            return result(False, "sign_in_expired", "登录已失效，请重新登录",
                          next_check=int(time.time() * 1000) + 30 * 60 * 1000)
        log("claim error %s" % message)
        return result(False, "failed", message,
                      next_check=int(time.time() * 1000) + 15 * 60 * 1000)
    except Exception as exc:
        log("claim error %s" % type(exc).__name__)
        return result(False, "failed", "运行失败：%s" % type(exc).__name__,
                      next_check=int(time.time() * 1000) + 15 * 60 * 1000)


def cmd_status():
    cred = load_cred()
    state = load_state()
    login = read_json(LOGIN_PATH)
    now = int(time.time() * 1000)
    return {
        "ok": True,
        "loggedIn": bool(cred),
        "email": (cred or {}).get("email", ""),
        "name": (cred or {}).get("name", ""),
        "uid": (cred or {}).get("uid", ""),
        "expiresAt": (cred or {}).get("expiresAt", ""),
        "machineAvailable": os.path.isfile(RUNTIME_INFO),
        "claimedToday": state.get("claimedDay") == day_key(now),
        "claimedAt": state.get("claimedAt", ""),
        "credit": state.get("credit"),
        "outcome": state.get("outcome", ""),
        "message": state.get("message", ""),
        "lastAttemptAt": state.get("lastAttemptAt", ""),
        "nextCheckAt": state.get("nextCheckAt", ""),
        "nextCheckDue": bool(state.get("nextCheckAt")) and parse_time(state.get("nextCheckAt")) <= now,
        "signInExpired": bool(state.get("signInExpired")),
        "pendingLogin": login.get("status") == "pending",
        "loginStatus": login.get("status", ""),
        "loginMessage": login.get("message", ""),
    }


def main(argv):
    command = argv[1] if len(argv) > 1 else "status"
    try:
        if command == "status":
            out = cmd_status()
        elif command == "login":
            out = cmd_login()
        elif command == "claim":
            out = cmd_claim("--auto" in argv[2:])
        elif command == "logout":
            for path in (CRED_PATH, LOGIN_PATH):
                try:
                    os.remove(path)
                except OSError:
                    pass
            out = {"ok": True, "loggedOut": True}
        else:
            out = {"ok": False, "error": "unknown_command"}
    except Exception as exc:
        log("fatal %s" % type(exc).__name__)
        out = {"ok": False, "error": type(exc).__name__}
    print(json.dumps(out, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
