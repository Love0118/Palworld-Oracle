#!/usr/bin/env python3
"""Restricted Discord control surface for Palworld Oracle."""

from __future__ import annotations

import asyncio
import logging
import os
import re
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


async def interaction_in_scope(interaction: discord.Interaction) -> bool:
    if interaction.guild_id != GUILD_ID or interaction.channel_id != CHANNEL_ID:
        await interaction.response.send_message(
            "이 명령어는 등록된 서버 관리 채널에서만 사용할 수 있습니다.",
            ephemeral=True,
        )
        return False
    return True


def is_restart_admin(interaction: discord.Interaction) -> bool:
    member = interaction.user
    if not isinstance(member, discord.Member):
        return False
    if member.guild_permissions.administrator:
        return True
    return any(role.id in ADMIN_ROLE_IDS for role in member.roles)


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

    async def setup_hook(self) -> None:
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
        write_ready_marker()
        LOGGER.info("connected as Discord application user %s", self.user)


client = PalworldClient()
pal = app_commands.Group(name="pal", description="Palworld 서버 관리")
restart_in_progress = False


@pal.command(name="status", description="서버 CPU, RAM, 접속자와 성능 상태를 확인합니다.")
async def status_command(interaction: discord.Interaction) -> None:
    if not await interaction_in_scope(interaction):
        return
    await interaction.response.defer(ephemeral=True, thinking=True)
    try:
        embed = await build_status_embed()
    except (OSError, RuntimeError, asyncio.TimeoutError) as error:
        LOGGER.warning("status query failed: %s", error)
        await interaction.edit_original_response(
            content="서버 상태를 조회하지 못했습니다. 잠시 후 다시 시도해 주세요."
        )
        return
    await interaction.edit_original_response(embed=embed)


@pal.command(
    name="restart",
    description="업데이트를 확인하고 Palworld 서버를 안전하게 재기동합니다.",
)
@app_commands.describe(confirm="점검 중단을 확인했다면 True를 선택하세요.")
async def restart_command(
    interaction: discord.Interaction, confirm: bool
) -> None:
    global restart_in_progress
    if not await interaction_in_scope(interaction):
        return
    if not is_restart_admin(interaction):
        await interaction.response.send_message(
            "이 명령어를 실행할 관리 역할이 없습니다.", ephemeral=True
        )
        return
    if not confirm:
        await interaction.response.send_message(
            "재기동을 취소했습니다. 실행하려면 `confirm`을 True로 선택하세요.",
            ephemeral=True,
        )
        return
    if restart_in_progress:
        await interaction.response.send_message(
            "이미 업데이트 또는 재기동 요청을 처리 중입니다.", ephemeral=True
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
            return
        try:
            os.write(descriptor, b"restart\n")
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

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
                return
            if seen_start and active_state == "inactive":
                if state.get("Result") == "success":
                    await interaction.edit_original_response(
                        content="업데이트 확인과 서버 재기동이 정상적으로 완료되었습니다."
                    )
                else:
                    await interaction.edit_original_response(
                        content="업데이트 또는 재기동에 실패했습니다. 서버 로그를 확인해 주세요."
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
    finally:
        restart_in_progress = False


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
