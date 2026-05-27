#!/usr/bin/env bash
# Fernet-key readiness probe — runs from web's initCommands BEFORE migrate.
#
# Why this exists: migration 1094 adds an EncryptedCharField with default="" — the first
# migration to actually invoke posthog.helpers.encrypted_fields. On a fresh container boot
# its initial migrate attempt has intermittently failed during Fernet construction even when
# every env var is already correct (verified by re-running manually right after). The retry
# in `zsc execOnce --retryUntilSuccessful` recovers, but the migrate traceback in the logs
# is loud and misleading.
#
# This probe builds the same Fernet keys as encrypted_fields.py (one per ENCRYPTION_SALT_KEYS
# entry + one per SALT_KEY entry, derived via PBKDF2). If construction fails, we exit non-zero
# fast and the retry kicks in cleanly. Once it passes, migrate runs once and succeeds.
set -euo pipefail

cd /opt/posthog/code
exec /opt/posthog/python-runtime/bin/python3.12 - <<'PY'
import base64
import django
from django.conf import settings
django.setup()

from cryptography.fernet import Fernet
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC

keys = [base64.urlsafe_b64encode(x.encode("utf-8")) for x in settings.ENCRYPTION_SALT_KEYS]
for k in keys:
    Fernet(k)

for salt_key in settings.SALT_KEY:
    kdf = PBKDF2HMAC(
        algorithm=hashes.SHA256(),
        length=32,
        salt=bytes(salt_key, "utf-8"),
        iterations=100000,
        backend=default_backend(),
    )
    derived = kdf.derive(settings.SECRET_KEY.encode("utf-8"))
    Fernet(base64.urlsafe_b64encode(derived))

print(f"Fernet keys verified ({len(keys) + len(settings.SALT_KEY)} total)")
PY
