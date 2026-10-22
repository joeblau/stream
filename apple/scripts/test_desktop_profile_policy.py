#!/usr/bin/env python3
"""Synthetic decoded-metadata policy fixtures, not Apple CMS/signing evidence."""
import copy
from datetime import datetime, timedelta, timezone
import unittest

from desktop_profile_policy import (APP_ID, GROUPS, INSTALL, KEYCHAIN, TEAM_ID,
                                    ProfilePolicyError, validate_decoded_profile)

TEAM = "K78G42H4U2"
PREFIX = "OLDPREFIX1"  # An App ID prefix is not necessarily the Team ID.
BUNDLE = "com.joeblau.StreamMac"
LEAF = b"synthetic-public-leaf-certificate"
NOW = datetime(2026, 10, 22, tzinfo=timezone.utc)


class DecodedProfilePolicyTests(unittest.TestCase):
    def setUp(self):
        self.actual = {APP_ID: PREFIX + "." + BUNDLE, TEAM_ID: TEAM, INSTALL: True,
                       GROUPS: ["group.com.joeblau.Stream", TEAM + ".com.joeblau.Stream.VirtualOutputs"],
                       KEYCHAIN: [PREFIX + ".com.joeblau.Stream"]}
        self.profile = {"Platform": ["OSX"], "TeamIdentifier": [TEAM],
                        "ApplicationIdentifierPrefix": [PREFIX], "DeveloperCertificates": [LEAF],
                        "CreationDate": NOW - timedelta(days=1), "ExpirationDate": NOW + timedelta(days=1),
                        "Entitlements": {APP_ID: PREFIX + ".com.joeblau.*", TEAM_ID: TEAM, INSTALL: True,
                                         GROUPS: ["group.com.joeblau.Stream", TEAM + ".*"],
                                         KEYCHAIN: [PREFIX + ".*"]}}

    def validate(self, profile=None, actual=None):
        return validate_decoded_profile(self.profile if profile is None else profile,
                                        bundle_identifier=BUNDLE, team=TEAM,
                                        actual=self.actual if actual is None else actual,
                                        leaf_certificate=LEAF, now=NOW)

    def test_non_team_app_prefix_and_documented_wildcards(self):
        self.assertTrue(self.validate().requires_profile)
        self.profile["Entitlements"][APP_ID] = self.actual[APP_ID]
        self.profile["Entitlements"][KEYCHAIN] = self.actual[KEYCHAIN]
        self.assertTrue(self.validate().requires_profile)

    def test_team_only_groups_do_not_require_profile(self):
        actual = {GROUPS: [TEAM + ".com.joeblau.Stream.VirtualOutputs"], "com.apple.security.app-sandbox": True}
        result = validate_decoded_profile(None, bundle_identifier=BUNDLE, team=TEAM, actual=actual)
        self.assertFalse(result.requires_profile)
        # A normal Keychain API caller without a keychain-access-groups claim
        # does not acquire a profile requirement from this policy.
        self.assertFalse(validate_decoded_profile(None, bundle_identifier=BUNDLE, team=TEAM, actual={}).requires_profile)

    def test_optional_profile_does_not_create_team_group_authorization_gate(self):
        actual = {APP_ID: self.actual[APP_ID], GROUPS: [TEAM + ".camera"], TEAM_ID: TEAM}
        del self.profile["Entitlements"][GROUPS]
        self.assertFalse(self.validate(actual=actual).requires_profile)

    def test_each_actual_restricted_or_registered_claim_requires_profile(self):
        for actual in [{INSTALL: True}, {GROUPS: ["group.com.joeblau.Stream"]}, {KEYCHAIN: [PREFIX + ".item"]}]:
            with self.subTest(actual=actual), self.assertRaisesRegex(ProfilePolicyError, "Missing embedded"):
                validate_decoded_profile(None, bundle_identifier=BUNDLE, team=TEAM, actual=actual)

    def test_profile_identity_certificate_and_dates_refusals(self):
        mutations = [
            ("platform", lambda p: p.update(Platform=["iOS"]), "not for macOS"),
            ("team", lambda p: p.update(TeamIdentifier=["AAAAAAAAAA"]), "team mismatch"),
            ("entitlement team", lambda p: p["Entitlements"].update({TEAM_ID: "AAAAAAAAAA"}), "team mismatch"),
            ("prefix", lambda p: p.update(ApplicationIdentifierPrefix=[TEAM]), "prefix mismatch"),
            ("app ID", lambda p: p["Entitlements"].update({APP_ID: PREFIX + ".com.other.*"}), "application identifier mismatch"),
            ("leaf", lambda p: p.update(DeveloperCertificates=[b"other-cert-same-team"]), "leaf certificate"),
            ("expired", lambda p: p.update(ExpirationDate=NOW), "expired"),
            ("future", lambda p: p.update(CreationDate=NOW + timedelta(hours=1)), "not yet valid"),
            ("interval", lambda p: p.update(ExpirationDate=NOW - timedelta(days=2)), "validity interval"),
        ]
        for label, mutate, message in mutations:
            with self.subTest(label=label):
                profile = copy.deepcopy(self.profile)
                mutate(profile)
                with self.assertRaisesRegex(ProfilePolicyError, message):
                    self.validate(profile=profile)

    def test_each_documented_claim_is_authorized(self):
        for key, value, message in [
            (INSTALL, False, "system-extension installation"),
            (KEYCHAIN, [TEAM + ".*"], "Keychain access group"),
            (GROUPS, ["group.other", TEAM + ".*"], "signed App Group"),
            (GROUPS, ["group.com.joeblau.Stream"], "signed App Group"),
        ]:
            with self.subTest(key=key, value=value):
                profile = copy.deepcopy(self.profile)
                profile["Entitlements"][key] = value
                with self.assertRaisesRegex(ProfilePolicyError, message):
                    self.validate(profile=profile)

    def test_rejects_glob_and_registered_group_wildcard_laundering(self):
        for key, patterns in [
            (APP_ID, [PREFIX + ".*evil", PREFIX + ".com.?oeblau.*", PREFIX + ".com.[j]oeblau.*"]),
            (KEYCHAIN, [PREFIX + ".*evil", PREFIX + ".com.?oeblau.*"]),
            (GROUPS, ["group.*", "group.com.joeblau.*"]),
        ]:
            for pattern in patterns:
                with self.subTest(key=key, pattern=pattern):
                    profile = copy.deepcopy(self.profile)
                    profile["Entitlements"][key] = pattern if key == APP_ID else [pattern, TEAM + ".*"]
                    with self.assertRaises(ProfilePolicyError):
                        self.validate(profile=profile)

    def test_signed_identity_and_claim_shape_refusals(self):
        for patch, message in [
            ({APP_ID: TEAM + ".com.other"}, "does not match bundle ID"),
            ({APP_ID: None}, "does not match bundle ID"),
            ({TEAM_ID: "AAAAAAAAAA"}, "Signed entitlement team mismatch"),
            ({GROUPS: ["AAAAAAAAAA.somewhere"]}, "namespace mismatch"),
            ({GROUPS: [TEAM + ".*"]}, "Wildcards"),
            ({KEYCHAIN: [PREFIX + ".*"]}, "Wildcards"),
            ({GROUPS: "group.com.joeblau.Stream"}, "Malformed"),
            ({KEYCHAIN: "not-an-array"}, "Malformed"),
            ({INSTALL: 1}, "Malformed"),
        ]:
            with self.subTest(patch=patch):
                actual = dict(self.actual, **patch)
                with self.assertRaisesRegex(ProfilePolicyError, message):
                    self.validate(actual=actual)

    def test_malformed_metadata_is_refused(self):
        for patch in [{"DeveloperCertificates": []}, {"DeveloperCertificates": ["not-DER-data"]},
                      {"CreationDate": "yesterday"}, {"TeamIdentifier": TEAM}, {"Entitlements": []}]:
            with self.subTest(patch=patch), self.assertRaisesRegex(ProfilePolicyError, "Malformed"):
                self.validate(profile=dict(self.profile, **patch))


if __name__ == "__main__":
    unittest.main()
