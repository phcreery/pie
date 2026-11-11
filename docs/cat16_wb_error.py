#!/usr/bin/env python3

import numpy as np

# CAT16 from Smet and Ma, Color Res Appl. 2020;45:172-177.
CAT16_M = np.array(
    [
        [0.401288, 0.650173, -0.051461],
        [-0.250268, 1.204414, 0.045854],
        [-0.002079, 0.048952, 0.953127],
    ]
)
CAT16_M_INV = np.array(
    [
        [1.86206786, -1.01125463, 0.14918677],
        [0.38752654, 0.62144744, -0.00897398],
        [-0.01584150, -0.03412294, 1.04996444],
    ]
)

# Same values as src/math/matrices.zig.
XYZ_FROM_REC2020 = np.array(
    [
        [0.636958048301291, 0.1446169035862084, 0.16888097516417205],
        [0.2627002120112669, 0.6779980715188711, 0.05930171646986194],
        [0.0, 0.02807269304908745, 1.0609850577107907],
    ]
)
REC2020_FROM_XYZ = np.array(
    [
        [1.71665119, -0.35567078, -0.25336628],
        [-0.66668435, 1.61648124, 0.01576855],
        [0.01763986, -0.04277061, 0.94210312],
    ]
)

CONE_FROM_REC2020 = CAT16_M @ XYZ_FROM_REC2020
REC2020_FROM_CONE = REC2020_FROM_XYZ @ CAT16_M_INV
D65 = np.ones(3)

# CIE standard illuminants, XYZ with Y = 1.
ILLUMINANTS = (
    ("D75", (0.94972, 1.0, 1.22638)),
    ("D65", (0.95047, 1.0, 1.08883)),
    ("D60", (0.95264, 1.0, 1.00883)),
    ("D55", (0.95682, 1.0, 0.92149)),
    ("D50", (0.96422, 1.0, 0.82521)),
    ("A (2856 K)", (1.09850, 1.0, 0.35585)),
)


def cat16(rgb, src, dst):
    cone = CONE_FROM_REC2020 @ rgb
    cone = cone * (CONE_FROM_REC2020 @ dst) / (CONE_FROM_REC2020 @ src)
    return REC2020_FROM_CONE @ cone


def fmt(v):
    return ", ".join(f"{x:.3f}" for x in v)


print(
    "| illuminant \t| w0 (Rec.2020, g=1) \t| cat16(D65 -> 1/w0) \t| cat16(w0 -> D65) \t|"
)
for name, xyz in ILLUMINANTS:
    w0 = REC2020_FROM_XYZ @ xyz
    w0 = w0 / w0[1]
    old = cat16(w0, D65, 1.0 / w0)
    new = cat16(w0, w0, D65)
    print(f"| {name} \t| {fmt(w0)} \t| {fmt(old)} \t| {fmt(new)} \t|")

print()
print(
    "| illuminant \t| w0 (Rec.2020, g=1) \t| cat16(D65 -> 1/w0) \t| cat16(w0 -> D65) \t|"
)
for name, xyz in ILLUMINANTS:
    w0 = REC2020_FROM_XYZ @ xyz
    w0 = w0 / w0[1]
    old = cat16(D65, D65, 1.0 / w0)
    new = cat16(D65 * w0, w0, D65)
    print(f"| {name} \t| {fmt(w0)} \t| {fmt(old)} \t| {fmt(new)} \t|")
