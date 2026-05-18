#!/usr/bin/env python3
import argparse
import json


def align_down(value: int, alignment: int) -> int:
    return value - (value % alignment)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sector-size", type=int, default=4096)
    parser.add_argument("--old-start", type=int, required=True)
    parser.add_argument("--old-end", type=int, required=True)
    parser.add_argument("--root-gib", type=int, default=80)
    parser.add_argument("--align-sectors", type=int, default=256)
    args = parser.parse_args()

    root_target_bytes = args.root_gib * 1024**3
    root_target_sectors = root_target_bytes // args.sector_size
    root_start_unaligned = args.old_end - root_target_sectors + 1
    root_start = align_down(root_start_unaligned, args.align_sectors)
    userdata_end = root_start - 1
    userdata_sectors = userdata_end - args.old_start + 1
    root_sectors = args.old_end - root_start + 1

    print(json.dumps({
        "sector_size": args.sector_size,
        "old_start": args.old_start,
        "old_end": args.old_end,
        "root_target_gib": args.root_gib,
        "root_target_sectors": root_target_sectors,
        "root_start_unaligned": root_start_unaligned,
        "align_sectors": args.align_sectors,
        "root_start": root_start,
        "userdata_end": userdata_end,
        "userdata_sectors": userdata_sectors,
        "userdata_bytes": userdata_sectors * args.sector_size,
        "root_sectors": root_sectors,
        "root_bytes": root_sectors * args.sector_size,
    }, indent=2))


if __name__ == "__main__":
    main()
