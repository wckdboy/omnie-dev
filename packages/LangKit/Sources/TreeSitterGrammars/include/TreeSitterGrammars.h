// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0
#pragma once

// Opaque here so Swift sees OpaquePointer, matching tree-sitter's runtime API (>= 0.25).
typedef struct TSLanguage TSLanguage;

const TSLanguage *tree_sitter_javascript(void);
const TSLanguage *tree_sitter_typescript(void);
const TSLanguage *tree_sitter_tsx(void);
const TSLanguage *tree_sitter_json(void);
const TSLanguage *tree_sitter_python(void);
const TSLanguage *tree_sitter_swift(void);
const TSLanguage *tree_sitter_css(void);
const TSLanguage *tree_sitter_html(void);
