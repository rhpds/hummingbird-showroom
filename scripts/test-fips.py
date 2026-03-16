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
from typing import Callable, Tuple, Optional


# Test specifications: (name, operation, should_succeed_in_fips)
TESTS = {
    "FIPS-Approved Algorithms": [
        ("SHA-256", lambda: hashlib.sha256(b"test").hexdigest(), True),
        ("HMAC-SHA256", lambda: hmac.new(b"key", b"msg", "sha256").hexdigest(), True),
        (
            "MD5 (usedforsecurity=False)",
            lambda: hashlib.md5(b"test", usedforsecurity=False).hexdigest(),
            True,
        ),
        ("AES-256-GCM cipher", lambda: _test_aes_gcm(), True),
    ],
    "Disallowed Algorithms Blocked": [
        ("MD5 via hashlib.new()", lambda: hashlib.new("md5", b"test"), False),
        ("MD5 via hashlib.md5()", lambda: hashlib.md5(b"test"), False),
        ("HMAC-MD5", lambda: hmac.new(b"key", b"msg", "md5").hexdigest(), False),
        ("CHACHA20-POLY1305 cipher", lambda: _test_chacha(), False),
    ],
}


def _test_aes_gcm():
    """Test AES-256-GCM cipher availability"""
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.set_ciphers("ECDHE-RSA-AES256-GCM-SHA384")
    assert len(ctx.get_ciphers()) > 0


def _test_chacha():
    """Test ChaCha20-Poly1305 cipher availability"""
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.set_ciphers("ECDHE-RSA-CHACHA20-POLY1305")


def print_section(text: str):
    """Print a section header"""
    print(f"\n\033[1m\033[94m{'=' * 60}\n{text}\n{'=' * 60}\033[0m")


def print_result(name: str, passed: bool, details: str = ""):
    """Print a check result with color coding"""
    status = "\033[92m✓ PASS" if passed else "\033[91m✗ FAIL"
    print(f"{status}\033[0m - {name}")
    if details:
        print(f"  {details}")


def run_test_suite(suite_name: str, tests: list) -> Tuple[bool, str]:
    """Run a suite of algorithm tests with unified error handling"""
    failures = []
    success_names = []

    for name, operation, should_succeed in tests:
        try:
            operation()
            if should_succeed:
                success_names.append(name)
            else:
                failures.append(f"{name} was allowed")
        except (ValueError, ssl.SSLError):
            if should_succeed:
                failures.append(f"{name} failed")
        except Exception as e:
            failures.append(f"{name} failed with unexpected error: {e}")

    if failures:
        return False, f"Failures: {'; '.join(failures)}"

    # Generate success message based on suite type
    if "Approved" in suite_name:
        return (
            True,
            f"All FIPS-approved algorithms available ({', '.join(success_names)})",
        )
    else:
        return (
            True,
            f"All disallowed algorithms properly blocked ({len(tests)} algorithms)",
        )


def get_fips_provider_version() -> Optional[str]:
    """Query FIPS provider version from OpenSSL using CFFI (more Pythonic than ctypes)"""
    try:
        from cffi import FFI

        ffi = FFI()
        ffi.cdef("""
            typedef struct {
                const char *key;
                unsigned int data_type;
                void *data;
                size_t data_size;
                size_t return_size;
            } OSSL_PARAM;
            
            void* OSSL_PROVIDER_load(void *libctx, const char *name);
            int OSSL_PROVIDER_get_params(void *prov, OSSL_PARAM *param);
            int OSSL_PROVIDER_unload(void *prov);
            OSSL_PARAM OSSL_PARAM_construct_utf8_ptr(const char *key, char **buf, size_t bsize);
            OSSL_PARAM OSSL_PARAM_construct_end(void);
        """)

        # Try to load OpenSSL library with fallback options for better robustness
        lib = None
        for lib_name in ["crypto", "libcrypto.so.3", "libcrypto.so"]:
            try:
                lib = ffi.dlopen(lib_name)
                break
            except OSError:
                continue

        if not lib:
            return None

        # Load FIPS provider and query version
        provider = lib.OSSL_PROVIDER_load(ffi.NULL, b"fips")
        if provider == ffi.NULL:
            return None

        version_ptr = ffi.new("char **")
        params = ffi.new("OSSL_PARAM[2]")
        params[0] = lib.OSSL_PARAM_construct_utf8_ptr(b"version", version_ptr, 0)
        params[1] = lib.OSSL_PARAM_construct_end()

        result = None
        if (
            lib.OSSL_PROVIDER_get_params(provider, params) == 1
            and version_ptr[0] != ffi.NULL
        ):
            result = ffi.string(version_ptr[0]).decode("utf-8")

        lib.OSSL_PROVIDER_unload(provider)
        return result

    except Exception:
        return None


def get_fips_info() -> str:
    """Get FIPS provider information by testing if restrictions are active"""
    try:
        hashlib.new("md5", b"test")
        return "not active"
    except ValueError:
        pass

    # MD5 is blocked - FIPS is active
    provider_version = get_fips_provider_version()
    return (
        f"active (provider {provider_version})"
        if provider_version
        else "active (provider version unknown)"
    )


def run_check(name: str, check_func: Callable[[], Tuple[bool, str]]) -> bool:
    """Run a check function and return pass/fail result"""
    try:
        passed, details = check_func()
        print_result(name, passed, details)
        return passed
    except Exception as e:
        print_result(name, False, f"Error: {e}")
        return False


def main() -> int:
    """Run FIPS validation checks and display results"""
    print_section("FIPS Validated Crypto Library Test")
    print(f"Python version: {sys.version.split()[0]}")
    print(f"OpenSSL version: {ssl.OPENSSL_VERSION}")
    print(f"FIPS provider: {get_fips_info()}")

    print_section("Running FIPS Validation Checks")

    results = [
        run_check(suite_name, lambda s=suite_name, t=tests: run_test_suite(s, t))
        for suite_name, tests in TESTS.items()
    ]

    all_passed = all(results)
    symbol, text, color = (
        ("✓", "FIPS CAPABLE", "\033[92m")
        if all_passed
        else ("✗", "NOT FIPS CAPABLE", "\033[91m")
    )
    print(f"\n{color}\033[1m{symbol} {text}\033[0m\n")

    return 0 if all_passed else 2


if __name__ == "__main__":
    sys.exit(main())
