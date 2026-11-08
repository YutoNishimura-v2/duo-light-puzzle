"""Replay OdaiCam's costume-figure rules on realperson ``*-frames.json`` logs.

Mirrors ``EffectEngine.implausibleReason`` / ``consistent`` / ``trustedBodies``
in ``OdaiCam/Sources/Effects.swift``. Keep the two in lockstep: this script is
how the thresholds are tuned without a 45-minute CI run.

Usage:
    python analyze.py <dir with *-frames.json> [key=value ...]

Keys are the entries of ``DEFAULTS`` (e.g. ``torso_tiny=0.01``).
"""
from __future__ import annotations

import glob
import json
import math
import os
import sys
from collections import Counter

Point = tuple[float, float]
Joints = dict[str, Point]

DEFAULTS: dict[str, float] = {
    "torso_max": 0.45,        # torso longer than this (fraction of frame) -> giant diagonal figure
    "torso_tiny": 0.01,       # torso shorter than this -> no torso at all
    "torso_min_ratio": 0.05,  # torso shorter than this x body size -> arms-only bar
    "arm": 1.4,
    "leg": 1.8,
    "short_leg": 0.6,
    "ref_size": 0.4,          # bones are compared with max(torso, body size x ref_size)
    "ratio_lo": 0.6,
    "ratio_hi": 1.6,
    "jump": 0.2,
    "hold": 0.8,              # seconds the last trusted pose is kept
    "carry": 0.3,             # seconds a lost joint is filled from the trusted pose
    "acquire": 3,             # consecutive ok frames before a new figure is shown
    "min_person_ratio": 0.5,  # skeleton smaller than this x biggest person -> background person
    "joint_step": 0.12,       # a joint moving farther than this in one frame is a misdetection
    "upper_head_neck_max": 0.35,  # head-and-shoulders: face farther than this from the neck -> misdetection
    "upper_shoulder_ratio": 3,    # shoulder farther than this x neck-to-face -> misdetection
    "upper_arm_ratio": 4,         # arm bone longer than this x neck-to-face -> long_bone
}

HIPS = ("left_upLeg_joint", "right_upLeg_joint")
KNEES = ("left_leg_joint", "right_leg_joint")
SHOULDERS = ("left_shoulder_1_joint", "right_shoulder_1_joint")


def mid(a: Point | None, b: Point | None) -> Point | None:
    """Midpoint of two points, or None if either is missing."""
    if a is None or b is None:
        return None
    return ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)


def dist(a: Point, b: Point) -> float:
    """Euclidean distance."""
    return math.hypot(a[0] - b[0], a[1] - b[1])


def extent(j: Joints) -> tuple[float, float, float, float] | None:
    """Bounding box (x, y, w, h) of the joints, or None for fewer than 3."""
    if len(j) < 3:
        return None
    xs = [p[0] for p in j.values()]
    ys = [p[1] for p in j.values()]
    return min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)


def neck_of(j: Joints) -> Point | None:
    """Neck, or the middle of both shoulders."""
    return j.get("neck_1_joint") or mid(j.get(SHOULDERS[0]), j.get(SHOULDERS[1]))


def root_of(j: Joints) -> Point | None:
    """Hip centre: root, both hips, one hip, or halfway from neck to the knees."""
    hips = [j[h] for h in HIPS if h in j]
    if j.get("root"):
        return j["root"]
    if hips:
        return (sum(p[0] for p in hips) / len(hips), sum(p[1] for p in hips) / len(hips))
    neck = neck_of(j)
    knees = [j[k] for k in KNEES if k in j]
    if neck is None or not knees:
        return None
    knee = (sum(p[0] for p in knees) / len(knees), sum(p[1] for p in knees) / len(knees))
    return ((neck[0] + knee[0]) / 2, (neck[1] + knee[1]) / 2)


FACE = ("head_joint", "left_eye_joint", "right_eye_joint", "left_ear_joint", "right_ear_joint")
ARMS = (("left_shoulder_1_joint", "left_forearm_joint"), ("right_shoulder_1_joint", "right_forearm_joint"),
        ("left_forearm_joint", "left_hand_joint"), ("right_forearm_joint", "right_hand_joint"))


def head_of(j: Joints) -> Point | None:
    """Face point: nose, mid-eyes, one eye, mid-ears, one ear (EffectEngine.headPoint)."""
    nose, le, re, lr, rr = (j.get(k) for k in FACE)
    return nose or mid(le, re) or le or re or mid(lr, rr) or lr or rr


def is_upper_body(j: Joints) -> bool:
    """Head-and-shoulders skeleton: a neck but no hip centre."""
    return neck_of(j) is not None and root_of(j) is None


def upper_body_reason(j: Joints, neck: Point, p: dict[str, float]) -> str | None:
    """Mirror EffectEngine.upperBodyReason: is a head-and-shoulders skeleton plausible?"""
    shoulders = [j[s] for s in SHOULDERS if s in j]
    head = head_of(j)
    if head is None or not shoulders or "left_foot_joint" in j or "right_foot_joint" in j:
        return "no_hip"
    head_neck = dist(head, neck)
    if head_neck < 0.01 or head_neck > p["upper_head_neck_max"]:
        return "upper_far"
    if any(dist(s, neck) > head_neck * p["upper_shoulder_ratio"] for s in shoulders):
        return "upper_far"
    for a, b in ARMS:
        if a in j and b in j and dist(j[a], j[b]) > head_neck * p["upper_arm_ratio"]:
            return "long_bone"
    return None


def is_background(c: Joints, frame: dict, p: dict[str, float]) -> bool:
    """Mirror EffectEngine.isBackgroundPerson (upper bodies inside a big person box are kept)."""
    biggest = frame.get("biggest_person", 0.0)
    box = extent(c)
    if not biggest or box is None:
        return False
    if is_upper_body(c):
        cx, cy = box[0] + box[2] / 2, box[1] + box[3] / 2
        return not any(b[3] >= biggest * p["min_person_ratio"]
                       and b[0] - 0.05 <= cx <= b[0] + b[2] + 0.05 and b[1] - 0.05 <= cy <= b[1] + b[3] + 0.05
                       for b in frame.get("boxes", []))
    return max(box[2], box[3]) < biggest * p["min_person_ratio"]


def reason(j: Joints, p: dict[str, float]) -> str | None:
    """Why the skeleton is not a plausible single person, or None if it is."""
    neck = neck_of(j)
    if neck is None:
        return "no_neck"
    root = root_of(j)
    if root is None:
        return upper_body_reason(j, neck, p)
    box = extent(j)
    if box is None:
        return "few_joints"
    torso = dist(neck, root)
    size = max(box[2], box[3])
    if torso <= p["torso_tiny"]:
        return "torso_tiny"
    if torso > p["torso_max"]:
        return "torso_over_45pct"
    if torso < size * p["torso_min_ratio"]:
        return "torso_short_for_body"
    ref = max(torso, size * p["ref_size"])
    bones = [("left_shoulder_1_joint", "left_forearm_joint", p["arm"]),
             ("right_shoulder_1_joint", "right_forearm_joint", p["arm"]),
             ("left_forearm_joint", "left_hand_joint", p["arm"]),
             ("right_forearm_joint", "right_hand_joint", p["arm"]),
             ("left_upLeg_joint", "left_leg_joint", p["leg"]),
             ("right_upLeg_joint", "right_leg_joint", p["leg"]),
             ("left_leg_joint", "left_foot_joint", p["leg"]),
             ("right_leg_joint", "right_foot_joint", p["leg"])]
    for a, b, most in bones:
        if a in j and b in j and dist(j[a], j[b]) > ref * most:
            return "long_bone"
    for side in ("left", "right"):
        hip, knee, ankle = (j.get(side + s) for s in ("_upLeg_joint", "_leg_joint", "_foot_joint"))
        if hip and knee and ankle and dist(hip, knee) + dist(knee, ankle) < torso * p["short_leg"]:
            return "short_leg"
    return None


def consistent(j: Joints, prev: Joints, p: dict[str, float]) -> bool:
    """Same person as the previous pose: similar size and no big jump."""
    a, b = extent(j), extent(prev)
    if a is None or b is None:
        return True
    sa, sb = max(a[2], a[3]), max(b[2], b[3])
    if sb <= 0:
        return True
    jump = math.hypot(a[0] + a[2] / 2 - b[0] - b[2] / 2, a[1] + a[3] / 2 - b[1] - b[3] / 2)
    return p["ratio_lo"] <= sa / sb <= p["ratio_hi"] and jump <= p["jump"]


def smooth(drawn: Joints, before: Joints) -> Joints:
    """Mirror bodyJoints' smoothing: average with the previous frame unless a joint moved far."""
    out = dict(drawn)
    for name, q in drawn.items():
        r = before.get(name)
        if r is not None and dist(q, r) < 0.08:
            out[name] = ((q[0] + r[0]) / 2, (q[1] + r[1]) / 2)
    return out


def jitter_p95(track: list[Joints], width: float = 540, height: float = 960) -> float:
    """95th percentile of each joint's second difference in pixels (main.swift's joint_jitter_px_p95)."""
    accel = []
    for i in range(1, len(track) - 1):
        for name, q in track[i].items():
            a, b = track[i - 1].get(name), track[i + 1].get(name)
            if a is None or b is None:
                continue
            accel.append(math.hypot((b[0] - 2 * q[0] + a[0]) * width, (b[1] - 2 * q[1] + a[1]) * height))
    accel.sort()
    return accel[min(len(accel) - 1, int(len(accel) * 0.95))] if accel else -1.0


def replay(frames: list[dict], p: dict[str, float],
           track: list[Joints] | None = None) -> tuple[float, Counter]:
    """Run the trust/hold rules over the frames; return (shown rate, hidden reasons).

    If ``track`` is given, the drawn (smoothed) joints of every frame are appended to it.
    """
    trusted: Joints = {}
    t_time = -1e9
    seen: dict[str, float] = {}
    streak = 0
    shown, why = 0, Counter()
    smoothed: Joints = {}
    for f in frames:
        t = f["t"]
        c: Joints = {k: tuple(v) for k, v in f["candidate"].items()}
        recent = t - t_time < p["hold"] and bool(trusted)
        fresh = list(c)
        if c and recent:
            # one joint leaping away in a single frame is Vision grabbing a neighbour: treat it as lost
            fresh = [k for k, v in c.items() if k not in trusted or dist(v, trusted[k]) <= p["joint_step"]]
            c = {k: c[k] for k in fresh}
            for name, q in trusted.items():
                if name not in c and t - seen.get(name, -1e9) < p["carry"]:
                    c[name] = q
        if not c:
            d = "no_body"
        elif is_background(c, f, p):
            d = "background_person"
        else:
            d = reason(c, p) or ("ok" if (not recent or consistent(c, trusted, p)) else "jump")
        streak = streak + 1 if d == "ok" else 0
        drawn: Joints = {}
        if d == "ok" and (recent or streak >= p["acquire"]):
            for name in fresh:
                seen[name] = t
            if "root" not in c and not any(h in c for h in HIPS) and (r := root_of(c)) is not None:
                c["root"] = r
            trusted, t_time = c, t
            drawn = c
            shown += 1
        elif recent and d != "background_person":
            drawn = trusted
            shown += 1
        else:
            if d != "ok":
                trusted = {}
            why[d] += 1
        if drawn:
            mixed = smooth(drawn, smoothed)
            # bodyJoints: if mixing broke a plausible pose, draw the unmixed one
            smoothed = drawn if reason(mixed, p) and not reason(drawn, p) else mixed
        else:
            smoothed = {}
        if track is not None:
            track.append(smoothed)
    return shown / max(len(frames), 1), why


def main() -> None:
    """Print the simulated and logged shown rate for each clip."""
    folder = sys.argv[1]
    p = dict(DEFAULTS)
    for kv in sys.argv[2:]:
        k, v = kv.split("=")
        p[k] = float(v)
    for path in sorted(glob.glob(os.path.join(folder, "*-frames.json"))):
        with open(path, encoding="utf-8") as fh:
            frames = json.load(fh)
        track: list[Joints] = []
        rate, why = replay(frames, p, track)
        name = os.path.basename(path).replace("-frames.json", "")
        logged = sum(f["visible"] for f in frames) / max(len(frames), 1)
        print(f"{name:10s} sim={rate:.3f} logged={logged:.3f} jitter_p95={jitter_p95(track):.1f}px"
              f" hidden_by={dict(why.most_common())}")


if __name__ == "__main__":
    main()
