"""Local Hive API access. Secrets live only in macOS Keychain and memory."""
import argparse
import asyncio
from contextlib import asynccontextmanager
from dataclasses import asdict
import getpass
import json
import logging
import math
import subprocess
import sys

from aiohttp import ClientSession
from hiveheating import Auth, Hive
from hiveheating.exceptions import HiveError, HiveReauthRequired
from hiveheating.nodes import HeatingProduct
from keyring.backends.macOS import Keyring
from keyring.errors import KeyringError

SERVICE = "local.hive-control"
ACCOUNT = "default"


def read_credentials():
    value = Keyring().get_password(SERVICE, ACCOUNT)
    if not value:
        raise ValueError("Hive is not connected. Run ./hive login --gui.")
    return json.loads(value)


def save_credentials(config):
    Keyring().set_password(SERVICE, ACCOUNT, json.dumps(config))


def prompt(label, *, secret=False, gui=False):
    if not gui:
        return getpass.getpass(label + ": ") if secret else input(label + ": ")
    # Capture locally; never echo passwords or SMS codes to the agent's output.
    script = ('tell application "System Events"\nactivate\n'
              'set answer to display dialog ' + json.dumps(label) +
              ' with title "Hive API setup" default answer ""' +
              (' with hidden answer' if secret else '') +
              ' buttons {"Cancel", "Continue"} default button "Continue"\n'
              'return text returned of answer\nend tell')
    result = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if result.returncode:
        raise ValueError("Local login cancelled or the dialog could not open.")
    return result.stdout.rstrip("\n")


async def login(gui=False):
    username = prompt("Hive account owner's email", gui=gui).strip()
    password = prompt("Hive password (saved in macOS Keychain)", secret=True, gui=gui)
    if not username or not password:
        raise ValueError("Email and password are required.")
    async with ClientSession() as web:
        auth = Auth(username=username, password=password, websession=web)
        result = await auth.login()
        if result.sms_required:
            print("Hive sent an SMS code; enter it in the local prompt.", file=sys.stderr, flush=True)
            result = await auth.sms_2fa(prompt("Hive SMS verification code", secret=True, gui=gui).strip(), result)
        if not result.complete:
            raise ValueError("Hive login requires an unsupported challenge.")
        if result.new_device:
            await auth.device_registration("Hive Control (Mac)")
        config = {"username": username, "password": password, "tokens": result.response}
        device_data = auth.get_device_data()
        if all(device_data):
            config["device_data"] = device_data
        # Save completed login before the read, so a temporary API outage does
        # not discard trusted-device credentials and require another SMS.
        save_credentials(config)
        hive = Hive(web)
        hive.new_session(config)
        nodes = await hive.get_nodes()
        persist(hive, config)
        return snapshot(nodes)


def persist(hive, config):
    data = hive.tokens.token_data
    config["tokens"] = {"AuthenticationResult": {
        "IdToken": data.get("token"), "RefreshToken": data.get("refreshToken"),
        "ExpiresIn": int(hive.tokens.token_expiry.total_seconds()),
    }}
    device_data = hive.auth.get_device_data()
    if all(device_data):
        config["device_data"] = device_data
    save_credentials(config)


@asynccontextmanager
async def connected(*, demo=False):
    """Yield the authenticated library client, refreshing tokens as needed."""
    config = {"username": "use@file.com"} if demo else read_credentials()
    async with ClientSession() as web:
        hive = Hive(web)
        hive.new_session(config)
        try:
            yield hive
        finally:
            if not demo:
                persist(hive, config)


def snapshot(nodes):
    return {"temperature_unit": nodes.user.temperature_unit,
            "products": [asdict(p) for p in nodes.products.values()]}


def select_product(nodes, selector):
    kind = None
    if ":" in selector:
        kind, selector = selector.split(":", 1)
        kind = kind.casefold()
        if kind not in {"heating", "hotwater"}:
            raise ValueError("Product prefix must be heating: or hotwater:.")
    matches = [p for p in nodes.products.values()
               if (kind is None or p.type == kind)
               and (p.id == selector or (p.name and p.name.casefold() == selector.casefold()))]
    if len(matches) != 1:
        raise ValueError("Select one exact ID or unique name; use heating:NAME or hotwater:NAME for shared names.")
    return matches[0]


def validate_temperature(value):
    # Deliberate bounds for this local interface; not a device capability claim.
    if isinstance(value, bool) or not math.isfinite(value) or not 5 <= value <= 32:
        raise ValueError("Temperature must be a finite number between 5 and 32 °C.")


async def command(hive, selector, action, *, temperature=None, minutes=None, mode=None, dry_run=False):
    """Control an exact product, returning requested values and observed state."""
    nodes = await hive.get_nodes()
    product = select_product(nodes, selector)
    if product.online is not True:
        raise ValueError("Product is offline or its online state is unknown.")
    if action in {"temperature", "manual", "boost"} and isinstance(product, HeatingProduct):
        if nodes.user.temperature_unit not in {"C", "CELSIUS", "Celsius", "celsius", "°C"}:
            raise ValueError("Account temperature units are not confirmed as Celsius.")
        if temperature is None:
            raise ValueError("A heating temperature is required.")
        validate_temperature(temperature)
    if action in {"temperature", "manual"} and not isinstance(product, HeatingProduct):
        raise ValueError("Only heating products accept a temperature.")
    if action == "boost":
        if isinstance(minutes, bool) or not isinstance(minutes, int) or not 1 <= minutes <= 360:
            raise ValueError("Boost duration must be 1–360 whole minutes.")
        if not isinstance(product, HeatingProduct) and temperature is not None:
            raise ValueError("Hot water boost does not accept a temperature.")
    if action == "mode" and mode not in {"SCHEDULE", "MANUAL", "OFF"}:
        raise ValueError("Mode must be SCHEDULE, MANUAL or OFF.")
    if action not in {"temperature", "manual", "boost", "mode"}:
        raise ValueError("Unknown action.")
    requested = {"action": action, "product_id": product.id,
                 "temperature": temperature, "minutes": minutes, "mode": mode}
    if dry_run:
        return {"dry_run": True, "requested": requested, "before": asdict(product)}
    if action == "temperature":
        await hive.set_target_temperature(product, temperature)
    elif action == "manual":
        # Pinned hiveheating 0.4.1: one atomic API request avoids briefly
        # enabling manual mode with an old, potentially higher target.
        await hive._set_state(product, mode="MANUAL", target=temperature)
    elif action == "mode":
        await hive.set_mode(product, mode)
    elif isinstance(product, HeatingProduct):
        await hive.set_heating_boost(product, minutes, temperature)
    else:
        await hive.set_hot_water_boost(product, minutes)
    # The command response is not evidence the physical boiler has responded.
    try:
        after = await hive.get_nodes()
    except HiveError:
        return {"submitted": True, "requested": requested, "observed": None,
                "note": "Readback failed; check status before retrying."}
    current = after.products.get(product.id)
    return {"submitted": True, "requested": requested,
            "observed": asdict(current) if current else None}


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="action", required=True)
    sub.add_parser("login").add_argument("--gui", action="store_true")
    sub.add_parser("status").add_argument("--demo", action="store_true")
    for action in ("temperature", "manual", "boost", "mode"):
        s = sub.add_parser(action)
        s.add_argument("product", help="Exact ID or unique product name from status")
        s.add_argument("--dry-run", action="store_true")
        if action in {"temperature", "manual"}:
            s.add_argument("temperature", type=float)
        if action == "boost":
            s.add_argument("--minutes", required=True, type=int)
            s.add_argument("--temperature", type=float)
        if action == "mode":
            s.add_argument("mode", choices=["SCHEDULE", "MANUAL", "OFF"])
    return p


async def run(args):
    if args.action == "login":
        return await login(args.gui)
    async with connected(demo=getattr(args, "demo", False)) as hive:
        if args.action == "status":
            return snapshot(await hive.get_nodes())
        return await command(hive, args.product, args.action,
                             temperature=getattr(args, "temperature", None),
                             minutes=getattr(args, "minutes", None),
                             mode=getattr(args, "mode", None), dry_run=args.dry_run)


if __name__ == "__main__":
    logging.disable(logging.CRITICAL)  # Do not leak auth payloads through dependency logs.
    try:
        print(json.dumps(asyncio.run(run(parser().parse_args())), indent=2))
    except HiveReauthRequired:
        print("Hive authentication failed or expired. Run ./hive login --gui.", file=sys.stderr)
        sys.exit(1)
    except HiveError as exc:
        print(f"Hive request failed ({type(exc).__name__}); no success is assumed.", file=sys.stderr)
        sys.exit(1)
    except (ValueError, KeyringError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
