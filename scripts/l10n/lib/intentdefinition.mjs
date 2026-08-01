// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}

export function parseIntentDescription(text, { id = "ctDNmu", file = "<memory>" } = {}) {
  const expression = new RegExp(
    `(<key>INIntentDescription<\\/key>\\s*<string>)([\\s\\S]*?)(<\\/string>\\s*` +
      `<key>INIntentDescriptionID<\\/key>\\s*<string>${escapeRegExp(id)}<\\/string>)`,
    "gu"
  );
  const matches = [...text.matchAll(expression)];
  if (matches.length !== 1) {
    throw new Error(`${file}: expected exactly one intent description for '${id}', found ${matches.length}`);
  }
  const match = matches[0];
  const valueStart = match.index + match[1].length;
  return {
    key: id,
    valueRaw: match[2],
    valueStart,
    valueEnd: valueStart + match[2].length
  };
}

export function replaceIntentDescription(text, value, options = {}) {
  const entry = parseIntentDescription(text, options);
  return `${text.slice(0, entry.valueStart)}${value}${text.slice(entry.valueEnd)}`;
}

export function maskIntentDescription(text, options = {}) {
  const id = options.id ?? "ctDNmu";
  return replaceIntentDescription(text, `__FLOORP_L10N_VALUE_${id}__`, options);
}
