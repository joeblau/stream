"""Decoded macOS profile metadata checks for the release audit.

This diagnostic policy does not verify Apple's CMS signer or the authoritative
DER profile, and does not replace platform trust/launch/notarization checks.
See TN3125 and https://developer.apple.com/forums/thread/721701 .
"""
from dataclasses import dataclass
from datetime import datetime, timezone
import re


INSTALL = "com.apple.developer.system-extension.install"
GROUPS = "com.apple.security.application-groups"
KEYCHAIN = "keychain-access-groups"
APP_ID = "com.apple.application-identifier"
TEAM_ID = "com.apple.developer.team-identifier"


class ProfilePolicyError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ProfilePolicyError(message)


def strings(value, label):
    require(isinstance(value, list) and all(isinstance(item, str) and item for item in value),
            f"Malformed {label}")
    return value


@dataclass(frozen=True)
class ProfileRequirements:
    system_extension: bool
    provisioned_groups: tuple[str, ...]
    team_groups: tuple[str, ...]
    keychain_groups: tuple[str, ...]

    @property
    def requires_profile(self):
        return self.system_extension or bool(self.provisioned_groups) or bool(self.keychain_groups)


def profile_requirements(actual, team):
    """Only actual signed claims trigger a profile; ordinary Keychain use doesn't."""
    require(isinstance(actual, dict), "Malformed signed entitlements")
    require(isinstance(team, str) and re.fullmatch(r"[A-Z0-9]{10}", team), "Invalid signing team")
    install = actual.get(INSTALL, False)
    require(type(install) is bool, "Malformed system-extension install entitlement")
    groups = strings(actual.get(GROUPS, []), "signed App Groups")
    require(all(not any(char in group for char in "*?[]") for group in groups),
            "Wildcards are not valid signed App Group claims")
    provisioned = tuple(group for group in groups if group.startswith("group."))
    team_groups = tuple(group for group in groups if group.startswith(team + "."))
    require(len(provisioned) + len(team_groups) == len(groups), "Signed App Group namespace mismatch")
    keychain = tuple(strings(actual.get(KEYCHAIN, []), "signed Keychain access groups"))
    require(all(not any(char in group for char in "*?[]") for group in keychain),
            "Wildcards are not valid signed Keychain access group claims")
    return ProfileRequirements(install, provisioned, team_groups, keychain)


def allows_identifier(pattern, value):
    """Apple's exact or terminal-component wildcard, never shell/glob syntax."""
    if not isinstance(pattern, str) or not isinstance(value, str):
        return False
    if pattern == value and not any(char in pattern for char in "*?[]"):
        return True
    return (pattern.endswith(".*") and pattern.count("*") == 1
            and not any(char in pattern for char in "?[]")
            and value.startswith(pattern[:-1]) and len(value) > len(pattern) - 1)


def allows_group(pattern, group, team):
    # Registered group. IDs are exact. Apple's generated TEAM_ID.* authorization
    # can cover that team's macOS-style groups; it cannot cover registered IDs.
    return pattern == group or (pattern == team + ".*" and group.startswith(team + ".")
                                and len(group) > len(team) + 1)


def utc(value, label):
    require(isinstance(value, datetime), f"Malformed profile {label}")
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def validate_decoded_profile(profile, *, bundle_identifier, team, actual, leaf_certificate=None, now=None):
    """Match decoded metadata to an already inspected Developer ID signature.

    A TEAM-only camera without restricted claims needs no profile. If one is
    embedded anyway, its identity/certificate metadata must still match.
    """
    requirements = profile_requirements(actual, team)
    require(isinstance(bundle_identifier, str) and bundle_identifier, "Invalid bundle identifier")
    require(actual.get(TEAM_ID, team) == team, "Signed entitlement team mismatch")
    signed_id = actual.get(APP_ID)
    prefix = None
    if signed_id is not None or profile is not None:
        suffix = "." + bundle_identifier
        require(isinstance(signed_id, str) and signed_id.endswith(suffix), "Signed application identifier does not match bundle ID")
        require(not any(char in signed_id for char in "*?[]"), "Wildcard in signed application identifier")
        prefix = signed_id[:-len(suffix)]
        require(re.fullmatch(r"[A-Z0-9]{10}", prefix) is not None, "Invalid signed App ID prefix")
    if profile is None:
        require(not requirements.requires_profile,
                "Missing embedded provisioning profile for actual signed restricted/provisioned claims")
        return requirements
    require(isinstance(profile, dict), "Malformed decoded provisioning profile")
    require("OSX" in strings(profile.get("Platform"), "profile platforms"), "Provisioning profile is not for macOS")
    require(team in strings(profile.get("TeamIdentifier"), "profile teams"), "Provisioning profile team mismatch")
    entitlements = profile.get("Entitlements")
    require(isinstance(entitlements, dict), "Malformed profile entitlement allowlist")
    require(entitlements.get(TEAM_ID) == team, "Provisioning profile entitlement team mismatch")

    now = utc(now or datetime.now(timezone.utc), "audit date")
    creation = utc(profile.get("CreationDate"), "creation date")
    expiration = utc(profile.get("ExpirationDate"), "expiration date")
    require(creation < expiration, "Provisioning profile validity interval is invalid")
    require(creation <= now, "Provisioning profile is not yet valid")
    require(now < expiration, "Provisioning profile has expired")

    require(prefix in strings(profile.get("ApplicationIdentifierPrefix"), "profile App ID prefixes"),
            "Provisioning profile App ID prefix mismatch")
    require(allows_identifier(entitlements.get(APP_ID), signed_id), "Provisioning profile application identifier mismatch")
    certificates = profile.get("DeveloperCertificates")
    require(isinstance(certificates, list) and certificates and all(isinstance(item, bytes) and item for item in certificates),
            "Malformed provisioning profile developer certificates")
    require(isinstance(leaf_certificate, bytes) and leaf_certificate and leaf_certificate in certificates,
            "Actual signing leaf certificate is not authorized by provisioning profile")

    if requirements.system_extension:
        require(entitlements.get(INSTALL) is True, "Provisioning profile does not authorize system-extension installation")
    if requirements.keychain_groups:
        allowed = strings(entitlements.get(KEYCHAIN, []), "profile Keychain allowlist")
        for group in requirements.keychain_groups:
            require(any(allows_identifier(pattern, group) for pattern in allowed),
                    "Provisioning profile does not authorize signed Keychain access group")
    groups_to_authorize = requirements.provisioned_groups
    if requirements.system_extension or requirements.keychain_groups:
        # With restricted claims, unallowlisted validation-required App Groups
        # can clear the process's entitlements-validated flag. Current Mac
        # profiles authorize the mixed namespace with TEAM_ID.* (DTS721701).
        groups_to_authorize += requirements.team_groups
    if groups_to_authorize:
        allowed = strings(entitlements.get(GROUPS, []), "profile App Group allowlist")
        for group in groups_to_authorize:
            require(any(allows_group(pattern, group, team) for pattern in allowed),
                    "Provisioning profile does not authorize signed App Group")
    return requirements
