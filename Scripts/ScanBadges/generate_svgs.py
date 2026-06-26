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
    "cleanupSystemJunk": """
      <circle cx="106" cy="104" r="34" fill="#ffffff"/>
      <g stroke="{dark}" stroke-width="8" stroke-linecap="round">
        <line x1="106" y1="104" x2="106" y2="82"/>
        <line x1="106" y1="104" x2="124" y2="112"/>
      </g>
      <circle cx="150" cy="150" r="28" fill="{dark}"/>
      <circle cx="150" cy="142" r="10" fill="#ffffff"/>
      <path d="M133 168 Q150 148 167 168 Z" fill="#ffffff"/>
    """,
    "xcodeJunk": """
      <g fill="none" stroke="#ffffff" stroke-width="13"
         stroke-linecap="round" stroke-linejoin="round">
        <path d="M104 92 L82 121 L104 150"/>
        <path d="M136 92 L158 121 L136 150"/>
      </g>
      <line x1="130" y1="88" x2="110" y2="154" stroke="#ffffff"
            stroke-width="12" stroke-linecap="round"/>
    """,
    "documentVersions": """
      <path d="M90 76 H132 L158 102 V164 Q158 171 151 171 H90 Q83 171 83 164 V83 Q83 76 90 76 Z"
            fill="#ffffff"/>
      <path d="M132 76 L158 102 H132 Z" fill="{dark}"/>
      <g stroke="{dark}" stroke-width="6" stroke-linecap="round">
        <line x1="97" y1="106" x2="127" y2="106"/>
        <line x1="97" y1="120" x2="144" y2="120"/>
      </g>
      <path d="M100 146 l11 12 24 -28" fill="none" stroke="{dark}"
            stroke-width="10" stroke-linecap="round" stroke-linejoin="round"/>
    """,
    "logs": """
      <path d="M84 74 H136 L160 98 V172 Q160 176 156 176 H84 Q80 176 80 172 V78 Q80 74 84 74 Z"
            fill="#ffffff"/>
      <path d="M136 74 L160 98 H136 Z" fill="{dark}"/>
      <g stroke="{dark}" stroke-width="7" stroke-linecap="round">
        <line x1="94" y1="104" x2="144" y2="104"/>
        <line x1="94" y1="122" x2="144" y2="122"/>
        <line x1="94" y1="140" x2="124" y2="140"/>
      </g>
    """,
    "languageFiles": """
      <circle cx="120" cy="118" r="46" fill="none" stroke="#ffffff" stroke-width="9"/>
      <ellipse cx="120" cy="118" rx="20" ry="46" fill="none" stroke="#ffffff" stroke-width="7"/>
      <g stroke="#ffffff" stroke-width="7" stroke-linecap="round">
        <line x1="76" y1="104" x2="164" y2="104"/>
        <line x1="76" y1="132" x2="164" y2="132"/>
      </g>
    """,
    "iosBackups": """
      <rect x="92" y="74" width="56" height="92" rx="12" fill="#ffffff"/>
      <rect x="100" y="84" width="40" height="60" rx="4" fill="{dark}"/>
      <circle cx="120" cy="156" r="6" fill="{dark}"/>
    """,
    # --- Protection Manager privacy categories ---
    "autofill": """
      <rect x="80" y="78" width="80" height="84" rx="11" fill="#ffffff"/>
      <g stroke="{dark}" stroke-width="7" stroke-linecap="round">
        <line x1="94" y1="100" x2="146" y2="100"/>
        <line x1="94" y1="118" x2="146" y2="118"/>
        <line x1="94" y1="136" x2="128" y2="136"/>
      </g>
    """,
    "browsingHistory": """
      <path d="M120 72 a46 46 0 1 1 -42 26" fill="none" stroke="#ffffff"
            stroke-width="11" stroke-linecap="round"/>
      <path d="M74 86 l6 26 24 -10 z" fill="#ffffff"/>
      <g stroke="#ffffff" stroke-width="9" stroke-linecap="round">
        <line x1="120" y1="118" x2="120" y2="96"/>
        <line x1="120" y1="118" x2="139" y2="129"/>
      </g>
    """,
    "cookies": """
      <circle cx="120" cy="118" r="45" fill="#ffffff"/>
      <g fill="{dark}">
        <circle cx="106" cy="103" r="7"/>
        <circle cx="135" cy="110" r="6"/>
        <circle cx="116" cy="135" r="6"/>
        <circle cx="139" cy="133" r="5"/>
        <circle cx="100" cy="126" r="4"/>
      </g>
    """,
    "downloadsHistory": """
      <g stroke="#ffffff" stroke-width="12" stroke-linecap="round" stroke-linejoin="round" fill="none">
        <line x1="120" y1="76" x2="120" y2="132"/>
        <path d="M98 110 L120 134 L142 110"/>
      </g>
      <rect x="84" y="150" width="72" height="13" rx="6" fill="#ffffff"/>
    """,
    "savedPasswords": """
      <circle cx="104" cy="104" r="23" fill="#ffffff"/>
      <circle cx="104" cy="104" r="9" fill="{dark}"/>
      <g stroke="#ffffff" stroke-width="12" stroke-linecap="round">
        <line x1="118" y1="118" x2="152" y2="152"/>
        <line x1="142" y1="142" x2="152" y2="132"/>
        <line x1="132" y1="152" x2="142" y2="162"/>
      </g>
    """,
    "searchQueries": """
      <g fill="none" stroke="#ffffff" stroke-width="12" stroke-linecap="round">
        <circle cx="110" cy="108" r="30"/>
        <line x1="133" y1="131" x2="156" y2="154"/>
      </g>
    """,
    "cachedFiles": """
      <g fill="#ffffff">
        <ellipse cx="120" cy="86" rx="40" ry="14"/>
        <path d="M80 86 v44 a40 14 0 0 0 80 0 v-44 a40 14 0 0 1 -80 0 z"/>
      </g>
      <path d="M80 108 a40 14 0 0 0 80 0" fill="none" stroke="{dark}" stroke-width="5"/>
    """,
    "tabs": """
      <g fill="#ffffff">
        <rect x="78" y="92" width="84" height="64" rx="10"/>
        <rect x="86" y="78" width="36" height="20" rx="7"/>
      </g>
      <line x1="78" y1="110" x2="162" y2="110" stroke="{dark}" stroke-width="5"/>
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
    "xcodeJunk": "green",
    "documentVersions": "green",
    "cleanupSystemJunk": "green",
    "logs": "green",
    "languageFiles": "green",
    "iosBackups": "green",
    "autofill": "pink",
    "browsingHistory": "pink",
    "cookies": "pink",
    "downloadsHistory": "pink",
    "savedPasswords": "pink",
    "searchQueries": "pink",
    "cachedFiles": "pink",
    "tabs": "pink",
}

# badge name -> body shape. Defaults to the glossy round orb; a few badges use a
# rounded-square "app icon" (squircle) instead to match the reference Cleanup
# tiles, where Xcode Junk and Document Versions read as app-style tiles rather
# than orbs.
SHAPES = {
    "xcodeJunk": "squircle",
    "documentVersions": "squircle",
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
  {shape}
  <g filter="url(#es)">{emblem}</g>
</svg>
"""

# The glossy round orb body: gradient fill, a top gloss highlight, and a faint
# rim. Used by every badge unless overridden in SHAPES.
ORB_SHAPE = """<g filter="url(#ds)">
    <circle cx="120" cy="118" r="98" fill="url(#body)"/>
    <ellipse cx="120" cy="70" rx="78" ry="46" fill="url(#gloss)"/>
    <circle cx="120" cy="118" r="98" fill="none" stroke="#ffffff" stroke-opacity="0.22" stroke-width="2"/>
  </g>"""

# The rounded-square "app icon" body — same gradient, gloss, and rim as the orb
# but a squircle silhouette, matching the reference's Xcode / Document tiles.
SQUIRCLE_SHAPE = """<g filter="url(#ds)">
    <rect x="26" y="24" width="188" height="188" rx="46" fill="url(#body)"/>
    <rect x="40" y="38" width="160" height="96" rx="34" fill="url(#gloss)"/>
    <rect x="26" y="24" width="188" height="188" rx="46" fill="none" stroke="#ffffff" stroke-opacity="0.22" stroke-width="2"/>
  </g>"""

SHAPE_BODIES = {"orb": ORB_SHAPE, "squircle": SQUIRCLE_SHAPE}


def main():
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "svg")
    os.makedirs(out_dir, exist_ok=True)
    for name, color in BADGES.items():
        light, mid, edge, dark = COLORS[color]
        emblem = EMBLEMS[name].format(dark=dark)
        shape = SHAPE_BODIES[SHAPES.get(name, "orb")]
        svg = TEMPLATE.format(light=light, mid=mid, edge=edge, emblem=emblem, shape=shape)
        with open(os.path.join(out_dir, f"{name}.svg"), "w") as f:
            f.write(svg)
        print(f"wrote {name}.svg ({color})")


if __name__ == "__main__":
    main()
