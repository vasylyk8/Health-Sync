#!/usr/bin/env python3
"""Shrinks an Apple Health export into two small files for checking KROK's numbers.

Usage (Mac Terminal, in the folder that holds the export):
    python3 krok_extract.py export.zip   # or the unzipped .../export.xml
Writes next to it:
    krok_records.csv.gz  every reading of the types still being checked (no heart rate)
    krok_daily.csv.gz    per day, per type, per source: count, sum, min, max (all types)
Only the Python standard library is used. Nothing is sent anywhere.
"""
import csv, gzip, os, re, sys, time, zipfile
import xml.etree.ElementTree as ET
from datetime import datetime

# Types whose every reading is kept (the open questions: floors, distance, steps, energy,
# sound levels, noise alerts, sleep, resting HR). Everything else only goes into the daily file.
RAW = {
    "StepCount", "DistanceWalkingRunning", "FlightsClimbed", "ActiveEnergyBurned", "BasalEnergyBurned",
    "AppleExerciseTime", "AppleStandTime", "TimeInDaylight", "RestingHeartRate", "WalkingHeartRateAverage",
    "EnvironmentalAudioExposure", "HeadphoneAudioExposure", "EnvironmentalSoundReduction",
    "AudioExposureEvent", "EnvironmentalAudioExposureEvent", "HeadphoneAudioExposureEvent", "SleepAnalysis",
}
PREFIXES = ("HKQuantityTypeIdentifier", "HKCategoryTypeIdentifier", "HKDataType")


def short(t):
    for p in PREFIXES:
        if t.startswith(p):
            return t[len(p):]
    return t


def epoch(s):
    return int(datetime.strptime(s, "%Y-%m-%d %H:%M:%S %z").timestamp())


def device_of(d):
    if not d:
        return ""
    # e.g. "<<HKDevice: 0x..>, name:Apple Watch, manufacturer:Apple Inc., model:Watch, hardware:Watch6,1, software:10.4>"
    m = re.search(r"hardware:(.*?)(?:, \w+:|>)", d) or re.search(r"model:(.*?)(?:, \w+:|>)", d)
    return m.group(1).strip() if m else ""


def open_xml(path):
    if zipfile.is_zipfile(path):
        z = zipfile.ZipFile(path)
        name = next(n for n in z.namelist() if n.endswith("/export.xml") or n == "export.xml")
        return z.open(name)
    return open(path, "rb")


def main(path):
    out_dir = os.path.dirname(os.path.abspath(path))
    rec_path = os.path.join(out_dir, "krok_records.csv.gz")
    day_path = os.path.join(out_dir, "krok_daily.csv.gz")
    sources, daily = {}, {}
    n = kept = 0
    t0 = time.time()
    with gzip.open(rec_path, "wt", newline="") as rf:
        rw = csv.writer(rf)
        rw.writerow(["type", "source", "device", "start", "seconds", "value"])
        depth, root = 0, None
        for ev, el in ET.iterparse(open_xml(path), events=("start", "end")):
            if ev == "start":
                if root is None:
                    root = el
                depth += 1
                continue
            depth -= 1
            if el.tag != "Record" or depth != 1:
                if depth == 1:
                    root.clear()
                continue
            n += 1
            a = el.attrib
            t = short(a.get("type", ""))
            src = a.get("sourceName", "")
            sid = sources.setdefault(src, len(sources))
            raw_v = a.get("value", "")
            try:
                v = float(raw_v)
            except ValueError:
                v = None
            start, end = a.get("startDate", ""), a.get("endDate", "")
            if t in RAW:
                s0 = epoch(start)
                rw.writerow([t, sid, device_of(a.get("device")), s0, epoch(end) - s0, raw_v.replace("HKCategoryValue", "")])
                kept += 1
            key = (start[:10], t, sid)
            d = daily.get(key)
            x = v if v is not None else 0.0
            if d is None:
                daily[key] = [1, x, x, x]
            else:
                d[0] += 1; d[1] += x
                if x < d[2]: d[2] = x
                if x > d[3]: d[3] = x
            root.clear()  # drop finished elements, or memory grows with the whole file
            if n % 500000 == 0:
                print(f"{n:,} readings ({time.time() - t0:.0f}s)", flush=True)
    with gzip.open(day_path, "wt", newline="") as df:
        dw = csv.writer(df)
        dw.writerow(["date", "type", "source", "count", "sum", "min", "max"])
        for (day, t, sid), (c, s, lo, hi) in sorted(daily.items()):
            dw.writerow([day, t, sid, c, round(s, 4), round(lo, 4), round(hi, 4)])
        dw.writerow([])
        dw.writerow(["# sources"])
        for name, sid in sorted(sources.items(), key=lambda kv: kv[1]):
            dw.writerow(["#", sid, name])
    print(f"done: {n:,} readings, {kept:,} kept in full, {time.time() - t0:.0f}s")
    for p in (rec_path, day_path):
        print(f"  {p}  {os.path.getsize(p) / 1e6:.1f} MB")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
