"""Command-line entry point for the bounded helper protocol runtime."""

import argparse
import asyncio
import sys

from . import __version__

_MISSING_RUNTIME_DEPENDENCY_EXIT = 78


def _protocol_runner():
    """Import the runtime lazily so dependency failure has one safe marker."""
    from .runtime import run_stdio

    return run_stdio


def _write_protocol_diagnostic(code: str) -> None:
    """Write one fixed, traceback-free startup diagnostic."""
    try:
        sys.stderr.write(f"ejn-helper: {code}\n")
    except BaseException:
        pass


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="ejn-helper", add_help=False)
    parser.add_argument("--version", action="store_true")
    parser.add_argument("--protocol", action="store_true", help=argparse.SUPPRESS)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.version:
        print(__version__)
        return 0
    if args.protocol:
        try:
            run_stdio = _protocol_runner()
        except ImportError:
            _write_protocol_diagnostic("missing-runtime-dependency")
            return _MISSING_RUNTIME_DEPENDENCY_EXIT
        try:
            return asyncio.run(run_stdio())
        except BaseException:
            _write_protocol_diagnostic("transport-error")
            return 2
    _parser().print_usage(sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
