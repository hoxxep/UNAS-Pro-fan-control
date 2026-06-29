# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "matplotlib>=3.8",
# ]
# ///
"""Generate CHART.png: the System, HDD, and SSD fan curves side by side.

Run with:  uv run charts/generate_chart.py

The thresholds below mirror the defaults in fan_control.sh. Each curve ramps
linearly from MIN_FAN at TGT to 100% at MAX, and is held at MIN_FAN below TGT.
"""

from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib import font_manager

# Defaults from fan_control.sh. Keep in sync if you change them there.
MIN_FAN = 39 / 255 * 100  # 15% baseline floor

CURVES = [
    ("System", 50, 75, "#E3120B"),  # SoC die + board/airflow sensors
    ("HDD", 32, 50, "#006BA2"),      # spinning disks
    ("SSD", 50, 70, "#379A8B"),      # SATA SSDs and NVMe
]

X_MIN, X_MAX = 20, 90  # x-axis range in °C
FS = 12               # one font size for every label on the chart

# Palette.
INK = "#121212"
GRID = "#d4dadd"
SUBTLE = "#5a5a5a"


def use_sf_pro() -> str:
    """Register macOS SF Pro from ~/Library/Fonts and return its family name."""
    candidates = [
        Path.home() / "Library/Fonts/SF-Pro-Text-Regular.otf",
        Path.home() / "Library/Fonts/SF-Pro.ttf",
    ]
    for path in candidates:
        if path.exists():
            font_manager.fontManager.addfont(str(path))
            return font_manager.FontProperties(fname=str(path)).get_name()
    return "Helvetica Neue"


def fan_speed(temp: float, tgt: float, mx: float) -> float:
    """Effective fan speed %: ramps from MIN_FAN at TGT to 100% at MAX."""
    ratio = (temp - tgt) / (mx - tgt)
    ratio = max(0.0, min(1.0, ratio))
    return MIN_FAN + (100 - MIN_FAN) * ratio


def main() -> None:
    plt.rcParams.update({
        "font.family": use_sf_pro(),
        "font.size": FS,
        "text.color": INK,
        "axes.edgecolor": INK,
        "axes.labelcolor": SUBTLE,
        "xtick.color": SUBTLE,
        "ytick.color": SUBTLE,
    })

    temps = [X_MIN + i * 0.1 for i in range(int((X_MAX - X_MIN) / 0.1) + 1)]

    # 1960x540 px: ~2x GitHub's ~980px README column for crisp retina display.
    fig, axes = plt.subplots(1, 3, figsize=(9.8, 2.7), dpi=200, sharey=True)
    fig.patch.set_facecolor("white")

    for ax, (name, tgt, mx, color) in zip(axes, CURVES):
        ax.set_facecolor("white")
        speeds = [fan_speed(t, tgt, mx) for t in temps]
        ax.plot(temps, speeds, color=color, linewidth=2.5, solid_capstyle="round")

        # Mark the TGT and MAX thresholds with faint guide lines + centred labels.
        for x, label in ((tgt, f"TGT {tgt}°C"), (mx, f"MAX {mx}°C")):
            ax.axvline(x, color=SUBTLE, linestyle=(0, (2, 3)), linewidth=0.8,
                       alpha=0.6, zorder=0)
            ax.annotate(label, (x, 52), rotation=90, va="center", ha="right",
                        fontsize=FS, color=SUBTLE)

        ax.set_title(name, fontsize=FS, fontweight="bold", loc="left",
                     color=INK, pad=8)
        ax.set_xlabel("Temperature (°C)", fontsize=FS)
        ax.set_xlim(X_MIN, X_MAX)
        ax.set_ylim(0, 105)  # headroom so the 100% line isn't clipped
        ax.set_xticks(range(X_MIN, X_MAX + 1, 10))
        ax.set_yticks(range(0, 101, 20))

        # Horizontal gridlines, y-axis line + ticks, no top/right border.
        ax.yaxis.grid(True, color=GRID, linewidth=0.9)
        ax.set_axisbelow(True)
        for side in ("top", "right"):
            ax.spines[side].set_visible(False)
        for side in ("left", "bottom"):
            ax.spines[side].set_color(INK)
        ax.tick_params(length=4, labelsize=FS)

    axes[0].set_ylabel("Fan speed (%)", fontsize=FS)

    fig.tight_layout()

    out = Path(__file__).resolve().parent / "CHART.png"
    fig.savefig(out, facecolor="white")
    print(f"Wrote {out}")


if __name__ == "__main__":
    main()
