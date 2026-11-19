# Termux terminal components

Vendored without modification from `termux/termux-app` tag `v0.118.0`,
commit `6e2689f55295fa444be8ac8592c527c2c5ef3253`:

- `terminal-emulator/src/main/java/com/termux/terminal/*.java`
- `terminal-view/src/main/java/com/termux/view/TerminalRenderer.java`

Upstream's `LICENSE.md` explicitly excepts these Terminal Emulator for Android
components from the repository's GPLv3 license under **Apache License 2.0**.
The upstream license statement and Apache license text are included here;
individual source copyright/license headers are retained.

DRP uses only the VT parser, buffers, key encoding and Canvas renderer. It does
not instantiate Termux's local process/session or load its JNI library. Shells
execute on the connected dsh host, over authenticated duplex mux streams.
