#!/usr/bin/env python3
"""Exercise release packaging with a fake Zig compiler and real archive tools.

Failure cases: explicit-version precedence, tagged release normalization,
default version, malformed or non-stable version rejected before any build,
wrong target count, missing license, wrong embedded build version, and missing
release archives.
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import traceback
import zipfile

REPO = pathlib.Path(__file__).resolve().parent.parent
ARTIFACTS = REPO / "artifacts/package-version-e2e"
EXPECTED_TARGETS = [
    "aarch64-macos.15.0",
    "x86_64-macos.15.0",
    "aarch64-linux-musl",
    "x86_64-linux-musl",
    "x86_64-windows-gnu",
]
cases, records = [], []


def run_case(name, expected_version=None, env_overrides=None, invalid=False):
    with tempfile.TemporaryDirectory(prefix="doin-package-version-") as temp:
        root = pathlib.Path(temp)
        workspace = root / "workspace"
        workspace.mkdir()
        (workspace / "scripts").mkdir()
        shutil.copy2(REPO / "scripts/package.sh", workspace / "scripts/package.sh")
        shutil.copyfile(REPO / "LICENSE", workspace / "LICENSE")

        shim_dir = root / "shim"
        shim_dir.mkdir()
        requests = root / "zig-requests.jsonl"
        zig = shim_dir / "zig"
        zig.write_text(
            "#!" + sys.executable + "\n" + '''import json, os, pathlib, sys
args = sys.argv[1:]
with pathlib.Path(os.environ["PACKAGE_ZIG_LOG"]).open("a") as log:
    log.write(json.dumps(args) + "\\n")
prefix = pathlib.Path(args[args.index("--prefix") + 1])
target = next(arg.split("=", 1)[1] for arg in args if arg.startswith("-Dtarget="))
version = next(arg.split("=", 1)[1] for arg in args if arg.startswith("-Dversion="))
name = next(arg.split("=", 1)[1] for arg in args if arg.startswith("-Dname="))
binary = prefix / "bin" / (name + ".exe" if "windows" in target else name)
binary.parent.mkdir(parents=True, exist_ok=True)
binary.write_text("fixture target=" + target + " version=" + version + "\\n")
'''
        )
        zig.chmod(0o755)

        env = os.environ.copy()
        env.update(PATH=str(shim_dir) + os.pathsep + env["PATH"], PACKAGE_ZIG_LOG=str(requests))
        env.pop("DOIN_BUILD_VERSION", None)
        env.pop("GITHUB_REF_NAME", None)
        if env_overrides:
            env.update(env_overrides)
        result = subprocess.run(
            ["sh", "scripts/package.sh"], cwd=workspace, env=env,
            text=True, capture_output=True, timeout=60,
        )
        requested = [json.loads(line) for line in requests.read_text().splitlines()] if requests.exists() else []
        record = {
            "case": name,
            "exit": result.returncode,
            "stdout": result.stdout,
            "stderr": result.stderr,
            "build_calls": requested,
        }
        if invalid:
            assert result.returncode != 0, record
            assert not requested, record
            assert not (workspace / "dist").exists(), record
        else:
            assert result.returncode == 0, record
            targets = [next(arg.split("=", 1)[1] for arg in args if arg.startswith("-Dtarget=")) for args in requested]
            versions = [next(arg.split("=", 1)[1] for arg in args if arg.startswith("-Dversion=")) for args in requested]
            assert targets == EXPECTED_TARGETS, (targets, record)
            assert versions == [expected_version] * 5, (versions, record)
            assert len(list((workspace / "dist").glob("doin-*.tar.gz"))) == 4, record
            for archive in sorted((workspace / "dist").glob("doin-*.tar.gz")):
                with tarfile.open(archive, "r:gz") as bundle:
                    assert bundle.extractfile("LICENSE").read() == (workspace / "LICENSE").read_bytes(), archive.name
                    binary_name = archive.name.removeprefix("doin-").removesuffix(".tar.gz")
                    binary = bundle.extractfile("doin")
                    assert binary is not None and f"version={expected_version}".encode() in binary.read(), archive.name
            windows = workspace / "dist/doin-windows-x86_64.zip"
            with zipfile.ZipFile(windows) as bundle:
                assert bundle.read("LICENSE") == (workspace / "LICENSE").read_bytes()
                assert f"version={expected_version}".encode() in bundle.read("doin.exe")
            sums = (workspace / "dist/SHA256SUMS").read_text().splitlines()
            assert len(sums) == 5, sums
        records.append(record)


def case(name, fn):
    try:
        fn()
        cases.append({"name": name, "passed": True})
    except Exception:
        cases.append({"name": name, "passed": False, "failure": traceback.format_exc()})


def valid_versions():
    run_case("explicit version takes precedence", "2.4.6", {"DOIN_BUILD_VERSION": "v2.4.6", "GITHUB_REF_NAME": "v8.8.8"})
    run_case("v-prefixed release tag is normalized", "0.4.0", {"GITHUB_REF_NAME": "v0.4.0"})
    run_case("default release version", "0.3.0")


def invalid_versions():
    for version in ("feature/luna", "v1.2", "1.2.3-rc.1", "1.2.3+build.4", "01.2.3", "vv1.2.3"):
        run_case("reject " + version, env_overrides={"DOIN_BUILD_VERSION": version}, invalid=True)


case("version selection reaches all five builds and archives retain version and license", valid_versions)
case("invalid or non-stable versions fail before build or output creation", invalid_versions)
report = {"cases": cases, "records": records}
ARTIFACTS.mkdir(parents=True, exist_ok=True)
(ARTIFACTS / "results.json").write_text(json.dumps(report, indent=2))
for item in cases:
    print(("PASS " if item["passed"] else "FAIL ") + item["name"])
print("Evidence: " + str(ARTIFACTS / "results.json"))
raise SystemExit(0 if all(item["passed"] for item in cases) else 1)
