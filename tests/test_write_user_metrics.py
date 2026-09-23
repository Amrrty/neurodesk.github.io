from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


SCRIPT_PATH = (
    Path(__file__).resolve().parents[1]
    / ".github"
    / "workflows"
    / "write-user-metrics.py"
)
SPEC = importlib.util.spec_from_file_location("write_user_metrics", SCRIPT_PATH)
assert SPEC and SPEC.loader
write_user_metrics = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(write_user_metrics)


class BuildMetricsTests(unittest.TestCase):
    def test_default_output_targets_astro_public_directory(self) -> None:
        with mock.patch("sys.argv", ["write-user-metrics.py"]):
            args = write_user_metrics.parse_args()

        self.assertEqual(args.output, "public/data/user-metrics.json")

    def test_summarize_tracking_start_uses_first_reported_date(self) -> None:
        rows = [
            {"dimensionValues": [{"value": "20260714"}]},
            {"dimensionValues": [{"value": "20260715"}]},
        ]

        self.assertEqual(
            write_user_metrics.summarize_tracking_start(rows),
            "2026-07-14",
        )

    def test_summarize_tracking_start_returns_none_for_empty_rows(self) -> None:
        self.assertIsNone(write_user_metrics.summarize_tracking_start([]))

    def test_users_to_date_uses_all_time_total_users(self) -> None:
        def fake_run_report(
            token: str,
            property_id: str,
            body: dict,
            start_date: str = write_user_metrics.EARLIEST_START_DATE,
            end_date: str = "today",
        ) -> list[dict]:
            del token, property_id, end_date
            metric_names = [metric["name"] for metric in body.get("metrics", [])]
            dimension_names = [
                dimension["name"] for dimension in body.get("dimensions", [])
            ]

            if metric_names == ["newUsers"] and dimension_names == ["yearMonth"]:
                return [
                    {
                        "dimensionValues": [{"value": "202607"}],
                        "metricValues": [{"value": "35"}],
                    }
                ]

            if metric_names == ["totalUsers"] and dimension_names == [
                "countryId",
                "country",
            ]:
                return []

            if metric_names == ["totalUsers"] and start_date == "30daysAgo":
                return [{"metricValues": [{"value": "60"}]}]

            if (
                metric_names == ["totalUsers"]
                and start_date == write_user_metrics.EARLIEST_START_DATE
            ):
                return [{"metricValues": [{"value": "75"}]}]

            if metric_names == ["totalUsers", "sessions", "screenPageViews"]:
                return [
                    {
                        "metricValues": [
                            {"value": "60"},
                            {"value": "103"},
                            {"value": "250"},
                        ]
                    }
                ]

            self.fail(
                f"Unexpected report: metrics={metric_names}, "
                f"dimensions={dimension_names}, start_date={start_date}"
            )

        with mock.patch.object(
            write_user_metrics, "run_report", side_effect=fake_run_report
        ):
            metrics = write_user_metrics.build_metrics("token", "property", 30)

        self.assertEqual(metrics["totalUsers"], 75)
        self.assertEqual(metrics["periodUsers"], 60)
        self.assertEqual(metrics["months"][0]["newUsers"], 35)
        self.assertEqual(metrics["months"][0]["cumulativeUsers"], 35)

    def test_main_keeps_segment_when_tracking_start_lookup_fails(self) -> None:
        aggregate_metrics = {
            "totalUsers": 75,
            "periodUsers": 60,
            "periodSessions": 103,
            "periodPageViews": 250,
            "months": [],
            "countries": [],
        }
        segment_metrics = {
            "totalUsers": 20,
            "periodUsers": 10,
            "periodSessions": 15,
            "periodPageViews": 25,
            "months": [],
            "countries": [],
        }

        with tempfile.TemporaryDirectory() as temporary_directory:
            output = Path(temporary_directory) / "user-metrics.json"
            args = SimpleNamespace(
                property_id="property",
                output=str(output),
                period_days=30,
                allow_missing_token=False,
            )
            with (
                mock.patch.dict(
                    os.environ,
                    {write_user_metrics.GA4_SERVICE_ACCOUNT_KEY_ENV: "{}"},
                ),
                mock.patch.object(write_user_metrics, "parse_args", return_value=args),
                mock.patch.object(
                    write_user_metrics,
                    "get_access_token",
                    return_value="token",
                ),
                mock.patch.object(
                    write_user_metrics,
                    "GA4_SEGMENTS",
                    [write_user_metrics.GA4_SEGMENTS[0]],
                ),
                mock.patch.object(
                    write_user_metrics,
                    "build_metrics",
                    side_effect=[aggregate_metrics, segment_metrics],
                ),
                mock.patch.object(
                    write_user_metrics,
                    "tracking_start_report",
                    side_effect=write_user_metrics.requests.RequestException(
                        "temporary GA4 failure"
                    ),
                ),
            ):
                result = write_user_metrics.main()

            data = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(result, 0)
        self.assertEqual(data["totalUsers"], 75)
        self.assertEqual(len(data["segments"]), 1)
        self.assertIsNone(data["segments"][0]["trackingStartDate"])
        self.assertEqual(data["segments"][0]["totalUsers"], 20)


if __name__ == "__main__":
    unittest.main()
