"""Firehose Lambda transform — flattens OTLP JSON into flat records for Parquet."""

import json
import base64

# Allowlists must match the Glue table columns in main.tf.
# Update both together when adding new telemetry fields.
LOGS_ALLOWED_ATTRS = {
    "event_name",
    "event_timestamp",
    "event_sequence",
    "user_id",
    "session_id",
    "terminal_type",
    "prompt_id",
    "prompt",
    "prompt_length",
    "model",
    "cost_usd",
    "input_tokens",
    "output_tokens",
    "cache_read_tokens",
    "cache_creation_tokens",
    "duration_ms",
    "tool_name",
    "decision",
    "speed",
}

METRICS_ALLOWED_ATTRS = {
    "user_id",
    "session_id",
    "terminal_type",
    "model",
    "type",
}


def handler(event, context):
    records = []
    for record in event["records"]:
        payload = base64.b64decode(record["data"])
        try:
            data = json.loads(payload)
            flat_records = flatten_otlp(data)
            flat_json = "\n".join(json.dumps(r) for r in flat_records) + "\n"
            records.append(
                {
                    "recordId": record["recordId"],
                    "result": "Ok",
                    "data": base64.b64encode(flat_json.encode()).decode(),
                }
            )
        except Exception as e:
            print(f"ERROR: {e}")
            records.append(
                {
                    "recordId": record["recordId"],
                    "result": "ProcessingFailed",
                    "data": record["data"],
                }
            )
    return {"records": records}


def flatten_otlp(data):
    """Extract flat records from OTLP JSON (logs or metrics)."""
    flat = []
    resource_logs = data.get("resourceLogs", data.get("resourcelogs", []))
    resource_metrics = data.get("resourceMetrics", data.get("resourcemetrics", []))

    for rl in resource_logs:
        resource = extract_attrs(rl.get("resource", {}).get("attributes", []))
        base = {
            "service_name": resource.get("service.name", ""),
            "service_version": resource.get("service.version", ""),
            "host_arch": resource.get("host.arch", ""),
            "os_type": resource.get("os.type", ""),
        }
        for sl in rl.get("scopeLogs", rl.get("scopelogs", [])):
            for lr in sl.get("logRecords", sl.get("logrecords", [])):
                record = dict(base)
                record["event_type"] = get_body(lr)
                attrs = extract_attrs(lr.get("attributes", []))
                attrs = filter_keys(attrs, LOGS_ALLOWED_ATTRS)
                record.update(attrs)
                flat.append(record)

    for rm in resource_metrics:
        resource = extract_attrs(rm.get("resource", {}).get("attributes", []))
        base = {
            "service_name": resource.get("service.name", ""),
            "service_version": resource.get("service.version", ""),
            "host_arch": resource.get("host.arch", ""),
            "os_type": resource.get("os.type", ""),
        }
        for sm in rm.get("scopeMetrics", rm.get("scopemetrics", [])):
            for metric in sm.get("metrics", []):
                metric_name = metric.get("name", "")
                for dp in get_datapoints(metric):
                    record = dict(base)
                    record["metric_name"] = metric_name
                    record["metric_value"] = dp.get("asDouble", dp.get("asInt", 0))
                    attrs = extract_attrs(dp.get("attributes", []))
                    attrs = filter_keys(attrs, METRICS_ALLOWED_ATTRS)
                    record.update(attrs)
                    flat.append(record)

    return flat if flat else [{"event_type": "unknown"}]


def extract_attrs(attrs):
    result = {}
    for a in attrs:
        key = a.get("key", "")
        val = a.get("value", {})
        result[key] = val.get(
            "stringValue",
            val.get(
                "stringvalue",
                val.get(
                    "intValue",
                    val.get(
                        "intvalue",
                        val.get(
                            "doubleValue",
                            val.get(
                                "doublevalue",
                                val.get("boolValue", val.get("boolvalue", "")),
                            ),
                        ),
                    ),
                ),
            ),
        )
    return result


def filter_keys(attrs, allowed):
    """Sanitize dots to underscores, then keep only allowed keys."""
    return {k: v for k, v in sanitize_keys(attrs).items() if k in allowed}


def sanitize_keys(d):
    return {k.replace(".", "_"): v for k, v in d.items()}


def get_body(log_record):
    body = log_record.get("body", {})
    return body.get("stringValue", body.get("stringvalue", ""))


def get_datapoints(metric):
    for key in ["sum", "gauge", "histogram", "summary"]:
        m = metric.get(key, {})
        dps = m.get("dataPoints", m.get("datapoints", []))
        if dps:
            return dps
    return []
