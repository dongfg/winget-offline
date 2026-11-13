"""Build Windows installation bundles from official manifests, without running WinGet."""

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import time
from datetime import datetime, timezone
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen
import zipfile

import yaml


ROOT = Path(__file__).resolve().parent.parent
API = "https://api.github.com/repos/microsoft/winget-pkgs"
RAW = "https://raw.githubusercontent.com/microsoft/winget-pkgs"
TYPES = {"wix": ".msi", "msi": ".msi", "inno": ".exe", "nullsoft": ".exe",
         "burn": ".exe", "exe": ".exe", "msix": ".msix"}
TYPE_ORDER = {name: index for index, name in enumerate(TYPES)}
STRING_FIELDS = {"PackageVersion", "MinimumVersion", "DisplayVersion", "MinimumOSVersion",
                 "InstallerSha256", "SignatureSha256"}
CONTROL_FIELDS = {"PackageIdentifier", "PackageVersion", "ManifestType", "ManifestVersion"}


class ManifestLoader(yaml.SafeLoader):
    # Preserve date strings; WinGet schemas expect ReleaseDate to be a string.
    yaml_implicit_resolvers = {
        key: [(tag, regex) for tag, regex in values
              if tag not in {"tag:yaml.org,2002:timestamp", "tag:yaml.org,2002:bool"}]
        for key, values in yaml.SafeLoader.yaml_implicit_resolvers.items()
    }

    def construct_mapping(self, node, deep=False):
        result = {}
        for key_node, value_node in node.value:
            key = self.construct_object(key_node, deep=deep)
            if key in result:
                raise ValueError(f"Duplicate YAML key: {key}")
            result[key] = (self.construct_scalar(value_node) if key in STRING_FIELDS
                           else self.construct_object(value_node, deep=deep))
        return result


ManifestLoader.add_implicit_resolver(
    "tag:yaml.org,2002:bool", re.compile(r"^(?:true|false)$", re.IGNORECASE), list("tTfF")
)


def get_json(url):
    headers = {"User-Agent": "winget-offline-linux", "Accept": "application/vnd.github+json"}
    token = os.environ.get("WINGET_GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    try:
        with urlopen(Request(url, headers=headers), timeout=120) as response:
            return json.load(response)
    except HTTPError as error:
        raise ValueError(
            f"GitHub manifest API returned HTTP {error.code}. Check package ID/version; "
            "for API rate limits, supply WINGET_GITHUB_TOKEN through CNB secrets."
        ) from error


def download(url, destination, expected_hash=None):
    if urlparse(url).scheme not in {"https", "http"}:
        raise ValueError("Only HTTP(S) installer URLs are supported")
    for attempt in range(3):
        try:
            digest = hashlib.sha256()
            request = Request(url, headers={"User-Agent": "winget-offline-linux"})
            with urlopen(request, timeout=120) as response, destination.open("wb") as output:
                while chunk := response.read(1024 * 1024):
                    digest.update(chunk)
                    output.write(chunk)
            if expected_hash and digest.hexdigest().lower() != expected_hash.lower():
                raise ValueError(f"Installer SHA256 mismatch: {destination.name}")
            return
        except (HTTPError, URLError, TimeoutError, ConnectionError):
            if attempt == 2:
                raise
            time.sleep(2 ** (attempt + 1))


def numeric_version(value):
    if not re.fullmatch(r"v?\d+(?:\.\d+)*", value, re.IGNORECASE):
        return None
    parts = [int(part) for part in value.lstrip("vV").split(".")]
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def list_directory(path, snapshot):
    entries = get_json(f"{API}/contents/{quote(path, safe='/')}?ref={snapshot}")
    if not isinstance(entries, list):
        raise ValueError(f"Expected a manifest directory: {path}")
    # GitHub's contents endpoint truncates directories at 1,000 entries.
    if len(entries) >= 1000:
        raise ValueError(f"Manifest directory may be truncated: {path}; pin version explicitly")
    return entries


def load_manifests(package, snapshot, workspace):
    identifier = package["id"]
    base = f"manifests/{identifier[0].lower()}/" + identifier.replace(".", "/")
    version = package.get("version")
    if not version:
        versions = [item["name"] for item in list_directory(base, snapshot)
                    if item["type"] == "dir" and numeric_version(item["name"]) is not None]
        if not versions:
            raise ValueError(f"{identifier}: no numeric stable version; set version explicitly")
        version = max(versions, key=lambda item: (numeric_version(item), item))
    directory = f"{base}/{version}"
    documents = []
    for item in list_directory(directory, snapshot):
        if item["type"] != "file" or not item["name"].endswith(".yaml"):
            continue
        target = workspace / item["name"]
        download(f"{RAW}/{snapshot}/{quote(directory + '/' + item['name'], safe='/')}", target)
        document = yaml.load(target.read_text(encoding="utf-8-sig"), Loader=ManifestLoader)
        if (not isinstance(document, dict) or document.get("PackageIdentifier") != identifier
                or document.get("PackageVersion") != version):
            raise ValueError(f"Manifest ID/version mismatch: {item['name']}")
        documents.append(document)
    return version, documents


def singleton(documents):
    kinds = {}
    for document in documents:
        kinds.setdefault(document.get("ManifestType"), []).append(document)
    if "singleton" in kinds and len(documents) == 1:
        return copy.deepcopy(documents[0])
    for kind in ("version", "installer", "defaultLocale"):
        if len(kinds.get(kind, [])) != 1:
            raise ValueError(f"Expected one {kind} manifest")
    if set(kinds) - {"version", "installer", "defaultLocale", "locale"}:
        raise ValueError("Unsupported manifest layout")
    version, installer, locale = (kinds[kind][0] for kind in ("version", "installer", "defaultLocale"))
    if version.get("DefaultLocale") != locale.get("PackageLocale"):
        raise ValueError("Default locale does not match the version manifest")
    result = {**copy.deepcopy(installer), **copy.deepcopy(locale)}
    if kinds.get("locale"):
        result["Localization"] = [
            {key: value for key, value in document.items() if key not in CONTROL_FIELDS}
            for document in kinds["locale"]
        ]
    result["ManifestType"] = "singleton"
    result["ManifestVersion"] = max(
        (document["ManifestVersion"] for document in documents),
        key=lambda value: tuple(int(part) for part in value.split(".")),
    )
    return result


def select_installer(manifest, package, architecture):
    candidates = []
    desired_locale = package.get("locale", manifest["PackageLocale"]).lower()
    for entry in manifest.get("Installers", []):
        effective = {**manifest, **entry}
        arch, kind = effective.get("Architecture"), effective.get("InstallerType")
        scope, locale = effective.get("Scope"), effective.get("InstallerLocale", "").lower()
        if arch not in {architecture, "neutral"} or kind not in TYPES:
            continue
        if package.get("scope") and scope != package["scope"]:
            continue
        if package.get("installerType") and kind != package["installerType"]:
            continue
        if locale and locale != desired_locale:
            continue
        if effective.get("DownloadCommandProhibited") or effective.get("Authentication"):
            continue
        # Do not bypass dependencies inherited from either level.
        if manifest.get("Dependencies") or entry.get("Dependencies"):
            continue
        rank = (arch != architecture, {"machine": 0, "user": 1, None: 2}.get(scope, 3),
                locale != desired_locale, TYPE_ORDER[kind])
        candidates.append((rank, entry, kind))
    if not candidates:
        raise ValueError(
            f"{package['id']}: no supported dependency-free installer matches architecture, "
            "scope, installerType and locale; portable, ZIP, Store and authenticated downloads are excluded"
        )
    best = min(item[0] for item in candidates)
    matches = [item for item in candidates if item[0] == best]
    if len(matches) != 1:
        raise ValueError(f"{package['id']}: ambiguous installer selection; specify scope, installerType or locale")
    return copy.deepcopy(matches[0][1]), matches[0][2]


def validate_config(config):
    if config.get("architecture") not in {"x64", "x86", "arm64"}:
        raise ValueError("architecture must be x64, x86 or arm64")
    if not isinstance(config.get("packages"), list) or not config["packages"]:
        raise ValueError("packages must be a non-empty array")
    seen = set()
    for package in config["packages"]:
        identifier = package.get("id", "")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_+-]*(?:\.[A-Za-z0-9_+-]+)+", identifier):
            raise ValueError(f"Invalid package ID: {identifier}")
        if identifier.lower() in seen:
            raise ValueError(f"Duplicate package: {identifier}")
        seen.add(identifier.lower())
        for key, value in package.items():
            if key not in {"id", "version", "scope", "installerType", "locale"}:
                raise ValueError(f"Unknown package option: {key}")
            if not isinstance(value, str) or not value.strip():
                raise ValueError(f"{identifier}: {key} must be a non-empty string")
        if "scope" in package and package["scope"] not in {"user", "machine"}:
            raise ValueError(f"{identifier}: invalid scope")
        if "version" in package and any(c in package["version"] for c in ("/", "\\")):
            raise ValueError(f"{identifier}: invalid version path")
        if "installerType" in package and package["installerType"] not in TYPES:
            raise ValueError(f"{identifier}: unsupported installerType")


def build(config_path, output_directory):
    config = json.loads(config_path.read_text(encoding="utf-8-sig"))
    validate_config(config)
    snapshot = get_json(f"{API}/git/ref/heads/master")["object"]["sha"]
    print(f"Official manifest snapshot: {snapshot}", flush=True)
    lock = {"schemaVersion": 1, "architecture": config["architecture"],
            "builtAt": datetime.now(timezone.utc).isoformat(), "manifestRepositoryCommit": snapshot,
            "packages": []}
    with tempfile.TemporaryDirectory(prefix="winget-offline-linux-") as temporary:
        work = Path(temporary)
        bundle = work / "bundle"
        (bundle / "packages").mkdir(parents=True)
        (bundle / "manifests").mkdir()
        for package in config["packages"]:
            identifier = package["id"]
            source = work / identifier
            source.mkdir()
            version, documents = load_manifests(package, snapshot, source)
            manifest = singleton(documents)
            installer, kind = select_installer(manifest, package, config["architecture"])
            digest = installer.get("InstallerSha256", "")
            if not re.fullmatch(r"[a-fA-F0-9]{64}", digest):
                raise ValueError(f"{identifier}: invalid InstallerSha256")
            original_url = installer["InstallerUrl"]
            payload = f"packages/{digest.lower()}{TYPES[kind]}"
            print(f"Downloading {identifier} {version} ({kind}, {installer.get('Scope', manifest.get('Scope', 'unspecified'))})...", flush=True)
            download(original_url, bundle / payload, digest)
            installer["InstallerUrl"] = f"http://127.0.0.1:__PORT__/{payload}"
            manifest["Installers"] = [installer]
            manifest_path = f"manifests/{identifier}.yaml"
            (bundle / manifest_path).write_text(
                yaml.safe_dump(manifest, allow_unicode=True, sort_keys=False), encoding="utf-8"
            )
            lock["packages"].append({
                "id": identifier, "version": version, "manifest": manifest_path,
                "manifestSha256": hashlib.sha256((bundle / manifest_path).read_bytes()).hexdigest(),
                "scope": package.get("scope"),
                "payloads": [{"path": payload, "sha256": digest, "originalUrl": original_url,
                              "installerType": kind}],
            })
        (bundle / "packages.json").write_text(json.dumps(lock, ensure_ascii=False, indent=2), encoding="utf-8")
        for name in ("install.ps1", "server.ps1", "install.cmd"):
            shutil.copyfile(ROOT / "scripts" / name, bundle / name)
        for name in ("README.md", "LICENSE"):
            shutil.copyfile(ROOT / name, bundle / name)
        # Write outside dist first so a failed build cannot expose an incomplete ZIP.
        archive = work / "bundle.zip"
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=1) as output:
            for path in sorted(bundle.rglob("*")):
                if path.is_file():
                    output.write(path, path.relative_to(bundle).as_posix())
        output_directory.mkdir(parents=True, exist_ok=True)
        destination = output_directory / f"winget-offline-{config['architecture']}.zip"
        shutil.move(str(archive), destination)
        print(f"Created {destination}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=ROOT / "packages.json")
    parser.add_argument("--output-directory", type=Path, default=ROOT / "dist")
    arguments = parser.parse_args()
    try:
        build(arguments.config, arguments.output_directory)
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr, flush=True)
        sys.exit(1)
