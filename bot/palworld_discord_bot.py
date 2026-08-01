#!/usr/bin/env python3
"""Restricted Discord control surface for Palworld Oracle."""

from __future__ import annotations

import asyncio
import base64
import binascii
import logging
import math
import os
import re
import secrets
import stat
import time
from contextlib import suppress
from dataclasses import dataclass
from pathlib import Path

import discord
from discord import app_commands

from palworld_status import (
    format_bytes,
    format_cpu,
    format_duration,
    metrics_age,
    read_prometheus,
)


LOGGER = logging.getLogger("palworld-discord")
PALWORLD_UNIT = "palworld.service"
MAINTENANCE_UNIT = "palworld-maintenance-restart.service"
SYSTEMCTL = "/usr/bin/systemctl"
READY_PATH = Path("/run/palworld-discord/ready")
RESTART_REQUEST_PATH = Path("/run/palworld-discord/restart.request")
ESCAPE_REQUEST_PATH = Path("/run/palworld-discord/escape.request")
LOG_CHANNEL_PATH = Path("/var/lib/palworld-discord/log-channel-id")
PLAYER_ID_PATTERN = re.compile(r"[!-~]{1,128}")
ESCAPE_PLAYER_ID_PATTERN = re.compile(r"steam_[0-9]{17}")
PLAYER_SNAPSHOT_MAX_BYTES = 16 * 1024
PLAYER_DIRECTORY_MAX_BYTES = 16 * 1024


def required_snowflake(name: str) -> int:
    serialized = os.environ.get(name, "")
    if not re.fullmatch(r"[1-9][0-9]{5,18}", serialized):
        raise RuntimeError(f"{name} must be a Discord snowflake")
    value = int(serialized)
    if value >= 2**64:
        raise RuntimeError(f"{name} is outside the Discord snowflake range")
    return value


def positive_integer(name: str, default: int, maximum: int) -> int:
    serialized = os.environ.get(name, str(default))
    if not serialized.isdecimal():
        raise RuntimeError(f"{name} must be a positive integer")
    value = int(serialized)
    if value < 1 or value > maximum:
        raise RuntimeError(f"{name} must be between 1 and {maximum}")
    return value


def read_token() -> str:
    credentials_directory = os.environ.get("CREDENTIALS_DIRECTORY", "")
    if not credentials_directory:
        raise RuntimeError("CREDENTIALS_DIRECTORY is not set")
    token_path = Path(credentials_directory) / "discord-token"
    token = token_path.read_text(encoding="utf-8").strip()
    if not re.fullmatch(r"[A-Za-z0-9._-]{32,256}", token):
        raise RuntimeError("Discord token credential is invalid")
    return token


def clear_ready_marker() -> None:
    READY_PATH.unlink(missing_ok=True)


def write_ready_marker() -> None:
    temporary = READY_PATH.with_name(f".ready.{os.getpid()}")
    descriptor = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC,
        0o600,
    )
    try:
        os.write(descriptor, b"ready\n")
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.replace(temporary, READY_PATH)


def read_log_channel_id() -> int | None:
    try:
        descriptor = os.open(
            LOG_CHANNEL_PATH,
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
        )
    except FileNotFoundError:
        return None
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 32:
            raise ValueError("stored log channel setting is not a small regular file")
        serialized = os.read(descriptor, 32)
        if os.read(descriptor, 1):
            raise ValueError("stored log channel ID is too long")
    finally:
        os.close(descriptor)

    value_text = serialized.decode("ascii").strip()
    if not re.fullmatch(r"[1-9][0-9]{5,18}", value_text):
        raise ValueError("stored log channel ID is invalid")
    value = int(value_text)
    if value >= 2**64:
        raise ValueError("stored log channel ID is outside the snowflake range")
    return value


def write_log_channel_id(channel_id: int) -> None:
    temporary = LOG_CHANNEL_PATH.with_name(
        f".log-channel-id.{os.getpid()}.{secrets.token_hex(8)}"
    )
    try:
        descriptor = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
            0o600,
        )
        try:
            payload = f"{channel_id}\n".encode("ascii")
            written = 0
            while written < len(payload):
                count = os.write(descriptor, payload[written:])
                if count == 0:
                    raise OSError("could not write log channel setting")
                written += count
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        os.replace(temporary, LOG_CHANNEL_PATH)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise

    directory = os.open(
        LOG_CHANNEL_PATH.parent,
        os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC,
    )
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def read_player_snapshot(path: Path) -> tuple[float, frozenset[str], float]:
    descriptor = os.open(
        path,
        os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
    )
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError("player snapshot is not a regular file")
        if metadata.st_size > PLAYER_SNAPSHOT_MAX_BYTES:
            raise ValueError("player snapshot exceeds the size limit")
        chunks: list[bytes] = []
        size = 0
        while True:
            chunk = os.read(descriptor, 4096)
            if not chunk:
                break
            size += len(chunk)
            if size > PLAYER_SNAPSHOT_MAX_BYTES:
                raise ValueError("player snapshot exceeds the size limit")
            chunks.append(chunk)
    finally:
        os.close(descriptor)

    lines = b"".join(chunks).decode("ascii").splitlines()
    if len(lines) < 2 or lines[0] != "PALWORLD_PLAYER_SNAPSHOT_V1":
        raise ValueError("player snapshot header is invalid")
    if not lines[1].startswith("uptime="):
        raise ValueError("player snapshot uptime is missing")
    server_uptime = float(lines[1].removeprefix("uptime="))
    if not math.isfinite(server_uptime) or server_uptime < 0:
        raise ValueError("player snapshot uptime is invalid")

    player_ids: set[str] = set()
    for line in lines[2:]:
        if not line.startswith("id="):
            raise ValueError("player snapshot entry is invalid")
        player_id = line.removeprefix("id=")
        if not PLAYER_ID_PATTERN.fullmatch(player_id):
            raise ValueError("player snapshot userId is invalid")
        if player_id in player_ids:
            raise ValueError("player snapshot repeats a userId")
        player_ids.add(player_id)
    return server_uptime, frozenset(player_ids), metadata.st_mtime


@dataclass(frozen=True)
class PlayerDirectoryEntry:
    user_id: str
    name: str


def read_player_directory(
    path: Path,
) -> tuple[float, tuple[PlayerDirectoryEntry, ...], float]:
    descriptor = os.open(
        path,
        os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
    )
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise ValueError("player directory is not a regular file")
        if metadata.st_size > PLAYER_DIRECTORY_MAX_BYTES:
            raise ValueError("player directory exceeds the size limit")
        chunks: list[bytes] = []
        size = 0
        while True:
            chunk = os.read(descriptor, 4096)
            if not chunk:
                break
            size += len(chunk)
            if size > PLAYER_DIRECTORY_MAX_BYTES:
                raise ValueError("player directory exceeds the size limit")
            chunks.append(chunk)
    finally:
        os.close(descriptor)

    lines = b"".join(chunks).decode("utf-8").splitlines()
    if len(lines) < 2 or lines[0] != "PALWORLD_PLAYER_DIRECTORY_V1":
        raise ValueError("player directory header is invalid")
    if not lines[1].startswith("uptime="):
        raise ValueError("player directory uptime is missing")
    server_uptime = float(lines[1].removeprefix("uptime="))
    if not math.isfinite(server_uptime) or server_uptime < 0:
        raise ValueError("player directory uptime is invalid")

    players: list[PlayerDirectoryEntry] = []
    player_ids: set[str] = set()
    for line in lines[2:]:
        prefix, separator, encoded_name = line.partition(" name_b64=")
        if not separator or not prefix.startswith("id="):
            raise ValueError("player directory entry is invalid")
        player_id = prefix.removeprefix("id=")
        if not PLAYER_ID_PATTERN.fullmatch(player_id):
            raise ValueError("player directory userId is invalid")
        if player_id in player_ids:
            raise ValueError("player directory repeats a userId")
        try:
            name = base64.b64decode(encoded_name, validate=True).decode("utf-8")
        except (binascii.Error, UnicodeError) as error:
            raise ValueError("player directory nickname is invalid") from error
        if not name or len(name) > 256 or any(
            ord(character) < 0x20 or ord(character) == 0x7F
            for character in name
        ):
            raise ValueError("player directory nickname is invalid")
        player_ids.add(player_id)
        players.append(PlayerDirectoryEntry(user_id=player_id, name=name))
    return server_uptime, tuple(players), metadata.st_mtime


GUILD_ID = required_snowflake("PALWORLD_DISCORD_GUILD_ID")
CHANNEL_ID = required_snowflake("PALWORLD_DISCORD_CHANNEL_ID")
METRICS_PATH = Path(
    os.environ.get(
        "PALWORLD_DISCORD_METRICS_FILE",
        "/var/lib/palworld-observer/palworld.prom",
    )
)
METRICS_MAX_AGE = positive_integer(
    "PALWORLD_DISCORD_METRICS_MAX_AGE_SECONDS", 30, 3600
)
PLAYER_SNAPSHOT_PATH = Path(
    os.environ.get(
        "PALWORLD_DISCORD_PLAYER_SNAPSHOT_FILE",
        "/var/lib/palworld-observer/players.snapshot",
    )
)
PLAYER_SNAPSHOT_MAX_AGE = positive_integer(
    "PALWORLD_DISCORD_PLAYER_SNAPSHOT_MAX_AGE_SECONDS", 30, 3600
)
PLAYER_DIRECTORY_PATH = Path(
    os.environ.get(
        "PALWORLD_DISCORD_PLAYER_DIRECTORY_FILE",
        "/var/lib/palworld-observer/player-directory.snapshot",
    )
)
PLAYER_WATCH_INTERVAL = positive_integer(
    "PALWORLD_DISCORD_PLAYER_WATCH_INTERVAL_SECONDS", 2, 60
)
COMMAND_TIMEOUT = positive_integer(
    "PALWORLD_DISCORD_COMMAND_TIMEOUT_SECONDS", 840, 840
)
ESCAPE_TIMEOUT = positive_integer(
    "PALWORLD_DISCORD_ESCAPE_TIMEOUT_SECONDS", 30, 120
)


async def systemctl_properties(unit: str, *properties: str) -> dict[str, str]:
    arguments = [SYSTEMCTL, "show", unit]
    arguments.extend(f"--property={name}" for name in properties)
    process = await asyncio.create_subprocess_exec(
        *arguments,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )
    try:
        stdout, _ = await asyncio.wait_for(process.communicate(), timeout=10)
    except asyncio.TimeoutError:
        process.kill()
        await process.wait()
        raise
    if process.returncode != 0:
        raise RuntimeError(f"could not query {unit}")
    result: dict[str, str] = {}
    for line in stdout.decode("utf-8", errors="replace").splitlines():
        key, separator, value = line.partition("=")
        if separator:
            result[key] = value
    return result


async def interaction_in_scope(
    interaction: discord.Interaction, command_name: str
) -> bool:
    if interaction.guild_id != GUILD_ID or interaction.channel_id != CHANNEL_ID:
        await interaction.response.send_message(
            "이 명령어는 등록된 서버 관리 채널에서만 사용할 수 있습니다.",
            ephemeral=True,
        )
        await audit_command(
            interaction,
            command_name,
            "거부됨",
            "등록된 서버 관리 채널 밖에서 실행했습니다.",
        )
        return False
    return True


async def interaction_in_configured_guild(
    interaction: discord.Interaction, command_name: str
) -> bool:
    if interaction.guild_id != GUILD_ID:
        await interaction.response.send_message(
            "이 명령어는 등록된 Discord 서버에서만 사용할 수 있습니다.",
            ephemeral=True,
        )
        await audit_command(
            interaction,
            command_name,
            "거부됨",
            "등록된 Discord 서버 밖에서 실행했습니다.",
        )
        return False
    return True


def is_audit_admin(interaction: discord.Interaction) -> bool:
    member = interaction.user
    if not isinstance(member, discord.Member):
        return False
    return member.id == member.guild.owner_id or member.guild_permissions.administrator


def metric(metrics: dict[str, float], name: str) -> float | None:
    return metrics.get(name)


async def build_status_embed() -> discord.Embed:
    service = await systemctl_properties(PALWORLD_UNIT, "ActiveState", "SubState")
    maintenance = await systemctl_properties(MAINTENANCE_UNIT, "ActiveState")
    active = service.get("ActiveState") == "active"
    maintenance_active = maintenance.get("ActiveState") in {"activating", "active"}
    maintenance_queued = RESTART_REQUEST_PATH.exists()
    colour = discord.Colour.green() if active else discord.Colour.red()
    embed = discord.Embed(
        title="Palworld 서버 상태",
        colour=colour,
        timestamp=discord.utils.utcnow(),
    )
    embed.add_field(
        name="서비스",
        value=(
            f"{'ONLINE' if active else 'OFFLINE'} "
            f"(`{service.get('SubState', 'unknown')}`)"
        ),
        inline=True,
    )
    embed.add_field(
        name="업데이트/재기동",
        value=(
            "진행 중"
            if maintenance_active
            else "요청 대기 중"
            if maintenance_queued
            else "대기 중"
        ),
        inline=True,
    )
    if not active:
        embed.description = "서버가 실행 중이 아니므로 이전 성능값은 표시하지 않습니다."
        return embed

    try:
        metrics, modified = read_prometheus(METRICS_PATH)
        age = metrics_age(metrics, modified)
    except (OSError, UnicodeError, ValueError) as error:
        LOGGER.warning("observer metrics unavailable: %s", error)
        embed.description = "성능 관측값을 읽을 수 없습니다."
        return embed

    if age > METRICS_MAX_AGE:
        embed.description = (
            f"성능 관측값이 {age:.0f}초 전에 수집되어 현재 값으로 표시하지 않습니다."
        )
        return embed

    players = metric(metrics, "palworld_current_players")
    max_players = metric(metrics, "palworld_max_players")
    server_fps = metric(metrics, "palworld_server_fps")
    frame_time = metric(metrics, "palworld_server_frame_time_milliseconds")
    frame_p95 = metric(metrics, "palworld_frame_time_p95_milliseconds")
    cpu = metric(metrics, "palworld_cgroup_cpu_percent")
    memory = metric(metrics, "palworld_cgroup_memory_bytes")
    uptime = metric(metrics, "palworld_uptime_seconds")

    if players is not None and max_players is not None:
        embed.add_field(
            name="접속자", value=f"{int(players)} / {int(max_players)}", inline=True
        )
    if server_fps is not None:
        embed.add_field(
            name="TPS 대체 지표",
            value=f"서버 FPS {server_fps:.1f}",
            inline=True,
        )
    if frame_time is not None:
        frame_value = f"{frame_time:.2f} ms"
        if frame_p95 is not None:
            frame_value += f" (p95 {frame_p95:.2f} ms)"
        embed.add_field(name="프레임 시간", value=frame_value, inline=True)
    if cpu is not None:
        embed.add_field(name="CPU", value=format_cpu(cpu), inline=True)
    if memory is not None:
        embed.add_field(name="RAM", value=format_bytes(memory), inline=True)
    if uptime is not None:
        embed.add_field(name="업타임", value=format_duration(uptime), inline=True)
    embed.set_footer(
        text="Palworld REST는 별도 TPS를 제공하지 않아 서버 FPS를 대체 지표로 표시합니다."
    )
    return embed


intents = discord.Intents.none()
intents.guilds = True


class PalworldClient(discord.Client):
    def __init__(self) -> None:
        super().__init__(intents=intents)
        self.tree = app_commands.CommandTree(self)
        self.log_channel_id: int | None = None
        self.player_watch_task: asyncio.Task[None] | None = None
        self.known_player_ids: frozenset[str] | None = None
        self.known_server_uptime: float | None = None
        self.player_snapshot_error: str | None = None

    async def setup_hook(self) -> None:
        try:
            self.log_channel_id = read_log_channel_id()
        except (OSError, UnicodeError, ValueError):
            LOGGER.warning(
                "stored Discord log channel setting is invalid; audit will use journal only"
            )
            self.log_channel_id = None
        guild = discord.Object(id=GUILD_ID)
        self.tree.copy_global_to(guild=guild)
        synced = await self.tree.sync(guild=guild)
        LOGGER.info("synced %d command(s) to configured guild", len(synced))

    async def on_ready(self) -> None:
        guild = self.get_guild(GUILD_ID)
        if guild is None:
            LOGGER.error("configured Discord guild is not visible to the bot")
            await self.close()
            return
        channel = guild.get_channel(CHANNEL_ID)
        if channel is None or not isinstance(
            channel, (discord.TextChannel, discord.VoiceChannel)
        ):
            LOGGER.error("configured Discord channel is not visible to the bot")
            await self.close()
            return
        member = guild.me
        if member is None:
            LOGGER.error("could not resolve the bot guild membership")
            await self.close()
            return
        permissions = channel.permissions_for(member)
        if not permissions.send_messages or not permissions.embed_links:
            LOGGER.error("the bot lacks send-message or embed-link permission")
            await self.close()
            return
        if self.log_channel_id is not None:
            log_channel = guild.get_channel(self.log_channel_id)
            if not isinstance(log_channel, discord.TextChannel):
                LOGGER.warning(
                    "configured Discord log channel is unavailable; audit will use journal only"
                )
            else:
                log_permissions = log_channel.permissions_for(member)
                if not (
                    log_permissions.view_channel
                    and log_permissions.send_messages
                    and log_permissions.embed_links
                ):
                    LOGGER.warning(
                        "configured Discord log channel lacks required permissions; "
                        "audit will use journal only"
                    )
        write_ready_marker()
        LOGGER.info("connected as Discord application user %s", self.user)
        if self.player_watch_task is None or self.player_watch_task.done():
            self.player_watch_task = asyncio.create_task(
                self.watch_player_connections(),
                name="palworld-player-connection-watch",
            )

    async def close(self) -> None:
        task = self.player_watch_task
        self.player_watch_task = None
        if task is not None and task is not asyncio.current_task():
            task.cancel()
            with suppress(asyncio.CancelledError):
                await task
        await super().close()

    async def send_player_presence_log(
        self, player_id: str, current_players: int, connected: bool
    ) -> None:
        event_name = "connected" if connected else "disconnected"
        LOGGER.info(
            "player_%s user_id=%s current_players=%d",
            event_name,
            player_id,
            current_players,
        )
        if self.log_channel_id is None:
            return
        try:
            guild = self.get_guild(GUILD_ID)
            if guild is None:
                raise RuntimeError("configured guild is unavailable")
            channel = guild.get_channel(self.log_channel_id)
            if not isinstance(channel, discord.TextChannel):
                raise RuntimeError("configured log channel is unavailable")
            member = guild.me
            if member is None:
                raise RuntimeError("bot guild membership is unavailable")
            permissions = channel.permissions_for(member)
            if not (
                permissions.view_channel
                and permissions.send_messages
                and permissions.embed_links
            ):
                raise RuntimeError("configured log channel lacks required permissions")

            safe_player_id = discord.utils.escape_markdown(
                discord.utils.escape_mentions(player_id)
            )
            embed = discord.Embed(
                title=("Palworld 플레이어 접속" if connected else "Palworld 플레이어 퇴장"),
                colour=(discord.Colour.green() if connected else discord.Colour.orange()),
                timestamp=discord.utils.utcnow(),
            )
            embed.add_field(
                name="플레이어 ID (userId)", value=safe_player_id, inline=False
            )
            embed.add_field(
                name="현재 접속 인원",
                value=f"{current_players}명",
                inline=True,
            )
            await asyncio.wait_for(
                channel.send(
                    embed=embed,
                    allowed_mentions=discord.AllowedMentions.none(),
                ),
                timeout=10,
            )
        except Exception as error:
            LOGGER.warning(
                "Discord player presence log delivery failed (%s); "
                "journal record retained",
                type(error).__name__,
            )

    async def watch_player_connections(self) -> None:
        while not self.is_closed():
            try:
                server_uptime, player_ids, modified = read_player_snapshot(
                    PLAYER_SNAPSHOT_PATH
                )
                snapshot_age = time.time() - modified
                if snapshot_age < -5 or snapshot_age > PLAYER_SNAPSHOT_MAX_AGE:
                    raise ValueError("player snapshot is stale")

                if self.player_snapshot_error is not None:
                    LOGGER.info("player snapshot monitoring recovered")
                    self.player_snapshot_error = None

                if self.known_player_ids is None:
                    self.known_player_ids = player_ids
                    self.known_server_uptime = server_uptime
                    LOGGER.info(
                        "player connection baseline initialized count=%d",
                        len(player_ids),
                    )
                else:
                    previous_ids = self.known_player_ids
                    server_restarted = (
                        self.known_server_uptime is not None
                        and server_uptime + 1 < self.known_server_uptime
                    )
                    if server_restarted:
                        previous_ids = frozenset()
                    joined_player_ids = sorted(player_ids - previous_ids)
                    left_player_ids = (
                        []
                        if server_restarted
                        else sorted(previous_ids - player_ids)
                    )
                    self.known_player_ids = player_ids
                    self.known_server_uptime = server_uptime
                    for player_id in left_player_ids:
                        await self.send_player_presence_log(
                            player_id, len(player_ids), connected=False
                        )
                    for player_id in joined_player_ids:
                        await self.send_player_presence_log(
                            player_id, len(player_ids), connected=True
                        )
            except FileNotFoundError:
                error_key = "missing"
                if self.player_snapshot_error != error_key:
                    LOGGER.warning("player snapshot is not available yet")
                    self.player_snapshot_error = error_key
            except (OSError, UnicodeError, ValueError) as error:
                error_key = type(error).__name__
                if self.player_snapshot_error != error_key:
                    LOGGER.warning(
                        "player snapshot cannot be used (%s)", error_key
                    )
                    self.player_snapshot_error = error_key
            await asyncio.sleep(PLAYER_WATCH_INTERVAL)


client = PalworldClient()
pal = app_commands.Group(name="pal", description="Palworld 서버 관리")
restart_in_progress = False
escape_in_progress = False


def journal_command_invocation(
    interaction: discord.Interaction, command_name: str
) -> None:
    LOGGER.info(
        "command_invocation interaction_id=%s created_at=%s command=%s "
        "user_id=%s guild_id=%s channel_id=%s",
        interaction.id,
        interaction.created_at.isoformat(),
        command_name,
        interaction.user.id,
        interaction.guild_id,
        interaction.channel_id,
    )


async def audit_command(
    interaction: discord.Interaction,
    command_name: str,
    outcome: str,
    detail: str,
) -> None:
    """Record command use without allowing audit failures to break commands."""
    LOGGER.info(
        "command_audit interaction_id=%s command=%s outcome=%s user_id=%s "
        "guild_id=%s channel_id=%s",
        interaction.id,
        command_name,
        outcome,
        interaction.user.id,
        interaction.guild_id,
        interaction.channel_id,
    )
    if client.log_channel_id is None:
        return

    try:
        guild = client.get_guild(GUILD_ID)
        if guild is None:
            raise RuntimeError("configured guild is unavailable")
        channel = guild.get_channel(client.log_channel_id)
        if not isinstance(channel, discord.TextChannel):
            raise RuntimeError("configured log channel is unavailable")
        member = guild.me
        if member is None:
            raise RuntimeError("bot guild membership is unavailable")
        permissions = channel.permissions_for(member)
        if not (
            permissions.view_channel
            and permissions.send_messages
            and permissions.embed_links
        ):
            raise RuntimeError("configured log channel lacks required permissions")

        colours = {
            "성공": discord.Colour.green(),
            "완료": discord.Colour.green(),
            "요청됨": discord.Colour.blue(),
            "진행 중": discord.Colour.blue(),
            "취소됨": discord.Colour.orange(),
            "거부됨": discord.Colour.orange(),
            "실패": discord.Colour.red(),
        }
        actor_name = discord.utils.escape_markdown(
            discord.utils.escape_mentions(interaction.user.display_name)
        )
        embed = discord.Embed(
            title="Palworld 관리 명령 기록",
            description=detail,
            colour=colours.get(outcome, discord.Colour.light_grey()),
            timestamp=discord.utils.utcnow(),
        )
        embed.add_field(name="명령어", value=f"`{command_name}`", inline=True)
        embed.add_field(name="결과", value=outcome, inline=True)
        embed.add_field(name="요청 ID", value=f"`{interaction.id}`", inline=False)
        embed.add_field(
            name="실행자",
            value=f"{actor_name} (`{interaction.user.id}`)",
            inline=False,
        )
        embed.add_field(
            name="실행 채널",
            value=(
                f"<#{interaction.channel_id}> (`{interaction.channel_id}`)"
                if interaction.channel_id is not None
                else "알 수 없음"
            ),
            inline=False,
        )
        await asyncio.wait_for(
            channel.send(
                embed=embed,
                allowed_mentions=discord.AllowedMentions.none(),
            ),
            timeout=10,
        )
    except Exception as error:
        LOGGER.warning(
            "Discord command audit delivery failed (%s); journal record retained",
            type(error).__name__,
        )


def write_escape_request(player_id: str) -> None:
    """Atomically publish a bounded player-reconnect request for systemd."""
    if not ESCAPE_PLAYER_ID_PATTERN.fullmatch(player_id):
        raise ValueError("player userId is invalid")

    temporary = ESCAPE_REQUEST_PATH.with_name(
        f".escape.{os.getpid()}.{secrets.token_hex(8)}"
    )
    payload = f"PALWORLD_ESCAPE_REQUEST_V1\nuser_id={player_id}\n".encode("ascii")
    published = False
    try:
        descriptor = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC,
            0o600,
        )
        try:
            written = 0
            while written < len(payload):
                count = os.write(descriptor, payload[written:])
                if count == 0:
                    raise OSError("could not write escape request")
                written += count
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

        # link(2) is an atomic no-replace publish. Replacing an existing
        # request could silently change the player selected by another admin.
        os.link(temporary, ESCAPE_REQUEST_PATH, follow_symlinks=False)
        published = True
        directory = os.open(
            ESCAPE_REQUEST_PATH.parent,
            os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC,
        )
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)
        if not published:
            # Do not remove ESCAPE_REQUEST_PATH: another request may already
            # be waiting and os.link() reports that race with FileExistsError.
            pass


def escape_choice_label(player: PlayerDirectoryEntry) -> str:
    suffix = f" · {player.user_id}"
    maximum_name_length = 100 - len(suffix)
    name = player.name
    if len(name) > maximum_name_length:
        name = f"{name[: maximum_name_length - 1]}…"
    return f"{name}{suffix}"


async def escape_player_autocomplete(
    interaction: discord.Interaction, current: str
) -> list[app_commands.Choice[str]]:
    if (
        interaction.guild_id != GUILD_ID
        or interaction.channel_id != CHANNEL_ID
    ):
        return []
    try:
        _, players, modified = read_player_directory(PLAYER_DIRECTORY_PATH)
        snapshot_age = time.time() - modified
        if snapshot_age < -5 or snapshot_age > PLAYER_SNAPSHOT_MAX_AGE:
            return []
    except (OSError, UnicodeError, ValueError):
        return []

    needle = current.casefold()
    matching_players = [
        player
        for player in players
        if ESCAPE_PLAYER_ID_PATTERN.fullmatch(player.user_id)
        and (needle in player.name.casefold() or needle in player.user_id.casefold())
    ]
    matching_players.sort(key=lambda player: (player.name.casefold(), player.user_id))
    return [
        app_commands.Choice(name=escape_choice_label(player), value=player.user_id)
        for player in matching_players[:25]
    ]


@pal.command(name="status", description="서버 CPU, RAM, 접속자와 성능 상태를 확인합니다.")
async def status_command(interaction: discord.Interaction) -> None:
    journal_command_invocation(interaction, "/pal status")
    if not await interaction_in_scope(interaction, "/pal status"):
        return
    await interaction.response.defer(ephemeral=True, thinking=True)
    try:
        embed = await build_status_embed()
    except (OSError, RuntimeError, asyncio.TimeoutError) as error:
        LOGGER.warning("status query failed: %s", error)
        await interaction.edit_original_response(
            content="서버 상태를 조회하지 못했습니다. 잠시 후 다시 시도해 주세요."
        )
        await audit_command(
            interaction, "/pal status", "실패", "서버 상태 조회에 실패했습니다."
        )
        return
    await interaction.edit_original_response(embed=embed)
    await audit_command(
        interaction, "/pal status", "성공", "서버 상태를 조회했습니다."
    )


@pal.command(
    name="restart",
    description="업데이트를 확인하고 Palworld 서버를 안전하게 재기동합니다.",
)
@app_commands.describe(confirm="점검 중단을 확인했다면 True를 선택하세요.")
async def restart_command(
    interaction: discord.Interaction, confirm: bool
) -> None:
    global restart_in_progress
    journal_command_invocation(interaction, "/pal restart")
    if not await interaction_in_configured_guild(interaction, "/pal restart"):
        return
    if not confirm:
        await interaction.response.send_message(
            "재기동을 취소했습니다. 실행하려면 `confirm`을 True로 선택하세요.",
            ephemeral=True,
        )
        await audit_command(
            interaction,
            "/pal restart",
            "취소됨",
            "확인 값이 False여서 재기동을 취소했습니다.",
        )
        return
    if restart_in_progress:
        await interaction.response.send_message(
            "이미 업데이트 또는 재기동 요청을 처리 중입니다.", ephemeral=True
        )
        await audit_command(
            interaction,
            "/pal restart",
            "거부됨",
            "이미 업데이트 또는 재기동을 처리 중입니다.",
        )
        return

    # Discord dispatch runs on one event loop. There is deliberately no await
    # between this check and assignment, so two interactions cannot queue two
    # sequential restarts through a check/acquire race.
    restart_in_progress = True
    try:
        await interaction.response.defer(ephemeral=True, thinking=True)
        before = await systemctl_properties(
            MAINTENANCE_UNIT,
            "ExecMainStartTimestampMonotonic",
        )
        before_start = int(before.get("ExecMainStartTimestampMonotonic", "0") or 0)
        try:
            descriptor = os.open(
                RESTART_REQUEST_PATH,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC,
                0o600,
            )
        except FileExistsError:
            await interaction.edit_original_response(
                content="이미 업데이트 또는 재기동 요청이 대기 중입니다."
            )
            await audit_command(
                interaction,
                "/pal restart",
                "거부됨",
                "이미 업데이트 또는 재기동 요청이 대기 중입니다.",
            )
            return
        try:
            os.write(descriptor, b"restart\n")
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

        await audit_command(
            interaction,
            "/pal restart",
            "요청됨",
            "업데이트 확인과 안전 재기동 요청을 접수했습니다.",
        )

        deadline = asyncio.get_running_loop().time() + COMMAND_TIMEOUT
        seen_start = False
        while asyncio.get_running_loop().time() < deadline:
            state = await systemctl_properties(
                MAINTENANCE_UNIT,
                "ActiveState",
                "Result",
                "ExecMainStartTimestampMonotonic",
            )
            start_timestamp = int(
                state.get("ExecMainStartTimestampMonotonic", "0") or 0
            )
            if start_timestamp > before_start:
                seen_start = True
            active_state = state.get("ActiveState", "unknown")
            if seen_start and active_state == "failed":
                await interaction.edit_original_response(
                    content="업데이트 또는 재기동에 실패했습니다. 서버 로그를 확인해 주세요."
                )
                await audit_command(
                    interaction,
                    "/pal restart",
                    "실패",
                    "업데이트 또는 재기동 서비스가 실패했습니다.",
                )
                return
            if seen_start and active_state == "inactive":
                if state.get("Result") == "success":
                    await interaction.edit_original_response(
                        content="업데이트 확인과 서버 재기동이 정상적으로 완료되었습니다."
                    )
                    await audit_command(
                        interaction,
                        "/pal restart",
                        "완료",
                        "업데이트 확인과 서버 재기동이 완료되었습니다.",
                    )
                else:
                    await interaction.edit_original_response(
                        content="업데이트 또는 재기동에 실패했습니다. 서버 로그를 확인해 주세요."
                    )
                    await audit_command(
                        interaction,
                        "/pal restart",
                        "실패",
                        "업데이트 또는 재기동 서비스가 실패했습니다.",
                    )
                return
            await asyncio.sleep(2)

        if not seen_start:
            RESTART_REQUEST_PATH.unlink(missing_ok=True)
        await interaction.edit_original_response(
            content=(
                "업데이트/재기동이 계속 진행 중입니다. 잠시 후 `/pal status`로 "
                "확인해 주세요."
            )
        )
        await audit_command(
            interaction,
            "/pal restart",
            "진행 중",
            "명령 응답 시간이 끝난 뒤에도 유지보수가 계속 진행 중입니다.",
        )
    except (OSError, RuntimeError, ValueError, asyncio.TimeoutError) as error:
        LOGGER.error("could not request or monitor maintenance: %s", error)
        try:
            RESTART_REQUEST_PATH.unlink(missing_ok=True)
        except OSError:
            pass
        if interaction.response.is_done():
            await interaction.edit_original_response(
                content="재기동 서비스를 호출하지 못했습니다."
            )
        await audit_command(
            interaction,
            "/pal restart",
            "실패",
            "재기동 서비스를 호출하거나 상태를 확인하지 못했습니다.",
        )
    finally:
        restart_in_progress = False


@pal.command(
    name="escape",
    description="버그에 걸린 온라인 플레이어를 강제 재접속시킵니다.",
)
@app_commands.describe(player="닉네임과 Steam ID가 표시되는 목록에서 선택하세요.")
@app_commands.autocomplete(player=escape_player_autocomplete)
async def escape_command(
    interaction: discord.Interaction, player: str
) -> None:
    global escape_in_progress
    command_name = "/pal escape"
    journal_command_invocation(interaction, command_name)
    if not await interaction_in_scope(interaction, command_name):
        return
    if not ESCAPE_PLAYER_ID_PATTERN.fullmatch(player):
        await interaction.response.send_message(
            "온라인 플레이어 목록에서 Steam ID를 선택해 주세요.",
            ephemeral=True,
        )
        await audit_command(
            interaction,
            command_name,
            "거부됨",
            "유효하지 않은 Palworld userId가 입력됐습니다.",
        )
        return
    if escape_in_progress:
        await interaction.response.send_message(
            "이미 다른 탈출 요청을 처리 중입니다.", ephemeral=True
        )
        await audit_command(
            interaction,
            command_name,
            "거부됨",
            "이미 다른 탈출 요청을 처리 중입니다.",
        )
        return

    escape_in_progress = True
    try:
        await interaction.response.defer(ephemeral=True, thinking=True)
        before = await systemctl_properties(
            "palworld-escape.service",
            "ExecMainStartTimestampMonotonic",
        )
        before_start = int(before.get("ExecMainStartTimestampMonotonic", "0") or 0)
        try:
            write_escape_request(player)
        except FileExistsError:
            await interaction.edit_original_response(
                content="이미 다른 탈출 요청이 대기 중입니다. 잠시 후 다시 시도해 주세요."
            )
            await audit_command(
                interaction,
                command_name,
                "거부됨",
                "이미 다른 탈출 요청이 대기 중입니다.",
            )
            return

        await audit_command(
            interaction,
            command_name,
            "요청됨",
            f"`{player}` 플레이어의 강제 재접속 요청을 접수했습니다.",
        )

        deadline = asyncio.get_running_loop().time() + ESCAPE_TIMEOUT
        seen_start = False
        while asyncio.get_running_loop().time() < deadline:
            state = await systemctl_properties(
                "palworld-escape.service",
                "ActiveState",
                "Result",
                "ExecMainStartTimestampMonotonic",
            )
            start_timestamp = int(
                state.get("ExecMainStartTimestampMonotonic", "0") or 0
            )
            if start_timestamp > before_start:
                seen_start = True
            active_state = state.get("ActiveState", "unknown")
            if seen_start and active_state == "failed":
                await interaction.edit_original_response(
                    content="탈출 처리에 실패했습니다. 대상이 온라인인지 확인해 주세요."
                )
                await audit_command(
                    interaction,
                    command_name,
                    "실패",
                    f"`{player}` 플레이어의 탈출 처리 서비스가 실패했습니다.",
                )
                return
            if seen_start and active_state == "inactive":
                if state.get("Result") == "success":
                    await interaction.edit_original_response(
                        content=(
                            "강제 재접속을 요청했습니다. 대상 플레이어는 다시 접속해 "
                            "버그가 풀렸는지 확인해 주세요."
                        )
                    )
                    await audit_command(
                        interaction,
                        command_name,
                        "완료",
                        f"`{player}` 플레이어의 강제 재접속을 요청했습니다.",
                    )
                else:
                    await interaction.edit_original_response(
                        content="탈출 처리에 실패했습니다. 서버 로그를 확인해 주세요."
                    )
                    await audit_command(
                        interaction,
                        command_name,
                        "실패",
                        f"`{player}` 플레이어의 탈출 처리 결과가 실패했습니다.",
                    )
                return
            await asyncio.sleep(1)

        if not seen_start:
            ESCAPE_REQUEST_PATH.unlink(missing_ok=True)
        await interaction.edit_original_response(
            content="탈출 요청을 처리 중입니다. 잠시 후 대상 플레이어의 접속 상태를 확인해 주세요."
        )
        await audit_command(
            interaction,
            command_name,
            "진행 중",
            f"`{player}` 플레이어의 탈출 처리가 아직 진행 중입니다.",
        )
    except (OSError, RuntimeError, ValueError, asyncio.TimeoutError) as error:
        LOGGER.error("could not request or monitor player escape: %s", error)
        try:
            ESCAPE_REQUEST_PATH.unlink(missing_ok=True)
        except OSError:
            pass
        if interaction.response.is_done():
            await interaction.edit_original_response(
                content="탈출 서비스를 호출하지 못했습니다."
            )
        await audit_command(
            interaction,
            command_name,
            "실패",
            f"`{player}` 플레이어의 탈출 서비스를 호출하거나 상태를 확인하지 못했습니다.",
        )
    finally:
        escape_in_progress = False


@pal.command(
    name="log-channel",
    description="Palworld 관리 명령 기록을 남길 Discord 채널을 지정합니다.",
)
@app_commands.describe(channel="관리 명령 기록을 남길 텍스트 채널")
async def log_channel_command(
    interaction: discord.Interaction, channel: discord.TextChannel
) -> None:
    journal_command_invocation(interaction, "/pal log-channel")
    if not await interaction_in_configured_guild(interaction, "/pal log-channel"):
        return
    if not is_audit_admin(interaction):
        await interaction.response.send_message(
            "로그 채널을 변경할 관리 권한이 없습니다.", ephemeral=True
        )
        await audit_command(
            interaction,
            "/pal log-channel",
            "거부됨",
            "관리 권한이 없는 사용자가 로그 채널 변경을 시도했습니다.",
        )
        return
    if channel.guild.id != GUILD_ID:
        await interaction.response.send_message(
            "현재 Discord 서버의 텍스트 채널만 지정할 수 있습니다.",
            ephemeral=True,
        )
        await audit_command(
            interaction,
            "/pal log-channel",
            "거부됨",
            "다른 Discord 서버의 채널을 지정했습니다.",
        )
        return

    member = channel.guild.me
    permissions = channel.permissions_for(member) if member is not None else None
    if permissions is None or not (
        permissions.view_channel
        and permissions.send_messages
        and permissions.embed_links
    ):
        await interaction.response.send_message(
            "봇이 해당 채널을 보고 메시지와 embed를 보낼 권한이 필요합니다.",
            ephemeral=True,
        )
        await audit_command(
            interaction,
            "/pal log-channel",
            "거부됨",
            "대상 채널에서 봇 권한이 부족합니다.",
        )
        return

    previous_channel_id = client.log_channel_id
    try:
        write_log_channel_id(channel.id)
    except OSError:
        LOGGER.error("could not persist Discord log channel setting")
        await interaction.response.send_message(
            "로그 채널 설정을 저장하지 못했습니다.", ephemeral=True
        )
        await audit_command(
            interaction,
            "/pal log-channel",
            "실패",
            "로그 채널 설정을 저장하지 못했습니다.",
        )
        return

    client.log_channel_id = channel.id
    LOGGER.info(
        "audit_channel_change interaction_id=%s actor_id=%s old_channel_id=%s "
        "new_channel_id=%s",
        interaction.id,
        interaction.user.id,
        previous_channel_id,
        channel.id,
    )
    await interaction.response.send_message(
        f"{channel.mention} 채널을 관리 명령 로그 채널로 설정했습니다.",
        ephemeral=True,
        allowed_mentions=discord.AllowedMentions.none(),
    )
    await audit_command(
        interaction,
        "/pal log-channel",
        "성공",
        "이 채널을 새 관리 명령 로그 채널로 설정했습니다.",
    )


client.tree.add_command(pal)


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    clear_ready_marker()
    token = read_token()
    client.run(token, log_handler=None)


if __name__ == "__main__":
    main()
