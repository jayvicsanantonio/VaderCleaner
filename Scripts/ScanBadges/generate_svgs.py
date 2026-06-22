#!/usr/bin/env python3
"""Authors the glossy 3D "Smart Care" badge SVGs (one per Smart Scan module and
System Junk category). Each badge is a colored glossy orb with a white emblem,
in the MacPaw Smart Care style. Run `generate_svgs.py` to (re)write the SVG
sources, then `rasterize.sh` to bake them into the asset catalog."""

import os

# Per-color radial-gradient stops: (light highlight, mid body, dark edge) plus
# the dark tone used for emblem cut-lines.
COLORS = {
    "green":  ("#7be88a", "#3fc24f", "#1f8a32", "#1f8a32"),
    "pink":   ("#ff9ec7", "#ef4d8f", "#b81e63", "#b81e63"),
    "orange": ("#ffd089", "#fb9b2e", "#d2700c", "#c2640a"),
    "blue":   ("#9fc4ff", "#3f8bf0", "#1f5fc0", "#1f5fc0"),
    "purple": ("#c9a8f5", "#9a5fe0", "#6a34b0", "#6a34b0"),
}

# Emblems are white shapes centered over the orb (orb center 120,118 r 98).
# `{dark}` is substituted with the color's cut-line tone.
EMBLEMS = {
    "smartCare": """
      <g fill="#ffffff">
        <rect x="76" y="82" width="88" height="60" rx="10"/>
        <rect x="108" y="142" width="24" height="13"/>
        <rect x="90" y="155" width="60" height="10" rx="5"/>
      </g>
      <path d="M120 92 l5 13 13 5 -13 5 -5 13 -5 -13 -13 -5 13 -5 z" fill="{dark}"/>
    """,
    "cleanup": """
      <g fill="#ffffff">
        <ellipse cx="98" cy="106" rx="11" ry="15"/>
        <ellipse cx="142" cy="106" rx="11" ry="15"/>
      </g>
      <path d="M92 138 Q120 166 148 138" fill="none" stroke="#ffffff"
            stroke-width="11" stroke-linecap="round"/>
    """,
    "systemJunk": """
      <g fill="#ffffff">
        <rect x="82" y="90" width="76" height="14" rx="7"/>
        <path d="M90 108 H150 L144 168 Q143 175 136 175 H104 Q97 175 96 168 Z"/>
      </g>
      <path d="M110 124 L130 158 M130 124 L110 158" stroke="{dark}"
            stroke-width="9" stroke-linecap="round"/>
    """,
    "mailAttachments": """
      <g fill="#ffffff">
        <rect x="78" y="96" width="84" height="58" rx="9"/>
      </g>
      <path d="M84 104 L120 134 L156 104" fill="none" stroke="{dark}"
            stroke-width="9" stroke-linecap="round" stroke-linejoin="round"/>
    """,
    "trash": """
      <g fill="#ffffff">
        <rect x="112" y="84" width="16" height="11" rx="4"/>
        <rect x="84" y="95" width="72" height="13" rx="6"/>
        <path d="M93 110 H147 L141 170 Q140 176 134 176 H106 Q100 176 99 170 Z"/>
      </g>
      <g stroke="{dark}" stroke-width="6" stroke-linecap="round">
        <line x1="110" y1="124" x2="111" y2="162"/>
        <line x1="120" y1="124" x2="120" y2="162"/>
        <line x1="130" y1="124" x2="129" y2="162"/>
      </g>
    """,
    "protection": """
      <g fill="#ffffff">
        <rect x="98" y="106" width="44" height="52" rx="17"/>
        <rect x="100" y="72" width="9" height="46" rx="4.5"/>
        <rect x="112" y="66" width="9" height="52" rx="4.5"/>
        <rect x="124" y="68" width="9" height="50" rx="4.5"/>
        <rect x="136" y="76" width="9" height="42" rx="4.5"/>
        <rect x="82" y="110" width="9" height="36" rx="4.5"
              transform="rotate(-35 86 128)"/>
      </g>
    """,
    "malware": """
      <g fill="none" stroke="#ffffff" stroke-width="12">
        <circle cx="120" cy="96" r="19"/>
        <circle cx="99" cy="138" r="19"/>
        <circle cx="141" cy="138" r="19"/>
      </g>
      <circle cx="120" cy="122" r="10" fill="#ffffff"/>
    """,
    "performance": """
      <path d="M134 76 L94 132 H117 L106 170 L150 110 H126 Z" fill="#ffffff"/>
    """,
    "applications": """
      <g fill="#ffffff">
        <rect x="90" y="90" width="26" height="26" rx="7"/>
        <rect x="124" y="90" width="26" height="26" rx="7"/>
        <rect x="90" y="124" width="26" height="26" rx="7"/>
        <rect x="124" y="124" width="26" height="26" rx="7"/>
      </g>
    """,
    "myClutter": """
      <rect x="88" y="84" width="52" height="66" rx="8" fill="#ffffff" opacity="0.5"/>
      <rect x="104" y="100" width="52" height="66" rx="8" fill="#ffffff"/>
    """,
}

# badge name -> color key
BADGES = {
    "smartCare": "pink",
    "cleanup": "green",
    "systemJunk": "green",
    "mailAttachments": "green",
    "trash": "green",
    "protection": "pink",
    "malware": "pink",
    "performance": "orange",
    "applications": "blue",
    "myClutter": "purple",
}

TEMPLATE = """<svg xmlns="http://www.w3.org/2000/svg" width="240" height="240" viewBox="0 0 240 240">
  <defs>
    <radialGradient id="body" cx="50%" cy="36%" r="66%">
      <stop offset="0%" stop-color="{light}"/>
      <stop offset="55%" stop-color="{mid}"/>
      <stop offset="100%" stop-color="{edge}"/>
    </radialGradient>
    <linearGradient id="gloss" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#ffffff" stop-opacity="0.85"/>
      <stop offset="100%" stop-color="#ffffff" stop-opacity="0"/>
    </linearGradient>
    <filter id="ds" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0" dy="6" stdDeviation="8" flood-color="#000000" flood-opacity="0.32"/>
    </filter>
    <filter id="es" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0" dy="2" stdDeviation="2" flood-color="#000000" flood-opacity="0.18"/>
    </filter>
  </defs>
  <g filter="url(#ds)">
    <circle cx="120" cy="118" r="98" fill="url(#body)"/>
    <ellipse cx="120" cy="70" rx="78" ry="46" fill="url(#gloss)"/>
    <circle cx="120" cy="118" r="98" fill="none" stroke="#ffffff" stroke-opacity="0.22" stroke-width="2"/>
  </g>
  <g filter="url(#es)">{emblem}</g>
</svg>
"""


def main():
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "svg")
    os.makedirs(out_dir, exist_ok=True)
    for name, color in BADGES.items():
        light, mid, edge, dark = COLORS[color]
        emblem = EMBLEMS[name].format(dark=dark)
        svg = TEMPLATE.format(light=light, mid=mid, edge=edge, emblem=emblem)
        with open(os.path.join(out_dir, f"{name}.svg"), "w") as f:
            f.write(svg)
        print(f"wrote {name}.svg ({color})")


if __name__ == "__main__":
    main()
