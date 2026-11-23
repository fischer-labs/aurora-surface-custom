#!/usr/bin/env python3
"""Generate shared/fixtures/recurrence.json using python-dateutil as the reference.

Semantics (see shared/README.md §5): wall-clock expansion in the event tz,
DTSTART always counts as the first occurrence (RFC 5545), exdates are
occurrence keys, overlap test against [rangeStart, rangeEnd).

  python -m venv .venv && .venv/bin/pip install python-dateutil
  .venv/bin/python shared/tools/gen_recurrence.py
"""
import json, pathlib
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo
from dateutil.rrule import rrulestr

OUT = pathlib.Path(__file__).resolve().parents[1] / "fixtures" / "recurrence.json"

CASES = [
  dict(name="weekly Tuesday across spring DST", tz="America/Chicago", start="2026-03-03T16:00", end="2026-03-03T17:30",
       rrule="FREQ=WEEKLY;BYDAY=TU", range=("2026-03-01T00:00", "2026-04-01T00:00"), utc=True),
  dict(name="daily every 3 days, count 5", tz="America/Chicago", start="2026-11-20T08:00", end="2026-11-20T08:30",
       rrule="FREQ=DAILY;INTERVAL=3;COUNT=5", range=("2026-11-01T00:00", "2027-01-01T00:00")),
  dict(name="every other week Mon/Wed/Fri", tz="America/Chicago", start="2026-11-02T07:30", end="2026-11-02T08:00",
       rrule="FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR", range=("2026-11-01T00:00", "2026-12-15T00:00")),
  dict(name="monthly on the 31st skips short months", tz="America/Chicago", start="2026-01-31T10:00", end="2026-01-31T11:00",
       rrule="FREQ=MONTHLY", range=("2026-01-01T00:00", "2027-01-01T00:00")),
  dict(name="second Tuesday monthly", tz="America/Chicago", start="2026-01-13T19:00", end="2026-01-13T20:30",
       rrule="FREQ=MONTHLY;BYDAY=2TU", range=("2026-01-01T00:00", "2026-07-01T00:00")),
  dict(name="last Friday monthly", tz="America/Chicago", start="2026-01-30T15:00", end="2026-01-30T16:00",
       rrule="FREQ=MONTHLY;BYDAY=-1FR", range=("2026-01-01T00:00", "2026-07-01T00:00")),
  dict(name="last weekday of month via BYSETPOS", tz="America/Chicago", start="2026-01-30T09:00", end="2026-01-30T09:30",
       rrule="FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1", range=("2026-01-01T00:00", "2026-07-01T00:00")),
  dict(name="yearly all-day birthday", tz="America/Chicago", start="2026-05-14", end="2026-05-15", allDay=True,
       rrule="FREQ=YEARLY", range=("2026-01-01T00:00", "2030-01-01T00:00")),
  dict(name="Feb 29 birthday only in leap years", tz="America/Chicago", start="2028-02-29", end="2028-03-01", allDay=True,
       rrule="FREQ=YEARLY", range=("2028-01-01T00:00", "2037-01-01T00:00")),
  dict(name="weekly Thursday until date-only (inclusive)", tz="America/Chicago", start="2026-11-05T18:00", end="2026-11-05T19:00",
       rrule="FREQ=WEEKLY;BYDAY=TH;UNTIL=20261217", range=("2026-11-01T00:00", "2027-01-01T00:00")),
  dict(name="daily until UTC instant", tz="America/Chicago", start="2026-11-20T23:30", end="2026-11-21T00:00",
       rrule="FREQ=DAILY;UNTIL=20261125T050000Z", range=("2026-11-01T00:00", "2026-12-01T00:00")),
  dict(name="exdate removes one occurrence", tz="America/Chicago", start="2026-11-02T15:00", end="2026-11-02T16:00",
       rrule="FREQ=WEEKLY;BYDAY=MO", exdates=["2026-11-16T15:00"], range=("2026-11-01T00:00", "2026-12-01T00:00")),
  dict(name="multi-day all-day event overlapping range", tz="America/Chicago", start="2026-12-23", end="2026-12-27", allDay=True,
       rrule=None, range=("2026-12-25T00:00", "2026-12-26T00:00")),
  dict(name="timed event crossing midnight into range", tz="America/Chicago", start="2026-11-22T22:00", end="2026-11-23T02:00",
       rrule=None, range=("2026-11-23T00:00", "2026-11-24T00:00")),
  dict(name="non-matching DTSTART still counts", tz="America/Chicago", start="2026-11-23T10:00", end="2026-11-23T11:00",
       rrule="FREQ=WEEKLY;BYDAY=WE;COUNT=3", range=("2026-11-01T00:00", "2027-01-01T00:00")),
  dict(name="Thanksgiving (4th Thursday of November)", tz="America/Chicago", start="2026-11-26", end="2026-11-27", allDay=True,
       rrule="FREQ=YEARLY;BYMONTH=11;BYDAY=4TH", range=("2026-01-01T00:00", "2030-01-01T00:00")),
  dict(name="last day of month", tz="America/Chicago", start="2026-01-31T12:00", end="2026-01-31T12:30",
       rrule="FREQ=MONTHLY;BYMONTHDAY=-1", range=("2026-01-01T00:00", "2026-07-01T00:00")),
  dict(name="weekends in London across DST", tz="Europe/London", start="2026-03-28T09:00", end="2026-03-28T10:00",
       rrule="FREQ=WEEKLY;BYDAY=SA,SU", range=("2026-03-28T00:00", "2026-04-06T00:00"), utc=True),
  dict(name="long-running daily, mid-series window", tz="America/Chicago", start="2025-01-01T07:00", end="2025-01-01T07:15",
       rrule="FREQ=DAILY", range=("2026-11-23T00:00", "2026-11-26T00:00")),
  dict(name="biweekly Friday Pacific across fall DST", tz="America/Los_Angeles", start="2026-10-23T17:00", end="2026-10-23T18:00",
       rrule="FREQ=WEEKLY;INTERVAL=2;BYDAY=FR", range=("2026-10-15T00:00", "2026-12-01T00:00"), utc=True),
  dict(name="every other month, count 4", tz="America/Chicago", start="2026-02-15T10:00", end="2026-02-15T11:00",
       rrule="FREQ=MONTHLY;INTERVAL=2;COUNT=4", range=("2026-01-01T00:00", "2027-01-01T00:00")),
  dict(name="weekly with implicit weekday", tz="America/Chicago", start="2026-11-25T18:00", end="2026-11-25T19:00",
       rrule="FREQ=WEEKLY", range=("2026-11-01T00:00", "2026-12-10T00:00")),
  dict(name="yearly on Jan 1 and Jul 1", tz="America/Chicago", start="2026-01-01", end="2026-01-02", allDay=True,
       rrule="FREQ=YEARLY;BYMONTH=1,7;BYMONTHDAY=1", range=("2026-01-01T00:00", "2028-01-01T00:00")),
  dict(name="first and third Monday", tz="America/Chicago", start="2026-12-07T18:30", end="2026-12-07T20:00",
       rrule="FREQ=MONTHLY;BYDAY=1MO,3MO", range=("2026-12-01T00:00", "2027-03-01T00:00")),
  dict(name="weekdays daily-style", tz="America/New_York", start="2026-11-20T08:15", end="2026-11-20T08:45",
       rrule="FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", range=("2026-11-20T00:00", "2026-12-01T00:00")),
  dict(name="all-day weekly exdate", tz="America/Chicago", start="2026-11-07", end="2026-11-08", allDay=True,
       rrule="FREQ=WEEKLY", exdates=["2026-11-28"], range=("2026-11-01T00:00", "2026-12-15T00:00")),
  dict(name="unsupported parts ignored gracefully", tz="America/Chicago", start="2026-11-02T09:00", end="2026-11-02T10:00",
       rrule="FREQ=WEEKLY;BYDAY=MO;X-NAME=foo;COUNT=3", range=("2026-11-01T00:00", "2027-01-01T00:00")),
]

def parse_local(s):
    return datetime.fromisoformat(s) if "T" in s else datetime.fromisoformat(s + "T00:00")

def key(dt, all_day):
    return dt.strftime("%Y-%m-%d") if all_day else dt.strftime("%Y-%m-%dT%H:%M")

def expand(c):
    tz = ZoneInfo(c["tz"]); all_day = c.get("allDay", False)
    start, end = parse_local(c["start"]), parse_local(c["end"])
    dur = end - start
    rs = parse_local(c["range"][0]).replace(tzinfo=tz); re_ = parse_local(c["range"][1]).replace(tzinfo=tz)
    occ = [start]
    if c.get("rrule"):
        parts = [p for p in c["rrule"].split(";") if not p.startswith("X-")]
        count = None; kept = []
        for p in parts:
            k, v = p.split("=", 1)
            if k == "COUNT": count = int(v); continue
            if k == "UNTIL":
                if v.endswith("Z"):
                    u = datetime.strptime(v, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc).astimezone(tz).replace(tzinfo=None)
                elif "T" in v:
                    u = datetime.strptime(v, "%Y%m%dT%H%M%S")
                else:
                    u = datetime.strptime(v, "%Y%m%d").replace(hour=23, minute=59, second=59)
                kept.append("UNTIL=" + u.strftime("%Y%m%dT%H%M%S")); continue
            kept.append(p)
        rule = ";".join(kept)
        def gen(n):
            r = rule + (f";COUNT={n}" if n is not None else "")
            return list(rrulestr(r, dtstart=start).between(start - timedelta(seconds=1), re_.replace(tzinfo=None) + timedelta(days=1), inc=True)) if n is None else list(rrulestr(r, dtstart=start))
        matches = gen(None) if count is None else gen(count)
        if start in matches:
            occ = matches
        else:
            if count is not None:
                matches = gen(count - 1) if count > 1 else []
            occ = [start] + matches
    ex = set(c.get("exdates", []))
    out, utc = [], []
    for o in occ:
        if key(o, all_day) in ex: continue
        s = o.replace(tzinfo=tz); e = (o + dur).replace(tzinfo=tz)
        if dur.total_seconds() == 0:
            hit = rs <= s < re_
        else:
            hit = s < re_ and e > rs
        if hit:
            out.append(key(o, all_day)); utc.append(s.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
    return out, utc

fixtures = []
for c in CASES:
    keys, utc = expand(c)
    f = {k: c[k] for k in ("name", "tz", "start", "end")}
    f["allDay"] = c.get("allDay", False)
    f["rrule"] = c.get("rrule")
    f["exdates"] = c.get("exdates", [])
    f["rangeStart"], f["rangeEnd"] = c["range"]
    f["expected"] = keys
    if c.get("utc"): f["expectedUtc"] = utc
    fixtures.append(f)
OUT.write_text(json.dumps({"_comment": "Generated by shared/tools/gen_recurrence.py — do not edit by hand.", "cases": fixtures}, indent=2) + "\n")
for f in fixtures:
    print(f"{f['name']}: {len(f['expected'])} -> {f['expected'][:6]}{' …' if len(f['expected'])>6 else ''}")
