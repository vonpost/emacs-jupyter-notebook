"""Pure incremental framing for the EJN helper transport."""

import json
import struct
from typing import Any, List, NoReturn


class FrameCodecError(ValueError):
    """A bounded, structured framing failure."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def _reject_json_constant(_constant: str) -> NoReturn:
    raise ValueError


def _check_limits(max_frame: int, accumulator_limit: int | None = None) -> int:
    if type(max_frame) is not int or max_frame < 5 or max_frame > 0x100000000 + 3:
        raise ValueError("max_frame must be a positive complete-frame size")
    if accumulator_limit is None:
        accumulator_limit = max_frame
    if type(accumulator_limit) is not int or accumulator_limit < max_frame:
        raise ValueError("accumulator_limit must be at least max_frame")
    return accumulator_limit


def encode(obj: Any, max_frame: int) -> bytes:
    """Encode one JSON object and enforce its complete wire-frame ceiling."""
    _check_limits(max_frame)
    if not isinstance(obj, dict):
        raise FrameCodecError("invalid-request", "envelope must be object")
    try:
        data = json.dumps(obj, ensure_ascii=False, allow_nan=False,
                          separators=(",", ":")).encode("utf-8")
    except (TypeError, ValueError, UnicodeEncodeError):
        raise FrameCodecError("protocol-error", "cannot encode JSON") from None
    if len(data) + 4 > max_frame:
        raise FrameCodecError("frame-too-large", "frame exceeds limit")
    return struct.pack(">I", len(data)) + data


class Decoder:
    """Incrementally decode frames without doing I/O or retaining failures."""

    def __init__(self, max_frame: int, accumulator_limit: int | None = None) -> None:
        self.accumulator_limit = _check_limits(max_frame, accumulator_limit)
        self.max_frame = max_frame
        self._raw = bytearray()
        self._need: int | None = None
        self.failed = False
        self.partial_frame = False

    @property
    def buffered_bytes(self) -> int:
        return len(self._raw)

    def feed(self, chunk: bytes) -> List[dict]:
        """Consume bytes and return all complete objects available."""
        if self.failed:
            raise FrameCodecError("protocol-error", "decoder is closed")
        if not isinstance(chunk, bytes):
            raise TypeError("decoder accepts bytes only")
        if len(self._raw) + len(chunk) > self.accumulator_limit:
            return self._fail("protocol-error", "raw accumulator exceeded")
        self._raw.extend(chunk)
        result: List[dict] = []
        while True:
            if self._need is None:
                if len(self._raw) < 4:
                    self.partial_frame = bool(self._raw)
                    break
                self._need = struct.unpack(">I", self._raw[:4])[0]
                del self._raw[:4]
                self.partial_frame = True
                if self._need + 4 > self.max_frame:
                    return self._fail("frame-too-large", "frame exceeds limit")
            if len(self._raw) < self._need:
                break
            data = bytes(self._raw[:self._need])
            del self._raw[:self._need]
            self._need = None
            try:
                obj = json.loads(data.decode("utf-8"), parse_constant=_reject_json_constant)
            except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
                return self._fail("protocol-error", "invalid UTF-8 or JSON")
            if not isinstance(obj, dict):
                return self._fail("protocol-error", "JSON payload must be object")
            result.append(obj)
            self.partial_frame = bool(self._raw)
            if not self._raw:
                break
        return result

    def partial_frame_expired(self) -> bool:
        """Fail closed when the caller's partial-frame deadline expires."""
        if self.failed:
            return True
        if self.partial_frame:
            self._fail("protocol-error", "partial frame timeout")
        return False

    def _fail(self, code: str, message: str) -> NoReturn:
        self._raw.clear()
        self._need = None
        self.partial_frame = False
        self.failed = True
        raise FrameCodecError(code, message)
