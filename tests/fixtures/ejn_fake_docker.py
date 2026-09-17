#!/usr/bin/env python3
"""Small Docker CLI fixture for executing EJN's real remote shell commands.

No daemon, container, network, kernel, or installed Jupyter is used. State and
the complete argv audit are confined to EJN_FAKE_DOCKER_STATE. Unknown command
forms fail loudly instead of accidentally making a production command pass.
"""

import json
import os
from pathlib import Path
import re
import sys


state_path = Path(os.environ["EJN_FAKE_DOCKER_STATE"])
state = json.loads(state_path.read_text())
args = sys.argv[1:]
state.setdefault("calls", []).append(args)


def save():
    state_path.write_text(json.dumps(state))


def fail(message, code=1):
    save()
    print(message, file=sys.stderr)
    raise SystemExit(code)


if state.get("unavailable"):
    fail("Cannot connect to the Docker daemon at unix:///var/run/docker.sock")

if args[:2] != ["--host", "unix:///var/run/docker.sock"]:
    fail("fixture: EJN must explicitly select the SSH host's Docker daemon")
args = args[2:]
if not args:
    fail("fixture: missing Docker command")


def option_value(arguments, key):
    for index, argument in enumerate(arguments):
        if argument == key:
            return arguments[index + 1]
        if argument.startswith(key + "="):
            return argument[len(key) + 1 :]
    return None


def format_object(template, data):
    """Interpret just the bounded inspect fields used by production commands."""
    def replace(match):
        expression = match[1].strip()
        as_json = expression.startswith("json ")
        if as_json:
            expression = expression[5:]
        if expression.startswith("index .Config.Labels "):
            key = json.loads(expression[len("index .Config.Labels ") :])
            value = data["Config"]["Labels"].get(key, "<no value>")
        elif expression.startswith("."):
            value = data
            for component in expression[1:].split("."):
                value = value[component]
        else:
            fail("fixture: unsupported inspect format " + expression)
        if as_json or isinstance(value, (dict, list, bool)):
            return json.dumps(value, separators=(",", ":"))
        return str(value)

    return re.sub(r"{{(.*?)}}", replace, template)


def lookup(identifier):
    for container in state.setdefault("containers", {}).values():
        if identifier in (container["Id"], container["Name"], container["Name"].lstrip("/")):
            return container
    return None


def publish_connection(container):
    command = container["Config"]["Cmd"]
    if "-f" in command:
        path = Path(command[command.index("-f") + 1])
        path.write_text(json.dumps({
            "transport": "tcp", "ip": "127.0.0.1", "key": "fixture-key",
            "signature_scheme": "hmac-sha256", "kernel_name": "python3",
            "shell_port": 41001, "iopub_port": 41002, "stdin_port": 41003,
            "hb_port": 41004, "control_port": 41005,
        }))
        path.chmod(0o600)


command = args[0]
if command in ("info", "version"):
    template = option_value(args, "--format")
    print(format_object(template, {"OSType": "linux"}) if template else "{}")
elif args[:2] == ["image", "inspect"]:
    if state.get("image_missing"):
        fail("Error response from daemon: No such image: " + args[-1])
    image = {"Id": state.get("image_id", "sha256:" + "a" * 64),
             "Os": "linux", "Architecture": "amd64"}
    template = option_value(args, "--format")
    print(format_object(template, image) if template else json.dumps([image]))
elif command in ("run", "create"):
    options = {}
    flags = set()
    index = 1
    while index < len(args) and args[index].startswith("-"):
        option = args[index]
        if option in ("-d", "--detach", "--rm", "--init"):
            flags.add(option)
            index += 1
            continue
        if "=" in option:
            key, value = option.split("=", 1)
            index += 1
        else:
            key, value = option, args[index + 1]
            index += 2
        options.setdefault(key, []).append(value)
    if index >= len(args):
        fail("fixture: run/create has no image")
    image = args[index]
    program_args = args[index + 1 :]
    if command == "run" and not flags.intersection({"-d", "--detach"}):
        # The kernelspec resolver's output is deterministic and belongs to
        # the simulated image, never to the host's Python installation.
        if len(program_args) < 5 or "-c" not in program_args:
            fail("fixture: unexpected foreground container command")
        kernel, connection, session = program_args[-3:]
        print(json.dumps({"kernelspecs": {kernel: {
            "resource_dir": "/opt/image/share/jupyter/kernels/" + kernel,
            "spec": {
                "argv": ["/opt/image/bin/python", "-m", "ipykernel_launcher", "-f", connection],
                "env": {"EJN_TEST": "resolved"},
                "metadata": {"ejn_connection_file": connection, "ejn_session_id": session},
            },
        }}}))
    else:
        name = options.get("--name", [None])[-1]
        if not name or lookup(name):
            fail("Conflict. The container name is already in use or missing")
        number = state.get("next_id", 1)
        state["next_id"] = number + 1
        identifier = f"{number:064x}"
        labels = dict(value.split("=", 1) for value in options.get("--label", []))
        running = command == "run"
        container = {
            "Id": identifier, "Name": "/" + name, "Image": image,
            "Config": {"Labels": labels, "Image": image,
                       "Entrypoint": options.get("--entrypoint", []),
                       "Cmd": program_args},
            "State": {"Running": running, "Pid": 4200 + number if running else 0,
                      "Status": "running" if running else "created", "ExitCode": 0},
            "HostConfig": {"NetworkMode": options.get("--network", [None])[-1]},
            "Logs": "fixture kernel log\n",
        }
        state.setdefault("containers", {})[identifier] = container
        if running:
            publish_connection(container)
        if options.get("--cidfile"):
            Path(options["--cidfile"][-1]).write_text(identifier)
        print(identifier)
elif command == "inspect" or args[:2] == ["container", "inspect"]:
    container = lookup(args[-1])
    if container is None:
        fail("Error response from daemon: No such container: " + args[-1])
    template = option_value(args, "--format")
    print(format_object(template, container) if template else json.dumps([container]))
elif command == "ps" or args[:2] == ["container", "ls"]:
    filters = [args[i + 1] for i, value in enumerate(args[:-1]) if value in ("--filter", "-f")]
    containers = list(state.setdefault("containers", {}).values())
    for criterion in filters:
        if criterion.startswith("label="):
            key, _, expected = criterion[6:].partition("=")
            containers = [c for c in containers if key in c["Config"]["Labels"]
                          and (not expected or c["Config"]["Labels"][key] == expected)]
        elif criterion.startswith("name="):
            pattern = criterion[5:]
            containers = [c for c in containers if re.search(pattern, c["Name"])]
        elif criterion.startswith("id="):
            containers = [c for c in containers if c["Id"].startswith(criterion[3:])]
        else:
            fail("fixture: unsupported list filter " + criterion)
    if not any(value in args for value in ("-a", "--all", "-aq", "-qa")):
        containers = [c for c in containers if c["State"]["Running"]]
    for container in containers:
        template = option_value(args, "--format")
        print(format_object(template, dict(container, ID=container["Id"]))
              if template else container["Id"])
elif command == "logs":
    container = lookup(args[-1])
    if container is None:
        fail("No such container")
    print(container["Logs"], end="")
elif command in ("rm", "start", "stop", "kill") or args[:2] == ["container", "rm"]:
    container = lookup(args[-1])
    if container is None:
        fail("Error response from daemon: No such container: " + args[-1])
    if command == "rm" or args[:2] == ["container", "rm"]:
        del state["containers"][container["Id"]]
    elif command == "start":
        container["State"].update(Running=True, Status="running", Pid=4201)
        publish_connection(container)
    else:
        container["State"].update(Running=False, Status="exited", Pid=0)
    print(container["Id"])
else:
    fail("fixture: unsupported Docker command " + repr(args))

save()
