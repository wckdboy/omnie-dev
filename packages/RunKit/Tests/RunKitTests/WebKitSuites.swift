// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Testing

/// Suites that drive WKWebViews run one at a time: in parallel, Pyodide's start and Mermaid's
/// parse starve each other past their timeouts.
@Suite(.serialized) enum WebKitSuites {}
