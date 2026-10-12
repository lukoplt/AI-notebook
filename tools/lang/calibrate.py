"""Exact, validation-only calibration for the frozen language detector contract.

Rows are already scored diagnostics. A three-dimensional cumulative histogram
evaluates each candidate without revisiting text or rescoring examples.
"""

from bisect import bisect_right
from itertools import product


BUCKETS = (12, 32, 80, 200)
GATES = {"acceptedError": 200, "csSkConfusion": 100, "foreignAcceptance": 100}


def _integer(value, minimum, maximum, name):
    if type(value) is not int or not minimum <= value <= maximum:
        raise ValueError(f"{name} must be an integer in [{minimum}, {maximum}]")


def exact_gate(numerator: int, denominator: int, max_bp: int) -> bool:
    """Zero support never passes, and display rounding never affects a gate."""
    _integer(denominator, 0, 2**63 - 1, "denominator")
    _integer(numerator, 0, denominator, "numerator")
    _integer(max_bp, 0, 10000, "max_bp")
    return denominator > 0 and 10000 * numerator <= max_bp * denominator


def metric(numerator, denominator):
    return {"numerator": numerator, "denominator": denominator,
            "rateBp": None if denominator == 0 else 10000 * numerator // denominator}


def _languages(targets, negatives):
    for values, name in [(targets, "targets"), (negatives, "negatives")]:
        if (not isinstance(values, list) or not values
                or any(not isinstance(value, str) or not value or not value.isascii() for value in values)
                or values != sorted(set(values)) or "background" in values):
            raise ValueError(f"{name} must be nonempty, sorted, unique ASCII language IDs")
    if set(targets) & set(negatives):
        raise ValueError("targets and negatives must be disjoint")
    return sorted(targets + negatives)


def _threshold(threshold):
    expected = {"start", "enabled", "minWinningScore", "minMargin", "minKnownCoverageBp"}
    if not isinstance(threshold, dict) or set(threshold) != expected:
        raise ValueError("threshold fields differ from the contract")
    _integer(threshold["start"], 0, 200, "start")
    if threshold["start"] not in (0, *BUCKETS):
        raise ValueError("invalid bucket start")
    _integer(threshold["enabled"], 0, 1, "enabled")
    if threshold["start"] == 0 and threshold["enabled"]:
        raise ValueError("the below-minimum reporting bucket cannot be enabled")
    _integer(threshold["minWinningScore"], -7000000, 0, "minWinningScore")
    _integer(threshold["minMargin"], 1 if threshold["enabled"] else 0, 7000000, "minMargin")
    _integer(threshold["minKnownCoverageBp"], 0, 10000, "minKnownCoverageBp")


def _candidates(candidates):
    expected = {"bucketStart", "minWinningScores", "minMargins", "minKnownCoverageBp"}
    if not isinstance(candidates, dict) or set(candidates) != expected:
        raise ValueError("candidate fields differ from the contract")
    _integer(candidates["bucketStart"], 12, 200, "bucketStart")
    if candidates["bucketStart"] not in BUCKETS:
        raise ValueError("invalid bucket start")
    axes = []
    for key, minimum, maximum in [("minWinningScores", -7000000, 0),
                                   ("minMargins", 1, 7000000),
                                   ("minKnownCoverageBp", 0, 10000)]:
        values = candidates[key]
        if not isinstance(values, list) or not values:
            raise ValueError(f"{key} must be a nonempty array")
        for value in values:
            _integer(value, minimum, maximum, key)
        if values != sorted(set(values)):
            raise ValueError(f"{key} must be ascending and unique")
        axes.append(values)
    return axes


def _rows(rows, start, targets, languages, validation_only=False):
    selected = []
    groups = {language: set() for language in languages}
    evaluated = {language: 0 for language in languages}
    for row in rows:
        if validation_only and row.get("split", "validation") != "validation":
            raise ValueError("calibration accepts validation rows only")
        if row.get("mode", "text") != "text":
            raise ValueError("document rows do not belong to text metrics")
        if row.get("truth") not in languages or row.get("winner") not in targets + ["background"]:
            raise ValueError("row has an unknown truth or winner")
        if not isinstance(row.get("originalGroupId"), str) or not row["originalGroupId"]:
            raise ValueError("row requires originalGroupId")
        for key, minimum, maximum in [("winningScore", -(2**63), 2**63 - 1),
                                       ("margin", 0, 2**63 - 1), ("coverageBp", 0, 10000),
                                       ("letterCount", 0, 2**63 - 1), ("wordCount", 0, 2**63 - 1)]:
            _integer(row.get(key), minimum, maximum, key)
        actual_bucket = next((bucket for bucket in reversed(BUCKETS) if row["letterCount"] >= bucket), None)
        provided_bucket = row.get("bucketStart")
        if provided_bucket == 0 and type(provided_bucket) is int:
            provided_bucket = None
        if provided_bucket != actual_bucket or (provided_bucket is not None and type(provided_bucket) is not int):
            raise ValueError("row bucketStart disagrees with letterCount")
        if (actual_bucket or 0) != start:
            continue
        selected.append(row)
        groups[row["truth"]].add(row["originalGroupId"])
        evaluated[row["truth"]] += 1
    return selected, groups, evaluated


def _report(stats, languages, negatives, groups, evaluated):
    accepted = dict(zip(languages, stats[:len(languages)]))
    total = sum(accepted.values())
    cs_sk = accepted.get("cs", 0) + accepted.get("sk", 0)
    return {
        "metrics": {
            "acceptedError": metric(stats[-2], total),
            "csSkConfusion": metric(stats[-1], cs_sk),
            "foreignAcceptance": metric(sum(accepted[language] for language in negatives),
                                        sum(evaluated[language] for language in negatives)),
            "acceptanceCoverage": metric(total, sum(evaluated.values())),
        },
        "support": {language: {"originalGroups": len(groups[language]),
                               "evaluated": evaluated[language], "accepted": accepted[language]}
                    for language in languages},
        "acceptedTotal": total,
        "acceptedTrueCs": accepted.get("cs", 0),
        "acceptedTrueSk": accepted.get("sk", 0),
    }


def _add_row(stats, row, language_index):
    stats[language_index[row["truth"]]] += 1
    stats[-2] += row["winner"] != row["truth"]
    stats[-1] += (row["truth"], row["winner"]) in (("cs", "sk"), ("sk", "cs"))


def _eligible_row(row):
    return row["letterCount"] >= 12 and row["wordCount"] >= 3 and row["winner"] != "background"


def evaluate_rows(rows: list[dict], threshold: dict, targets: list[str], negatives: list[str]) -> dict:
    """Report one bucket, including abstentions in evaluated/group support.

    Returns metrics, support keyed by true language, acceptedTotal,
    acceptedTrueCs and acceptedTrueSk. Disabled thresholds yield zero accepts.
    Start zero is allowed only when disabled, for below-minimum report rows;
    it is never a calibrated or exported model threshold.
    The caller may supply validation or test rows; calibration enforces its
    separate validation-only boundary.
    """
    _threshold(threshold)
    languages = _languages(targets, negatives)
    selected, groups, evaluated = _rows(rows, threshold["start"], targets, languages)
    indexes = {language: index for index, language in enumerate(languages)}
    stats = [0] * (len(languages) + 2)
    if threshold["enabled"]:
        for row in selected:
            if (_eligible_row(row) and row["winningScore"] >= threshold["minWinningScore"]
                    and row["margin"] >= threshold["minMargin"]
                    and row["coverageBp"] >= threshold["minKnownCoverageBp"]):
                _add_row(stats, row, indexes)
    return _report(stats, languages, negatives, groups, evaluated)


def calibrate_bucket(rows: list[dict], candidates: dict, targets: list[str], negatives: list[str]) -> dict:
    """Choose grid-max-accepted-v1 using exact validation support/error gates."""
    axes = _candidates(candidates)
    languages = _languages(targets, negatives)
    start = candidates["bucketStart"]
    selected, groups, evaluated = _rows(rows, start, targets, languages, validation_only=True)
    score_count, margin_count, coverage_count = map(len, axes)
    size = score_count * margin_count * coverage_count
    stats_count = len(languages) + 2
    histogram = [[0] * stats_count for _ in range(size)]
    indexes = {language: index for index, language in enumerate(languages)}

    def offset(score, margin, coverage):
        return (score * margin_count + margin) * coverage_count + coverage

    for row in selected:
        if not _eligible_row(row):
            continue
        positions = [bisect_right(axis, value) - 1 for axis, value in zip(
            axes, (row["winningScore"], row["margin"], row["coverageBp"]))]
        if min(positions) >= 0:
            _add_row(histogram[offset(*positions)], row, indexes)

    # Three suffix sums turn each cell into counts at or above all minima.
    dimensions = (score_count, margin_count, coverage_count)
    for dimension in range(3):
        for position in product(*(range(count - 1, -1, -1) for count in dimensions)):
            if position[dimension] + 1 >= dimensions[dimension]:
                continue
            neighbor = list(position)
            neighbor[dimension] += 1
            current, following = histogram[offset(*position)], histogram[offset(*neighbor)]
            for statistic in range(stats_count):
                current[statistic] += following[statistic]

    groups_pass = all(len(groups[language]) >= 200 for language in languages)
    best, supported_candidate = None, False
    if groups_pass:
        for score, margin, coverage in product(range(score_count), range(margin_count), range(coverage_count)):
            stats = histogram[offset(score, margin, coverage)]
            accepted = sum(stats[:len(languages)])
            cs = stats[indexes["cs"]] if "cs" in indexes else 0
            sk = stats[indexes["sk"]] if "sk" in indexes else 0
            if accepted < 1000 or cs < 100 or sk < 100:
                continue
            supported_candidate = True
            foreign = sum(stats[indexes[language]] for language in negatives)
            if not (exact_gate(stats[-2], accepted, 200)
                    and exact_gate(stats[-1], cs + sk, 100)
                    and exact_gate(foreign, sum(evaluated[language] for language in negatives), 100)):
                continue
            key = (accepted, axes[0][score], axes[1][margin], axes[2][coverage])
            if best is None or key > best:
                best = key

    values = best[1:] if best is not None else tuple(axis[0] for axis in axes)
    threshold = {"start": start, "enabled": int(best is not None),
                 "minWinningScore": values[0], "minMargin": values[1], "minKnownCoverageBp": values[2]}
    report = evaluate_rows(selected, threshold, targets, negatives)
    reason = "accepted" if best is not None else ("noEligibleThreshold" if supported_candidate else "insufficientSupport")
    return {"threshold": threshold, "reason": reason, **report}
