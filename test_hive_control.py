import unittest
from dataclasses import replace
from types import SimpleNamespace
from unittest.mock import AsyncMock

from hiveheating.exceptions import HiveConnectionError
from hive_control import command, connected, select_product


class ControlTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        async with connected(demo=True) as hive:
            self.nodes = await hive.get_nodes()
        self.heating = next(p for p in self.nodes.products.values() if p.type == "heating")
        self.water = next(p for p in self.nodes.products.values() if p.type == "hotwater")
        self.client = SimpleNamespace(
            get_nodes=AsyncMock(return_value=self.nodes),
            set_target_temperature=AsyncMock(), set_mode=AsyncMock(),
            _set_state=AsyncMock(),
            set_heating_boost=AsyncMock(), set_hot_water_boost=AsyncMock())

    def assert_no_write(self):
        for name in ("set_target_temperature", "set_mode", "set_heating_boost", "set_hot_water_boost", "_set_state"):
            getattr(self.client, name).assert_not_called()

    async def test_dry_run_never_writes(self):
        result = await command(self.client, self.heating.id, "boost", minutes=30, temperature=20, dry_run=True)
        self.assertTrue(result["dry_run"])
        self.assert_no_write()

    async def test_invalid_temperatures_never_write(self):
        for temperature in (float("nan"), float("inf"), -1, 99, True):
            with self.assertRaises(ValueError):
                await command(self.client, self.heating.id, "temperature", temperature=temperature)
        self.assert_no_write()

    async def test_hot_water_rejects_temperature(self):
        with self.assertRaises(ValueError):
            await command(self.client, self.water.id, "temperature", temperature=20)
        self.assert_no_write()

    async def test_offline_and_unknown_state_never_write(self):
        for online in (False, None):
            node = replace(self.heating, online=online)
            self.client.get_nodes.return_value = replace(self.nodes, products={node.id: node})
            with self.assertRaises(ValueError):
                await command(self.client, node.id, "mode", mode="OFF")
        self.assert_no_write()

    async def test_unknown_units_never_write(self):
        self.client.get_nodes.return_value = replace(self.nodes, user=replace(self.nodes.user, temperature_unit="F"))
        with self.assertRaises(ValueError):
            await command(self.client, self.heating.id, "temperature", temperature=20)
        self.assert_no_write()

    async def test_ambiguous_name_rejected(self):
        second = replace(self.heating, id="another-zone")
        nodes = replace(self.nodes, products={self.heating.id: self.heating, second.id: second})
        with self.assertRaises(ValueError):
            select_product(nodes, self.heating.name)

    async def test_type_prefix_distinguishes_heating_from_water(self):
        water = replace(self.water, name=self.heating.name)
        nodes = replace(self.nodes, products={self.heating.id: self.heating, water.id: water})
        with self.assertRaises(ValueError):
            select_product(nodes, self.heating.name)
        self.assertEqual(select_product(nodes, "heating:" + self.heating.name), self.heating)
        self.assertEqual(select_product(nodes, "hotwater:" + self.heating.name), water)

    async def test_boost_targets_only_selected_zone(self):
        await command(self.client, self.heating.id, "boost", minutes=30, temperature=20)
        self.client.set_heating_boost.assert_awaited_once_with(self.heating, 30, 20)
        self.client.set_mode.assert_not_called()
        self.client.set_hot_water_boost.assert_not_called()

    async def test_manual_sets_mode_and_target_in_one_request(self):
        await command(self.client, self.heating.id, "manual", temperature=20)
        self.client._set_state.assert_awaited_once_with(self.heating, mode="MANUAL", target=20)
        self.client.set_mode.assert_not_called()
        self.client.set_target_temperature.assert_not_called()

    async def test_manual_validation_and_dry_run_never_write(self):
        for selector, temperature in ((self.water.id, 20), (self.heating.id, 99)):
            with self.assertRaises(ValueError):
                await command(self.client, selector, "manual", temperature=temperature)
        await command(self.client, self.heating.id, "manual", temperature=20, dry_run=True)
        self.assert_no_write()

    async def test_failed_readback_reports_submitted_not_verified(self):
        self.client.get_nodes.side_effect = [self.nodes, HiveConnectionError("test")]
        result = await command(self.client, self.heating.id, "mode", mode="SCHEDULE")
        self.assertTrue(result["submitted"])
        self.assertIsNone(result["observed"])
        self.client.set_mode.assert_awaited_once()


if __name__ == "__main__":
    unittest.main()
