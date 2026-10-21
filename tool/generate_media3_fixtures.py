#!/usr/bin/env python3
"""Generate tiny, synthetic Media3 parity fixtures; FFmpeg is test tooling only."""
from __future__ import annotations
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def run(*args: str) -> bytes:
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout


def probe(path: Path) -> dict:
    return json.loads(run('ffprobe', '-v', 'error', '-show_streams', '-show_packets', '-show_data', '-of', 'json', str(path)))


def describe(paths: list[Path]) -> list[dict]:
    result: dict[str, dict] = {}
    for path in paths:
        data = probe(path)
        streams = {s['index']: s for s in data['streams']}
        for packet in data['packets']:
            stream = streams[packet['stream_index']]
            kind = stream['codec_type']
            if kind not in ('audio', 'video'):
                continue
            track = result.setdefault(kind, {
                'kind': kind, 'codec': stream['codec_name'], 'sampleRate': int(stream.get('sample_rate', 0)),
                'channels': stream.get('channels'), 'width': stream.get('width'), 'height': stream.get('height'),
                'ptsUs': [], 'dtsUs': [], 'durationUs': [],
            })
            for source, dest in [('pts_time', 'ptsUs'), ('dts_time', 'dtsUs'), ('duration_time', 'durationUs')]:
                track[dest].append(round(float(packet.get(source, 0)) * 1_000_000))
    for track in result.values():
        track['sampleCount'] = len(track['ptsUs'])
        track['hasBFrames'] = any(a < b for a, b in zip(track['ptsUs'][1:], track['ptsUs']))
    return list(result.values())


def main() -> None:
    for executable in ('ffmpeg', 'ffprobe', 'openssl'):
        if not shutil.which(executable):
            raise SystemExit(f'{executable} is required to regenerate fixtures')
    with tempfile.TemporaryDirectory(prefix='site-lens-media3-fixtures-') as temp:
        work = Path(temp)
        fixtures = []
        for name, codec, kind in [('h264_ts', 'libx264', 'mpegts'), ('h264_fmp4', 'libx264', 'fmp4'), ('hevc_ts', 'libx265', 'mpegts')]:
            folder = work / name
            folder.mkdir()
            options = ['-preset', 'ultrafast', '-bf', '2', '-g', '24', '-keyint_min', '24']
            if codec == 'libx265':
                options += ['-x265-params', 'pools=1:frame-threads=1:log-level=error:bframes=2:keyint=24:min-keyint=24:scenecut=0']
            else:
                options += ['-sc_threshold', '0']
            run('ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=160x96:rate=12',
                '-f', 'lavfi', '-i', 'sine=frequency=997:sample_rate=48000', '-t', '4', '-c:v', codec,
                *options, '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '48k', '-ac', '2',
                '-f', 'hls', '-hls_time', '2', '-hls_list_size', '0', '-hls_segment_type', kind,
                '-hls_flags', 'independent_segments', '-hls_segment_filename', str(folder / ('seg%02d.ts' if kind == 'mpegts' else 'seg%02d.m4s')),
                str(folder / 'index.m3u8'))
            playlist = (folder / 'index.m3u8').read_text()
            segments = [folder / line for line in playlist.splitlines() if line and not line.startswith('#')]
            # ffprobe needs the init segment to parse individual fMP4 fragments.
            inspect_paths = segments
            if kind == 'fmp4':
                inspect_paths = []
                for index, segment in enumerate(segments):
                    merged = work / f'inspect-{name}-{index}.mp4'
                    merged.write_bytes((folder / 'init.mp4').read_bytes() + segment.read_bytes())
                    inspect_paths.append(merged)
            tracks = describe(inspect_paths)
            assert next(t for t in tracks if t['kind'] == 'video')['hasBFrames'], name
            fixtures.append({'name': name, 'playlist': f'{name}/index.m3u8', 'tracks': tracks, 'encrypted': False})
            if codec == 'libx264':
                encrypted_name = f'{name}_aes128'
                encrypted = work / encrypted_name
                shutil.copytree(folder, encrypted)
                key = bytes(range(16))
                (encrypted / 'key.bin').write_bytes(key)
                seq = 0
                lines = []
                for line in playlist.splitlines():
                    if line and not line.startswith('#'):
                        iv = seq.to_bytes(16, 'big')
                        target = encrypted / line
                        data = run('openssl', 'enc', '-aes-128-cbc', '-K', key.hex(), '-iv', iv.hex(), '-in', str(target))
                        target.write_bytes(data)
                        # Explicit IV is necessary for encrypted fMP4 initialization; the init is clear.
                        lines.append(f'#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x{iv.hex()}')
                        seq += 1
                    lines.append(line)
                (encrypted / 'index.m3u8').write_text('\n'.join(lines) + '\n')
                fixtures.append({'name': encrypted_name, 'playlist': f'{encrypted_name}/index.m3u8', 'tracks': tracks, 'encrypted': True})
        files = sorted({path for fixture in fixtures for path in (work / fixture['name']).iterdir() if path.is_file()})
        manifest = {'schemaVersion': 1, 'description': 'Synthetic 4-second test patterns, 12 fps, B frames, 48 kHz stereo AAC. No production media.',
                    'fixtures': fixtures, 'sha256': {str(f.relative_to(work)): hashlib.sha256(f.read_bytes()).hexdigest() for f in files}}
        output = ROOT / 'integration_test/fixtures/media3_parity.zip'
        with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as z:
            for file in files:
                entry = zipfile.ZipInfo(str(file.relative_to(work)), date_time=(2026, 1, 1, 0, 0, 0))
                entry.compress_type = zipfile.ZIP_DEFLATED
                z.writestr(entry, file.read_bytes())
            z.writestr('manifest.json', json.dumps(manifest, indent=2))
        print(f'{output}: {output.stat().st_size} bytes; {len(fixtures)} fixtures')
        print([(f['name'], [(t['kind'], t['sampleCount'], t['hasBFrames']) for t in f['tracks']]) for f in fixtures])


if __name__ == '__main__':
    main()
