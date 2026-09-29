"""Prints a short-lived App Store Connect API token (ES256 JWT) from env ASC_KEY_ID/ASC_ISSUER_ID/ASC_KEY_P8."""
import base64, json, os, subprocess, tempfile, time

def b64(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

header = b64(json.dumps({"alg": "ES256", "kid": os.environ["ASC_KEY_ID"], "typ": "JWT"}).encode())
now = int(time.time())
payload = b64(json.dumps({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}).encode())
signing_input = f"{header}.{payload}".encode()
with tempfile.NamedTemporaryFile("w", suffix=".p8", delete=False) as f:
    f.write(os.environ["ASC_KEY_P8"])
    key = f.name
der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key], input=signing_input, capture_output=True, check=True).stdout
os.unlink(key)
# Convert DER ECDSA signature to raw r||s (64 bytes) as JWS requires.
def read_int(buf, i):
    assert buf[i] == 0x02
    length = buf[i + 1]
    return int.from_bytes(buf[i + 2:i + 2 + length], "big"), i + 2 + length
i = 2 if der[1] < 0x80 else 3
r, i = read_int(der, i)
s, _ = read_int(der, i)
print(f"{header}.{payload}.{b64(r.to_bytes(32, 'big') + s.to_bytes(32, 'big'))}")
