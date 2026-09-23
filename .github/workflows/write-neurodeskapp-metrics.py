#!/usr/bin/env python3
"""Generate the Neurodesk App release-download figure from GitHub data."""

from __future__ import annotations

import argparse
import json
import os
import re
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter, FixedLocator


API_URL = "https://api.github.com/repos/neurodesk/neurodesk-app/releases?per_page=100"
DEFAULT_OUTPUT = Path("public/docs/overview/neurodeskapp_metrics.png")


@dataclass(frozen=True)
class ReleaseDownloads:
    tag: str
    published_at: datetime
    windows: int
    linux: int
    macos: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--input-json",
        type=Path,
        help="Read a saved GitHub releases API response instead of fetching it.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help=f"Output PNG path (default: {DEFAULT_OUTPUT}).",
    )
    return parser.parse_args()


def fetch_releases() -> list[dict[str, Any]]:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "neurodesk-metrics-generator",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"

    releases: list[dict[str, Any]] = []
    next_url: str | None = API_URL
    while next_url:
        request = urllib.request.Request(next_url, headers=headers)
        with urllib.request.urlopen(request, timeout=30) as response:
            releases.extend(json.load(response))
            next_url = next_link_url(response.headers.get("Link"))
    return releases


def next_link_url(link_header: str | None) -> str | None:
    if not link_header:
        return None
    for link in link_header.split(","):
        parts = [part.strip() for part in link.split(";")]
        if len(parts) < 2 or 'rel="next"' not in parts[1:]:
            continue
        url = parts[0]
        if url.startswith("<") and url.endswith(">"):
            return url[1:-1]
    return None


def read_releases(input_json: Path | None) -> list[dict[str, Any]]:
    if input_json is None:
        return fetch_releases()
    with input_json.open(encoding="utf-8") as handle:
        return json.load(handle)


def classify_asset(name: str) -> str | None:
    if re.search(r"windows.*\.exe$", name, re.IGNORECASE):
        return "windows"
    if re.search(r"(debian|fedora).*\.((deb)|(rpm))$", name, re.IGNORECASE):
        return "linux"
    if re.search(r"macos.*\.((dmg)|(zip))$", name, re.IGNORECASE):
        return "macos"
    return None


def summarize_releases(raw_releases: list[dict[str, Any]]) -> list[ReleaseDownloads]:
    releases: list[ReleaseDownloads] = []
    for release in raw_releases:
        if release.get("draft") or not release.get("published_at"):
            continue

        counts = {"windows": 0, "linux": 0, "macos": 0}
        for asset in release.get("assets", []):
            platform = classify_asset(asset.get("name", ""))
            if platform:
                counts[platform] += int(asset.get("download_count", 0))

        releases.append(
            ReleaseDownloads(
                tag=release["tag_name"],
                published_at=datetime.fromisoformat(
                    release["published_at"].replace("Z", "+00:00")
                ),
                windows=counts["windows"],
                linux=counts["linux"],
                macos=counts["macos"],
            )
        )

    return sorted(releases, key=lambda release: release.published_at)


def format_downloads(value: float, _position: float | None = None) -> str:
    return f"{int(value):,}"


def generate_figure(releases: list[ReleaseDownloads], output: Path) -> None:
    if not releases:
        raise RuntimeError("No published releases were returned by the GitHub API.")

    x = list(range(len(releases)))
    series = [
        ("Windows", [release.windows for release in releases], "#377EB8", "o"),
        ("Linux", [release.linux for release in releases], "#E6833A", "s"),
        ("macOS", [release.macos for release in releases], "#2FA45A", "^"),
    ]
    total_downloads = sum(sum(values) for _, values, _, _ in series)
    generated_at = datetime.now(timezone.utc)

    plt.rcParams.update(
        {
            "font.family": "DejaVu Sans",
            "font.size": 11,
            "axes.titleweight": "bold",
            "axes.titlesize": 20,
            "axes.labelsize": 12,
        }
    )
    figure, axis = plt.subplots(figsize=(16, 6.5), dpi=160)
    figure.patch.set_facecolor("white")
    axis.set_facecolor("#FAFBFC")

    for label, values, color, marker in series:
        cumulative = sum(values)
        axis.plot(
            x,
            values,
            color=color,
            linewidth=2.4,
            marker=marker,
            markersize=5,
            markeredgecolor="white",
            markeredgewidth=0.8,
            label=f"{label} — {cumulative:,} downloads",
            zorder=3,
        )
        axis.annotate(
            f"{values[-1]:,}",
            (x[-1], values[-1]),
            xytext=(8, 0),
            textcoords="offset points",
            color=color,
            fontsize=10,
            fontweight="bold",
            va="center",
        )

    axis.set_yscale("symlog", linthresh=1, linscale=0.6)
    axis.yaxis.set_major_locator(FixedLocator([0, 1, 10, 100, 1_000, 10_000]))
    axis.yaxis.set_major_formatter(FuncFormatter(format_downloads))
    axis.grid(axis="y", which="major", color="#D7DCE2", linewidth=0.8)
    axis.grid(axis="y", which="minor", color="#E9ECEF", linewidth=0.5)

    axis.set_xlim(-0.5, len(releases) - 0.15)
    axis.set_xticks(x)
    axis.set_xticklabels(
        [f"{release.tag}\n{release.published_at:%Y-%m-%d}" for release in releases],
        rotation=48,
        ha="right",
        fontsize=9,
    )
    axis.set_ylabel("Downloads per release (log scale)")
    axis.set_xlabel("Neurodesk App release and published date")

    for spine in ("top", "right"):
        axis.spines[spine].set_visible(False)
    axis.spines["left"].set_color("#AEB6BF")
    axis.spines["bottom"].set_color("#AEB6BF")

    axis.set_title(
        "Neurodesk App downloads per release and operating system",
        loc="left",
        pad=30,
    )
    axis.text(
        0,
        1.035,
        (
            f"{total_downloads:,} platform downloads across {len(releases)} releases "
            f"• {releases[0].published_at:%b %Y}–{releases[-1].published_at:%b %Y}"
        ),
        transform=axis.transAxes,
        color="#4D5966",
        fontsize=11,
        va="bottom",
    )
    axis.legend(
        loc="upper left",
        frameon=False,
        ncol=3,
        bbox_to_anchor=(0, 1.01),
        borderaxespad=0,
        handlelength=2.4,
        columnspacing=1.8,
    )

    figure.text(
        0.075,
        0.012,
        (
            "Source: GitHub release asset download counts. macOS = DMG + ZIP; "
            "Linux = DEB + RPM; Windows = EXE. Metadata assets excluded. "
            f"Updated {generated_at:%d %b %Y} UTC."
        ),
        color="#5D6873",
        fontsize=9,
    )
    figure.subplots_adjust(left=0.075, right=0.965, top=0.82, bottom=0.25)

    output.parent.mkdir(parents=True, exist_ok=True)
    figure.savefig(output, facecolor=figure.get_facecolor())
    plt.close(figure)


def main() -> None:
    args = parse_args()
    releases = summarize_releases(read_releases(args.input_json))
    generate_figure(releases, args.output)
    print(f"Wrote {args.output} from {len(releases)} releases.")


if __name__ == "__main__":
    main()
