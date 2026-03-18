#!/usr/bin/env python3
"""
Stitch hourly frames into an MP4 movie.

Usage:
  python make_movie.py                    # all frames, 2 fps
  python make_movie.py --fps 4            # faster playback
  python make_movie.py --output timelapse.mp4
"""

import argparse
import re
import subprocess
from pathlib import Path

FRAMES_DIR = Path(__file__).parent / 'frames'


def detect_interpolated(frames):
    """Check if frames include interpolated tweens (frame_*_i*.png)."""
    for f in frames:
        if re.search(r'_i\d+\.png$', f.name):
            return True
    return False


def make_movie(fps=None, output='concept_timelapse.mp4'):
    frames = sorted(FRAMES_DIR.glob('frame_*.png'))
    if not frames:
        print("No frames found in frames/")
        return

    # Auto-detect fps from frame naming
    if fps is None:
        if detect_interpolated(frames):
            fps = 24
            print("Detected interpolated frames, using 24 fps")
        else:
            fps = 2
            print("No interpolation detected, using 2 fps")

    print(f"Found {len(frames)} frames")
    print(f"  First: {frames[0].name}")
    print(f"  Last:  {frames[-1].name}")

    # Write file list for ffmpeg
    filelist = FRAMES_DIR / 'filelist.txt'
    with open(filelist, 'w') as f:
        for frame in frames:
            f.write(f"file '{frame.name}'\n")
            f.write(f"duration {1/fps}\n")
        # Hold last frame a bit longer
        f.write(f"file '{frames[-1].name}'\n")

    cmd = [
        'ffmpeg', '-y',
        '-f', 'concat', '-safe', '0',
        '-i', str(filelist),
        '-vf', 'scale=1920:-2',
        '-c:v', 'libx264',
        '-pix_fmt', 'yuv420p',
        '-crf', '23',
        str(Path(__file__).parent / output),
    ]

    print(f"\nGenerating {output} at {fps} fps...")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode == 0:
        print(f"Movie saved: {output}")
    else:
        print(f"ffmpeg error:\n{result.stderr[-500:]}")

    filelist.unlink(missing_ok=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--fps', type=float, default=None)
    parser.add_argument('--output', default='concept_timelapse.mp4')
    args = parser.parse_args()
    make_movie(args.fps, args.output)
