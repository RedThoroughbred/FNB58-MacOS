"""1200x627 LinkedIn Featured card for The AI Choice (matches the app cards' style)."""
from PIL import Image, ImageDraw, ImageFilter, ImageFont
import sys, os

REPO = "/Users/sethegger/Library/Application Support/Claude/scratch-workspaces/ba5054e8-e1a6-4abb-a8c1-dd2f216d10b6/2642fc77-dd0d-4736-b70b-ebbf7f2eeffe/scratch-2026-09-25-a40dc7/FNB58-MacOS"
OUT = os.path.join(REPO, "ios/AppStore/badges/featured-book.png")
COVER_SRC = "book-cover.jpg"
COVER_DST = os.path.join(REPO, "ios/AppStore/badges/book-cover.jpg")
FONT = "/System/Library/Fonts/SFNS.ttf"

def font(size, weight):
    f = ImageFont.truetype(FONT, size)
    try:
        names = [n.decode() if isinstance(n, bytes) else n for n in f.get_variation_names()]
        for cand in (weight, "Semibold", "Medium", "Regular"):
            if cand in names:
                f.set_variation_by_name(cand); break
    except Exception as e:
        print("variation:", e)
    return f

W, H = 1200, 627
# background: same soft light gradient as the app cards
bg = Image.new("RGB", (W, H))
px = bg.load()
for y in range(H):
    t = y / (H - 1)
    r = int(246 - 8 * t); g = int(246 - 8 * t); b = int(248 - 6 * t)
    for x in range(W):
        px[x, y] = (r, g, b)

# cover tile 380x380 with rounded corners + soft shadow
S = 380; X0, Y0 = 80, (H - S) // 2
cover = Image.open(COVER_SRC).convert("RGB").resize((S, S), Image.LANCZOS)
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, S - 1, S - 1), radius=64, fill=255)
shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
sd = ImageDraw.Draw(shadow)
sd.rounded_rectangle((X0 + 4, Y0 + 14, X0 + S + 4, Y0 + S + 14), radius=64, fill=(0, 0, 0, 70))
shadow = shadow.filter(ImageFilter.GaussianBlur(18))
bg = Image.alpha_composite(bg.convert("RGBA"), shadow).convert("RGB")
bg.paste(cover, (X0, Y0), mask)

d = ImageDraw.Draw(bg)
TX = X0 + S + 52
ink = (28, 28, 30); sub = (60, 60, 67); grey = (110, 110, 118)
y = 150
d.text((TX, y), "The AI Choice", font=font(60, "Bold"), fill=ink); y += 74
d.text((TX, y), "Into the Light, Into the Dark", font=font(34, "Semibold"), fill=sub); y += 58
d.text((TX, y), "Conscious choices in the age of artificial intelligence.", font=font(26, "Regular"), fill=sub); y += 46
d.text((TX, y), "Book · Published November 14, 2025 · 210 pages", font=font(23, "Regular"), fill=grey); y += 60

# black pill, same silhouette as the App Store badge (no third-party logo)
pill_w, pill_h = 300, 84
d.rounded_rectangle((TX, y, TX + pill_w, y + pill_h), radius=14, fill=(0, 0, 0), outline=(166, 166, 166), width=2)
d.text((TX + 24, y + 12), "Available on", font=font(20, "Regular"), fill=(255, 255, 255))
d.text((TX + 24, y + 34), "Amazon", font=font(36, "Semibold"), fill=(255, 255, 255))
d.text((TX + pill_w + 24, y + 18), "Kindle · Paperback · Hardcover", font=font(22, "Regular"), fill=sub)
d.text((TX + pill_w + 24, y + 48), "theaichoice.com", font=font(20, "Regular"), fill=grey)

bg.save(OUT, "PNG", optimize=True)
import shutil; shutil.copy(COVER_SRC, COVER_DST)
print("wrote", OUT, bg.size)
