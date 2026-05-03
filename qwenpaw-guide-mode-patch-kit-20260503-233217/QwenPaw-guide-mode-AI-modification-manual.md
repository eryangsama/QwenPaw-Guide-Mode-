# QwenPaw 引导模式从零改造教程（给 AI 执行用）

本教程是给另一个 AI 编码代理使用的施工手册。目标是：在一个原版或刚重装的 QwenPaw 安装目录里，从零修改后端和 Desktop 前端，实现类似 Codex 的“引导模式”。

执行者必须真的修改本机文件、做备份、做校验、重启并验证。不要只给方案。

## 目标行为

改造完成后，QwenPaw Desktop 必须支持：

- `/guide on`：开启引导模式。
- `/guide off`：关闭引导模式。
- `/g 内容`：把内容作为当前运行任务的引导注入。
- `/引导 on`：中文开启引导模式。
- `/引导 off`：中文关闭引导模式。
- 开启引导模式后，任务正在执行时，用户在 Desktop 输入框继续输入普通文本并回车，不应该触发 stop，不应该启动一个排队的新任务，而应该通过侧通道注入当前正在运行的 agent。
- 如果模型收到引导后只说“好的/我会处理”却没有执行工具，后端要强制再走一次工具调用倾向的推理，尽量把引导里的具体动作做掉。

验收时，日志里应看到这些关键记录：

```text
Console guide queued
Injected 1 guidance item(s)
Guidance action guard
```

同时，在一次运行任务中途插入“再复制一份命名为 C”之类指令时，最终应在同一轮任务里完成，不应出现第二次普通 `Handle agent query`。

## 重要原则

1. 先备份，再修改。
2. 优先修改 QwenPaw 当前安装目录里的文件，不要修改无关 Python 环境。
3. 不要删除用户文件。
4. 不要用 `git reset --hard`、`Remove-Item -Recurse` 之类危险命令处理安装目录。
5. Python 文件必须用 UTF-8 保存。
6. PowerShell 5 读取 `.ps1` 里的中文可能乱码。校验脚本里如果需要中文命令，优先用 Unicode 码点生成：`([char]0x5f15)+([char]0x5bfc)`。
7. Frontend 如果只有打包后的 `console/assets/*.js`，可以修改 bundle，但必须改完后实际打开 Desktop 验证。

## 目录定位

常见安装目录：

```text
D:\QwenPaw
C:\QwenPaw
%LOCALAPPDATA%\Programs\QwenPaw
```

执行前先定位安装根目录。下面示例用 `D:\QwenPaw`，实际以本机为准。

PowerShell 检查：

```powershell
$QwenPawRoot = "D:\QwenPaw"
Test-Path "$QwenPawRoot\Lib\site-packages\qwenpaw"
Test-Path "$QwenPawRoot\python.exe"
```

目标文件清单：

```text
Lib\site-packages\qwenpaw\app\runner\guidance.py
Lib\site-packages\qwenpaw\app\runner\control_commands\guide_handler.py
Lib\site-packages\qwenpaw\app\runner\control_commands\__init__.py
Lib\site-packages\qwenpaw\app\routers\console.py
Lib\site-packages\qwenpaw\app\channels\base.py
Lib\site-packages\qwenpaw\app\channels\command_registry.py
Lib\site-packages\qwenpaw\agents\react_agent.py
Lib\site-packages\qwenpaw\console\index.html
Lib\site-packages\qwenpaw\console\assets\*.js
```

## 第 0 步：关闭 QwenPaw 并备份

关闭 QwenPaw Desktop。然后创建备份目录：

```powershell
$QwenPawRoot = "D:\QwenPaw"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupRoot = Join-Path ([Environment]::GetFolderPath("Desktop")) "QwenPaw-guide-mode-source-backup-$Stamp"
New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null

$Files = @(
  "Lib\site-packages\qwenpaw\app\runner\guidance.py",
  "Lib\site-packages\qwenpaw\app\runner\control_commands\guide_handler.py",
  "Lib\site-packages\qwenpaw\app\runner\control_commands\__init__.py",
  "Lib\site-packages\qwenpaw\app\routers\console.py",
  "Lib\site-packages\qwenpaw\app\channels\base.py",
  "Lib\site-packages\qwenpaw\app\channels\command_registry.py",
  "Lib\site-packages\qwenpaw\agents\react_agent.py",
  "Lib\site-packages\qwenpaw\console\index.html"
)

foreach ($Rel in $Files) {
  $Src = Join-Path $QwenPawRoot $Rel
  if (Test-Path -LiteralPath $Src) {
    $Dst = Join-Path $BackupRoot $Rel
    New-Item -ItemType Directory -Path (Split-Path $Dst -Parent) -Force | Out-Null
    Copy-Item -LiteralPath $Src -Destination $Dst -Force
  }
}

$AssetBackup = Join-Path $BackupRoot "Lib\site-packages\qwenpaw\console\assets"
New-Item -ItemType Directory -Path $AssetBackup -Force | Out-Null
Copy-Item -LiteralPath "$QwenPawRoot\Lib\site-packages\qwenpaw\console\assets\*.js" -Destination $AssetBackup -Force

Write-Host "Backup saved at $BackupRoot"
```

## 第 1 步：新增引导队列模块

创建或覆盖：

```text
Lib\site-packages\qwenpaw\app\runner\guidance.py
```

内容必须是 UTF-8：

```python
# -*- coding: utf-8 -*-
"""In-process guidance side channel for running agent tasks."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from threading import RLock
from time import time

_MAX_ITEMS_PER_KEY = 50


@dataclass(frozen=True)
class GuidanceItem:
    """A user steering note delivered while a task is running."""

    text: str
    created_at: float
    channel: str = ""
    user_id: str = ""


_pending: dict[tuple[str, str], list[GuidanceItem]] = {}
_guide_mode: set[tuple[str, str]] = set()
_lock = RLock()


def _key(agent_id: str | None, session_id: str | None) -> tuple[str, str]:
    return ((agent_id or "").strip(), (session_id or "").strip())


def add_guidance(
    agent_id: str | None,
    session_id: str | None,
    text: str,
    *,
    channel: str = "",
    user_id: str = "",
) -> int:
    """Add one guidance item and return the pending count for the session."""
    clean_text = (text or "").strip()
    if not clean_text:
        return pending_count(agent_id, session_id)

    key = _key(agent_id, session_id)
    with _lock:
        items = _pending.setdefault(key, [])
        items.append(
            GuidanceItem(
                text=clean_text,
                created_at=time(),
                channel=channel or "",
                user_id=user_id or "",
            ),
        )
        overflow = len(items) - _MAX_ITEMS_PER_KEY
        if overflow > 0:
            del items[:overflow]
        return len(items)


def drain_guidance(
    agent_id: str | None,
    session_id: str | None,
) -> list[GuidanceItem]:
    """Remove and return all pending guidance for a session."""
    key = _key(agent_id, session_id)
    with _lock:
        items = _pending.pop(key, [])
    return list(items)


def clear_guidance(agent_id: str | None, session_id: str | None) -> int:
    """Clear pending guidance and return how many items were removed."""
    key = _key(agent_id, session_id)
    with _lock:
        items = _pending.pop(key, [])
    return len(items)


def pending_count(agent_id: str | None, session_id: str | None) -> int:
    key = _key(agent_id, session_id)
    with _lock:
        return len(_pending.get(key, []))


def set_guide_mode(
    agent_id: str | None,
    session_id: str | None,
    enabled: bool,
) -> None:
    """Enable or disable guide mode for a session."""
    key = _key(agent_id, session_id)
    with _lock:
        if enabled:
            _guide_mode.add(key)
        else:
            _guide_mode.discard(key)


def is_guide_mode(agent_id: str | None, session_id: str | None) -> bool:
    key = _key(agent_id, session_id)
    with _lock:
        return key in _guide_mode


def _format_time(ts: float) -> str:
    return (
        datetime.fromtimestamp(ts, timezone.utc)
        .isoformat(timespec="seconds")
        .replace("+00:00", "Z")
    )


def format_guidance_hint(items: list[GuidanceItem]) -> str:
    """Format guidance as a hint message for the next reasoning pass."""
    lines = [
        "<system-hint>",
        (
            "User guidance arrived while the current task was already "
            "running. Treat it as steering input, not a new task and not "
            "a cancellation. Keep working on the current task, adjust "
            "direction if relevant, and do not restart unless explicitly "
            "asked to. If the guidance implies concrete file, browser, "
            "shell, or other tool work, perform that work before giving "
            "the final response; do not merely acknowledge it."
        ),
        "</system-hint>",
        "<user-guidance>",
    ]
    for index, item in enumerate(items, start=1):
        source_bits = [f"time={_format_time(item.created_at)}"]
        if item.channel:
            source_bits.append(f"channel={item.channel}")
        if item.user_id:
            source_bits.append(f"user={item.user_id}")
        lines.append(f"[{index}] {' '.join(source_bits)}")
        lines.append(item.text)
    lines.append("</user-guidance>")
    return "\n".join(lines)
```

## 第 2 步：新增 `/guide` 控制命令

创建或覆盖：

```text
Lib\site-packages\qwenpaw\app\runner\control_commands\guide_handler.py
```

内容：

```python
# -*- coding: utf-8 -*-
"""Handler for /guide command."""

from __future__ import annotations

import logging

from .base import BaseControlCommandHandler, ControlContext
from ..guidance import (
    add_guidance,
    clear_guidance,
    is_guide_mode,
    pending_count,
    set_guide_mode,
)

logger = logging.getLogger(__name__)


class GuideCommandHandler(BaseControlCommandHandler):
    """Add non-interrupting guidance to the currently running task."""

    command_name = "/guide"

    async def _current_status(
        self,
        context: ControlContext,
    ) -> tuple[str | None, str]:
        workspace = context.workspace
        channel_id = context.channel.channel
        chat_manager = getattr(workspace, "chat_manager", None)
        if chat_manager is None:
            return None, "idle"
        chat_id = await chat_manager.get_chat_id_by_session(
            context.session_id,
            channel_id,
        )
        if chat_id is None:
            return None, "idle"
        status = await workspace.task_tracker.get_status(chat_id)
        return chat_id, status

    def _agent_id(self, context: ControlContext) -> str:
        return context.agent_id or getattr(context.workspace, "agent_id", "")

    def _usage(self) -> str:
        return (
            "**Guide Mode**\n\n"
            "- `/guide <内容>`：把这段内容作为当前任务的引导，不打断任务。\n"
            "- `/guide on`：开启引导模式。任务运行时，后续普通消息会被当作引导注入。\n"
            "- `/guide off`：关闭引导模式。\n"
            "- `/guide status`：查看模式、任务和待注入引导状态。\n"
            "- `/guide clear`：清空尚未被 Agent 吸收的引导。\n"
            "\n别名：`/g <内容>`、`/引导 on`、`/引导 off`。"
        )

    async def handle(self, context: ControlContext) -> str:
        raw_args = str(context.args.get("_raw_args") or "").strip()
        command_text, _, trailing_text = raw_args.partition("\n")
        command, _, inline_text = command_text.strip().partition(" ")
        command = command.lower()
        extra_text = "\n".join(
            part for part in (inline_text.strip(), trailing_text.strip()) if part
        )
        agent_id = self._agent_id(context)

        if not raw_args or command in {"help", "-h", "--help"}:
            return self._usage()

        if command in {"on", "enable", "start"}:
            set_guide_mode(agent_id, context.session_id, True)
            _, status = await self._current_status(context)
            parts = [
                "**Guide Mode On**",
                (
                    "Guide mode is enabled. While the current task is "
                    "running, normal messages will be injected as guidance "
                    "instead of starting a new task."
                ),
                f"Current task status: `{status}`.",
            ]
            if extra_text:
                if status == "running":
                    pending = add_guidance(
                        agent_id,
                        context.session_id,
                        extra_text,
                        channel=context.channel.channel,
                        user_id=context.user_id,
                    )
                    logger.info(
                        "/guide on: queued trailing guidance session=%s pending=%d",
                        context.session_id[:30],
                        pending,
                    )
                    parts.append(
                        "Extra text after `/guide on` was added as guidance. "
                        f"Pending guidance: `{pending}`."
                    )
                else:
                    parts.append(
                        "Extra text after `/guide on` was ignored because no "
                        "task is currently running. Send it again as a normal "
                        "message to start the task."
                    )
            return "\n\n".join(parts)

        if command in {"off", "disable", "stop"}:
            set_guide_mode(agent_id, context.session_id, False)
            return (
                "**Guide Mode Off**\n\n"
                "Guide mode is disabled. Normal messages will start normal tasks again."
            )

        if command == "status":
            _, status = await self._current_status(context)
            enabled = is_guide_mode(agent_id, context.session_id)
            pending = pending_count(agent_id, context.session_id)
            return (
                "**Guide Status**\n\n"
                f"- Mode: `{'on' if enabled else 'off'}`\n"
                f"- Current task: `{status}`\n"
                f"- Pending guidance: `{pending}`"
            )

        if command == "clear":
            removed = clear_guidance(agent_id, context.session_id)
            return (
                "**Guide Cleared**\n\n"
                f"Cleared `{removed}` pending guidance item(s)."
            )

        _, status = await self._current_status(context)
        if status != "running":
            return (
                "**No Running Task**\n\n"
                "There is no running task in this session, so this guidance was not injected."
            )

        pending = add_guidance(
            agent_id,
            context.session_id,
            raw_args,
            channel=context.channel.channel,
            user_id=context.user_id,
        )
        logger.info(
            "/guide: queued guidance session=%s pending=%d",
            context.session_id[:30],
            pending,
        )
        return (
            "**Guide Added**\n\n"
            "Added to the current task. It will be injected before the next reasoning step.\n\n"
            f"Pending guidance: `{pending}`."
        )


class GuideAliasCommandHandler(GuideCommandHandler):
    """Short alias for /guide."""

    command_name = "/g"


class ChineseGuideAliasCommandHandler(GuideCommandHandler):
    """Chinese alias for /guide."""

    command_name = "/引导"
```

## 第 3 步：注册控制命令

修改：

```text
Lib\site-packages\qwenpaw\app\runner\control_commands\__init__.py
```

找到已有 handler imports，在附近加入：

```python
from .guide_handler import (
    ChineseGuideAliasCommandHandler,
    GuideAliasCommandHandler,
    GuideCommandHandler,
)
```

找到 `_register_defaults()`，在其它命令注册前加入：

```python
    register_command(GuideCommandHandler())
    register_command(GuideAliasCommandHandler())
    register_command(ChineseGuideAliasCommandHandler())
```

找到 `__all__`，加入：

```python
    "ChineseGuideAliasCommandHandler",
    "GuideAliasCommandHandler",
    "GuideCommandHandler",
```

完成后用 Python 检查：

```powershell
$env:PYTHONDONTWRITEBYTECODE = "1"
& "D:\QwenPaw\python.exe" -c "from qwenpaw.app.runner import control_commands; key=chr(47)+chr(0x5f15)+chr(0x5bfc); print('/guide' in control_commands._COMMAND_REGISTRY, '/g' in control_commands._COMMAND_REGISTRY, key in control_commands._COMMAND_REGISTRY)"
```

期望输出：

```text
True True True
```

## 第 4 步：注册通道命令优先级

修改：

```text
Lib\site-packages\qwenpaw\app\channels\command_registry.py
```

找到内置命令注册处，通常能搜到：

```python
self.register_command("/approval", priority_level=10)
```

在其后加入：

```python
        # Guidance commands (non-interrupting steering)
        self.register_command("/guide", priority_level=10)
        self.register_command("/g", priority_level=10)
        self.register_command("/引导", priority_level=10)
```

如果当前函数使用的参数名不是 `priority_level`，要按原文件的 `register_command` 签名调整，但优先级必须和 `/stop`、`/approval` 一样高，确保它被当成控制命令识别。

## 第 5 步：新增 Console 侧通道 API

修改：

```text
Lib\site-packages\qwenpaw\app\routers\console.py
```

找到已有 `router` 和 console stream 路由。将下面 endpoint 放在同一个 router 文件里，通常放在已有 stream endpoint 后、其它 POST endpoint 前。

注意：该文件应已有 `Request`、`HTTPException`、`logger`、`get_agent_for_request`。如果缺失，按原项目风格导入，不要重复创建 router。

```python
@router.post(
    "/guide",
    status_code=200,
    summary="Add guidance to a running console chat",
)
async def post_console_guide(
    request_data: dict,
    request: Request,
) -> dict:
    """Queue guidance for the current running console task."""
    workspace = await get_agent_for_request(request)
    console_channel = await workspace.channel_manager.get_channel("console")
    if console_channel is None:
        raise HTTPException(
            status_code=503,
            detail="Channel Console not found",
        )

    raw_text = str(
        request_data.get("text") or request_data.get("query") or ""
    ).strip()
    if not raw_text:
        raise HTTPException(status_code=400, detail="Guidance text is empty")

    lowered = raw_text.lower()
    mode_only = lowered in {"/guide on", "/g on", "/引导 on"}
    if lowered.startswith("/guide "):
        raw_text = raw_text[7:].strip()
    elif lowered.startswith("/g "):
        raw_text = raw_text[3:].strip()
    elif lowered.startswith("/引导 "):
        raw_text = raw_text[4:].strip()

    mode_enabled = True
    if raw_text.lower() in {"on", "enable", "start"}:
        mode_only = True
        raw_text = ""
        mode_enabled = True
    elif raw_text.lower() in {"off", "disable", "stop"}:
        mode_only = True
        raw_text = ""
        mode_enabled = False

    if not raw_text and not mode_only:
        raise HTTPException(status_code=400, detail="Guidance text is empty")

    sender_id = str(request_data.get("user_id") or "default")
    requested_session_id = str(request_data.get("session_id") or "default")
    session_id = console_channel.resolve_session_id(
        sender_id=sender_id,
        channel_meta={
            "session_id": requested_session_id,
            "user_id": sender_id,
        },
    )

    chat_id = None
    status = "idle"
    chat_manager = getattr(workspace, "chat_manager", None)
    if chat_manager is not None:
        chat_id = await chat_manager.get_chat_id_by_session(session_id, "console")
    if chat_id:
        status = await workspace.task_tracker.get_status(chat_id)

    if status != "running":
        active = await workspace.task_tracker.list_active_tasks()
        if len(active) == 1 and chat_manager is not None:
            fallback_chat_id = active[0]
            fallback_chat = await chat_manager.get_chat(fallback_chat_id)
            if fallback_chat is not None:
                chat_id = fallback_chat_id
                session_id = fallback_chat.session_id
                sender_id = fallback_chat.user_id
                status = await workspace.task_tracker.get_status(chat_id)

    from ..runner.guidance import add_guidance, pending_count, set_guide_mode

    agent_id = getattr(workspace, "agent_id", "")
    set_guide_mode(agent_id, session_id, mode_enabled)

    if mode_only:
        pending = pending_count(agent_id, session_id)
        logger.info(
            "Console guide mode set: enabled=%s session=%s chat_id=%s "
            "status=%s pending=%d",
            mode_enabled,
            session_id[:30],
            chat_id,
            status,
            pending,
        )
        return {
            "ok": status == "running",
            "status": status,
            "pending": pending,
            "session_id": session_id,
            "chat_id": chat_id,
            "mode": "on" if mode_enabled else "off",
        }

    if status != "running":
        pending = pending_count(agent_id, session_id)
        logger.info(
            "Console guide ignored: session=%s chat_id=%s status=%s text=%r",
            session_id[:30],
            chat_id,
            status,
            raw_text,
        )
        return {
            "ok": False,
            "status": status,
            "pending": pending,
            "session_id": session_id,
            "chat_id": chat_id,
        }

    pending = add_guidance(
        agent_id,
        session_id,
        raw_text,
        channel="console",
        user_id=sender_id,
    )
    logger.info(
        "Console guide queued: session=%s chat_id=%s pending=%d text=%r",
        session_id[:30],
        chat_id,
        pending,
        raw_text,
    )
    return {
        "ok": True,
        "status": status,
        "pending": pending,
        "session_id": session_id,
        "chat_id": chat_id,
    }
```

QwenPaw 的 API 通常会把该 router 挂到 `/api/console`，因此实际 URL 是：

```text
POST /api/console/guide
```

## 第 6 步：后端通道兜底捕获普通消息

修改：

```text
Lib\site-packages\qwenpaw\app\channels\base.py
```

在通道基类里加入方法，位置建议放在 `_consume_with_tracker` 前面，保持和其它 helper 方法同级缩进：

```python
    async def _maybe_capture_guide_mode_message(
        self,
        request: "AgentRequest",
        payload: Any,
        chat_id: str,
    ) -> bool:
        """Turn normal input into guidance while guide mode is active."""
        if self._workspace is None:
            return False

        query_text = self._extract_query_from_payload(payload).strip()
        if not query_text or query_text.startswith("/"):
            return False

        session_id = getattr(request, "session_id", "") or ""
        agent_id = getattr(self._workspace, "agent_id", "")
        try:
            from ..runner.guidance import add_guidance, is_guide_mode

            if not is_guide_mode(agent_id, session_id):
                return False
        except Exception:
            logger.debug("Guide mode check failed", exc_info=True)
            return False

        status = await self._workspace.task_tracker.get_status(chat_id)
        if status != "running":
            return False

        pending = add_guidance(
            agent_id,
            session_id,
            query_text,
            channel=getattr(request, "channel", self.channel),
            user_id=getattr(request, "user_id", "") or "",
        )
        logger.info(
            "Guide mode captured normal message: chat_id=%s session=%s pending=%d",
            chat_id,
            session_id[:30],
            pending,
        )

        if isinstance(payload, dict):
            send_meta = dict(payload.get("meta") or {})
            if payload.get("session_webhook"):
                send_meta["session_webhook"] = payload["session_webhook"]
        else:
            send_meta = getattr(request, "channel_meta", None) or {}
        bot_prefix = getattr(self, "bot_prefix", None) or getattr(
            self,
            "_bot_prefix",
            "",
        )
        if bot_prefix and "bot_prefix" not in send_meta:
            send_meta = {**send_meta, "bot_prefix": bot_prefix}

        to_handle = self.get_to_handle_from_request(request)
        try:
            await self.send(
                to_handle,
                (
                    "**Guide Added**\n\n"
                    "已加入当前任务，会在下一次推理前被吸收。\n\n"
                    f"待注入引导：`{pending}`。"
                ),
                send_meta,
            )
        except Exception:
            logger.debug("Failed to send guide-mode ack", exc_info=True)
        return True
```

然后在 `_consume_with_tracker()` 中，找到 `chat = await self._workspace.chat_manager.get_or_create_chat(...)` 以及随后 `task_tracker.attach_or_start(...)` 的位置。必须在 `attach_or_start` 前加入：

```python
        if await self._maybe_capture_guide_mode_message(
            request,
            payload,
            chat.id,
        ):
            return
```

这样即使 Desktop 前端没有走侧通道，普通 channel 入口也会在 guide mode 开启且任务正在运行时把普通输入改成 guidance。

## 第 7 步：Agent 推理前注入引导，并防止只说不做

修改：

```text
Lib\site-packages\qwenpaw\agents\react_agent.py
```

找到主 agent 类里已有的 `_reasoning()` 方法。不要整段重写原逻辑，只做插入。

### 7.1 添加两个 helper 方法

把下面两个方法加入同一个类内，位置建议放在 `_reasoning()` 前。缩进必须和 `_reasoning()` 一致。

```python
    async def _force_guidance_action_if_text_only(
        self,
        msg: Msg,
        tool_choice: Literal["auto", "none", "required"] | None,
    ) -> Msg:
        """Force one tool-seeking pass after live guidance if model stops."""
        if msg is None or msg.has_content_blocks("tool_use"):
            return msg
        if tool_choice == "none":
            return msg

        setattr(self, "_guidance_action_pending", False)
        tail = self._auto_continue_tail_context(
            msg,
            self._AUTO_CONTINUE_TAIL_CHARS,
        )
        guidance_hint = str(
            getattr(self, "_last_guidance_action_hint", "") or "",
        )
        guidance_hint = guidance_hint[-4000:].lstrip()
        hint_body = (
            "<system-hint>\n"
            "Live user guidance was injected while the task was running, "
            "but the previous assistant response did not call any tool. "
            "If that guidance asks for a concrete action such as creating, "
            "copying, editing, renaming, reading, browsing, or shell/file "
            "work, perform it now with the available tools before giving a "
            "final answer. Do not merely acknowledge or summarize the "
            "guidance. If no tool action is actually required, answer briefly.\n"
            "</system-hint>"
        )
        if guidance_hint:
            hint_body += (
                "\n\n<live-guidance-to-satisfy>\n"
                f"{guidance_hint}\n"
                "</live-guidance-to-satisfy>"
            )
        if tail:
            hint_body += (
                "\n\n<previous-assistant-tail>\n"
                f"{tail}\n"
                "</previous-assistant-tail>"
            )

        logger.info(
            "Guidance action guard: text-only after guidance; "
            "forcing _reasoning tool_choice='required'",
        )
        await self.memory.add(Msg("user", hint_body, "user"), marks=_MemoryMark.HINT)
        try:
            next_msg = await super()._reasoning(tool_choice="required")
        except Exception:
            logger.warning(
                "Guidance action guard required _reasoning failed; "
                "retrying with original tool_choice=%r",
                tool_choice,
                exc_info=True,
            )
            try:
                next_msg = await super()._reasoning(tool_choice=tool_choice)
            except Exception:
                logger.warning(
                    "Guidance action guard fallback _reasoning failed; "
                    "keeping prior response",
                    exc_info=True,
                )
                return msg

        if next_msg.has_content_blocks("tool_use"):
            return next_msg

        logger.info(
            "Guidance action guard still text-only; keeping prior response",
        )
        return msg

    async def _inject_guidance_hints(self) -> bool:
        """Inject pending non-interrupting user guidance before reasoning."""
        request_context = getattr(self, "_request_context", {}) or {}
        session_id = request_context.get("session_id", "")
        agent_id = request_context.get("agent_id", "")
        if not session_id:
            return False
        try:
            from ..app.runner.guidance import (
                drain_guidance,
                format_guidance_hint,
            )

            guidance_items = drain_guidance(agent_id, session_id)
        except Exception:
            logger.debug("Failed to drain guidance", exc_info=True)
            return False
        if not guidance_items:
            return False
        formatted_hint = format_guidance_hint(guidance_items)
        hint_msg = Msg(
            "user",
            formatted_hint,
            "user",
        )
        await self.memory.add(hint_msg, marks=_MemoryMark.HINT)
        setattr(self, "_guidance_action_pending", True)
        setattr(self, "_last_guidance_action_hint", formatted_hint)
        logger.info(
            "Injected %d guidance item(s) into session=%s",
            len(guidance_items),
            session_id[:30],
        )
        return True
```

如果当前文件没有 `Literal`、`Msg` 或 `_MemoryMark` 名称，要按原项目已有 imports 补齐。不要重复定义这些类。

### 7.2 在 `_reasoning()` 开始处注入

在 `_reasoning()` 方法体开始、调用 `super()._reasoning(...)` 之前，加入：

```python
        guidance_injected = await self._inject_guidance_hints()
```

### 7.3 在 `_reasoning()` 返回前加入 action guard

找到 `_reasoning()` 正常返回的位置。常见形态：

```python
        return await self._auto_continue_if_text_only(msg, tool_choice)
```

改成：

```python
        guidance_action_pending = bool(
            getattr(self, "_guidance_action_pending", False),
        )
        if guidance_injected or guidance_action_pending:
            msg = await self._force_guidance_action_if_text_only(
                msg,
                tool_choice,
            )
        return await self._auto_continue_if_text_only(msg, tool_choice)
```

如果当前版本直接 `return msg`，改成：

```python
        guidance_action_pending = bool(
            getattr(self, "_guidance_action_pending", False),
        )
        if guidance_injected or guidance_action_pending:
            msg = await self._force_guidance_action_if_text_only(
                msg,
                tool_choice,
            )
        return msg
```

关键要求：凡是一次正常 `_reasoning()` 得到 `msg` 后准备返回，都要先经过这段 guard。否则模型可能收到引导但只文字回复。

## 第 8 步：修改 Desktop 前端，让运行中输入能发送引导而不是 stop

QwenPaw Desktop 前端一般是打包后的静态文件：

```text
Lib\site-packages\qwenpaw\console\index.html
Lib\site-packages\qwenpaw\console\assets\*.js
```

### 8.1 找到输入组件所在 bundle

在 assets 里搜索：

```powershell
Select-String -LiteralPath "$QwenPawRoot\Lib\site-packages\qwenpaw\console\assets\*.js" -Pattern "chat-anywhere-input","getPrefixCls(`"sender`")","onCancel","loading"
```

通常需要修改的文件是较大的 vendor bundle，例如：

```text
ui-vendor-xxxx.js
```

不要假设文件名固定。以搜索结果为准。

### 8.2 前端必须实现的逻辑

无论原始代码结构如何，最终必须满足这些行为：

1. 当用户输入 `/guide on` 或 `/引导 on` 并发送后，把 `qwenpaw_guide_mode=on` 写入 `sessionStorage` 和 `localStorage`。
2. 当用户输入 `/guide off` 或 `/引导 off` 并发送后，删除两个 storage 里的 `qwenpaw_guide_mode`。
3. 当任务正在运行时，如果输入框有内容，且 guide mode 为 on，或者文本以 `/g`、`/guide`、`/引导` 开头，发送键/回车应调用：

```text
POST /api/console/guide
```

而不是调用 cancel/stop。

4. side-channel 请求体：

```json
{
  "text": "用户当前输入内容",
  "session_id": "当前会话 id",
  "user_id": "当前用户 id",
  "channel": "console"
}
```

5. 请求头：

```js
{
  "Content-Type": "application/json",
  "Authorization": "Bearer " + localStorage.getItem("qwenpaw_auth_token") // 有 token 才加
}
```

如果能从 `qwenpaw-agent-storage` 取到 selectedAgent，则加：

```js
headers["X-Agent-Id"] = selectedAgent;
```

6. 发送成功后清空输入框和附件列表，并显示一个短提示，例如“引导已加入当前任务：xxx”。

### 8.3 可直接嵌入 bundle 的 helper 逻辑

如果只能改打包 JS，可以在输入组件所在 bundle 顶部或输入组件闭包附近加入等价 helper。变量名可按 bundle 调整，但逻辑必须等价：

```js
function qwenpawGuideModeEnabled() {
  try {
    return sessionStorage.getItem("qwenpaw_guide_mode") === "on" ||
      localStorage.getItem("qwenpaw_guide_mode") === "on";
  } catch (_) {
    return false;
  }
}

function qwenpawRememberGuideMode(text) {
  var q = String(text || "").trim();
  try {
    if (/^\/(?:guide|引导)\s+on(?:\s|$)/i.test(q)) {
      sessionStorage.setItem("qwenpaw_guide_mode", "on");
      localStorage.setItem("qwenpaw_guide_mode", "on");
    } else if (/^\/(?:guide|引导)\s+(?:off|disable)(?:\s|$)/i.test(q)) {
      sessionStorage.removeItem("qwenpaw_guide_mode");
      localStorage.removeItem("qwenpaw_guide_mode");
    }
  } catch (_) {}
}

function qwenpawIsGuideCommand(text) {
  return /^\/(?:g|guide|引导)(?:\s|$)/i.test(String(text || "").trim());
}

function qwenpawShouldSideChannelGuide(text, loading) {
  var q = String(text || "").trim();
  return !!q && !!loading && (qwenpawGuideModeEnabled() || qwenpawIsGuideCommand(q));
}

function qwenpawGuideToast(text, isError) {
  try {
    var el = document.createElement("div");
    el.textContent = text;
    el.style.cssText =
      "position:fixed;left:50%;bottom:92px;transform:translateX(-50%);" +
      "z-index:2147483647;max-width:min(680px,calc(100vw - 32px));" +
      "padding:10px 14px;border-radius:8px;background:" +
      (isError ? "rgba(185,28,28,.94)" : "rgba(31,41,55,.94)") +
      ";color:#fff;font-size:13px;line-height:1.45;" +
      "box-shadow:0 12px 32px rgba(0,0,0,.22);transition:opacity .25s ease;";
    document.body.appendChild(el);
    setTimeout(function () {
      el.style.opacity = "0";
      setTimeout(function () {
        if (el && el.parentNode) el.parentNode.removeChild(el);
      }, 280);
    }, 2400);
  } catch (_) {}
}

function qwenpawCurrentSessionId() {
  try {
    if (window.currentSessionId) return window.currentSessionId;
  } catch (_) {}
  try {
    var m = location.pathname.match(/\/chat\/([^/?#]+)/);
    if (m && m[1]) return decodeURIComponent(m[1]);
  } catch (_) {}
  return "";
}

function qwenpawCurrentUserId() {
  try {
    return window.currentUserId || "default";
  } catch (_) {
    return "default";
  }
}

function qwenpawGuideHeaders() {
  var headers = {"Content-Type": "application/json"};
  try {
    var token = localStorage.getItem("qwenpaw_auth_token");
    if (token) headers.Authorization = "Bearer " + token;
  } catch (_) {}
  try {
    var raw = sessionStorage.getItem("qwenpaw-agent-storage") ||
      localStorage.getItem("qwenpaw-agent-storage");
    if (raw) {
      var parsed = JSON.parse(raw);
      var agent = parsed && parsed.state && parsed.state.selectedAgent;
      if (agent) headers["X-Agent-Id"] = agent;
    }
  } catch (_) {}
  return headers;
}

function qwenpawPostGuide(text) {
  var q = String(text || "").trim();
  if (!q) return Promise.resolve(false);
  try {
    var now = Date.now();
    var last = window.qwenpaw_last_guide || {};
    if (last.text === q && now - last.time < 1500) {
      return Promise.resolve(true);
    }
    window.qwenpaw_last_guide = {text: q, time: now};
  } catch (_) {}

  return fetch("/api/console/guide", {
    method: "POST",
    headers: qwenpawGuideHeaders(),
    body: JSON.stringify({
      text: q,
      session_id: qwenpawCurrentSessionId(),
      user_id: qwenpawCurrentUserId(),
      channel: "console"
    })
  })
    .then(function (res) {
      return res.json().catch(function () {
        return {ok: res.ok, status: res.status};
      });
    })
    .then(function (data) {
      if (data && data.ok) {
        qwenpawGuideToast("引导已加入当前任务：" + q, false);
        return true;
      }
      qwenpawGuideToast("当前没有运行中的任务，引导未加入", true);
      return false;
    })
    .catch(function () {
      qwenpawGuideToast("引导发送失败，请重试", true);
      return false;
    });
}
```

### 8.4 修改输入 submit/cancel 入口

在输入组件的 submit 函数开头加入等价逻辑：

```js
var q = getCurrentInputText().trim();
qwenpawRememberGuideMode(q);
if (qwenpawShouldSideChannelGuide(q, isCurrentlyLoading())) {
  qwenpawPostGuide(q);
  clearInputText();
  clearAttachmentsIfAny();
  return;
}
```

具体到 minified bundle，要把 `getCurrentInputText()`、`isCurrentlyLoading()`、`clearInputText()` 替换成该闭包里的真实变量。

当前已验证版本里的变量形态曾经类似：

```js
var B=i().trim();
var loading = !!l.loading || !!window.qwenpaw_chat_loading;
...
a("");
C && C([]);
```

其中：

- `i()` 是取输入框文本。
- `a("")` 是清空输入框。
- `C && C([])` 是清空附件。
- `l.loading` 是当前聊天 loading 状态。

如果 bundle 里还有另一个 Sender 组件，也必须改它的 send 函数。搜索这些特征：

```text
getPrefixCls("sender")
onCancel
onPressEnter
onSend
```

在它的 send 函数开头加入同样逻辑。当前已验证版本里另一个组件的变量形态曾经类似：

```js
var Ze = Oe && Oe.trim();
if (S && Ze) {
  if (qwenpawGuideModeEnabled() || qwenpawIsGuideCommand(Ze)) {
    qwenpawPostGuide(Ze);
    Ee("");
    return;
  }
}
```

并且 Enter 键判断不能因为 loading 而禁止：

```js
var allowEnter = !compositionActive && (!dropdownOpen || (loading && inputText && isGuideEligible(inputText)));
```

### 8.5 修改 loading 按钮显示

如果原组件在 loading 时把发送按钮变成 stop/cancel，需要让“输入框有内容且符合 guide 条件”时仍表现为发送。

当前已验证思路：

```js
loading: l.loading && !(
  inputText.trim() &&
  (qwenpawGuideModeEnabled() || qwenpawIsGuideCommand(inputText))
)
```

如果不改这个，用户在任务运行时输入 `/g` 或普通引导，按钮可能仍是 stop，导致点击时取消任务。

### 8.6 缓存刷新

修改 `console/index.html`，给被改过的 JS asset URL 加版本参数，防止 Desktop 继续用旧缓存。

示例：

```html
<script type="module" crossorigin src="/assets/ui-vendor-xxxx.js?v=guide-YYYYMMDD-HHMM"></script>
```

如果原文件名带 hash，不要改文件名，只加 query 参数。

## 第 9 步：清理 Python 缓存

修改 Python 文件后清掉相关 `__pycache__`：

```powershell
$CacheDirs = @(
  "$QwenPawRoot\Lib\site-packages\qwenpaw\app\runner\__pycache__",
  "$QwenPawRoot\Lib\site-packages\qwenpaw\app\runner\control_commands\__pycache__",
  "$QwenPawRoot\Lib\site-packages\qwenpaw\app\routers\__pycache__",
  "$QwenPawRoot\Lib\site-packages\qwenpaw\app\channels\__pycache__",
  "$QwenPawRoot\Lib\site-packages\qwenpaw\agents\__pycache__"
)
foreach ($Dir in $CacheDirs) {
  if (Test-Path -LiteralPath $Dir) {
    Remove-Item -LiteralPath $Dir -Recurse -Force
  }
}
```

这一步只删除 Python 字节码缓存，不删除源码。

## 第 10 步：静态校验

### 10.1 Python 导入校验

```powershell
$env:PYTHONDONTWRITEBYTECODE = "1"
& "$QwenPawRoot\python.exe" -c "from qwenpaw.app.runner import control_commands; key=chr(47)+chr(0x5f15)+chr(0x5bfc); print(sorted(k for k in control_commands._COMMAND_REGISTRY if k in ['/guide','/g',key])); print(key in control_commands._COMMAND_REGISTRY)"
```

期望至少包含：

```text
['/g', '/guide', '/引导']
True
```

### 10.2 搜索关键锚点

```powershell
Select-String -LiteralPath "$QwenPawRoot\Lib\site-packages\qwenpaw\app\routers\console.py" -Pattern "Console guide queued"
Select-String -LiteralPath "$QwenPawRoot\Lib\site-packages\qwenpaw\agents\react_agent.py" -Pattern "Injected","Guidance action guard"
Select-String -LiteralPath "$QwenPawRoot\Lib\site-packages\qwenpaw\console\assets\*.js" -Pattern "/api/console/guide"
```

三类搜索都必须有结果。

## 第 11 步：启动和 API 校验

启动 QwenPaw Desktop，或者运行原来的启动脚本。

常见启动文件：

```text
D:\QwenPaw\QwenPaw Desktop.vbs
D:\QwenPaw\QwenPaw Desktop.bat
```

检查端口，常见是 `8088`。然后测试侧通道。注意中文 body 用 UTF-8 bytes：

```powershell
$Body = @{
  text = "/引导 on"
  session_id = "guide_probe"
  user_id = "default"
  channel = "console"
} | ConvertTo-Json -Compress

Invoke-RestMethod `
  -Uri "http://127.0.0.1:8088/api/console/guide" `
  -Method Post `
  -ContentType "application/json; charset=utf-8" `
  -Body ([System.Text.Encoding]::UTF8.GetBytes($Body))
```

没有运行中任务时，返回可能是：

```json
{
  "ok": false,
  "status": "idle",
  "pending": 0,
  "mode": "on"
}
```

这不算失败。它表示命令解析成功，只是当前没有 running task。

## 第 12 步：真实运行验收

打开 QwenPaw Desktop，按下面顺序测试：

1. 输入 `/引导 on`，回车。
2. 输入：`在桌面创建个 B.txt，放进今天科技新闻 3 条`。
3. 等任务开始运行，中途输入：`再复制一份命名为 C`，回车。
4. 等任务结束。
5. 检查桌面是否出现 `B.txt` 和 `C.txt`。
6. 检查日志：

```powershell
Select-String -LiteralPath "$env:USERPROFILE\.qwenpaw\qwenpaw.log" -Pattern "Console guide queued","Injected","Guidance action guard","Handle agent query" | Select-Object -Last 80
```

判定标准：

- 有 `Console guide queued`，说明 Desktop 运行中输入进入了侧通道。
- 有 `Injected 1 guidance item(s)`，说明 agent 在同一轮任务里吸收了引导。
- 如果引导涉及文件/浏览器/shell 等具体动作，且模型一开始想只输出文字，应看到 `Guidance action guard`。
- 在主任务开始和结束之间，不应有第二个普通 `Handle agent query` 对应“再复制一份命名为 C”。如果有第二个，说明它变成顺序执行，不是引导。

日志里的中文可能因 Windows 控制台编码显示成乱码。不要用中文日志文本作为唯一判断依据，优先看英文锚点。

## 常见失败与修复

### `/引导 on` 不识别

检查：

```powershell
$env:PYTHONDONTWRITEBYTECODE = "1"
& "$QwenPawRoot\python.exe" -c "from qwenpaw.app.runner import control_commands; key=chr(47)+chr(0x5f15)+chr(0x5bfc); print(key in control_commands._COMMAND_REGISTRY)"
```

如果输出 `False`：

- `guide_handler.py` 没有 `ChineseGuideAliasCommandHandler`。
- `control_commands/__init__.py` 没 import 或没 register。
- Python `__pycache__` 没清。

### Desktop 运行中回车还是 stop

说明前端 bundle 没改全。重新搜索：

```powershell
Select-String -LiteralPath "$QwenPawRoot\Lib\site-packages\qwenpaw\console\assets\*.js" -Pattern "/api/console/guide"
```

如果没结果，前端完全没改进去。

如果有结果但还是 stop：

- 另一个 Sender/Input 组件没改。
- loading button 的 `loading` 条件没排除 guide 输入。
- Enter 键处理仍因 loading 被阻断。
- `index.html` 没 cache-bust，Desktop 仍在加载旧 bundle。

### API 能进，但日志没有 `Injected`

说明引导入队了，但 agent 没在 `_reasoning()` 前 drain：

- 检查 `react_agent.py` 是否在 `_reasoning()` 开头调用 `_inject_guidance_hints()`。
- 检查 agent request context 是否有 `session_id` 和 `agent_id`。
- 检查入队时的 session_id 和 agent 运行时 session_id 是否一致。Console endpoint 中的 active task fallback 是为了解决这个问题，不能删。

### 有 `Injected`，但没有执行引导动作

说明模型吸收了引导但文字停了：

- 检查 `react_agent.py` 是否有 `_force_guidance_action_if_text_only()`。
- 检查 `_reasoning()` 返回前是否调用了这个 guard。
- 检查日志是否有 `Guidance action guard`。

### API 中文变成 `/?? on`

这是请求编码问题。PowerShell 直接传中文字符串可能按本地编码发出。测试 API 时使用：

```powershell
-ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($Body))
```

前端 `fetch(... JSON.stringify(...))` 正常情况下是 UTF-8，不需要额外处理。

## 最终交付要求

执行完成后，AI 必须向用户报告：

1. QwenPaw 安装目录。
2. 备份目录。
3. 修改过的文件列表。
4. 静态校验结果。
5. 真实运行测试结果。
6. 如果没能做真实运行测试，必须明确说明原因和剩余风险。

最终不要只说“已修改”。必须说明是否确认：

```text
这次是引导注入，不是顺序执行。
```

并给出日志证据，例如：

```text
Console guide queued -> Injected 1 guidance item(s) -> Guidance action guard
```

