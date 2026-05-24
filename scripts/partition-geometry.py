#!/usr/bin/env python3
import argparse
import json


def align_down(value: int, alignment: int) -> int:
    return value - (value % alignment)


def align_up(value: int, alignment: int) -> int:
    remainder = value % alignment
    if remainder == 0:
        return value
    return value + alignment - remainder


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sector-size", type=int, default=4096)
    parser.add_argument("--old-start", type=int, required=True)
    parser.add_argument("--old-end", type=int, required=True)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--root-gib", type=int)
    group.add_argument("--root-percent", type=float)
    group.add_argument("--debug-gib", type=int)
    parser.add_argument("--align-sectors", type=int, default=256)
    args = parser.parse_args()

    old_sectors = args.old_end - args.old_start + 1
    old_bytes = old_sectors * args.sector_size

    if args.debug_gib is not None:
        debug_target_bytes = args.debug_gib * 1024**3
        debug_target_sectors = debug_target_bytes // args.sector_size
        root_start_unaligned = args.old_start + debug_target_sectors
        root_start = align_up(root_start_unaligned, args.align_sectors)
        debug_end = root_start - 1
        debug_sectors = debug_end - args.old_start + 1
        root_sectors = args.old_end - root_start + 1
        result = {
            "mode": "debug-gib",
            "sector_size": args.sector_size,
            "old_start": args.old_start,
            "old_end": args.old_end,
            "old_sectors": old_sectors,
            "old_bytes": old_bytes,
            "debug_target_gib": args.debug_gib,
            "debug_target_sectors": debug_target_sectors,
            "align_sectors": args.align_sectors,
            "debug_start": args.old_start,
            "debug_end": debug_end,
            "debug_sectors": debug_sectors,
            "debug_bytes": debug_sectors * args.sector_size,
            "root_start_unaligned": root_start_unaligned,
            "root_start": root_start,
            "root_end": args.old_end,
            "root_sectors": root_sectors,
            "root_bytes": root_sectors * args.sector_size,
        }
    else:
        if args.root_percent is not None:
            root_target_sectors = int(old_sectors * args.root_percent / 100)
            root_target_bytes = root_target_sectors * args.sector_size
            root_target = {"root_target_percent": args.root_percent}
        else:
            root_gib = args.root_gib if args.root_gib is not None else 80
            root_target_bytes = root_gib * 1024**3
            root_target_sectors = root_target_bytes // args.sector_size
            root_target = {"root_target_gib": root_gib}

        root_start_unaligned = args.old_end - root_target_sectors + 1
        root_start = align_down(root_start_unaligned, args.align_sectors)
        userdata_end = root_start - 1
        userdata_sectors = userdata_end - args.old_start + 1
        root_sectors = args.old_end - root_start + 1
        result = {
            "mode": "root-size",
            "sector_size": args.sector_size,
            "old_start": args.old_start,
            "old_end": args.old_end,
            "old_sectors": old_sectors,
            "old_bytes": old_bytes,
            **root_target,
            "root_target_sectors": root_target_sectors,
            "root_target_bytes": root_target_bytes,
            "root_start_unaligned": root_start_unaligned,
            "align_sectors": args.align_sectors,
            "root_start": root_start,
            "userdata_end": userdata_end,
            "userdata_sectors": userdata_sectors,
            "userdata_bytes": userdata_sectors * args.sector_size,
            "root_sectors": root_sectors,
            "root_bytes": root_sectors * args.sector_size,
        }

    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
