# Quickstart

[简体中文](GETTING-STARTED.zh-CN.md) · [Documentation index](README.md)

## Connect on the same network

1. [Install the plugin](../README.en.md#install) and restart DeepSeek Harness. On the computer running dsh, open **Remote access** in the sidebar.
2. Set an access password. If remote access is disabled, enable it. Open **Local network** and confirm the portal is running.
3. Put your phone or other computer on the same trusted network, then choose how to sign in:
   - **Use the password:** open the LAN address shown in the panel (the portal defaults to port `3081`), then enter your access password. Don't use `127.0.0.1` on the phone; that's the phone's own loopback address.
   - **Pair once:** scan the QR code under **Pair by QR code**, or send the pairing link privately to the device. The code is valid for 180 seconds and works once. Generate another one in the panel if it expires.

If the address won't open, check that the portal is running, that your device isn't on an isolated guest Wi-Fi network, and that the host firewall allows the portal port from the trusted LAN. Use plain HTTP only on a trusted network.

## Connect away from home

You don't need to forward the home portal's port on your router. [Deploy an HTTPS relay](DEPLOY-SERVER.md) on a server you control. In the panel's **Public access** tab, enter the relay endpoint and tunnel token printed by the installer. Once connected, open the visitor URL on your other device.
