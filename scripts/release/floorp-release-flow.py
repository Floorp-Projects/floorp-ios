"""mitmproxy addon that records only host/URL metadata for the Floorp release.

Deliberately never records request or response bodies, headers, cookies,
tokens, or key material -- only scheme, host, path, and method are written to
the JSON output, so the trace cannot leak secrets.
"""

import json
from mitmproxy import http


class FloorpReleaseFlowRecorder:
    def __init__(self):
        self.output_path = "/tmp/floorp-release-network.json"
        self.flows = []

    def load(self, loader):
        loader.add_option(
            "floorp_output",
            str,
            "/tmp/floorp-release-network.json",
            "JSON output path for recorded flow metadata",
        )

    def request(self, flow: http.HTTPFlow) -> None:
        self.flows.append(
            {
                "method": flow.request.method,
                "scheme": flow.request.scheme,
                "host": flow.request.host,
                "port": flow.request.port,
                "path": flow.request.path,
            }
        )

    def done(self):
        with open(self.output_path, "w") as handle:
            json.dump({"schema_version": 1, "flows": self.flows}, handle, indent=2)


addons = [FloorpReleaseFlowRecorder()]
