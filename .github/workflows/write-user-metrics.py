#!/usr/bin/env python3
"""Generate static monthly user statistics from the Google Analytics 4 Data API."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
from pathlib import Path
from typing import Any

import requests


GA4_PROPERTY_ID_ENV = "GA4_PROPERTY_ID"
GA4_SERVICE_ACCOUNT_KEY_ENV = "GA4_SERVICE_ACCOUNT_KEY"
ANALYTICS_SCOPE = "https://www.googleapis.com/auth/analytics.readonly"
# Earliest date the GA4 Data API accepts; months without data return no rows.
EARLIEST_START_DATE = "2015-08-14"
DEFAULT_PERIOD_DAYS = 30

GA4_SEGMENTS: list[dict[str, Any]] = [
    {
        "id": "neurodeskedu",
        "name": "NeurodeskEDU",
        "url": "https://neurodesk.org/edu/",
        "description": "Learning resources hosted under neurodesk.org/edu.",
        "hostNames": ["neurodesk.org"],
        "pagePathPrefix": "/edu",
    },
    {
        "id": "play-america",
        "name": "Play US",
        "url": "https://play-america.neurodesk.org",
        "description": "Neurodesk Play server in the US.",
        "hostNames": ["play-america.neurodesk.org"],
    },
    {
        "id": "play-europe",
        "name": "Play Europe",
        "url": "https://play-europe.neurodesk.org",
        "description": "Neurodesk Play server in Europe.",
        "hostNames": ["play-europe.neurodesk.org"],
    },
    {
        "id": "play-australia",
        "name": "Play Australia",
        "url": "https://play.neurodesk.cloud.edu.au",
        "description": "Neurodesk Play server in Australia.",
        "hostNames": [
            "play.neurodesk.cloud.edu.au",
        ],
    },
    {
        "id": "webapp-calmar",
        "name": "CALMaR",
        "url": "https://calmar.neurodesk.org/",
        "description": "CALMaR lesion mapping and reporting webapp.",
        "hostNames": ["calmar.neurodesk.org"],
    },
    {
        "id": "webapp-dicompare",
        "name": "dicompare",
        "url": "https://dicompare.neurodesk.org",
        "description": "dicompare DICOM protocol comparison webapp.",
        "hostNames": ["dicompare.neurodesk.org"],
    },
    {
        "id": "webapp-musclemap",
        "name": "MuscleMap",
        "url": "https://musclemap.neurodesk.org",
        "description": "MuscleMap muscle segmentation webapp.",
        "hostNames": ["musclemap.neurodesk.org"],
    },
    {
        "id": "webapp-qsmbly",
        "name": "QSMbly",
        "url": "https://qsmbly.neurodesk.org",
        "description": "QSMbly quantitative susceptibility mapping webapp.",
        "hostNames": ["qsmbly.neurodesk.org"],
    },
    {
        "id": "webapp-seedseg",
        "name": "SeedSeg",
        "url": "https://seedseg.neurodesk.org/",
        "description": "SeedSeg fiducial marker segmentation webapp.",
        "hostNames": ["seedseg.neurodesk.org"],
    },
    {
        "id": "webapp-sct",
        "name": "Spinal Cord Toolbox",
        "url": "https://sct.neurodesk.org",
        "description": "Spinal Cord Toolbox segmentation webapp.",
        "hostNames": ["sct.neurodesk.org"],
    },
    {
        "id": "webapp-vesselboost",
        "name": "VesselBoost",
        "url": "https://vesselboost.neurodesk.org",
        "description": "VesselBoost blood vessel segmentation webapp.",
        "hostNames": ["vesselboost.neurodesk.org"],
    },
]


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def isoformat_z(value: dt.datetime) -> str:
    return value.isoformat().replace("+00:00", "Z")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Write public/data/user-metrics.json from the GA4 Data API."
    )
    parser.add_argument(
        "--property-id",
        default=os.environ.get(GA4_PROPERTY_ID_ENV, ""),
        help="GA4 property id (numeric).",
    )
    parser.add_argument(
        "--output",
        default="public/data/user-metrics.json",
        help="Path to the generated JSON file.",
    )
    parser.add_argument(
        "--period-days",
        type=int,
        default=DEFAULT_PERIOD_DAYS,
        help="Trailing days to include in service usage summaries.",
    )
    parser.add_argument(
        "--allow-missing-token",
        action="store_true",
        help="Write an unavailable placeholder instead of failing when credentials are absent.",
    )
    return parser.parse_args()


def public_segment_config(segment: dict[str, Any]) -> dict[str, Any]:
    filters: dict[str, Any] = {"hostNames": segment.get("hostNames", [])}
    page_path_prefix = segment.get("pagePathPrefix")
    if page_path_prefix:
        filters["pagePathPrefix"] = page_path_prefix
    return {
        "id": segment["id"],
        "name": segment["name"],
        "url": segment["url"],
        "description": segment.get("description", ""),
        "filters": filters,
    }


def empty_segment(segment: dict[str, Any]) -> dict[str, Any]:
    return {
        **public_segment_config(segment),
        "trackingStartDate": None,
        "totalUsers": 0,
        "periodUsers": 0,
        "periodSessions": 0,
        "periodPageViews": 0,
        "months": [],
        "countries": [],
    }


def empty_metrics(
    generated_at: str,
    period_days: int = DEFAULT_PERIOD_DAYS,
    unavailable: bool = False,
) -> dict[str, Any]:
    data: dict[str, Any] = {
        "generatedAt": generated_at,
        "source": "Google Analytics 4",
        "periodDays": period_days,
        "totalUsers": 0,
        "periodUsers": 0,
        "periodSessions": 0,
        "periodPageViews": 0,
        "months": [],
        "countries": [],
        "segments": [empty_segment(segment) for segment in GA4_SEGMENTS],
    }
    if unavailable:
        data["unavailable"] = True
    return data


def write_json(path: str, data: dict[str, Any]) -> None:
    output_path = Path(path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(data, indent=2, sort_keys=False) + "\n", encoding="utf-8")
    print(f"Wrote {output_path}")


def get_access_token(service_account_info: dict[str, Any]) -> str:
    # Imported lazily so placeholder mode works without google-auth installed.
    from google.oauth2 import service_account
    import google.auth.transport.requests

    credentials = service_account.Credentials.from_service_account_info(
        service_account_info, scopes=[ANALYTICS_SCOPE]
    )
    credentials.refresh(google.auth.transport.requests.Request())
    return credentials.token


def run_report(
    token: str,
    property_id: str,
    body: dict[str, Any],
    start_date: str = EARLIEST_START_DATE,
    end_date: str = "today",
) -> list[dict[str, Any]]:
    response = requests.post(
        f"https://analyticsdata.googleapis.com/v1beta/properties/{property_id}:runReport",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
        json={
            "dateRanges": [{"startDate": start_date, "endDate": end_date}],
            "limit": 10000,
            **body,
        },
        timeout=60,
    )
    if response.status_code != 200:
        raise RuntimeError(
            f"GA4 Data API returned HTTP {response.status_code}: {response.text[:500]}"
        )
    return response.json().get("rows") or []


def string_filter(field_name: str, value: str, match_type: str = "EXACT") -> dict[str, Any]:
    return {
        "filter": {
            "fieldName": field_name,
            "stringFilter": {
                "matchType": match_type,
                "value": value,
                "caseSensitive": False,
            },
        }
    }


def grouped_filter(group_name: str, expressions: list[dict[str, Any]]) -> dict[str, Any] | None:
    if not expressions:
        return None
    if len(expressions) == 1:
        return expressions[0]
    return {group_name: {"expressions": expressions}}


def dimension_filter_for_segment(segment: dict[str, Any]) -> dict[str, Any] | None:
    expressions: list[dict[str, Any]] = []

    host_filters = [
        string_filter("hostName", host_name)
        for host_name in segment.get("hostNames", [])
        if host_name
    ]
    host_filter = grouped_filter("orGroup", host_filters)
    if host_filter:
        expressions.append(host_filter)

    page_path_prefix = segment.get("pagePathPrefix")
    if page_path_prefix:
        expressions.append(string_filter("pagePath", page_path_prefix, "BEGINS_WITH"))

    return grouped_filter("andGroup", expressions)


def with_dimension_filter(
    body: dict[str, Any],
    dimension_filter: dict[str, Any] | None,
) -> dict[str, Any]:
    if dimension_filter:
        return {**body, "dimensionFilter": dimension_filter}
    return body


def monthly_report(
    token: str,
    property_id: str,
    dimension_filter: dict[str, Any] | None = None,
) -> list[dict[str, Any]]:
    return run_report(
        token,
        property_id,
        with_dimension_filter(
            {
                "dimensions": [{"name": "yearMonth"}],
                "metrics": [{"name": "newUsers"}],
                "orderBys": [{"dimension": {"dimensionName": "yearMonth"}}],
            },
            dimension_filter,
        ),
    )


def all_time_users_report(
    token: str,
    property_id: str,
    dimension_filter: dict[str, Any] | None = None,
) -> list[dict[str, Any]]:
    return run_report(
        token,
        property_id,
        with_dimension_filter(
            {
                "metrics": [{"name": "totalUsers"}],
            },
            dimension_filter,
        ),
    )


def tracking_start_report(
    token: str,
    property_id: str,
    dimension_filter: dict[str, Any] | None = None,
) -> list[dict[str, Any]]:
    return run_report(
        token,
        property_id,
        with_dimension_filter(
            {
                "dimensions": [{"name": "date"}],
                "metrics": [{"name": "screenPageViews"}],
                "metricFilter": {
                    "filter": {
                        "fieldName": "screenPageViews",
                        "numericFilter": {
                            "operation": "GREATER_THAN",
                            "value": {"int64Value": "0"},
                        },
                    }
                },
                "orderBys": [{"dimension": {"dimensionName": "date"}}],
                "limit": "1",
            },
            dimension_filter,
        ),
    )


def country_report(
    token: str,
    property_id: str,
    dimension_filter: dict[str, Any] | None = None,
) -> list[dict[str, Any]]:
    return run_report(
        token,
        property_id,
        with_dimension_filter(
            {
                "dimensions": [{"name": "countryId"}, {"name": "country"}],
                "metrics": [{"name": "totalUsers"}],
                "orderBys": [{"metric": {"metricName": "totalUsers"}, "desc": True}],
            },
            dimension_filter,
        ),
    )


def period_report(
    token: str,
    property_id: str,
    period_days: int,
    dimension_filter: dict[str, Any] | None = None,
) -> list[dict[str, Any]]:
    return run_report(
        token,
        property_id,
        with_dimension_filter(
            {
                "metrics": [
                    {"name": "totalUsers"},
                    {"name": "sessions"},
                    {"name": "screenPageViews"},
                ],
            },
            dimension_filter,
        ),
        start_date=f"{period_days}daysAgo",
    )


def summarize_countries(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    countries: list[dict[str, Any]] = []
    for row in rows:
        dimensions = row.get("dimensionValues") or [{}, {}]
        code = (dimensions[0].get("value") or "").strip()
        name = (dimensions[1].get("value") or "").strip() if len(dimensions) > 1 else ""
        users = int(round(float((row.get("metricValues") or [{}])[0].get("value") or 0)))
        if len(code) != 2 or not code.isalpha() or users <= 0:
            continue
        countries.append({"code": code.upper(), "name": name or code.upper(), "users": users})
    return countries


def summarize(rows: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], int]:
    months: list[dict[str, Any]] = []
    cumulative = 0
    for row in rows:
        year_month = (row.get("dimensionValues") or [{}])[0].get("value", "")
        if len(year_month) != 6 or not year_month.isdigit():
            continue
        new_users = int(round(float((row.get("metricValues") or [{}])[0].get("value") or 0)))
        cumulative += new_users
        months.append(
            {
                "month": f"{year_month[:4]}-{year_month[4:]}",
                "newUsers": new_users,
                "cumulativeUsers": cumulative,
            }
        )
    return months, cumulative


def summarize_tracking_start(rows: list[dict[str, Any]]) -> str | None:
    if not rows:
        return None
    value = (rows[0].get("dimensionValues") or [{}])[0].get("value", "")
    if len(value) != 8 or not value.isdigit():
        return None
    return f"{value[:4]}-{value[4:6]}-{value[6:]}"


def metric_value(row: dict[str, Any], index: int) -> int:
    values = row.get("metricValues") or []
    if index >= len(values):
        return 0
    return int(round(float(values[index].get("value") or 0)))


def summarize_period(rows: list[dict[str, Any]]) -> dict[str, int]:
    row = rows[0] if rows else {}
    return {
        "periodUsers": metric_value(row, 0),
        "periodSessions": metric_value(row, 1),
        "periodPageViews": metric_value(row, 2),
    }


def build_metrics(
    token: str,
    property_id: str,
    period_days: int,
    dimension_filter: dict[str, Any] | None = None,
) -> dict[str, Any]:
    # Monthly newUsers power the acquisition chart, but "users to date" must use
    # totalUsers so returning users within a filtered service are still counted.
    months, _ = summarize(monthly_report(token, property_id, dimension_filter))
    all_time_rows = all_time_users_report(token, property_id, dimension_filter)
    total_users = metric_value(all_time_rows[0] if all_time_rows else {}, 0)
    countries = summarize_countries(country_report(token, property_id, dimension_filter))
    period = summarize_period(period_report(token, property_id, period_days, dimension_filter))
    return {
        "totalUsers": total_users,
        **period,
        "months": months,
        "countries": countries,
    }


def main() -> int:
    args = parse_args()
    generated_at = isoformat_z(utc_now())

    key_json = os.environ.get(GA4_SERVICE_ACCOUNT_KEY_ENV, "").strip()
    property_id = args.property_id.strip()

    if not key_json or not property_id:
        missing = GA4_SERVICE_ACCOUNT_KEY_ENV if not key_json else GA4_PROPERTY_ID_ENV
        if not args.allow_missing_token:
            print(f"{missing} is not set", file=sys.stderr)
            return 1
        print(f"{missing} is not set — writing unavailable placeholder")
        write_json(args.output, empty_metrics(generated_at, args.period_days, unavailable=True))
        return 0

    try:
        service_account_info = json.loads(key_json)
    except json.JSONDecodeError as error:
        print(f"{GA4_SERVICE_ACCOUNT_KEY_ENV} is not valid JSON: {error}", file=sys.stderr)
        return 1

    token = get_access_token(service_account_info)
    aggregate = build_metrics(token, property_id, args.period_days)
    print(
        f"GA4 property {property_id}: {len(aggregate['months'])} months, "
        f"{aggregate['totalUsers']} users total, {len(aggregate['countries'])} countries"
    )

    segments = []
    for segment in GA4_SEGMENTS:
        dimension_filter = dimension_filter_for_segment(segment)
        try:
            tracking_start_date = summarize_tracking_start(
                tracking_start_report(token, property_id, dimension_filter)
            )
        except (requests.RequestException, RuntimeError) as error:
            print(
                f"  {segment['id']}: could not determine tracking start date: {error}",
                file=sys.stderr,
            )
            tracking_start_date = None
        segment_metrics = build_metrics(
            token,
            property_id,
            args.period_days,
            dimension_filter,
        )
        print(
            f"  {segment['id']}: {segment_metrics['periodUsers']} users, "
            f"{segment_metrics['periodSessions']} sessions, "
            f"{segment_metrics['periodPageViews']} views in last {args.period_days} days"
        )
        segments.append(
            {
                **public_segment_config(segment),
                "trackingStartDate": tracking_start_date,
                **segment_metrics,
            }
        )

    data = empty_metrics(generated_at, args.period_days)
    data.update(aggregate)
    data["segments"] = segments
    write_json(args.output, data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
