"""Checks the CI proof files with tools that are not ours: poppler renders the PDF, Pillow reads the PNG, unzip tests the ZIP.

The sample document is 100 x 60 mm. It is rendered at 254 dpi, which is exactly 10 pixels per millimetre.
"""
import subprocess
import sys

from PIL import Image

PROOF = sys.argv[1] if len(sys.argv) > 1 else "proof"
failures = []


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (" " + detail if detail else ""))
    if not ok:
        failures.append(name)


# --- PDF rendered by poppler -------------------------------------------------------------------------------
subprocess.check_call(["pdftoppm", "-r", "254", "-png", "-singlefile", f"{PROOF}/document-sample.pdf", f"{PROOF}/document-sample-render"])
im = Image.open(f"{PROOF}/document-sample-render.png").convert("RGB")
check("render size is 1000 x 600 px", abs(im.size[0] - 1000) <= 2 and abs(im.size[1] - 600) <= 2, str(im.size))


def at(x_mm, y_mm):
    return im.getpixel((int(x_mm * 10), int(y_mm * 10)))


def near(a, b, tol=8):
    return all(abs(x - y) <= tol for x, y in zip(a, b))


expected = [
    ("paper", (95, 55), (255, 255, 255)),
    ("opaque red rectangle", (12, 12), (255, 0, 0)),
    ("50% green over white", (75, 20), (128, 255, 128)),
    ("multiply over red keeps only the red channel at half", (30, 25), (128, 0, 0)),
    ("multiply over white", (45, 35), (128, 128, 255)),
    ("image: opaque magenta half", (72, 45), (255, 0, 255)),
    ("image: transparent half shows the paper", (88, 45), (255, 255, 255)),
    ("ring outline is blue", (10, 45), (0, 0, 255)),
    ("ring is not filled", (20, 45), (255, 255, 255)),
]
for name, pos, want in expected:
    got = at(*pos)
    check(name, near(got, want), f"at {pos} mm got {got} want {want}")

# --- PNG written by our encoder ------------------------------------------------------------------------------
png = Image.open(f"{PROOF}/encoder-sample.png")
png.load()
check("PNG size", png.size == (4, 2), str(png.size))
check("PNG pixel", png.convert("RGBA").getpixel((1, 0)) == (30, 100, 200, 255), str(png.convert("RGBA").getpixel((1, 0))))
dpi = png.info.get("dpi", (0, 0))
check("PNG records 300 dpi", abs(dpi[0] - 300) < 1 and abs(dpi[1] - 300) < 1, str(dpi))

# --- ZIP -----------------------------------------------------------------------------------------------------
out = subprocess.run(["unzip", "-t", f"{PROOF}/zip-sample.zip"], capture_output=True, text=True)
print(out.stdout)
check("unzip -t finds no errors", "No errors detected" in out.stdout)

sys.exit(1 if failures else 0)
