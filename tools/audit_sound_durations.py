#!/usr/bin/env python3
"""audit_sound_durations.py - developer-only validation tool.

Not part of the addon's runtime - never loaded by the .toc, never shipped
in a way that adds any in-game complexity. Run this by hand (or in CI)
whenever a shipped sound file changes, to catch two classes of problem
before they reach a player:

  1. SoundDurations.lua's registered duration for a sound no longer
     matches what's actually encoded in the shipped audio file (stale
     metadata - inflates or shrinks the Announcer's progress bar/duration
     text relative to the real clip, and previously misled the "how long
     should this be" investigation into what turned out to be corrupted
     source assets, not a code bug).
  2. The audio file itself is encoded in a way that's an outlier next to
     the rest of the library (unusual MPEG version/sample rate, or a
     size far too small for its declared frame count) - the actual root
     cause found for "Bad To The Bone" and "Dry Fart": both files' own
     LAME/Xing header declares MORE frames than the file's real byte
     length can hold, meaning the shipped file is a truncated/corrupted
     encode, not merely a short clip.

Pure Python 3 standard library only (no ffmpeg/mutagen/ID3 dependency) -
implements just enough of the MPEG-1/2/2.5 Layer III frame header spec to
walk every real audio frame in a file and sum its sample count. Flags
mismatches; NEVER auto-edits SoundDurations.lua or any audio file - a
human decides what a flagged mismatch actually means (stale metadata vs.
a genuinely corrupted asset needing a replacement recording).

Usage:
    python3 tools/audit_sound_durations.py [--repo-root PATH] [--tolerance SECONDS]

Exit code is non-zero if any duration mismatch or missing file was found,
so this can be wired into CI as a cheap sanity gate.
"""

import argparse
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# MPEG Audio Layer III frame header parsing
# ---------------------------------------------------------------------------

_BITRATES = {
    (1, 1): [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],
    (1, 2): [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
    (1, 3): [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
    (2, 1): [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],
    (2, 2): [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
}
_BITRATES[(2, 3)] = _BITRATES[(2, 2)]
_SAMPLERATES = {1: [44100, 48000, 32000], 2: [22050, 24000, 16000], 2.5: [11025, 12000, 8000]}
_CHANNEL_MODES = {0: "stereo", 1: "joint-stereo", 2: "dual-channel", 3: "mono"}


class Frame:
    __slots__ = ("version", "layer", "bitrate", "samplerate", "channel_mode",
                 "samples_per_frame", "frame_len", "offset")

    def __init__(self, version, layer, bitrate, samplerate, channel_mode, offset):
        self.version = version
        self.layer = layer
        self.bitrate = bitrate
        self.samplerate = samplerate
        self.channel_mode = channel_mode
        self.samples_per_frame = 1152 if (version == 1 and layer == 3) else (384 if layer == 1 else 576)
        vkey = 1 if version == 1 else 2
        padding_bit = 0  # filled in by caller if needed; not used for frame_len math below
        self.offset = offset
        self.frame_len = None  # computed by caller (needs the padding bit)


def _parse_header(b1, b2, b3, b4):
    if not (b1 == 0xFF and (b2 & 0xE0) == 0xE0):
        return None
    version_bits = (b2 >> 3) & 0x3
    layer_bits = (b2 >> 1) & 0x3
    if version_bits == 1 or layer_bits == 0:
        return None
    version = {0: 2.5, 2: 2, 3: 1}[version_bits]
    layer = {1: 3, 2: 2, 3: 1}[layer_bits]
    bitrate_idx = (b3 >> 4) & 0xF
    samplerate_idx = (b3 >> 2) & 0x3
    padding = (b3 >> 1) & 0x1
    if bitrate_idx in (0, 15) or samplerate_idx == 3:
        return None
    vkey = 1 if version == 1 else 2
    bitrate = _BITRATES[(vkey, layer)][bitrate_idx] * 1000
    samplerate = _SAMPLERATES[version][samplerate_idx]
    channel_mode = (b4 >> 6) & 0x3
    samples_per_frame = 1152 if (version == 1 and layer == 3) else (384 if layer == 1 else 576)
    if layer == 1:
        frame_len = (12 * bitrate // samplerate + padding) * 4
    else:
        frame_len = 144 * bitrate // samplerate + padding
    return {
        "version": version, "layer": layer, "bitrate": bitrate,
        "samplerate": samplerate, "channel_mode": _CHANNEL_MODES.get(channel_mode, "?"),
        "samples_per_frame": samples_per_frame, "frame_len": frame_len,
    }


def analyze_mp3(path: Path):
    """Walks every real MPEG frame in an MP3 file.

    Returns a dict: measured_seconds, frame_count, first_frame (version/
    samplerate/channel_mode of the very first frame - usually the LAME/
    Xing metadata frame itself), declared_frames (from that Xing/Info
    header, if present - None if the file has no such header), file_size.
    """
    data = path.read_bytes()
    offset = 0
    if data[:3] == b"ID3":
        size = ((data[6] & 0x7F) << 21) | ((data[7] & 0x7F) << 14) | ((data[8] & 0x7F) << 7) | (data[9] & 0x7F)
        offset = 10 + size

    declared_frames = None
    idx = data.find(b"Xing", offset, offset + 100)
    if idx < 0:
        idx = data.find(b"Info", offset, offset + 100)
    if idx > 0:
        flags = int.from_bytes(data[idx + 4:idx + 8], "big")
        p = idx + 8
        if flags & 0x1:
            declared_frames = int.from_bytes(data[p:p + 4], "big")

    pos = offset
    total_samples = 0
    frame_count = 0
    first_frame = None
    while pos < len(data) - 4:
        h = _parse_header(data[pos], data[pos + 1], data[pos + 2], data[pos + 3])
        if h:
            if first_frame is None:
                first_frame = h
            if h["frame_len"] <= 0:
                pos += 1
                continue
            total_samples += h["samples_per_frame"]
            frame_count += 1
            pos += h["frame_len"]
        else:
            pos += 1

    measured_seconds = (total_samples / first_frame["samplerate"]) if first_frame else None
    return {
        "measured_seconds": measured_seconds,
        "frame_count": frame_count,
        "first_frame": first_frame,
        "declared_frames": declared_frames,
        "file_size": len(data),
    }


# ---------------------------------------------------------------------------
# SoundDurations.lua parsing (read-only - this script never writes it)
# ---------------------------------------------------------------------------

_ENTRY_RE = re.compile(r'\["([^"]+)"\]\s*=\s*([\d.]+)')


def load_registered_durations(repo_root: Path):
    lua_path = repo_root / "SoundDurations.lua"
    text = lua_path.read_text(encoding="utf-8")
    entries = []
    for wow_path, dur in _ENTRY_RE.findall(text):
        parts = re.split(r"\\+", wow_path)
        try:
            idx = parts.index("Soundbook")
        except ValueError:
            continue
        rel = "/".join(parts[idx + 1:])
        entries.append((rel, float(dur)))
    return entries


def resolve_audio_file(repo_root: Path, rel_base: str):
    for ext in ("mp3", "ogg", "wav"):
        p = repo_root / f"{rel_base}.{ext}"
        if p.exists():
            return p
    return None


# ---------------------------------------------------------------------------
# Sounds.lua parsing (read-only) - which bundled sounds actually need a
# registered duration at all, independent of what SoundDurations.lua
# happens to already contain. Only "Legacy" and "German Memes" ship with
# real content (Category1/Category2 are empty placeholder folders for the
# player's own sounds, never bundled) - see Sounds.lua's own header.
# ---------------------------------------------------------------------------

_BUNDLED_CATEGORIES = ("Legacy", "German Memes")
_CATEGORY_BLOCK_RE = re.compile(r'\["(' + "|".join(re.escape(c) for c in _BUNDLED_CATEGORIES) + r')"\]\s*=\s*\{')
_NAME_ENTRY_RE = re.compile(r'\{\s*name\s*=\s*"((?:[^"\\]|\\.)*)"')


def load_bundled_sound_names(repo_root: Path):
    """Returns [(category, name), ...] for every entry under a bundled
    category in Sounds.lua - a plain regex walk, not a real Lua parser,
    but Sounds.lua's own header mandates this exact `{ name = "...", ... }`
    shape for every entry, so this is a faithful, low-risk read of it."""
    text = (repo_root / "Sounds.lua").read_text(encoding="utf-8")
    results = []
    for match in _CATEGORY_BLOCK_RE.finditer(text):
        category = match.group(1)
        start = match.end()
        # The block ends at the next top-level `["..."] = {` (any category,
        # bundled or not) or the closing of SoundbookSounds itself -
        # whichever comes first - so this never reads past its own list.
        next_block = re.search(r'\n\s*\["[^"]+"\]\s*=\s*\{', text[start:])
        end = start + next_block.start() if next_block else len(text)
        block = text[start:end]
        for name_match in _NAME_ENTRY_RE.finditer(block):
            name = name_match.group(1).replace('\\"', '"')
            results.append((category, name))
    return results


def expected_rel_base(category: str, name: str) -> str:
    # Mirrors SoundRegistry.lua's BuildFileBase for a category with real
    # content ("Legacy"/"German Memes" get their own named folder, not
    # "CategoryN\") - see that function's own comment for why.
    return f"Sounds/{category}/{name}"


# ---------------------------------------------------------------------------
# Main audit
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo-root", default=str(Path(__file__).resolve().parent.parent),
                         help="Path to the Soundbook addon repo root (default: parent of tools/)")
    parser.add_argument("--tolerance", type=float, default=0.05,
                         help="Seconds of registered-vs-measured drift to tolerate before flagging (default: 0.05)")
    args = parser.parse_args()

    repo_root = Path(args.repo_root)
    entries = load_registered_durations(repo_root)
    registered_lower = {rel.lower() for rel, _ in entries}

    # Coverage gap: a bundled sound (Sounds.lua) with NO registered
    # duration at all - not a mismatch, an outright missing entry. This is
    # the class of bug that left "Brother eeew" etc. with no progress bar
    # at all (relying on live learning, which a bundled sound should never
    # need) - measured here (same MPEG frame walk as everything else) so
    # a ready-to-paste SoundDurations.lua entry can be printed directly.
    coverage_gaps = []
    for category, name in load_bundled_sound_names(repo_root):
        rel_base = expected_rel_base(category, name)
        if rel_base.lower() in registered_lower:
            continue
        audio_path = resolve_audio_file(repo_root, rel_base)
        if not audio_path:
            coverage_gaps.append((category, name, rel_base, None, "no shipped file found either"))
            continue
        if audio_path.suffix.lower() != ".mp3":
            coverage_gaps.append((category, name, rel_base, None, f"unmeasured ({audio_path.suffix} - only .mp3 frame-walking is implemented)"))
            continue
        info = analyze_mp3(audio_path)
        if info["measured_seconds"] is None:
            coverage_gaps.append((category, name, rel_base, None, "no valid MPEG frames found"))
        else:
            coverage_gaps.append((category, name, rel_base, info["measured_seconds"], None))

    missing = []
    duration_mismatches = []
    encoding_outliers = []
    frame_count_suspects = []
    samplerate_counts = {}
    version_counts = {}
    checked_mp3 = 0

    for rel_base, registered in entries:
        audio_path = resolve_audio_file(repo_root, rel_base)
        if not audio_path:
            missing.append(rel_base)
            continue
        if audio_path.suffix.lower() != ".mp3":
            continue  # only MP3 frame-walking is implemented; .ogg/.wav are skipped, not flagged

        checked_mp3 += 1
        info = analyze_mp3(audio_path)
        if info["measured_seconds"] is None:
            print(f"WARN: no valid MPEG frames found at all in {audio_path}")
            continue

        samplerate_counts[info["first_frame"]["samplerate"]] = samplerate_counts.get(
            info["first_frame"]["samplerate"], 0) + 1
        version_counts[info["first_frame"]["version"]] = version_counts.get(
            info["first_frame"]["version"], 0) + 1

        diff = info["measured_seconds"] - registered
        if abs(diff) > args.tolerance:
            duration_mismatches.append((str(audio_path), registered, info["measured_seconds"], diff))

        # Encoding outlier: non-standard-for-this-library sample rate/version,
        # or a Xing/Info header that promises more frames than the file's
        # actual byte length can hold (the exact signature both known
        # corrupted assets share) - a strong, independent corroboration of
        # truncation, not just a duration-number mismatch.
        ff = info["first_frame"]
        is_rate_outlier = ff["samplerate"] != 44100 and ff["samplerate"] != 48000
        frame_shortfall = None
        if info["declared_frames"] is not None and info["declared_frames"] > 0:
            frame_shortfall = info["declared_frames"] - info["frame_count"]
            if frame_shortfall > max(2, info["declared_frames"] * 0.1):
                frame_count_suspects.append((str(audio_path), info["declared_frames"], info["frame_count"], frame_shortfall))
        if is_rate_outlier:
            encoding_outliers.append((str(audio_path), ff["version"], ff["samplerate"], ff["channel_mode"], info["file_size"]))

    print(f"Checked {checked_mp3} .mp3 files against SoundDurations.lua ({len(entries)} registered entries).\n")

    if coverage_gaps:
        print(f"--- {len(coverage_gaps)} bundled sound(s) in Sounds.lua have NO registered duration at all ---")
        for category, name, rel_base, measured, problem in coverage_gaps:
            if problem:
                print(f"  {category}::{name} ({rel_base}): {problem}")
            else:
                wow_path = "Interface\\\\AddOns\\\\Soundbook\\\\" + rel_base.replace("/", "\\\\")
                print(f"  {category}::{name}: measured={measured:.3f}s -> add to SoundDurations.lua:")
                print(f'    ["{wow_path}"] = {measured:.3f},')
        print()
    else:
        print("No coverage gaps. Every bundled Sounds.lua entry has a registered duration.\n")

    if missing:
        print(f"--- {len(missing)} registered entr{'y has' if len(missing)==1 else 'ies have'} no matching shipped file ---")
        for rel in missing:
            print(f"  MISSING: {rel}")
        print()

    if duration_mismatches:
        print(f"--- {len(duration_mismatches)} duration mismatch(es) beyond {args.tolerance}s tolerance ---")
        for path, registered, measured, diff in sorted(duration_mismatches, key=lambda x: -abs(x[3])):
            print(f"  {path}: registered={registered:.3f}s measured={measured:.3f}s diff={diff:+.3f}s")
        print()
    else:
        print("No duration mismatches beyond tolerance. Registered durations match their shipped files.\n")

    if frame_count_suspects:
        print(f"--- {len(frame_count_suspects)} file(s) whose own LAME/Xing header declares more frames than are actually present (likely truncated/corrupted encode) ---")
        for path, declared, actual, shortfall in frame_count_suspects:
            print(f"  {path}: header declares {declared} frames, only {actual} present ({shortfall} missing)")
        print()

    if encoding_outliers:
        print(f"--- {len(encoding_outliers)} file(s) with a sample rate outside 44.1/48kHz (unusual for this library) ---")
        for path, version, sr, chan, size in encoding_outliers:
            print(f"  {path}: MPEG version={version} samplerate={sr}Hz channels={chan} size={size}B")
        print()

    print(f"Sample rate distribution across checked files: {samplerate_counts}")
    print(f"MPEG version distribution across checked files: {version_counts}")

    problems = len(missing) + len(duration_mismatches) + len(coverage_gaps)
    if problems:
        print(f"\n{problems} issue(s) found - review above before shipping.")
        return 1
    print("\nNo issues found.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
