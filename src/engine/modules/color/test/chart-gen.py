import pathlib
import numpy as np
import colour

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

def vkdt_white_from_w0(w0):
    w0 = np.asarray(w0, dtype=np.float64)
    return 1.0 / (w0 / w0[1])

CMFS = colour.MSDS_CMFS["CIE 1931 2 Degree Standard Observer"]
CC = colour.SDS_COLOURCHECKERS["ColorChecker N Ohta"]
CC_NAMES = list(CC.keys())
CC_SDS = [CC[n] for n in CC_NAMES]
ILL_D65 = colour.SDS_ILLUMINANTS["D65"]
ONES = colour.SpectralDistribution(dict.fromkeys(ILL_D65.wavelengths, 1.0))
SHAPE = ILL_D65.shape


def xyz_under(sd, ill):
    return colour.sd_to_XYZ(sd, CMFS, ill) / 100.0

def illum_D(T):
    return colour.sd_CIE_illuminant_D_series(colour.temperature.CCT_to_xy_CIE_D(T))

def scene(T):
    """-> (sim [24x3 camera-like Rec.2020, white G=1], w0 [3], truth [24x3 Rec.2020 under D65])"""
    ill = illum_D(T)
    w = REC2020_FROM_XYZ @ xyz_under(ONES, ill)
    g = w[1]
    sim = np.array([REC2020_FROM_XYZ @ xyz_under(sd, ill) for sd in CC_SDS]) / g
    truth = np.array([REC2020_FROM_XYZ @ xyz_under(sd, ILL_D65) for sd in CC_SDS])
    return sim, w / g, truth


def patch_image(colours, cols, size):
    rows = -(-len(colours) // cols)
    img = np.zeros((rows * size, cols * size, 3), dtype=np.float32)
    for i, c in enumerate(colours):
        r, k = divmod(i, cols)
        img[r * size : (r + 1) * size, k * size : (k + 1) * size] = c
    return img

def write_pfm(path, img):
    img = np.ascontiguousarray(img, dtype="<f4")
    h, w, _ = img.shape
    with open(path, "wb") as f:
        f.write(f"PF\n{w} {h}\n-1.0\n".encode())  # negative scale = little endian; rows are not flipped
        f.write(img.tobytes())

CHART_DIR = pathlib.Path("charts")


def export_chart(T, size=100):
    sim, w0, _ = scene(T)
    img = patch_image(sim, cols=6, size=size)  # 6 x 4 patches
    CHART_DIR.mkdir(exist_ok=True)
    path = CHART_DIR / f"chart_{T}K.pfm"
    write_pfm(path, img)
    wh = vkdt_white_from_w0(w0)
    print(f"{path}  {img.shape[1]}x{img.shape[0]}  white sliders {wh[0]:.5f}:{wh[1]:.0f}:{wh[2]:.5f}")


for T in (2500, 6500, 7500, 15000):
    export_chart(T)