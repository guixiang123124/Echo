#!/usr/bin/env python3
"""Generate streaming telemetry metrics report from Echo SQLite recordings."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import statistics
import sqlite3
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional


DEFAULT_ROOT = Path.home()
DEFAULT_OUTPUT_DIR = Path("reports/streaming")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Export stream regression metrics from the local Echo sqlite DB."
    )
    parser.add_argument("--db", help="Explicit path to echo.sqlite")
    parser.add_argument(
        "--platform",
        choices=["auto", "mac", "ios", "simulator"],
        default="auto",
        help="Database discovery mode",
    )
    parser.add_argument(
        "--days",
        type=int,
        default=0,
        help="Recent N days window, 0 means all records.",
    )
    parser.add_argument(
        "--output-dir",
        default=str(DEFAULT_OUTPUT_DIR),
        help="Output directory for markdown/json report.",
    )
    return parser.parse_args()


def _db_candidates() -> List[Path]:
    candidates: List[Path] = []
    mac_db = DEFAULT_ROOT / "Library" / "Application Support" / "Echo" / "echo.sqlite"
    if mac_db.exists():
        candidates.append(mac_db)

    simulator_root = DEFAULT_ROOT / "Library" / "Developer" / "CoreSimulator" / "Devices"
    if simulator_root.exists():
        for device_dir in sorted(simulator_root.glob("*")):
            app_root = device_dir / "data" / "Containers" / "Data" / "Application"
            if not app_root.exists():
                continue
            for app_dir in sorted(app_root.glob("*")):
                db_path = app_dir / "Library" / "Application Support" / "Echo" / "echo.sqlite"
                if db_path.exists():
                    candidates.append(db_path)
    return candidates


def resolve_db(db_arg: Optional[str], platform: str) -> Path:
    if db_arg:
        db_path = Path(db_arg).expanduser()
        if not db_path.exists():
            raise FileNotFoundError(f"Database not found: {db_path}")
        return db_path

    candidates = _db_candidates()
    if platform == "mac":
        candidates = [p for p in candidates if "CoreSimulator" not in str(p)]
    elif platform in {"ios", "simulator"}:
        candidates = [p for p in candidates if "CoreSimulator" in str(p)]

    if not candidates:
        raise FileNotFoundError(
            "No echo.sqlite found. Set --platform=ios/mac or pass --db explicitly."
        )

    candidates.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return candidates[0]


def column_names(cur: sqlite3.Cursor) -> set[str]:
    return {row[1] for row in cur.execute("PRAGMA table_info(recordings)").fetchall()}


def load_rows(conn: sqlite3.Connection, days: int) -> List[sqlite3.Row]:
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    cols = column_names(cur)

    select_parts = [
        "asr_provider_id",
        "transcript_final",
        "status",
        "created_at",
    ]

    optional = {
        "stream_mode": "NULL AS stream_mode",
        "first_partial_ms": "NULL AS first_partial_ms",
        "first_final_ms": "NULL AS first_final_ms",
        "fallback_used": "0 AS fallback_used",
        "error_code": "NULL AS error_code",
    }

    for name, fallback_expr in optional.items():
        if name in cols:
            select_parts.append(name)
        else:
            select_parts.append(fallback_expr)

    required = {"asr_provider_id", "transcript_final", "status", "created_at"}
    missing = required.difference(cols)
    if missing:
        raise RuntimeError(f"Database missing columns: {', '.join(sorted(missing))}")

    sql = f"SELECT {', '.join(select_parts)} FROM recordings"
    if days > 0:
        cutoff = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)).timestamp()
        sql += " WHERE created_at >= ?"
        return cur.execute(sql, (cutoff,)).fetchall()

    return cur.execute(sql).fetchall()


def percentile(values: List[int], p: float) -> Optional[float]:
    if not values:
        return None
    values = sorted(values)
    idx = max(0, min(len(values) - 1, round((p / 100.0) * (len(values) - 1))))
    return float(values[int(idx)])


def build_metrics(rows: Iterable[sqlite3.Row], days: int) -> Dict[str, Any]:
    rows = list(rows)
    if not rows:
        return {
            "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
            "window_days": days,
            "totals": {
                "recordings": 0,
                "success": 0,
                "errors": 0,
                "empty_final": 0,
                "fallback_used": 0,
            },
            "rates": {
                "error_rate": 0.0,
                "empty_final_rate": 0.0,
                "fallback_rate": 0.0,
            },
            "latency": {
                "first_partial_ms": {
                    "count": 0,
                    "mean": None,
                    "median": None,
                    "p90": None,
                },
                "first_final_ms": {
                    "count": 0,
                    "mean": None,
                    "median": None,
                    "p90": None,
                },
            },
            "providers": [],
            "modes": [],
            "error_codes": [],
            "provider_mode_matrix": [],
        }

    total = len(rows)
    total_success = 0
    total_errors = 0
    empty_final = 0
    fallback = 0

    provider_counts: Counter[str] = Counter()
    mode_counts: Counter[str] = Counter()
    per_provider: Dict[str, Dict[str, int]] = defaultdict(lambda: {"count": 0, "empty_final": 0, "fallback": 0})
    per_mode: Dict[str, Dict[str, int]] = defaultdict(lambda: {"count": 0, "empty_final": 0, "fallback": 0})
    per_provider_mode: Dict[str, Dict[str, int]] = defaultdict(lambda: {"count": 0})

    first_partial_ms: List[int] = []
    first_final_ms: List[int] = []
    error_codes: Counter[str] = Counter()

    def is_empty(value: Optional[str]) -> bool:
        return value is None or str(value).strip() == ""

    for row in rows:
        provider = str(row["asr_provider_id"] or "unknown").lower()
        mode = str(row["stream_mode"] or "batch").lower()
        status = str(row["status"] or "").lower()
        transcript = row["transcript_final"]

        provider_counts[provider] += 1
        mode_counts[mode] += 1
        per_provider[provider]["count"] += 1
        per_mode[mode]["count"] += 1
        per_provider_mode[(provider, mode)]["count"] += 1

        if status == "success":
            total_success += 1
        else:
            total_errors += 1

        if is_empty(transcript):
            empty_final += 1
            per_provider[provider]["empty_final"] += 1
            per_mode[mode]["empty_final"] += 1

        if int(row["fallback_used"] or 0) != 0:
            fallback += 1
            per_provider[provider]["fallback"] += 1
            per_mode[mode]["fallback"] += 1

        if row["error_code"]:
            error_codes[str(row["error_code"]).strip()] += 1

        if row["first_partial_ms"] is not None:
            try:
                first_partial_ms.append(int(row["first_partial_ms"]))
            except (TypeError, ValueError):
                pass
        if row["first_final_ms"] is not None:
            try:
                first_final_ms.append(int(row["first_final_ms"]))
            except (TypeError, ValueError):
                pass

    providers = []
    for name, total_count in provider_counts.most_common():
        empty_count = per_provider[name]["empty_final"]
        fallback_count = per_provider[name]["fallback"]
        providers.append(
            {
                "provider": name,
                "recordings": total_count,
                "empty_final": empty_count,
                "fallback": fallback_count,
                "empty_final_rate": empty_count / total_count if total_count else 0.0,
                "fallback_rate": fallback_count / total_count if total_count else 0.0,
            }
        )

    modes = []
    for name, total_count in mode_counts.most_common():
        empty_count = per_mode[name]["empty_final"]
        fallback_count = per_mode[name]["fallback"]
        modes.append(
            {
                "mode": name,
                "recordings": total_count,
                "empty_final": empty_count,
                "fallback": fallback_count,
                "empty_final_rate": empty_count / total_count if total_count else 0.0,
                "fallback_rate": fallback_count / total_count if total_count else 0.0,
            }
        )

    matrix = []
    for (provider, mode), data in sorted(
        per_provider_mode.items(), key=lambda item: item[1]["count"], reverse=True
    ):
        matrix.append({"provider": provider, "mode": mode, "recordings": data["count"]})

    return {
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "window_days": days,
        "totals": {
            "recordings": total,
            "success": total_success,
            "errors": total_errors,
            "empty_final": empty_final,
            "fallback_used": fallback,
        },
        "rates": {
            "error_rate": total_errors / total if total else 0.0,
            "empty_final_rate": empty_final / total if total else 0.0,
            "fallback_rate": fallback / total if total else 0.0,
        },
        "latency": {
            "first_partial_ms": {
                "count": len(first_partial_ms),
                "mean": statistics.mean(first_partial_ms) if first_partial_ms else None,
                "median": statistics.median(first_partial_ms) if first_partial_ms else None,
                "p90": percentile(first_partial_ms, 90),
            },
            "first_final_ms": {
                "count": len(first_final_ms),
                "mean": statistics.mean(first_final_ms) if first_final_ms else None,
                "median": statistics.median(first_final_ms) if first_final_ms else None,
                "p90": percentile(first_final_ms, 90),
            },
        },
        "providers": providers,
        "modes": modes,
        "error_codes": [{"code": code, "count": count} for code, count in error_codes.most_common()],
        "provider_mode_matrix": matrix,
    }


def format_pct(value: float) -> str:
    return f"{value * 100:.1f}%"


def render_markdown(report: Dict[str, Any], db_path: Path) -> str:
    lines: List[str] = []
    lines.append("# Echo Streaming Metrics Report")
    lines.append(f"- Source DB: `{db_path}`")
    lines.append(f"- Generated: `{report['generated_at']}`")
    if report["window_days"] > 0:
        lines.append(f"- Window: last `{report['window_days']} day(s)`")
    lines.append("")

    lines.append("## Totals")
    lines.append(f"- Recordings: `{report['totals']['recordings']}`")
    lines.append(f"- Success: `{report['totals']['success']}`")
    lines.append(f"- Errors: `{report['totals']['errors']}` ({format_pct(report['rates']['error_rate'])})")
    lines.append(
        f"- Empty final: `{report['totals']['empty_final']}` ({format_pct(report['rates']['empty_final_rate'])})"
    )
    lines.append(
        f"- Fallback used: `{report['totals']['fallback_used']}` ({format_pct(report['rates']['fallback_rate'])})"
    )
    lines.append("")

    lines.append("## Latency")
    lines.append("### first_partial_ms")
    partial = report["latency"]["first_partial_ms"]
    lines.append(f"- Count: `{partial['count']}`")
    if partial["mean"] is None:
        lines.append("- Mean: `N/A`")
    else:
        lines.append(f"- Mean: `{partial['mean']:.1f} ms`")
    lines.append(f"- Median: `{partial['median']} ms`" if partial["median"] is not None else "- Median: `N/A`")
    lines.append(f"- P90: `{partial['p90']} ms`" if partial["p90"] is not None else "- P90: `N/A`")
    lines.append("")

    lines.append("### first_final_ms")
    final_ms = report["latency"]["first_final_ms"]
    lines.append(f"- Count: `{final_ms['count']}`")
    if final_ms["mean"] is None:
        lines.append("- Mean: `N/A`")
    else:
        lines.append(f"- Mean: `{final_ms['mean']:.1f} ms`")
    lines.append(f"- Median: `{final_ms['median']} ms`" if final_ms["median"] is not None else "- Median: `N/A`")
    lines.append(f"- P90: `{final_ms['p90']} ms`" if final_ms["p90"] is not None else "- P90: `N/A`")
    lines.append("")

    lines.append("## Provider breakdown")
    lines.append("| Provider | Recordings | Empty final | Rate | Fallback | Rate |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: |")
    for item in report["providers"]:
        lines.append(
            f"| {item['provider']} | {item['recordings']} | {item['empty_final']} | {format_pct(item['empty_final_rate'])} | {item['fallback']} | {format_pct(item['fallback_rate'])} |"
        )
    lines.append("")

    lines.append("## Mode breakdown")
    lines.append("| Mode | Recordings | Empty final | Rate | Fallback | Rate |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: |")
    for item in report["modes"]:
        lines.append(
            f"| {item['mode']} | {item['recordings']} | {item['empty_final']} | {format_pct(item['empty_final_rate'])} | {item['fallback']} | {format_pct(item['fallback_rate'])} |"
        )
    lines.append("")

    lines.append("## Error codes")
    if report["error_codes"]:
        lines.append("| Code | Count |")
        lines.append("| --- | ---: |")
        for item in report["error_codes"]:
            lines.append(f"| {item['code']} | {item['count']} |")
    else:
        lines.append("- No error_code recorded.")
    lines.append("")

    lines.append("## Provider x Mode")
    lines.append("| Provider | Mode | Recordings |")
    lines.append("| --- | --- | ---: |")
    for item in report["provider_mode_matrix"]:
        lines.append(f"| {item['provider']} | {item['mode']} | {item['recordings']} |")

    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    try:
        db_path = resolve_db(args.db, args.platform)
        conn = sqlite3.connect(str(db_path))
    except Exception as exc:
        print(f"Error: {exc}")
        return 1

    try:
        rows = load_rows(conn, args.days)
        report = build_metrics(rows, args.days)
        output_dir = Path(args.output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)

        now = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        md_path = output_dir / f"streaming-metrics-{now}.md"
        json_path = output_dir / f"streaming-metrics-{now}.json"

        md_path.write_text(render_markdown(report, db_path), encoding="utf-8")
        json_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

        print(f"Wrote markdown report: {md_path}")
        print(f"Wrote json report:     {json_path}")
    except Exception as exc:
        print(f"Error: failed to build report: {exc}")
        return 1
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
