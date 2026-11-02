#!/usr/bin/env python3
"""Regression checks for the macOS app's LaunchServices metadata.

Upstream #12990: a duplicated `UTExportedTypeDeclarations` key kept
LaunchServices (`lsd`) re-registering the app. plistlib silently keeps the
last duplicate, so the XML is checked directly.
"""

import collections
import pathlib
import plistlib
import unittest
import xml.etree.ElementTree as ET


ROOT = pathlib.Path(__file__).resolve().parents[1]
INFO_PLIST = ROOT / "Resources" / "Info.plist"


class InfoPlistTests(unittest.TestCase):
    def test_info_plist_has_no_duplicate_top_level_keys(self) -> None:
        root = ET.parse(INFO_PLIST).getroot()
        dictionary = root.find("dict")
        self.assertIsNotNone(dictionary)
        keys = [element.text for element in dictionary if element.tag == "key"]
        duplicates = [key for key, count in collections.Counter(keys).items() if count > 1]
        self.assertEqual(duplicates, [], f"Duplicate top-level Info.plist keys: {duplicates}")
        self.assertEqual(keys.count("UTExportedTypeDeclarations"), 1)

    def test_info_plist_is_valid_and_keeps_drag_types(self) -> None:
        with INFO_PLIST.open("rb") as stream:
            info = plistlib.load(stream)
        identifiers = {
            declaration["UTTypeIdentifier"]
            for declaration in info["UTExportedTypeDeclarations"]
        }
        self.assertIn("com.splittabbar.tabtransfer", identifiers)
        self.assertIn("com.cmux.sidebar-tab-reorder", identifiers)
        self.assertIn("com.cmux.filepreview.transfer", identifiers)


if __name__ == "__main__":
    unittest.main()
