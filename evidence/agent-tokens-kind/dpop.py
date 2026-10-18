# ES256 DPoP proofs with openssl and the standard library only (no cryptography module here).
import base64, json, os, subprocess, time, uuid, hashlib

def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

def _der_to_raw(der):
    # SEQUENCE { INTEGER r, INTEGER s } -> 32-byte r || 32-byte s
    assert der[0] == 0x30
    i = 2
    if der[1] & 0x80:
        i = 2 + (der[1] & 0x7f)
    def read_int(j):
        assert der[j] == 0x02
        ln = der[j + 1]
        val = der[j + 2:j + 2 + ln]
        return val.lstrip(b"\x00").rjust(32, b"\x00"), j + 2 + ln
    r, i = read_int(i)
    s, i = read_int(i)
    return r + s

class Key:
    def __init__(self, path):
        self.path = path
        if not os.path.exists(path):
            subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", path], check=True, capture_output=True)
        der = subprocess.run(["openssl", "pkey", "-in", path, "-pubout", "-outform", "DER"], check=True, capture_output=True).stdout
        pt = der[-65:]
        assert pt[0] == 4
        self.x, self.y = pt[1:33], pt[33:65]
    def jwk(self):
        return {"kty": "EC", "crv": "P-256", "x": b64u(self.x), "y": b64u(self.y)}
    def thumbprint(self):
        canon = json.dumps({"crv": "P-256", "kty": "EC", "x": b64u(self.x), "y": b64u(self.y)}, separators=(",", ":"), sort_keys=True)
        return b64u(hashlib.sha256(canon.encode()).digest())

def proof(key, htm, htu, ath=None, iat=None):
    header = {"typ": "dpop+jwt", "alg": "ES256", "jwk": key.jwk()}
    payload = {"jti": str(uuid.uuid4()), "htm": htm, "htu": htu, "iat": int(time.time()) if iat is None else iat}
    if ath:
        payload["ath"] = ath
    signing = b64u(json.dumps(header, separators=(",", ":")).encode()) + "." + b64u(json.dumps(payload, separators=(",", ":")).encode())
    p = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key.path], input=signing.encode(), check=True, capture_output=True)
    return signing + "." + b64u(_der_to_raw(p.stdout))
