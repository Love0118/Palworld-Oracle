#!/usr/bin/env python3
"""Restricted Discord control surface for Palworld Oracle."""

from __future__ import annotations

import asyncio
import logging
import os
import re
import secrets
import stat
from pathlib import Path

import discord
from discord import app_commands

from palworld_status import (
    format_bytes,
    format_cpu,
    format_duration,
    metrics_age,
    parse_snowflake_list,
    read_prometheus,
)


LOGGER = logging.getLogger("palworld-discord")
PALWORLD_UNIT = "palworld.service"
MAINTENANCE_UNIT = "palworld-maintenance-restart.service"
SYSTEMCTL = "/usr/bin/systemctl"
READY_PATH = Path("/run/palworld-discord/ready")
RESTART_REQUEST_PATH = Path("/run/palworld-discord/restart.request")
LOG_CHANNEL_PATH = Path("/var/lib/palworld-discord/log-channel-id")


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


GUILD_ID = required_snowflake("PALWORLD_DISCORD_GUILD_ID")
CHANNEL_ID = required_snowflake("PALWORLD_DISCORD_CHANNEL_ID")
ADMIN_ROLE_IDS = parse_snowflake_list(
    os.environ.get("PALWORLD_DISCORD_ADMIN_ROLE_IDS", "")
)
METRICS_PATH = Path(
    os.environ.get(
        "PALWORLD_DISCORD_METRICS_FILE",
        "/var/lib/palworld-observer/palworld.prom",
    )
)
METRICS_MAX_AGE = positive_integer(
    "PALWORLD_DISCORD_METRICS_MAX_AGE_SECONDS", 30, 3600
)
COMMAND_TIMEOUT = positive_integer(
    "PALWORLD_DISCORD_COMMAND_TIMEOUT_SECONDS", 840, 840
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


def is_management_admin(interaction: discord.Interaction) -> bool:
    member = interaction.user
    if not isinstance(member, discord.Member):
        return False
    if member.guild_permissions.administrator:
        return True
    return any(role.id in ADMIN_ROLE_IDS for role in member.roles)


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
        missing_roles = [
            role_id
            for role_id in ADMIN_ROLE_IDS
            if guild.get_role(role_id) is None
        ]
        if missing_roles:
            LOGGER.error("one or more configured Discord administrator roles are missing")
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


client = PalworldClient()
pal = app_commands.Group(name="pal", description="Palworld 서버 관리")
restart_in_progress = False


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
    if not await interaction_in_scope(interaction, "/pal restart"):
        return
    if not is_management_admin(interaction):
        await interaction.response.send_message(
            "이 명령어를 실행할 관리 역할이 없습니다.", ephemeral=True
        )
        await audit_command(
            interaction,
            "/pal restart",
            "거부됨",
            "관리 권한이 없는 사용자가 실행했습니다.",
        )
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
