# Test fixtures

Everything in this directory is fake test data. None of it is a real credential.

- `singbox-config.json`, `xray-config.json`: sample server configs. The UUIDs and passwords are invented. The REALITY `private_key` is the public X25519 test vector from RFC 7748 §6.1 (Alice's private key), so the expected public key can be checked against the RFC.
- `certs/*.pem`: certificates generated for the tests. `self.pem` is self-signed; `leaf.pem` is signed by `ca.pem`. Only the public certificates are kept. The private keys were deleted right after generation.

Do not put real server configs or keys here.
