#!/usr/bin/env python3
"""
Generate SQL SELECT statements for public.wh_create_waypoint()
from the qrcode_map section of a YAML file.

Usage:
    python3 gen_waypoints.py <yaml_file> [--graph-id <id>]

By default uses current_setting('wh.graph_id')::bigint as the graph_id,
matching the existing fibo_6fl.sql convention.
"""

import sys
import argparse
import yaml


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("yaml_file", help="Path to the YAML file (e.g. fibo_6fl.yaml)")
    parser.add_argument(
        "--graph-id",
        default=None,
        help="Explicit graph_id integer. If omitted, uses current_setting('wh.graph_id')::bigint",
    )
    args = parser.parse_args()

    with open(args.yaml_file, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f)

    qrcode_map = data.get("qrcode_map")
    if not qrcode_map:
        print("ERROR: 'qrcode_map' key not found in YAML.", file=sys.stderr)
        sys.exit(1)

    if args.graph_id is not None:
        graph_id_expr = args.graph_id
    else:
        graph_id_expr = "current_setting('wh.graph_id')::bigint"

    print("-- Auto-generated waypoints from qrcode_map")
    print("-- 4) Create waypoints")
    for key, entry in qrcode_map.items():
        qr_id = entry["id"]
        x = entry["x"]
        y = entry["y"]
        alias = key          # e.g. qr_1, qr_2, ...
        tag_id = str(qr_id)  # id field as text

        print(
            f"SELECT public.wh_create_waypoint("
            f"{graph_id_expr}, "
            f"{x}, "
            f"{y}, "
            f"'{alias}'::text, "
            f"'{tag_id}'::text"
            f");"
        )


if __name__ == "__main__":
    main()
