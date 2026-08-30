"""Command-line entry point; protocol implementation lands in later tasks."""

import argparse
import sys

from . import __version__


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="ejn-helper", add_help=False)
    parser.add_argument("--version", action="store_true")
    parser.add_argument("--protocol", action="store_true", help=argparse.SUPPRESS)
    return parser


def _require_runtime() -> bool:
    try:
        import jupyter_client  # noqa: F401
        import zmq  # noqa: F401
    except ImportError:
        print(
            "ejn-helper: protocol runtime unavailable; install jupyter_client and pyzmq",
            file=sys.stderr,
        )
        return False
    return True


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.version:
        print(__version__)
        return 0
    if args.protocol and not _require_runtime():
        return 2
    if args.protocol:
        return 0
    _parser().print_usage(sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
