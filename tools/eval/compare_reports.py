#!/usr/bin/env python3
"""Compare complete eval reports, optionally ignoring only root platform."""

import argparse
import json
from pathlib import Path
import sys


def first_difference(left, right, ignore_platform=False):
    """Return the first unequal JSON path; do not mutate either report."""
    def compare(a, b, path):
        if type(a) is not type(b):
            return path
        if isinstance(a, dict):
            for key in sorted(set(a) | set(b)):
                if path == '$' and key == 'platform' and ignore_platform:
                    continue
                child = path + '[' + json.dumps(key, ensure_ascii=False) + ']'
                if key not in a or key not in b:
                    return child
                difference = compare(a[key], b[key], child)
                if difference is not None:
                    return difference
        elif isinstance(a, list):
            if len(a) != len(b):
                return path
            for index, (item_a, item_b) in enumerate(zip(a, b)):
                difference = compare(item_a, item_b, f'{path}[{index}]')
                if difference is not None:
                    return difference
        elif a != b:
            return path
        return None
    return compare(left, right, '$')


def reject_constant(value):
    raise ValueError('nonfinite JSON number: ' + value)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate JSON key: ' + key)
        result[key] = value
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mac', type=Path)
    parser.add_argument('win', type=Path)
    parser.add_argument('--ignore-platform', action='store_true')
    args = parser.parse_args()
    try:
        reports = [json.loads(path.read_bytes(), parse_constant=reject_constant,
                              object_pairs_hook=unique_object) for path in (args.mac, args.win)]
        difference = first_difference(*reports, ignore_platform=args.ignore_platform)
        if difference is not None:
            print('Reports differ at ' + difference, file=sys.stderr)
            return 1
        print('Reports match')
        return 0
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
