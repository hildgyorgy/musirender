#!/usr/bin/env python3
"""Generate lossless test audio or compare a digital WAV capture sample by sample."""

import argparse
from array import array
from pathlib import Path
import random
import struct
import subprocess
import sys
import wave


PCM_GUID_SUFFIX = bytes.fromhex("00001000800000aa00389b71")
SYNC_FRAMES = 64


def generate(folder):
    folder.mkdir(parents=True, exist_ok=False)
    for rate, bits in [(44_100, 16), (96_000, 24)]:
        reference = folder / f"{rate}Hz-{bits}bit.wav"
        random_source = random.Random(rate)
        amplitude = 1 << (bits - 5)
        width = bits // 8
        samples = bytearray()
        for _ in range(rate * 2):
            sample = random_source.getrandbits(bits - 4) - amplitude
            samples.extend(sample.to_bytes(width, "little", signed=True))
        with wave.open(str(reference), "wb") as file:
            file.setparams((2, width, rate, 0, "NONE", "not compressed"))
            file.writeframes(samples)
        subprocess.run(["afconvert", "-f", "m4af", "-d", "alac", str(reference),
                        str(reference.with_suffix(".m4a"))], check=True)
        print(f"{reference.name} / {reference.with_suffix('.m4a').name}")


def read_wav(file):
    raw = file.read_bytes()
    if len(raw) < 12 or raw[:4] != b"RIFF" or raw[8:12] != b"WAVE":
        raise ValueError(f"{file.name}: expected a RIFF WAV file")
    riff_end = 8 + struct.unpack_from("<I", raw, 4)[0]
    if not 12 <= riff_end <= len(raw):
        raise ValueError(f"{file.name}: invalid RIFF length")

    chunks = {}
    offset = 12
    while offset + 8 <= riff_end:
        chunk_id, size = struct.unpack_from("<4sI", raw, offset)
        start = offset + 8
        if start + size > riff_end:
            raise ValueError(f"{file.name}: truncated WAV chunk")
        if chunk_id in (b"fmt ", b"data"):
            if chunk_id in chunks:
                raise ValueError(f"{file.name}: multiple {chunk_id!r} chunks")
            chunks[chunk_id] = memoryview(raw)[start:start + size]
        offset = start + size + size % 2
    header = chunks.get(b"fmt ", b"")
    data = chunks.get(b"data", b"")
    if len(header) < 16 or not data:
        raise ValueError(f"{file.name}: missing WAV format or audio")

    encoding, channels, rate, _, frame_bytes, bits = struct.unpack_from("<HHIIHH", header)
    valid_bits = bits
    if encoding == 0xFFFE:
        if len(header) < 40 or struct.unpack_from("<H", header, 16)[0] < 22:
            raise ValueError(f"{file.name}: invalid WAVE_FORMAT_EXTENSIBLE header")
        valid_bits, = struct.unpack_from("<H", header, 18)
        encoding, = struct.unpack_from("<I", header, 24)
        if header[28:40] != PCM_GUID_SUFFIX:
            raise ValueError(f"{file.name}: unsupported WAV subformat")

    integer = encoding == 1 and bits in (16, 24, 32)
    floating = encoding == 3 and bits in (32, 64) and valid_bits == bits
    width = bits // 8
    if not (integer or floating) or not 1 <= valid_bits <= bits:
        raise ValueError(f"{file.name}: expected signed 16/24/32-bit PCM or 32/64-bit float PCM")
    if rate == 0 or channels == 0 or frame_bytes != width * channels or len(data) % frame_bytes:
        raise ValueError(f"{file.name}: invalid WAV frame layout")

    normalized = array("i")
    if integer:
        shift = 32 - bits
        padding_mask = (1 << (bits - valid_bits)) - 1
        for index in range(0, len(data), width):
            value = int.from_bytes(data[index:index + width], "little", signed=True)
            if value & padding_mask:
                raise ValueError(f"{file.name}: nonzero bits in PCM padding at sample {index // width}")
            normalized.append(value << shift)
    else:
        kind = "<f" if bits == 32 else "<d"
        for index, (value,) in enumerate(struct.iter_unpack(kind, data)):
            scaled = value * (1 << 31)
            if not scaled.is_integer() or not -(1 << 31) <= scaled < (1 << 31):
                raise ValueError(f"{file.name}: float sample {index} cannot be represented exactly as signed PCM32")
            normalized.append(int(scaled))
    if sys.byteorder != "little":
        normalized.byteswap()
    return rate, channels, normalized.tobytes()


def find_offset(reference, capture, frame_bytes):
    marker = reference[:frame_bytes * SYNC_FRAMES]
    offset = capture.find(marker)
    match = None
    while offset != -1:
        if offset % frame_bytes == 0:
            if match is not None:
                raise ValueError("the reference starts at multiple offsets; specify --offset in frames")
            match = offset // frame_bytes
        offset = capture.find(marker, offset + 1)
    if match is None:
        raise ValueError("reference start not found; supply --offset if the capture alignment is known")
    return match


def compare(reference_file, capture_file, offset):
    ref_rate, ref_channels, reference = read_wav(reference_file)
    rate, channels, capture = read_wav(capture_file)
    if (rate, channels) != (ref_rate, ref_channels):
        raise ValueError(f"format mismatch: reference {ref_rate} Hz/{ref_channels} ch, "
                         f"capture {rate} Hz/{channels} ch")
    frame_bytes = channels * 4
    if offset is None:
        offset = find_offset(reference, capture, frame_bytes)
    if offset < 0:
        raise ValueError("offset must be nonnegative")
    start = offset * frame_bytes
    recorded = capture[start:start + len(reference)]
    if len(recorded) != len(reference):
        raise ValueError("capture ends before the reference segment is complete")

    frames = len(reference) // frame_bytes
    if recorded == reference:
        print(f"PASS: {frames:,} frames, {rate} Hz, {channels} channels, capture offset {offset} frames")
        return 0

    differences = 0
    for sample, ((expected,), (actual,)) in enumerate(zip(
        struct.iter_unpack("<i", reference), struct.iter_unpack("<i", recorded)
    )):
        if expected != actual:
            if differences == 0:
                print(f"First mismatch at reference frame {sample // channels}, channel {sample % channels + 1}: "
                      f"expected PCM32 {expected}, got {actual}")
            differences += 1
    print(f"FAIL: {differences:,} of {frames * channels:,} samples differ (capture offset {offset} frames)")
    return 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    make = commands.add_parser("generate", help="create reference WAV and ALAC files in a new directory")
    make.add_argument("directory", type=Path)
    check = commands.add_parser("compare", help="compare a reference WAV with an unprocessed digital WAV capture")
    check.add_argument("reference", type=Path)
    check.add_argument("capture", type=Path)
    check.add_argument("--offset", type=int, help="first reference frame in the capture; otherwise find it automatically")
    arguments = parser.parse_args()
    try:
        if arguments.command == "generate":
            generate(arguments.directory)
            return 0
        return compare(arguments.reference, arguments.capture, arguments.offset)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
