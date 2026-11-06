#!/usr/bin/env python3
"""Check the contract layout and identity tables without compiling CoreAudio."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
MAP_C = ROOT / "src" / "FlowMultichannelMap.c"
MAP_H = ROOT / "src" / "FlowMultichannelMap.h"
DRIVER_H = ROOT / "src" / "FlowVirtualAudioMultichannel.h"
STEREO_H = ROOT / "src" / "FlowVirtualAudio.h"

EXPECTED = {
    "MC_LAYOUT_MONO": (1, ["MC_LABEL_M"]),
    "MC_LAYOUT_STEREO": (2, ["MC_LABEL_FL", "MC_LABEL_FR"]),
    "MC_LAYOUT_3_0": (3, ["MC_LABEL_FL", "MC_LABEL_FR", "MC_LABEL_FC"]),
    "MC_LAYOUT_4_0": (4, ["MC_LABEL_FL", "MC_LABEL_FR", "MC_LABEL_BL",
                          "MC_LABEL_BR"]),
    "MC_LAYOUT_5_1_SIDE": (6, ["MC_LABEL_FL", "MC_LABEL_FR", "MC_LABEL_FC",
                               "MC_LABEL_LFE", "MC_LABEL_SL", "MC_LABEL_SR"]),
    "MC_LAYOUT_5_1_BACK": (6, ["MC_LABEL_FL", "MC_LABEL_FR", "MC_LABEL_FC",
                               "MC_LABEL_LFE", "MC_LABEL_BL", "MC_LABEL_BR"]),
    "MC_LAYOUT_7_1": (8, ["MC_LABEL_FL", "MC_LABEL_FR", "MC_LABEL_FC",
                          "MC_LABEL_LFE", "MC_LABEL_SL", "MC_LABEL_SR",
                          "MC_LABEL_BL", "MC_LABEL_BR"]),
    "MC_LAYOUT_5_1_2": (8, ["MC_LABEL_FL", "MC_LABEL_FR", "MC_LABEL_FC",
                            "MC_LABEL_LFE", "MC_LABEL_SL", "MC_LABEL_SR",
                            "MC_LABEL_TFL", "MC_LABEL_TFR"]),
    "MC_LAYOUT_7_1_2": (10, ["MC_LABEL_FL", "MC_LABEL_FR", "MC_LABEL_FC",
                             "MC_LABEL_LFE", "MC_LABEL_SL", "MC_LABEL_SR",
                             "MC_LABEL_BL", "MC_LABEL_BR", "MC_LABEL_TFL",
                             "MC_LABEL_TFR"]),
    "MC_LAYOUT_7_1_4": (12, ["MC_LABEL_FL", "MC_LABEL_FR", "MC_LABEL_FC",
                             "MC_LABEL_LFE", "MC_LABEL_SL", "MC_LABEL_SR",
                             "MC_LABEL_BL", "MC_LABEL_BR", "MC_LABEL_TFL",
                             "MC_LABEL_TFR", "MC_LABEL_TRL", "MC_LABEL_TRR"]),
}


def fail(message: str) -> None:
    raise SystemExit("FAIL: " + message)


def main() -> int:
    map_text = MAP_C.read_text(encoding="utf-8")
    header_text = MAP_H.read_text(encoding="utf-8")
    driver_header = DRIVER_H.read_text(encoding="utf-8")
    stereo_header = STEREO_H.read_text(encoding="utf-8")

    pattern = re.compile(
        r"\.layout\s*=\s*(MC_LAYOUT_[A-Z0-9_]+).*?"
        r"\.channelCount\s*=\s*(\d+).*?"
        r"\.labels\s*=\s*\{([^}]*)\}",
        re.S,
    )
    parsed = {}
    for match in pattern.finditer(map_text):
        layout, count, labels_text = match.groups()
        labels = re.findall(r"MC_LABEL_[A-Z0-9_]+", labels_text)
        parsed[layout] = (int(count), labels)

    for layout, (count, labels) in EXPECTED.items():
        if layout not in parsed:
            fail(f"layout table is missing {layout}")
        actual_count, actual_labels = parsed[layout]
        if actual_count != count or actual_labels != labels:
            fail(f"{layout} table mismatch: {actual_count} {actual_labels}")
    if len(parsed) != len(EXPECTED):
        fail(f"unexpected layout row count {len(parsed)}")

    max_channels = re.search(r"#define\s+MC_MAX_CHANNELS\s+(\d+)", header_text)
    if not max_channels or int(max_channels.group(1)) < 12:
        fail("MC_MAX_CHANNELS must cover the 12-channel RES layout")

    ids = re.findall(r"\b(kMCObject(?:Device|Stream)[A-Za-z0-9_]+)\s*=\s*(\d+)",
                     driver_header)
    if len(ids) != 14:
        fail(f"expected 7 device/stream pairs, found {len(ids) // 2}")
    if len({value for _, value in ids}) != len(ids):
        fail("device/stream object IDs are not unique")
    expected_ids = {
        "kMCObjectDeviceStereo": "2", "kMCObjectStreamStereo": "3",
        "kMCObjectDeviceMono": "4", "kMCObjectStreamMono": "5",
        "kMCObjectDevice30": "6", "kMCObjectStream30": "7",
        "kMCObjectDevice40": "8", "kMCObjectStream40": "9",
        "kMCObjectDevice51S": "10", "kMCObjectStream51S": "11",
        "kMCObjectDevice51B": "12", "kMCObjectStream51B": "13",
        "kMCObjectDevice71": "14", "kMCObjectStream71": "15",
    }
    for name, value in expected_ids.items():
        if (name, value) not in ids:
            fail(f"contract object ID mismatch for {name}")

    if "#define MC_DEVICE_COUNT 7" not in driver_header:
        fail("MC_DEVICE_COUNT is not 7")
    if 'MC_DEVICE_UID_STEREO "com.homepodflow.virtual-audio.stereo.v1"' not in driver_header:
        fail("production stereo UID is not in the production identity block")
    if 'MC_DEVICE_UID_STEREO "com.homepodflow.virtual-audio.dev.stereo.v1"' not in driver_header:
        fail("dev stereo UID is not distinct from the production stereo UID")
    if 'FLOW_DEVICE_UID "com.homepodflow.virtual-audio.stereo.v1"' not in stereo_header:
        fail("production stereo UID changed")
    if 'MC_LAYOUT_7_1' not in map_text or 'MC_LABEL_SL, MC_LABEL_SR, MC_LABEL_BL, MC_LABEL_BR' not in map_text:
        fail("7.1 side-before-back order is missing")
    if '"source_padded"' not in map_text:
        fail("source_padded provenance token is missing")
    print("PASS multichannel tables: 7 R1 devices, contract IDs, 7.1 side/back order, "
          "source_padded, height RES names")
    return 0


if __name__ == "__main__":
    sys.exit(main())
