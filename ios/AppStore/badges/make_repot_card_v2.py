from PIL import Image, ImageDraw, ImageFilter, ImageFont
import os
REPO = os.environ["REPO"]; B = os.path.join(REPO, "ios/AppStore/badges")
FONT = "/System/Library/Fonts/SFNS.ttf"
def font(size, weight):
    f = ImageFont.truetype(FONT, size)
    try:
        names = [n.decode() if isinstance(n, bytes) else n for n in f.get_variation_names()]
        for cand in (weight, "Semibold", "Medium", "Regular"):
            if cand in names: f.set_variation_by_name(cand); break
    except Exception as e: print("variation:", e)
    return f
W, H = 1200, 627
bg = Image.new("RGB", (W, H)); px = bg.load()
for y in range(H):
    t = y/(H-1); row = (int(246-8*t), int(246-8*t), int(248-6*t))
    for x in range(W): px[x, y] = row
S = 380; X0, Y0 = 80, (H-S)//2
icon = Image.open(os.path.join(B, "repot-icon.png")).convert("RGB").resize((S, S), Image.LANCZOS)
mask = Image.new("L", (S, S), 0); ImageDraw.Draw(mask).rounded_rectangle((0,0,S-1,S-1), radius=84, fill=255)
shadow = Image.new("RGBA", (W, H), (0,0,0,0))
ImageDraw.Draw(shadow).rounded_rectangle((X0+4, Y0+14, X0+S+4, Y0+S+14), radius=84, fill=(0,0,0,70))
shadow = shadow.filter(ImageFilter.GaussianBlur(18))
bg = Image.alpha_composite(bg.convert("RGBA"), shadow).convert("RGB"); bg.paste(icon, (X0, Y0), mask)
d = ImageDraw.Draw(bg); TX = X0+S+52; ink=(28,28,30); sub=(60,60,67); grey=(110,110,118)
y = 158
d.text((TX, y), "Repot: Plant Care", font=font(60, "Bold"), fill=ink); y += 78
d.text((TX, y), "The whole workbench for a home nursery.", font=font(28, "Regular"), fill=sub); y += 46
d.text((TX, y), "iPhone · Pay once, no subscription · Lifestyle", font=font(23, "Regular"), fill=grey); y += 60
badge = Image.open(os.path.join(B, "badge-black.png")).convert("RGBA")
bw = 300; bh = int(badge.height * bw / badge.width); badge = badge.resize((bw, bh), Image.LANCZOS)
bg.paste(badge, (TX, y), badge)
d.text((TX+bw+24, y+18), "therepotapp.com", font=font(28, "Semibold"), fill=ink)
d.text((TX+bw+24, y+56), "apps.apple.com/app/id6790598058", font=font(20, "Regular"), fill=grey)
out = os.path.join(B, "featured-repot-v2.png"); bg.save(out, "PNG", optimize=True); print("wrote", out)
