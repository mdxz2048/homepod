"""Narrow validation for the versioned App↔worker protocol."""
from __future__ import annotations

from collections import OrderedDict
import json
import math
from pathlib import Path
import uuid

MAX_LINE_BYTES = 65536
MAX_ID_CHARS = 128
MAX_ID_HISTORY = 4096
COMMANDS = ("hello", "inspect", "scan", "start", "stop", "shutdown")


class ProtocolError(ValueError):
    def __init__(self, code, message, request_id=None, session=None):
        self.code, self.request_id, self.session = code, request_id, session
        super().__init__(message)


def identifier(value):
    return (isinstance(value, str) and 0 < len(value) <= MAX_ID_CHARS
            and not any(ord(char) < 32 for char in value))


def session_id(value):
    try:
        if not isinstance(value, str) or str(uuid.UUID(value)) != value.lower():
            raise ValueError()
    except (ValueError, AttributeError):
        raise ProtocolError("invalid_params", "session must be a hyphenated UUID string")
    return value


def related_session(command, params):
    if command not in ("start", "stop") or not isinstance(params, dict):
        return None
    try:
        return session_id(params.get("session"))
    except ProtocolError:
        return None


def keys(value, required=(), optional=()):
    if not isinstance(value, dict) or not set(required) <= value.keys() or value.keys() - set(required) - set(optional):
        raise ProtocolError("invalid_params", "missing or unsupported parameter fields")


def absolute_path(value, label):
    if not isinstance(value, str) or not value or len(value) > 4096 or not Path(value).is_absolute():
        raise ProtocolError("invalid_params", label + " must be an absolute local path")
    if "\x00" in value:
        raise ProtocolError("invalid_params", label + " contains an invalid character")
    return value


def number(value, low, high, name):
    if type(value) not in (int, float) or not math.isfinite(value) or not low <= value <= high:
        raise ProtocolError("invalid_params", name + " is outside supported limits")
    return value


def validate_params(command, params):
    if command in ("hello", "shutdown"):
        keys(params)
    elif command == "inspect":
        keys(params, ("wav",))
        absolute_path(params["wav"], "wav")
    elif command == "scan":
        keys(params, optional=("hosts", "timeout_seconds"))
        hosts = params.get("hosts", [])
        if (not isinstance(hosts, list) or len(hosts) > 8
                or any(not isinstance(host, str) or not 0 < len(host) <= 255 for host in hosts)
                or len(set(hosts)) != len(hosts)):
            raise ProtocolError("invalid_params", "hosts must be up to eight unique addresses")
        number(params.get("timeout_seconds", 8), 1, 15, "timeout_seconds")
    elif command == "stop":
        keys(params, ("session",))
        session_id(params["session"])
    elif command == "start":
        keys(params, ("session", "library", "wav", "execution", "routes"), ("volume", "lead_seconds"))
        session_id(params["session"])
        absolute_path(params["library"], "library")
        absolute_path(params["wav"], "wav")
        if params["execution"] not in ("offline", "airplay"):
            raise ProtocolError("invalid_params", "execution must be explicit offline or airplay")
        number(params.get("volume", 15), 0, 100, "volume")
        number(params.get("lead_seconds", 8), .000000001, 60, "lead_seconds")
        routes = params["routes"]
        if not isinstance(routes, list) or not 1 <= len(routes) <= 8:
            raise ProtocolError("invalid_params", "routes must contain one to eight outputs")
        ids, hosts = set(), set()
        for route in routes:
            network = params["execution"] == "airplay"
            keys(route, ("output_id", "channels", "host") if network else ("output_id", "channels"))
            output = route["output_id"]
            if type(output) is not int or not 0 <= output < 1 << 32 or output in ids:
                raise ProtocolError("invalid_params", "output IDs must be unique uint32 integers")
            ids.add(output)
            channels = route["channels"]
            if (not isinstance(channels, list) or len(channels) != 2
                    or any(type(channel) is not int or not 0 <= channel < 16 for channel in channels)):
                raise ProtocolError("invalid_params", "each stereo route needs two zero-based input channels")
            if network:
                host = route["host"]
                if not isinstance(host, str) or not 0 < len(host) <= 255 or host in hosts:
                    raise ProtocolError("invalid_params", "airplay hosts must be nonempty and unique")
                hosts.add(host)
    return params


def parse_request(line):
    def reject_constant(_):
        raise ValueError("nonfinite JSON number")

    def finite_float(text):
        value = float(text)
        if not math.isfinite(value):
            raise ValueError("nonfinite JSON number")
        return value

    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("duplicate JSON object key")
            result[key] = value
        return result

    if isinstance(line, bytes):
        try:
            line = line.decode("utf-8", "strict")
        except UnicodeDecodeError:
            raise ProtocolError("invalid_request", "request must be UTF-8 JSON")
    try:
        encoded_length = len(line.encode("utf-8")) if isinstance(line, str) else MAX_LINE_BYTES + 1
    except UnicodeError:
        raise ProtocolError("invalid_request", "request must be valid UTF-8")
    if encoded_length > MAX_LINE_BYTES:
        raise ProtocolError("invalid_request", "request line exceeds 64 KiB")
    if not line.endswith("\n"):
        raise ProtocolError("invalid_request", "request must end with LF")
    try:
        request = json.loads(line, parse_constant=reject_constant, parse_float=finite_float, object_pairs_hook=pairs)
        json.dumps(request, ensure_ascii=False).encode("utf-8")
    except (ValueError, TypeError, RecursionError, UnicodeError):
        raise ProtocolError("invalid_request", "request must contain one finite JSON object")
    if not isinstance(request, dict):
        raise ProtocolError("invalid_request", "request must be an object")
    request_id = request.get("id") if identifier(request.get("id")) else None
    if request_id is None:
        raise ProtocolError("invalid_request", "id must be a bounded nonempty string")
    correlated_session = related_session(request.get("command"), request.get("params"))
    if set(request) != {"v", "id", "command", "params"}:
        raise ProtocolError("invalid_request", "request fields must be v, id, command, params", request_id, correlated_session)
    if type(request["v"]) is not int or request["v"] != 1:
        raise ProtocolError("unsupported_version", "only protocol version 1 is supported", request_id, correlated_session)
    if request["command"] not in COMMANDS:
        raise ProtocolError("unknown_command", "unsupported worker command", request_id)
    try:
        validate_params(request["command"], request["params"])
    except ProtocolError as exc:
        exc.request_id = request_id
        exc.session = correlated_session
        raise
    return request


class IdHistory:
    def __init__(self, limit=MAX_ID_HISTORY):
        self.limit = limit
        self.values = OrderedDict()

    def add(self, value, active_id=None):
        if value in self.values or value == active_id:
            return False
        if len(self.values) >= self.limit:
            return None
        self.values[value] = None
        return True
