"""Generate high-resolution social preview image (1280x640) for Mornye Network Storage.
"""
from PIL import Image, ImageDraw, ImageFont
import os

def create_social_preview(output_path="assets/mornye-social-preview.png"):
    width = 1280
    height = 640
    img = Image.new("RGBA", (width, height), (9, 13, 22, 255))
    draw = ImageDraw.Draw(img)

    # 1. Subtle gradient background
    for y in range(height):
        ratio = y / height
        r = int(9 + (15 - 9) * ratio)
        g = int(13 + (23 - 13) * ratio)
        b = int(22 + (42 - 22) * ratio)
        draw.line([(0, y), (width, y)], fill=(r, g, b, 255))

    # 2. Subtle grid pattern
    grid_color = (255, 255, 255, 12)
    for x in range(0, width, 40):
        draw.line([(x, 0), (x, height)], fill=grid_color, width=1)
    for y in range(0, height, 40):
        draw.line([(0, y), (width, y)], fill=grid_color, width=1)

    # 3. Outer glowing border
    draw.rounded_rectangle([(30, 30), (width - 30, height - 30)], radius=24, outline=(56, 189, 248, 60), width=2)
    draw.rounded_rectangle([(32, 32), (width - 32, height - 32)], radius=22, outline=(37, 99, 235, 120), width=2)

    # Try loading system fonts or fallback to default
    def get_font(size, bold=False):
        font_names = [
            "C:/Windows/Fonts/segoeuib.ttf" if bold else "C:/Windows/Fonts/segoeui.ttf",
            "C:/Windows/Fonts/arialbd.ttf" if bold else "C:/Windows/Fonts/arial.ttf",
            "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        ]
        for fn in font_names:
            if os.path.exists(fn):
                try:
                    return ImageFont.truetype(fn, size)
                except Exception:
                    pass
        return ImageFont.load_default()

    font_title = get_font(52, bold=True)
    font_subtitle = get_font(23, bold=False)
    font_badge = get_font(18, bold=True)
    font_footer = get_font(18, bold=False)

    # 4. Server / Storage Icon Box (top-left)
    icon_box = [(80, 80), (160, 160)]
    draw.rounded_rectangle(icon_box, radius=16, fill=(37, 99, 235, 200), outline=(56, 189, 248, 255), width=2)
    # Server rack lines inside icon box
    draw.rounded_rectangle([(95, 95), (145, 110)], radius=4, fill=(15, 23, 42, 255), outline=(147, 197, 253, 255), width=1)
    draw.ellipse([(102, 101), (106, 105)], fill=(52, 211, 153, 255))
    draw.rounded_rectangle([(95, 115), (145, 130)], radius=4, fill=(15, 23, 42, 255), outline=(147, 197, 253, 255), width=1)
    draw.ellipse([(102, 121), (106, 125)], fill=(52, 211, 153, 255))
    draw.rounded_rectangle([(95, 135), (145, 150)], radius=4, fill=(15, 23, 42, 255), outline=(147, 197, 253, 255), width=1)
    draw.ellipse([(102, 141), (106, 145)], fill=(52, 211, 153, 255))

    # Version tag next to icon
    draw.rounded_rectangle([(180, 85), (270, 115)], radius=8, fill=(30, 41, 59, 255), outline=(56, 189, 248, 180), width=1)
    draw.text((195, 91), "v3.3.0", fill=(56, 189, 248, 255), font=font_badge)

    draw.rounded_rectangle([(280, 85), (420, 115)], radius=8, fill=(16, 185, 129, 40), outline=(52, 211, 153, 180), width=1)
    draw.text((292, 91), "OFFICIAL RELEASE", fill=(52, 211, 153, 255), font=font_badge)

    # 5. Main Title
    draw.text((80, 190), "Mornye Network Storage", fill=(255, 255, 255, 255), font=font_title)

    # 6. Subtitle / Value proposition
    subtitle_line1 = "High-performance, self-hosted private cloud & RFC 4918 WebDAV storage server"
    subtitle_line2 = "Engineered for Linux with rootless Docker, Argon2id security & Cloudflare Tunnel."
    draw.text((80, 265), subtitle_line1, fill=(226, 232, 240, 255), font=font_subtitle)
    draw.text((80, 300), subtitle_line2, fill=(148, 163, 184, 255), font=font_subtitle)

    # 7. Badges Row
    badges = [
        ("RFC 4918 WebDAV", (37, 99, 235)),
        ("Argon2id Auth", (13, 148, 136)),
        ("Rootless Docker UID 1000", (124, 58, 237)),
        ("Cloudflare Tunnel Subdomain", (217, 119, 6)),
        ("Zero Open Ports", (225, 29, 72)),
    ]

    bx = 80
    by = 380
    for text, color in badges:
        # Measure text width
        bbox = draw.textbbox((0, 0), text, font=font_badge)
        tw = bbox[2] - bbox[0]
        th = bbox[3] - bbox[1]
        bw = tw + 28
        bh = 38
        draw.rounded_rectangle([(bx, by), (bx + bw, by + bh)], radius=8, fill=(color[0]//4, color[1]//4, color[2]//4, 200), outline=color, width=1)
        draw.text((bx + 14, by + 9), text, fill=(241, 245, 249, 255), font=font_badge)
        bx += bw + 14

    # 8. Copy-paste installation command box
    cmd_box = [(80, 450), (width - 80, 520)]
    draw.rounded_rectangle(cmd_box, radius=12, fill=(15, 23, 42, 230), outline=(51, 65, 85, 255), width=1)
    prompt_sym = "$ "
    draw.text((105, 472), prompt_sym, fill=(52, 211, 153, 255), font=font_subtitle)
    cmd_text = "curl -fsSL https://raw.githubusercontent.com/navyaXdev/Mornye-Network-Storage/main/setup.sh | bash"
    draw.text((130, 472), cmd_text, fill=(248, 250, 252, 255), font=font_subtitle)

    # 9. Footer with Creator Attribution & Repo Link
    footer_text = "Created by NavyaXdev  •  https://github.com/navyaXdev/Mornye-Network-Storage  •  MIT License"
    draw.text((80, 560), footer_text, fill=(148, 163, 184, 255), font=font_footer)

    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    # Convert RGBA to RGB for standard PNG
    rgb_img = Image.new("RGB", (width, height), (9, 13, 22))
    rgb_img.paste(img, mask=img.split()[3])
    rgb_img.save(output_path, "PNG", optimize=True)
    print(f"Generated {output_path} successfully ({os.path.getsize(output_path)} bytes)")

if __name__ == "__main__":
    create_social_preview()

