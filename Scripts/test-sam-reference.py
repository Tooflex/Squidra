#!/usr/bin/env python3
"""Development-only pinned SAM reference decoder; never a server dependency."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
WHEEL = ROOT / '.build/provider-access/meta-sam-parser-0.1.0.whl'
SHA = 'eca156907911c56cef3a350ffc81c34b7e70655e5fa3ccdddb77042c541a0152'
URL = 'https://files.pythonhosted.org/packages/29/6b/4f079abae8fbef65d08a5f315444ca96a3e267ad017576a97264ee17b26b/meta_sam_parser-0.1.0-py3-none-any.whl'


def reference(prepare=False):
    if prepare and not WHEEL.exists():
        with urllib.request.urlopen(URL, timeout=20) as response:
            data = response.read(1000001)
        if len(data) > 1000000 or hashlib.sha256(data).hexdigest() != SHA:
            raise ValueError('reference_hash_mismatch')
        WHEEL.parent.mkdir(parents=True, exist_ok=True)
        WHEEL.write_bytes(data)
    if WHEEL.is_symlink() or WHEEL.stat().st_size > 1000000 or hashlib.sha256(WHEEL.read_bytes()).hexdigest() != SHA:
        raise ValueError('reference_hash_mismatch')
    sys.path.insert(0, str(WHEEL))
    import meta_sam_parser
    return meta_sam_parser


def decode(report, parser):
    text = report.get('segmentationText')
    if not isinstance(text, str) or len(text.encode()) > 16384:
        raise ValueError('oversized_segmentation')
    # The reference parser has no project quotas. Check every declared raster
    # before it can allocate, including declarations in malformed token order.
    masks = re.findall(r'data=([0-9]+),([0-9]+),', text)
    if len(masks) != text.count('<|mask') or not 1 <= len(masks) <= 16:
        raise ValueError('invalid_mask_count')
    area = 0
    for h, w in masks:
        if len(h) > 4 or len(w) > 4 or not 1 <= int(h) <= 1024 or not 1 <= int(w) <= 1024:
            raise ValueError('oversized_mask')
        area += int(h)*int(w)
    if area > 1048576:
        raise ValueError('oversized_total_area')
    boxes_wire = re.findall(r'<\|box;([^|]+)\|>', text)
    if len(boxes_wire) != len(masks):
        raise ValueError('invalid_box_count')
    for token in boxes_wire:
        fields = [part.split('=', 1) for part in token.split(';')]
        widths = [v.strip() for k,v in fields if k.strip() == 'w']
        heights = [v.strip() for k,v in fields if k.strip() == 'h']
        if widths != ['512'] or heights != ['512']:
            raise ValueError('wrong_source_dimensions')
    reader = parser.image_segmentation_format().create_parser()
    reader.push(text)
    result = reader.finish(parser.CompletedOutcome()).result
    if result.diagnostics or result.outcome.status != 'completed':
        raise ValueError('reference_diagnostics')
    records = result.records
    boxes = [r for r in records if r.kind == 'box']
    masks = [r for r in records if r.kind == 'mask']
    if len(records) != 2 or len(boxes) != 1 or len(masks) != 1 or boxes[0].object_id != masks[0].object_id:
        raise ValueError('unexpected_red_square_count')
    box, mask = boxes[0], masks[0]
    bounds = [box.left, box.top, box.right, box.bottom]
    if any(not isinstance(v, (int,float)) or int(v) != v for v in bounds):
        raise ValueError('invalid_pixel_bounds')
    left, top, right, bottom = map(int, bounds)
    if not 0 <= left < right <= 512 or not 0 <= top < bottom <= 512:
        raise ValueError('out_of_frame_box')
    if mask.mask.width != right-left or mask.mask.height != bottom-top:
        raise ValueError('unsupported_mask_scale')
    raster = bytes(parser.decode_mask_to_raster(mask.mask))
    if len(raster) != mask.mask.width*mask.mask.height or any(v not in (0,1) for v in raster):
        raise ValueError('invalid_binary_raster')
    foreground = sum(raster)
    intersection = sum(v for i,v in enumerate(raster) if 128 <= left+i%mask.mask.width < 384 and 128 <= top+i//mask.mask.width < 384)
    union = foreground+256*256-intersection
    iou = intersection/union if union else 0
    if iou < 0.9:
        raise ValueError('red_square_mask_mismatch')
    report['maskQualification'] = {'referencePackage': 'meta-sam-parser', 'referenceVersion': '0.1.0',
        'wheelSHA256': SHA, 'license': 'SAM License', 'maskCount': 1, 'box': bounds,
        'boxConfidence': box.confidence, 'maskConfidence': mask.confidence,
        'maskWidth': mask.mask.width, 'maskHeight': mask.mask.height, 'foregroundPixels': foreground,
        'rasterSHA256': hashlib.sha256(raster).hexdigest(), 'sourceImageIoU': iou}
    return report


if __name__ == '__main__':
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument('--prepare', action='store_true')
    args.add_argument('--decode', action='store_true')
    options = args.parse_args()
    try:
        parser = reference(options.prepare)
        if options.decode:
            raw = sys.stdin.buffer.read(16385)
            if len(raw) > 16384:
                raise ValueError('oversized_report')
            print(json.dumps(decode(json.loads(raw), parser), sort_keys=True))
        else:
            print('SAM_REFERENCE_READY')
    except Exception:
        # Never print an opaque parser exception or provider text on failure.
        print('SAM_REFERENCE_REJECTED', file=sys.stderr)
        raise SystemExit(1)
