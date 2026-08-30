"""Per-Jupyter-message terminal arbitration for the async backend."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Mapping


@dataclass(slots=True)
class ExecutionState:
    jupyter_id: str
    reply: dict | None = None
    idle: bool = False
    terminal: bool = False

    def accepts(self, message: Mapping[str, object]) -> bool:
        """Return whether MESSAGE still belongs to this live execution."""
        parent = message.get("parent_header", {})
        return (
            not self.terminal
            and isinstance(parent, Mapping)
            and parent.get("msg_id") == self.jupyter_id
        )

    def accept_shell(self, message: Mapping[str, object]) -> bool:
        if not self.accepts(message):
            return False
        if message.get("msg_type") != "execute_reply" or self.reply is not None:
            return False
        content = message.get("content", {})
        self.reply = content if isinstance(content, dict) else {}
        return True

    def accept_iopub(self, message: Mapping[str, object]) -> bool:
        if not self.accepts(message):
            return False
        content = message.get("content", {})
        if (
            message.get("msg_type") == "status"
            and isinstance(content, Mapping)
            and content.get("execution_state") == "idle"
            and not self.idle
        ):
            self.idle = True
            return True
        return False

    def complete(self) -> dict | None:
        if self.reply is not None and self.idle and not self.terminal:
            self.terminal = True
            return self.reply
        return None
