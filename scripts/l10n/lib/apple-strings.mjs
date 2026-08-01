// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

export class AppleStringsParseError extends Error {
  constructor(message, { file = "<memory>", offset = 0 } = {}) {
    super(`${file}:${offset}: ${message}`);
    this.name = "AppleStringsParseError";
    this.file = file;
    this.offset = offset;
  }
}

function decodeKey(raw) {
  let result = "";
  for (let index = 0; index < raw.length; index += 1) {
    const character = raw[index];
    if (character !== "\\") {
      result += character;
      continue;
    }

    const escaped = raw[index + 1];
    if (escaped === undefined) {
      result += character;
      continue;
    }
    index += 1;
    switch (escaped) {
      case "n": result += "\n"; break;
      case "r": result += "\r"; break;
      case "t": result += "\t"; break;
      case "\"": result += "\""; break;
      case "\\": result += "\\"; break;
      case "U": {
        const digits = raw.slice(index + 1, index + 5);
        if (/^[0-9A-Fa-f]{4}$/.test(digits)) {
          result += String.fromCharCode(Number.parseInt(digits, 16));
          index += 4;
        } else {
          result += `\\${escaped}`;
        }
        break;
      }
      default: result += escaped;
    }
  }
  return result;
}

function skipTrivia(text, start, file) {
  let index = start;
  while (index < text.length) {
    if (/\s/u.test(text[index])) {
      index += 1;
      continue;
    }
    if (text.startsWith("/*", index)) {
      const end = text.indexOf("*/", index + 2);
      if (end === -1) {
        throw new AppleStringsParseError("unterminated block comment", { file, offset: index });
      }
      index = end + 2;
      continue;
    }
    if (text.startsWith("//", index) || text[index] === "#") {
      const end = text.indexOf("\n", index + 1);
      index = end === -1 ? text.length : end + 1;
      continue;
    }
    break;
  }
  return index;
}

function readQuoted(text, start, file) {
  if (text[start] !== "\"") {
    throw new AppleStringsParseError("expected a quoted string", { file, offset: start });
  }
  let index = start + 1;
  while (index < text.length) {
    if (text[index] === "\\") {
      index += 2;
      continue;
    }
    if (text[index] === "\"") {
      return {
        raw: text.slice(start + 1, index),
        contentStart: start + 1,
        contentEnd: index,
        end: index + 1
      };
    }
    index += 1;
  }
  throw new AppleStringsParseError("unterminated quoted string", { file, offset: start });
}

export function parseAppleStrings(text, { file = "<memory>" } = {}) {
  const entries = [];
  // Keep offsets relative to the original byte-preserving JavaScript string.
  // Stripping a BOM here would shift every replacement span by one code unit.
  let index = text.charCodeAt(0) === 0xFEFF ? 1 : 0;
  while (true) {
    index = skipTrivia(text, index, file);
    if (index >= text.length) break;

    let keyRaw;
    let keyToken;
    if (text[index] === "\"") {
      const quoted = readQuoted(text, index, file);
      keyRaw = quoted.raw;
      keyToken = text.slice(index, quoted.end);
      index = quoted.end;
    } else {
      const keyStart = index;
      while (index < text.length && !/[\s=]/u.test(text[index])) index += 1;
      if (index === keyStart) {
        throw new AppleStringsParseError("expected a key", { file, offset: index });
      }
      keyRaw = text.slice(keyStart, index);
      keyToken = keyRaw;
    }

    index = skipTrivia(text, index, file);
    if (text[index] !== "=") {
      throw new AppleStringsParseError("expected '=' after key", { file, offset: index });
    }
    index = skipTrivia(text, index + 1, file);
    const value = readQuoted(text, index, file);
    index = skipTrivia(text, value.end, file);
    if (text[index] !== ";") {
      throw new AppleStringsParseError("expected ';' after value", { file, offset: index });
    }
    index += 1;

    entries.push({
      key: decodeKey(keyRaw),
      keyRaw,
      keyToken,
      valueRaw: value.raw,
      valueStart: value.contentStart,
      valueEnd: value.contentEnd
    });
  }

  return entries;
}

export function indexAppleStrings(entries, { file = "<memory>" } = {}) {
  const indexed = new Map();
  for (const entry of entries) {
    if (indexed.has(entry.key)) {
      throw new AppleStringsParseError(`duplicate key '${entry.key}'`, {
        file,
        offset: entry.valueStart
      });
    }
    indexed.set(entry.key, entry);
  }
  return indexed;
}

export function replaceAppleStringValues(text, replacements, { file = "<memory>" } = {}) {
  const entries = parseAppleStrings(text, { file });
  const indexed = indexAppleStrings(entries, { file });
  const edits = [];

  for (const [key, value] of replacements) {
    const entry = indexed.get(key);
    if (!entry) throw new AppleStringsParseError(`missing key '${key}'`, { file });
    edits.push({ start: entry.valueStart, end: entry.valueEnd, value });
  }

  edits.sort((left, right) => right.start - left.start);
  let output = text;
  for (const edit of edits) {
    output = `${output.slice(0, edit.start)}${edit.value}${output.slice(edit.end)}`;
  }
  return output;
}

export function maskAppleStringValues(text, keys, { file = "<memory>" } = {}) {
  const entries = parseAppleStrings(text, { file });
  const indexed = indexAppleStrings(entries, { file });
  const replacements = new Map();
  let index = 0;
  for (const key of keys) {
    if (!indexed.has(key)) throw new AppleStringsParseError(`missing key '${key}'`, { file });
    // Do not embed a localization key in a quoted value: keys may themselves
    // contain quotes, backslashes, or newlines.
    replacements.set(key, `__FLOORP_L10N_VALUE_${index}__`);
    index += 1;
  }
  return replaceAppleStringValues(text, replacements, { file });
}
