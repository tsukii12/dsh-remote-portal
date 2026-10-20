# Test-only TLS material

cert.pem / key.pem are a throwaway self-signed pair generated with:

    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -keyout key.pem -out cert.pem \
      -subj "/CN=dsh-remote-portal test" \
      -addext "subjectAltName=IP:127.0.0.1,DNS:localhost"

They exist so 	est/relay.test.mjs can exercise the visitor HTTPS listener and
the TLS agent listener (trusted here via insecure: true / ejectUnauthorized:
false). The key is committed on purpose and has no value outside these tests —
never use it for anything real.
