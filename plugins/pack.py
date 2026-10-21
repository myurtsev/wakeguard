#!/usr/bin/env python3
"""Build and check WakeGuard plugin packages without third-party dependencies."""

import argparse
import hashlib
import json
import re
import unicodedata
from pathlib import Path
from urllib.parse import urlsplit


BASE_URL = "https://myurtsev.github.io/wakeguard/plugins/"
PACKAGE_LIMIT = 128 * 1024
SCRIPT_LIMIT = 96 * 1024
ID = r"[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+"
VERSION = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def text(value, limit):
    return (isinstance(value, str) and bool(value.strip()) and len(value) <= limit
            and not any(unicodedata.category(char) in ("Cc", "Cf") for char in value))


def matches(value, pattern):
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def https_url(value):
    require(isinstance(value, str) and len(value.encode("utf-8")) <= 4096,
            "URL must be a string of at most 4096 bytes")
    try:
        url = urlsplit(value)
        valid = (value.startswith("https://") and url.scheme == "https" and bool(url.hostname)
                 and url.username is None and url.password is None
                 and url.port in (None, 443)
                 and not any(char.isspace() or unicodedata.category(char) == "Cc"
                             for char in value))
    except ValueError:
        valid = False
    require(valid, "Use an HTTPS URL without credentials or a custom port")
    return url


def validate(package):
    require(isinstance(package, dict), "Package must be a JSON object")
    require(type(package.get("apiVersion")) is int and package["apiVersion"] == 1,
            "apiVersion must be 1")
    require(matches(package.get("id"), ID) and len(package["id"]) <= 120,
            "Use a lowercase reverse-DNS plugin id")
    require(matches(package.get("version"), VERSION) and len(package["version"]) <= 30,
            "version must contain three numbers, for example 1.0.0")
    for key, limit in (("name", 60), ("author", 100), ("description", 300)):
        require(text(package.get(key), limit), f"Invalid {key}")
    if package.get("homepage") is not None:
        https_url(package["homepage"])
    script = package.get("script")
    require(isinstance(script, str) and 0 < len(script.encode("utf-8")) <= SCRIPT_LIMIT,
            "script must contain 1–98304 UTF-8 bytes")
    permissions = package.get("permissions")
    require(isinstance(permissions, dict), "permissions must be an object")
    for key in ("notifications", "openURLs"):
        require(type(permissions.get(key)) is bool, f"permissions.{key} must be boolean")
    hosts = permissions.get("network")
    require(isinstance(hosts, list) and len(hosts) <= 8
            and all(isinstance(host, str) for host in hosts)
            and len(hosts) == len(set(hosts)), "Use up to eight distinct network hosts")
    for host in hosts:
        require(len(host) <= 253 and matches(host, r"[a-z0-9]([a-z0-9.-]*[a-z0-9])?")
                and "." in host and ".." not in host,
                "Network permissions must name exact lowercase hosts")
        require(https_url("https://" + host).hostname == host, "Invalid network host")
    settings = package.get("settings")
    require(isinstance(settings, list) and len(settings) <= 12, "Use up to 12 settings")
    keys = []
    for setting in settings:
        require(isinstance(setting, dict), "Each setting must be an object")
        key, kind = setting.get("key"), setting.get("type")
        require(matches(key, r"[a-z][a-zA-Z0-9_]{0,39}")
                and text(setting.get("label"), 60)
                and kind in ("text", "secret", "toggle")
                and type(setting.get("required")) is bool, "Invalid setting")
        default = setting.get("defaultValue")
        require(default is None or isinstance(default, str)
                and len(default.encode("utf-8")) <= 2048, "Invalid setting default")
        require(kind != "secret" or default is None, "Never package a default secret")
        require(kind != "toggle" or default is None or default in ("true", "false"),
                "Toggle defaults must be strings: true or false")
        keys.append(key)
    require(len(keys) == len(set(keys)), "Setting keys must be unique")
    commands = package.get("commands")
    require(isinstance(commands, list) and len(commands) <= 8, "Use up to eight commands")
    command_ids = []
    for command in commands:
        require(isinstance(command, dict)
                and matches(command.get("id"), r"[a-z][a-zA-Z0-9_-]{0,39}")
                and text(command.get("title"), 60), "Invalid command")
        command_ids.append(command["id"])
    require(len(command_ids) == len(set(command_ids)), "Command ids must be unique")
    return package


def encode(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n").encode("utf-8")


def decode_json(value):
    def reject_constant(constant):
        raise ValueError(f"Invalid JSON constant: {constant}")
    return json.loads(value, parse_constant=reject_constant)


def read_package(path):
    data = path.read_bytes()
    require(len(data) <= PACKAGE_LIMIT, "Package exceeds 128 KiB")
    return validate(decode_json(data)), data


def pack(source, output):
    package = decode_json((source / "manifest.json").read_text(encoding="utf-8"))
    require(isinstance(package, dict), "Manifest must be a JSON object")
    require("script" not in package, "Keep script in plugin.js, not manifest.json")
    package["script"] = (source / "plugin.js").read_text(encoding="utf-8")
    data = encode(validate(package))
    require(len(data) <= PACKAGE_LIMIT, "Encoded package exceeds 128 KiB")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(data)


def catalog(output, paths):
    entries = []
    for path in paths:
        package, data = read_package(path)
        relative = Path(package["id"]) / (package["version"] + ".wakeguardplugin")
        require(path.resolve() == (output.parent / relative).resolve(),
                f"Place package at {output.parent / relative}")
        entry = {key: package[key] for key in
                 ("id", "name", "version", "author", "description")}
        entry.update(url=BASE_URL + relative.as_posix(), sha256=hashlib.sha256(data).hexdigest())
        entries.append(entry)
    require(len(entries) <= 200 and len({entry["id"] for entry in entries}) == len(entries),
            "Catalog must contain up to 200 distinct plugin ids")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(encode({"schemaVersion": 1, "plugins": sorted(entries, key=lambda entry: entry["id"])}))


def verify(path):
    index = decode_json(path.read_text(encoding="utf-8"))
    require(isinstance(index, dict), "Catalog must be a JSON object")
    require(type(index.get("schemaVersion")) is int and index["schemaVersion"] == 1,
            "Invalid catalog schemaVersion")
    entries = index.get("plugins")
    require(isinstance(entries, list) and len(entries) <= 200, "Invalid catalog plugins")
    ids = []
    for entry in entries:
        require(isinstance(entry, dict) and matches(entry.get("id"), ID)
                and matches(entry.get("version"), VERSION), "Invalid catalog identity")
        relative = Path(entry["id"]) / (entry["version"] + ".wakeguardplugin")
        require(entry.get("url") == BASE_URL + relative.as_posix(), "Unexpected catalog package URL")
        package, data = read_package(path.parent / relative)
        require(entry.get("sha256") == hashlib.sha256(data).hexdigest(), "Catalog checksum mismatch")
        for key in ("id", "name", "version", "author", "description"):
            require(entry.get(key) == package[key], f"Catalog/package {key} mismatch")
        ids.append(entry["id"])
    require(len(ids) == len(set(ids)), "Duplicate catalog plugin id")
    return len(entries)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("pack", help="Combine SOURCE/manifest.json and plugin.js")
    build.add_argument("source", type=Path)
    build.add_argument("output", type=Path)
    index = commands.add_parser("catalog", help="Generate the official catalog and SHA-256 values")
    index.add_argument("output", type=Path)
    index.add_argument("packages", type=Path, nargs="+")
    check = commands.add_parser("verify", help="Verify local catalog packages and checksums")
    check.add_argument("catalog", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "pack":
            pack(args.source, args.output)
            print(f"Built {args.output}")
        elif args.command == "catalog":
            catalog(args.output, args.packages)
            print(f"Built {args.output}")
        else:
            print(f"Verified {verify(args.catalog)} catalog packages")
    except (ValueError, OSError, UnicodeError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
