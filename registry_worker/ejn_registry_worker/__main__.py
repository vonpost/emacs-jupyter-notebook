"""One-shot command entry point for the registry transaction worker."""

from .worker import main


if __name__ == "__main__":
    raise SystemExit(main())
