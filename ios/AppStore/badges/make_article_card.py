from PIL import Image, ImageDraw, ImageFilter, ImageFont
import os
REPO = "/Users/sethegger/Library/Application Support/Claude/scratch-workspaces/ba5054e8-e1a6-4abb-a8c1-dd2f216d10b6/2642fc77-dd0d-4736-b70b-ebbf7f2eeffe/scratch-2026-09-25-a40dc7/FNB58-MacOS"
OUT = os.path.join(REPO, "ios/AppStore/badges/featured-article.png")
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
    t = y / (H - 1); px_row = (int(246 - 8*t), int(246 - 8*t), int(248 - 6*t))
    for x in range(W): px[x, y] = px_row
S = 380; X0, Y0 = 80, (H - S)//2
hero = Image.open("medium-hero.jpg").convert("RGB")           # 1600x893, lobster centred ~x=1000
side = hero.height; left = min(max(1000 - side//2, 0), hero.width - side)
tile = hero.crop((left, 0, left + side, side)).resize((S, S), Image.LANCZOS)
mask = Image.new("L", (S, S), 0); ImageDraw.Draw(mask).rounded_rectangle((0, 0, S-1, S-1), radius=64, fill=255)
shadow = Image.new("RGBA", (W, H), (0,0,0,0))
ImageDraw.Draw(shadow).rounded_rectangle((X0+4, Y0+14, X0+S+4, Y0+S+14), radius=64, fill=(0,0,0,70))
shadow = shadow.filter(ImageFilter.GaussianBlur(18))
bg = Image.alpha_composite(bg.convert("RGBA"), shadow).convert("RGB"); bg.paste(tile, (X0, Y0), mask)
d = ImageDraw.Draw(bg); TX = X0 + S + 52
ink=(28,28,30); sub=(60,60,67); grey=(110,110,118)
y = 140
d.text((TX, y), "I Gave an AI Control", font=font(54, "Bold"), fill=ink); y += 62
d.text((TX, y), "of My Computer", font=font(54, "Bold"), fill=ink); y += 76
d.text((TX, y), "What happens when you stop asking an AI to help", font=font(25, "Regular"), fill=sub); y += 34
d.text((TX, y), "and start asking it to act? Notes from running an", font=font(25, "Regular"), fill=sub); y += 34
d.text((TX, y), "agent on my own machine, sandboxed, in week one.", font=font(25, "Regular"), fill=sub); y += 48
d.text((TX, y), "Article · February 7, 2026 · 13 min read", font=font(23, "Regular"), fill=grey); y += 56
pill_w, pill_h = 300, 84
d.rounded_rectangle((TX, y, TX+pill_w, y+pill_h), radius=14, fill=(0,0,0), outline=(166,166,166), width=2)
d.text((TX+24, y+12), "Read it on", font=font(20, "Regular"), fill=(255,255,255))
d.text((TX+24, y+34), "Medium", font=font(36, "Semibold"), fill=(255,255,255))
d.text((TX+pill_w+24, y+18), "OpenClaw · Claude · Claude Code", font=font(22, "Regular"), fill=sub)
d.text((TX+pill_w+24, y+48), "medium.com/@sethnicholausegger", font=font(20, "Regular"), fill=grey)
bg.save(OUT, "PNG", optimize=True); print("wrote", OUT)
