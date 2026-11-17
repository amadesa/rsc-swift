#!/usr/bin/env python3
"""Builds the AltStore/SideStore source and the Cydia repo for a release.

    scripts/make-distribution.py SITE MAIN_IPA LEGACY_IPA

SITE is a checkout of the gh-pages branch, served at SITE_URL. The IPAs
are the release's (rsc-swift-<version>.ipa and the legacy one), which must
already be attached to the GitHub release v<version>: the AltStore source
links to them there. Writes:

    apps.json        AltStore/SideStore source (new version first, the
                     earlier ones kept)
    icon.png         the app icon, for the source and the repo
    index.html       the page with the add-source links (also the
                     packages' depiction)
    repo/            the Cydia repo: Packages(.gz/.bz2), Release,
                     CydiaIcon.png and debs/ with three packages:
      io.github.amadesa.rscswift         iphoneos-arm, iOS 12.2+ (rootful)
      io.github.amadesa.rscswift         iphoneos-arm64, rootless (/var/jb)
      io.github.amadesa.rscswift.legacy  iphoneos-arm, iOS 10 (32-bit)

The apps in the packages are fakesigned with ldid (brew install ldid) and
leave out the watch app, which a jailbreak can't install.
"""

import bz2
import datetime
import gzip
import hashlib
import io
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile

SITE_URL = "https://amadesa.github.io/rsc-swift"
REPO_URL = SITE_URL + "/repo/"
RELEASES = "https://github.com/amadesa/rsc-swift/releases/download"
HOMEPAGE = "https://github.com/amadesa/rsc-swift"
BUNDLE_ID = "io.github.amadesa.rscswift"
MAINTAINER = "amadesa <amadesa@users.noreply.github.com>"
APP_NAME = "rsc-swift.app"
TINT = "6E7F8C"

SUBTITLE = "RuneScape Classic on iPhone, iPad and Apple Watch."
DESCRIPTION = (
    "A native RuneScape Classic client built on the 2003scape rsc-c client, "
    "with a touch-first interface. Plays RSC Preservation and other "
    "Open-RSC worlds, and 2001Scape's May 2001 game. Includes an Apple "
    "Watch app, which plays through rsc-relay (see the README).\n\n"
    "An unofficial fan project, not affiliated with Jagex. Source and "
    "license (GNU AGPL v3.0): " + HOMEPAGE)

# for the jailbreak packages: an app in /Applications needs these for the
# keychain (saved accounts); it has no team, so the group is its own id
JAILBREAK_ENTITLEMENTS = {
    "application-identifier": BUNDLE_ID,
    "keychain-access-groups": [BUNDLE_ID],
}


def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL)


def info_plist(app):
    with open(os.path.join(app, "Info.plist"), "rb") as f:
        return plistlib.load(f)


def extract_app(ipa, into):
    with zipfile.ZipFile(ipa) as z:
        z.extractall(into)

    app = os.path.join(into, "Payload", APP_NAME)

    # zipfile drops the executable bits
    for root, _, files in os.walk(app):
        for name in files:
            path = os.path.join(root, name)
            if is_macho(path):
                os.chmod(path, 0o755)

    return app


def is_macho(path):
    with open(path, "rb") as f:
        magic = f.read(4)

    return magic in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe",
                     b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca")


def binaries(app):
    for root, _, files in os.walk(app):
        for name in sorted(files):
            path = os.path.join(root, name)
            if is_macho(path):
                yield path


def entitlements_of(binary):
    """The entitlements a binary is signed with (none if unsigned)."""
    result = subprocess.run(["ldid", "-e", binary], capture_output=True)
    if result.returncode != 0 or not result.stdout.strip():
        return {}
    try:
        return plistlib.loads(result.stdout)
    except Exception:
        return {}


# ---- AltStore / SideStore ------------------------------------------------

def app_permissions(app):
    """Every entitlement and usage description in the app and what it
    contains (the watch app), which AltStore checks against the IPA."""
    entitlements = set()
    privacy = {}

    for root, dirs, files in os.walk(app):
        if "Info.plist" in files and root.endswith(".app"):
            for key, value in info_plist(root).items():
                if key.endswith("UsageDescription"):
                    privacy[key] = value

    for binary in binaries(app):
        entitlements.update(entitlements_of(binary))

    # not listed, per AltStore's docs
    entitlements -= {"application-identifier",
                     "com.apple.developer.team-identifier"}

    return {"entitlements": sorted(entitlements), "privacy": privacy}


def update_source(site, ipa, app, notes, date):
    info = info_plist(app)
    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]

    entry = {
        "version": version,
        "buildVersion": build,
        "date": date,
        "localizedDescription": notes,
        "downloadURL": f"{RELEASES}/v{version}/{os.path.basename(ipa)}",
        "size": os.path.getsize(ipa),
        "minOSVersion": info.get("MinimumOSVersion", "12.2"),
    }

    path = os.path.join(site, "apps.json")
    versions = []
    if os.path.exists(path):
        with open(path) as f:
            old = json.load(f)
        for a in old.get("apps", []):
            if a.get("bundleIdentifier") == BUNDLE_ID:
                versions = [v for v in a.get("versions", [])
                            if (v["version"], v["buildVersion"]) != (version, build)]

    versions.insert(0, entry)

    source = {
        "name": "RSC",
        "identifier": BUNDLE_ID + ".source",
        "subtitle": SUBTITLE,
        "description": DESCRIPTION,
        "iconURL": SITE_URL + "/icon.png",
        "website": SITE_URL + "/",
        "tintColor": TINT,
        "featuredApps": [BUNDLE_ID],
        "apps": [{
            "name": "RSC",
            "bundleIdentifier": BUNDLE_ID,
            "developerName": "amadesa",
            "subtitle": SUBTITLE,
            "localizedDescription": DESCRIPTION,
            "iconURL": SITE_URL + "/icon.png",
            "tintColor": TINT,
            "category": "games",
            "versions": versions,
            "appPermissions": app_permissions(app),
            # what older AltStore and SideStore versions read
            "version": entry["version"],
            "versionDate": entry["date"],
            "versionDescription": entry["localizedDescription"],
            "downloadURL": entry["downloadURL"],
            "size": entry["size"],
        }],
        "news": [],
    }

    with open(path, "w") as f:
        json.dump(source, f, indent=2, ensure_ascii=False)
        f.write("\n")

    return version


# ---- Cydia ---------------------------------------------------------------

def ar_member(name, data, mtime):
    header = (name.ljust(16) + str(mtime).ljust(12) + "0".ljust(6) +
              "0".ljust(6) + "100644".ljust(8) + str(len(data)).ljust(10) +
              "`\n").encode()
    assert len(header) == 60
    return header + data + (b"\n" if len(data) % 2 else b"")


def tar_gz(entries, mtime):
    """entries: (archive path, local path or None for a directory, or
    bytes for a file's contents, mode)"""
    buffer = io.BytesIO()

    with gzip.GzipFile(fileobj=buffer, mode="wb", mtime=mtime) as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT) as tar:
            for name, source, mode in entries:
                info = tarfile.TarInfo(name)
                info.uid = info.gid = 0
                info.uname, info.gname = "root", "wheel"
                info.mtime = mtime
                info.mode = mode

                if source is None:
                    info.type = tarfile.DIRTYPE
                    tar.addfile(info)
                elif isinstance(source, bytes):
                    info.size = len(source)
                    tar.addfile(info, io.BytesIO(source))
                elif os.path.islink(source):
                    info.type = tarfile.SYMTYPE
                    info.linkname = os.readlink(source)
                    tar.addfile(info)
                else:
                    info.size = os.path.getsize(source)
                    with open(source, "rb") as f:
                        tar.addfile(info, f)

    return buffer.getvalue()


def app_entries(app, prefix):
    """The app's files under prefix (e.g. ./Applications), with the
    directories leading to it."""
    entries = []
    parts = prefix.strip("./").split("/")
    for i in range(len(parts)):
        entries.append(("./" + "/".join(parts[:i + 1]) + "/", None, 0o755))

    base = prefix.rstrip("/") + "/" + APP_NAME
    entries.append((base + "/", None, 0o755))

    for root, dirs, files in os.walk(app):
        dirs.sort()
        rel = os.path.relpath(root, app)
        target = base if rel == "." else base + "/" + rel
        for d in dirs:
            path = os.path.join(root, d)
            if os.path.islink(path):
                entries.append((target + "/" + d, path, 0o755))
            else:
                entries.append((target + "/" + d + "/", None, 0o755))
        for name in sorted(files):
            path = os.path.join(root, name)
            mode = 0o755 if is_macho(path) else 0o644
            entries.append((target + "/" + name, path, mode))

    return entries


def installed_size(app):
    total = 0
    for root, _, files in os.walk(app):
        for name in files:
            total += os.path.getsize(os.path.join(root, name))
    return (total + 1023) // 1024


def fakesign(app, work):
    """Signs every binary with ldid; the app's with the keychain
    entitlements."""
    entitlements = os.path.join(work, "entitlements.plist")
    with open(entitlements, "wb") as f:
        plistlib.dump(JAILBREAK_ENTITLEMENTS, f)

    shutil.rmtree(os.path.join(app, "_CodeSignature"), ignore_errors=True)

    main = os.path.join(app, info_plist(app)["CFBundleExecutable"])
    for binary in binaries(app):
        if binary == main:
            run("ldid", "-S" + entitlements, binary)
        else:
            run("ldid", "-S", binary)


def build_deb(app, out_dir, control, prefix, mtime):
    """prefix: ./Applications or ./var/jb/Applications"""
    app_path = prefix.lstrip(".") + "/" + APP_NAME

    # refresh the home screen's app list: uikittools-ng (current
    # jailbreaks) takes the app's path; older uicache takes none
    postinst = (f"#!/bin/sh\n"
                f"uicache -p {app_path} 2>/dev/null || uicache\n"
                f"exit 0\n").encode()
    postrm = (f"#!/bin/sh\n"
              f"if [ \"$1\" = remove ] || [ \"$1\" = purge ]; then\n"
              f"    uicache -u {app_path} 2>/dev/null || uicache\n"
              f"fi\n"
              f"exit 0\n").encode()

    control_text = "".join(f"{k}: {v}\n" for k, v in control.items()).encode()

    control_tar = tar_gz([
        ("./", None, 0o755),
        ("./control", control_text, 0o644),
        ("./postinst", postinst, 0o755),
        ("./postrm", postrm, 0o755),
    ], mtime)

    data_tar = tar_gz([("./", None, 0o755)] + app_entries(app, prefix), mtime)

    deb = (b"!<arch>\n" +
           ar_member("debian-binary", b"2.0\n", mtime) +
           ar_member("control.tar.gz", control_tar, mtime) +
           ar_member("data.tar.gz", data_tar, mtime))

    name = f"{control['Package']}_{control['Version']}_{control['Architecture']}.deb"
    with open(os.path.join(out_dir, name), "wb") as f:
        f.write(deb)

    return name, control_text


def hashes(data):
    return {"MD5sum": hashlib.md5(data).hexdigest(),
            "SHA1": hashlib.sha1(data).hexdigest(),
            "SHA256": hashlib.sha256(data).hexdigest()}


def build_repo(site, main_ipa, legacy_ipa, version, mtime):
    repo = os.path.join(site, "repo")
    debs = os.path.join(repo, "debs")
    shutil.rmtree(debs, ignore_errors=True)
    os.makedirs(debs)

    common = {
        "Version": version,
        "Section": "Games",
        "Maintainer": MAINTAINER,
        "Author": MAINTAINER,
        "Homepage": HOMEPAGE,
        "Icon": SITE_URL + "/icon.png",
        "Depiction": SITE_URL + "/",
    }

    description = ("RuneScape Classic client (unofficial). "
                   "iPhone and iPad; the Apple Watch app isn't included.")

    packages = [
        # (ipa, package, name, architecture, prefix, depends, conflicts)
        (main_ipa, BUNDLE_ID, "RSC", "iphoneos-arm", "./Applications",
         "firmware (>= 12.2)", BUNDLE_ID + ".legacy"),
        (main_ipa, BUNDLE_ID, "RSC", "iphoneos-arm64", "./var/jb/Applications",
         "firmware (>= 15.0)", None),
        (legacy_ipa, BUNDLE_ID + ".legacy", "RSC (iOS 10)", "iphoneos-arm",
         "./Applications", "firmware (>= 10.0), firmware (<< 11.0)", BUNDLE_ID),
    ]

    stanzas = []

    with tempfile.TemporaryDirectory() as work:
        signed = {}
        for ipa in (main_ipa, legacy_ipa):
            app = extract_app(ipa, os.path.join(work, os.path.basename(ipa)))
            # a jailbreak can't install the watch app
            shutil.rmtree(os.path.join(app, "Watch"), ignore_errors=True)
            fakesign(app, work)
            signed[ipa] = app

        for ipa, package, name, arch, prefix, depends, conflicts in packages:
            app = signed[ipa]
            control = {"Package": package, "Name": name, "Architecture": arch}
            control.update(common)
            control["Depends"] = depends
            if conflicts:
                control["Conflicts"] = conflicts
                control["Replaces"] = conflicts
            control["Installed-Size"] = str(installed_size(app))
            control["Description"] = description

            filename, text = build_deb(app, debs, control, prefix, mtime)
            with open(os.path.join(debs, filename), "rb") as f:
                data = f.read()

            stanza = text.decode()
            stanza += f"Filename: debs/{filename}\nSize: {len(data)}\n"
            stanza += "".join(f"{k}: {v}\n" for k, v in hashes(data).items())
            stanzas.append(stanza)

    packages_text = "\n".join(stanzas).encode()
    files = {
        "Packages": packages_text,
        "Packages.gz": gzip.compress(packages_text, mtime=mtime),
        "Packages.bz2": bz2.compress(packages_text),
    }
    for name, data in files.items():
        with open(os.path.join(repo, name), "wb") as f:
            f.write(data)

    release = (
        "Origin: RSC\n"
        "Label: RSC\n"
        "Suite: stable\n"
        "Version: 1.0\n"
        "Codename: ios\n"
        "Architectures: iphoneos-arm iphoneos-arm64\n"
        "Components: main\n"
        "Description: RSC, a RuneScape Classic client (unofficial)\n")
    for field, algorithm in (("MD5Sum", "md5"), ("SHA256", "sha256")):
        release += field + ":\n"
        for name, data in files.items():
            digest = hashlib.new(algorithm, data).hexdigest()
            release += f" {digest} {len(data)} {name}\n"

    with open(os.path.join(repo, "Release"), "w") as f:
        f.write(release)


# ---- the page --------------------------------------------------------------

PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>RSC</title>
<style>
:root {{ --bg: #f4f5f7; --card: #ffffff; --text: #1d2125; --muted: #5d6670;
        --line: #dde1e5; --button: #2d3a44; --button-text: #ffffff; }}
@media (prefers-color-scheme: dark) {{
  :root {{ --bg: #0f1214; --card: #1a1f23; --text: #e8ebee; --muted: #9aa4ad;
          --line: #2a3238; --button: #c9d2d9; --button-text: #11161a; }}
}}
* {{ box-sizing: border-box; }}
body {{ margin: 0; background: var(--bg); color: var(--text);
       font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }}
main {{ max-width: 560px; margin: 0 auto; padding: 32px 16px 48px; }}
header {{ display: flex; gap: 16px; align-items: center; margin-bottom: 20px; }}
header img {{ width: 72px; height: 72px; border-radius: 16px; }}
h1 {{ margin: 0; font-size: 28px; }}
h2 {{ font-size: 18px; margin: 28px 0 8px; }}
p {{ margin: 0 0 12px; }}
.muted {{ color: var(--muted); }}
.card {{ background: var(--card); border: 1px solid var(--line);
        border-radius: 14px; padding: 16px; margin-bottom: 12px; }}
.buttons {{ display: flex; flex-wrap: wrap; gap: 8px; margin-top: 10px; }}
a.button {{ display: inline-block; background: var(--button); color: var(--button-text);
           text-decoration: none; padding: 9px 14px; border-radius: 10px; font-weight: 600; }}
code {{ word-break: break-all; font-size: 14px; }}
a {{ color: inherit; }}
</style>
</head>
<body>
<main>
<header>
  <img src="icon.png" alt="">
  <div><h1>RSC</h1><p class="muted">{subtitle} Version {version}.</p></div>
</header>

<div class="card">
  <h2 style="margin-top:0">AltStore or SideStore</h2>
  <p class="muted">iOS 12.2 or later. Includes the Apple Watch app.</p>
  <div class="buttons">
    <a class="button" href="altstore://source?url={source}">Add to AltStore</a>
    <a class="button" href="sidestore://source?url={source}">Add to SideStore</a>
  </div>
  <p class="muted" style="margin-top:10px">Source: <code>{source}</code></p>
</div>

<div class="card">
  <h2 style="margin-top:0">Jailbroken devices</h2>
  <p class="muted">Cydia, Sileo or Zebra. iOS 10 on 32-bit devices (iPad 4,
  iPhone 5 and 5c), iOS 12.2 and later, and rootless jailbreaks on iOS 15
  and later. iPhone and iPad only.</p>
  <div class="buttons">
    <a class="button" href="cydia://url/https://cydia.saurik.com/api/share#?source={repo}">Add to Cydia</a>
    <a class="button" href="sileo://source/{repo}">Add to Sileo</a>
    <a class="button" href="zbra://sources/add/{repo}">Add to Zebra</a>
  </div>
  <p class="muted" style="margin-top:10px">Repo: <code>{repo}</code></p>
</div>

<div class="card">
  <h2 style="margin-top:0">Or download</h2>
  <p>The IPAs, to sideload with Sideloadly or another tool, are on the
  <a href="{homepage}/releases/latest">releases page</a>.</p>
  <p class="muted">To play on the Apple Watch, set up
  <a href="{homepage}#apple-watch">rsc-relay</a> first.</p>
</div>

<p class="muted">An unofficial fan project, not affiliated with Jagex.
RuneScape is a trademark of Jagex Ltd. Source and license (GNU AGPL v3.0):
<a href="{homepage}">github.com/amadesa/rsc-swift</a>.</p>
</main>
</body>
</html>
"""


def write_page(site, version):
    with open(os.path.join(site, "index.html"), "w") as f:
        f.write(PAGE.format(subtitle=SUBTITLE, version=version,
                            source=SITE_URL + "/apps.json", repo=REPO_URL,
                            homepage=HOMEPAGE))

    # GitHub Pages: serve files as they are
    open(os.path.join(site, ".nojekyll"), "w").close()


def write_icons(site, root):
    icon = os.path.join(root, "rsc-swift", "Assets.xcassets",
                        "AppIcon.appiconset", "AppIcon.png")
    os.makedirs(os.path.join(site, "repo"), exist_ok=True)
    run("sips", "-z", "512", "512", icon, "--out",
        os.path.join(site, "icon.png"))
    run("sips", "-z", "120", "120", icon, "--out",
        os.path.join(site, "repo", "CydiaIcon.png"))


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)

    site, main_ipa, legacy_ipa = sys.argv[1:]
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    if shutil.which("ldid") is None:
        sys.exit("ldid is needed: brew install ldid")

    notes = os.environ.get("RELEASE_NOTES", "")
    now = datetime.datetime.now(datetime.timezone.utc)
    mtime = int(now.timestamp())

    with tempfile.TemporaryDirectory() as work:
        app = extract_app(main_ipa, work)
        version = update_source(site, main_ipa, app, notes,
                                now.strftime("%Y-%m-%d"))

    write_icons(site, root)
    build_repo(site, main_ipa, legacy_ipa, version, mtime)
    write_page(site, version)

    print(f"built the source and repo for {version} in {site}")


if __name__ == "__main__":
    main()
