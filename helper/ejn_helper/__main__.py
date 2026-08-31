"""Command-line entry point for the bounded helper protocol runtime."""

import argparse
import asyncio
import sys

from . import __version__


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
            from .runtime import run_stdio

            return asyncio.run(run_stdio())
        except BaseException:
            try:
                sys.stderr.write("ejn-helper: transport-error\n")
            except BaseException:
                pass
            return 2
    _parser().print_usage(sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
