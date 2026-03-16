#!/usr/bin/env python3.14
"""
FIPS Validated Crypto Test Script for Containers

Tests if FIPS validated cryptographic libraries are available and working
inside a container using Python native capabilities only.

Design Philosophy:
- If you choose a FIPS image, you're using FIPS-certified crypto modules
- You can only use FIPS-allowed algorithms
- Tests verify Python's actual crypto capabilities, not external tools
"""

import sys
import hashlib
import hmac
import ssl
from ctypes import CDLL, Structure, POINTER, c_void_p, c_char_p, c_uint, c_int, c_size_t, byref
from ctypes.util import find_library


class Colors:
    """ANSI color codes for terminal output"""
    GREEN = '\033[92m'
    RED = '\033[91m'
    BLUE = '\033[94m'
    BOLD = '\033[1m'
    RESET = '\033[0m'


def print_header(text):
    """Print a section header"""
    header_style = f"{Colors.BOLD}{Colors.BLUE}"
    print(f"\n{header_style}{'=' * 60}{Colors.RESET}")
    print(f"{header_style}{text}{Colors.RESET}")
    print(f"{header_style}{'=' * 60}{Colors.RESET}")


def print_result(check_name, passed, details=""):
    """Print a check result with color coding"""
    status = f"{Colors.GREEN}✓ PASS" if passed else f"{Colors.RED}✗ FAIL"
    print(f"{status}{Colors.RESET} - {check_name}")
    if details:
        print(f"  {details}")


def check_approved_algorithms():
    """Verify that FIPS-approved algorithms work correctly"""
    failures = []

    def ensure_works(name, operation):
        try:
            operation()
        except Exception as e:
            failures.append(f"{name} failed: {e}")

    ensure_works("SHA-256", lambda: hashlib.sha256(b'test').hexdigest())
    ensure_works("HMAC-SHA256", lambda: hmac.new(b'key', b'msg', 'sha256').hexdigest())
    ensure_works("MD5 (usedforsecurity=False)",
                 lambda: hashlib.md5(b'test', usedforsecurity=False).hexdigest())

    def test_aes_gcm():
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.set_ciphers('ECDHE-RSA-AES256-GCM-SHA384')
        assert len(ctx.get_ciphers()) > 0
    ensure_works("AES-256-GCM cipher", test_aes_gcm)

    return (False, f"Failures: {'; '.join(failures)}") if failures else \
           (True, "All FIPS-approved algorithms available (SHA-256, HMAC-SHA256, AES-GCM)")


def check_disallowed_algorithms():
    """Verify that FIPS-disallowed algorithms are properly blocked"""
    failures = []

    def ensure_blocked(name, operation):
        try:
            operation()
            failures.append(f"{name} was allowed")
        except (ValueError, ssl.SSLError):
            pass

    ensure_blocked("MD5 via hashlib.new()", lambda: hashlib.new('md5', b'test'))
    ensure_blocked("MD5 via hashlib.md5()", lambda: hashlib.md5(b'test'))
    ensure_blocked("HMAC-MD5", lambda: hmac.new(b'key', b'msg', 'md5').hexdigest())

    def test_chacha():
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.set_ciphers('ECDHE-RSA-CHACHA20-POLY1305')
    ensure_blocked("CHACHA20-POLY1305 cipher", test_chacha)

    return (False, f"Failures: {'; '.join(failures)}") if failures else \
           (True, "All disallowed algorithms properly blocked (MD5, HMAC-MD5, ChaCha20)")


class OSSL_PARAM(Structure):
    """OpenSSL parameter structure for provider queries"""
    _fields_ = [
        ("key", c_char_p),
        ("data_type", c_uint),
        ("data", c_void_p),
        ("data_size", c_size_t),
        ("return_size", c_size_t)
    ]


def get_fips_provider_version():
    """Query the actual FIPS provider version from OpenSSL"""
    try:
        libcrypto_path = find_library('crypto')
        if not libcrypto_path:
            return None

        lib = CDLL(libcrypto_path)

        # Configure OpenSSL provider API functions
        lib.OSSL_PROVIDER_load.argtypes = [c_void_p, c_char_p]
        lib.OSSL_PROVIDER_load.restype = c_void_p
        lib.OSSL_PROVIDER_get_params.argtypes = [c_void_p, POINTER(OSSL_PARAM)]
        lib.OSSL_PROVIDER_get_params.restype = c_int
        lib.OSSL_PROVIDER_unload.argtypes = [c_void_p]
        lib.OSSL_PROVIDER_unload.restype = c_int
        lib.OSSL_PARAM_construct_utf8_ptr.argtypes = [c_char_p, POINTER(c_char_p), c_size_t]
        lib.OSSL_PARAM_construct_utf8_ptr.restype = OSSL_PARAM
        lib.OSSL_PARAM_construct_end.restype = OSSL_PARAM

        prov = lib.OSSL_PROVIDER_load(None, b"fips")
        if not prov:
            return None

        try:
            vers = c_char_p()
            params = (OSSL_PARAM * 2)()
            params[0] = lib.OSSL_PARAM_construct_utf8_ptr(b"version", byref(vers), 0)
            params[1] = lib.OSSL_PARAM_construct_end()

            if lib.OSSL_PROVIDER_get_params(prov, params) == 1 and vers.value:
                return vers.value.decode('utf-8')
        finally:
            lib.OSSL_PROVIDER_unload(prov)

    except Exception:
        pass

    return None


def get_fips_info():
    """Get FIPS provider information by testing if restrictions are active"""
    try:
        hashlib.new('md5', b'test')
        return "not active"
    except ValueError:
        pass

    # MD5 is blocked - FIPS is active
    provider_version = get_fips_provider_version()
    return f"active (provider {provider_version})" if provider_version else "active (provider version unknown)"


def run_check(name, check_func):
    """Run a check function and return pass/fail result"""
    try:
        passed, details = check_func()
        print_result(name, passed, details)
        return passed
    except Exception as e:
        print_result(name, False, f"Unexpected error: {e}")
        return False


def main():
    """Run FIPS validation checks and display results"""
    print_header("FIPS Validated Crypto Library Test")
    print(f"Python version: {sys.version.split()[0]}")
    print(f"OpenSSL version: {ssl.OPENSSL_VERSION}")
    print(f"FIPS provider: {get_fips_info()}")

    print_header("Running FIPS Validation Checks")

    results = [
        run_check("FIPS-Approved Algorithms", check_approved_algorithms),
        run_check("Disallowed Algorithms Blocked", check_disallowed_algorithms),
    ]

    all_passed = all(results)
    symbol, text, color = ("✓", "FIPS CAPABLE", Colors.GREEN) if all_passed else ("✗", "NOT FIPS CAPABLE", Colors.RED)
    print(f"\n{color}{Colors.BOLD}{symbol} {text}{Colors.RESET}\n")

    return 0 if all_passed else 2


if __name__ == "__main__":
    sys.exit(main())
