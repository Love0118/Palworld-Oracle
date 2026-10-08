#!/usr/bin/env python3
"""Exercise server controls without connecting to Discord or starting services."""
from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bot"))

with patch.dict(os.environ, {"PALWORLD_DISCORD_GUILD_ID": "123456789012345678"}):
    import palworld_discord_bot as bot


class ServerControlTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        bot.autorestart_in_progress = False
        self.addCleanup(setattr, bot, "autorestart_in_progress", False)
        self.role = patch.object(bot.client, "operator_role_id", 234567890123456789)
        self.role.start()
        self.addCleanup(self.role.stop)
        self.request = AsyncMock(return_value="success")
        self.audit = AsyncMock()
        for name, value in (
            ("request_autorestart", self.request),
            ("audit_command", self.audit),
            ("journal_command_invocation", Mock()),
        ):
            replacement = patch.object(bot, name, value)
            replacement.start()
            self.addCleanup(replacement.stop)

    def interaction(self, *, allowed: bool = True, guild_id: int | None = None):
        member = Mock(spec=bot.discord.Member)
        member.id = 345678901234567890
        member.guild = SimpleNamespace(owner_id=456789012345678901)
        member.guild_permissions = SimpleNamespace(administrator=False)
        member.roles = (
            [SimpleNamespace(id=bot.client.operator_role_id)] if allowed else []
        )
        return SimpleNamespace(
            guild_id=bot.GUILD_ID if guild_id is None else guild_id,
            user=member,
            response=SimpleNamespace(
                send_message=AsyncMock(),
                defer=AsyncMock(),
                is_done=lambda: True,
            ),
            edit_original_response=AsyncMock(),
        )

    async def invoke(self, name, interaction):
        command = bot.pal.get_command(name)
        self.assertIsNotNone(command)
        await command.callback(interaction)

    async def test_enable_starts_management_and_audits_the_actual_command(self):
        interaction = self.interaction()
        await self.invoke("enable", interaction)
        self.request.assert_awaited_once_with("on")
        interaction.response.defer.assert_awaited_once_with(
            ephemeral=True, thinking=True
        )
        self.assertIn("활성화", interaction.edit_original_response.call_args.kwargs["content"])
        self.assertEqual(self.audit.call_args.args[1:3], ("/pal enable", "완료"))
        self.assertFalse(bot.autorestart_in_progress)

    async def test_disable_stops_management_and_explains_how_to_enable_again(self):
        interaction = self.interaction()
        await self.invoke("disable", interaction)
        self.request.assert_awaited_once_with("off")
        self.assertIn("/pal enable", interaction.edit_original_response.call_args.kwargs["content"])
        self.assertEqual(self.audit.call_args.args[1:3], ("/pal disable", "완료"))

    async def test_both_commands_reject_the_wrong_guild(self):
        for name in ("enable", "disable"):
            with self.subTest(command=name):
                interaction = self.interaction(guild_id=987654321098765432)
                await self.invoke(name, interaction)
                interaction.response.send_message.assert_awaited_once()
                interaction.response.defer.assert_not_awaited()
        self.request.assert_not_awaited()

    async def test_both_commands_require_the_operator_role(self):
        for name in ("enable", "disable"):
            with self.subTest(command=name):
                interaction = self.interaction(allowed=False)
                await self.invoke(name, interaction)
                interaction.response.send_message.assert_awaited_once()
                interaction.response.defer.assert_not_awaited()
        self.request.assert_not_awaited()

    async def test_an_existing_change_blocks_both_new_commands(self):
        bot.autorestart_in_progress = True
        for name in ("enable", "disable"):
            await self.invoke(name, self.interaction())
        self.request.assert_not_awaited()
        self.assertTrue(bot.autorestart_in_progress)

    async def test_failure_releases_the_lock_for_a_retry(self):
        self.request.side_effect = OSError("test request failure")
        interaction = self.interaction()
        await self.invoke("disable", interaction)
        self.assertFalse(bot.autorestart_in_progress)
        self.assertEqual(self.audit.call_args.args[1:3], ("/pal disable", "실패"))
        self.request.side_effect = None
        await self.invoke("enable", self.interaction())
        self.assertEqual(self.request.await_count, 2)

    async def test_pending_request_is_not_reported_as_completed(self):
        self.request.return_value = "pending"
        await self.invoke("enable", self.interaction())
        self.assertEqual(self.audit.call_args.args[1:3], ("/pal enable", "진행 중"))

    async def test_legacy_commands_remain_available(self):
        for action in ("on", "off"):
            with self.subTest(action=action):
                self.request.reset_mock()
                await bot.autorestart.get_command(action).callback(self.interaction())
                self.request.assert_awaited_once_with(action)
                self.assertEqual(
                    self.audit.call_args.args[1:3], (f"/autorestart {action}", "완료")
                )


if __name__ == "__main__":
    unittest.main()
